//! Declaration specifiers and the bodies they can contain.
//!
//! `parse_specs` walks the specifier-qualifier list of one declaration and
//! leaves the cursor on the first token of the declarator. Everything the
//! specifiers name is reduced to a `@ast.CType` plus, for a storage class, a
//! `Storage`. A record or enum body is parsed here too, but is only installed
//! in the module when `commit_specs` runs: C allows the attributes that
//! change layout (`__attribute__((packed))`) to appear after the body and
//! even after the declarator, so the definition cannot be finalised earlier.

///|
/// | Start the specifier list for `struct`, `union` or `enum`, including an
/// optional tag and an optional body.
fn Cursor::parse_tagged_spec(self : Cursor, specs : Specs) -> Unit {
  let kind = if self.accept("union") {
    @ast.Union
  } else if self.at("struct") {
    let _ = self.next()
    @ast.Struct
  } else if self.accept("enum") {
    specs.is_enum = true
    @ast.Struct
  } else {
    @ast.Struct
  }
  let is_enum = specs.is_enum
  self.skip_attributes(specs.attrs)
  let mut tag = ""
  if !self.at("{") && self.peek().kind == @lex.Ident {
    tag = self.next().text
  }
  self.skip_attributes(specs.attrs)
  if self.at("{") {
    if tag == "" {
      self.anon = self.anon + 1
      tag = "__anon_\{self.anon}"
      specs.anon = true
    }
    if is_enum {
      let items = self.parse_enum_body(tag)
      specs.tag = Some(tag)
      specs.pending_items = Some(items)
    } else {
      self.module.forward_record(kind, tag)
      let fields = self.parse_record_body(kind, tag)
      specs.tag = Some(tag)
      specs.pending_fields = Some(fields)
    }
    return
  }
  if tag == "" {
    // `struct;` is not valid C and has no useful reading; fall back to void
    // so that the surrounding declaration is still parsed.
    specs.base = BVoid
    return
  }
  if is_enum {
    if !self.module.enums.contains(tag) {
      self.module.define_enum(@ast.CEnumDecl::{
        tag,
        items: [],
        complete: false,
      })
    }
    specs.tag = Some(tag)
  } else {
    self.module.forward_record(kind, tag)
    specs.tag = Some(tag)
  }
}

///|
/// | Parse `{ field; field; ... }` for a record and return its members.
fn Cursor::parse_record_body(
  self : Cursor,
  kind : @ast.RecordKind,
  tag : String,
) -> Array[@ast.CField] {
  let fields : Array[@ast.CField] = []
  let _ = self.accept("{")
  while !self.at_end() && !self.at("}") {
    // A stray `;` between members is legal (C11 6.7.2.1p1).
    if self.accept(";") {
      continue
    }
    self.skip_attributes(Attrs::new())
    let specs = Specs::new()
    let attrs = Attrs::new()
    self.parse_specs(specs, attrs)
    if specs.base == BUnset &&
      specs.tag is None &&
      specs.named is None &&
      specs.signed is None &&
      specs.short == 0 &&
      specs.long == 0 {
      self.diagnose(
        self.peek(),
        "unknown_field_type",
        "field type is missing or unsupported",
      )
    }
    self.skip_attributes(attrs)
    if self.accept(";") {
      // A declaration with no declarator inside a record: a C11 anonymous
      // struct/union member, or a tag declaration that declares nothing.
      match specs.tag {
        Some(inner) =>
          if !specs.is_enum {
            fields.push(@ast.CField::{
              name: inner,
              ty: @ast.Record(inner),
              bit_width: None,
              anonymous: true,
              align: None,
            })
          }
        None => ()
      }
      self.commit_specs(specs)
      continue
    }
    while !self.at_end() && !self.at(";") && !self.at("}") {
      let member_attrs = Attrs::new()
      let d = self.parse_declarator()
      self.skip_attributes(member_attrs)
      let mut bit_width : Int32? = None
      if self.accept(":") {
        let start = self.pos
        self.skip_constant_expression()
        let toks = self.tokens[start:self.pos].to_owned()
        bit_width = Some(
          match self.eval_const(toks) {
            Some(v) => if v < 0L { 0 } else { v.to_int() }
            None => 0
          },
        )
      }
      let mut align = member_attrs.align
      if align == None {
        align = specs.attrs.align
      }
      fields.push(@ast.CField::{
        name: d.name,
        ty: d.type_of(specs.resolve(self.platform)),
        bit_width,
        anonymous: false,
        align,
      })
      if !self.accept(",") {
        break
      }
    }
    if !self.accept(";") {
      self.diagnose(
        self.peek(),
        "missing_field_semicolon",
        "expected semicolon after field",
      )
      if !self.at_end() && !self.at("}") {
        let _ = self.next()
      }
    }
    self.commit_specs(specs)
  }
  if !self.accept("}") {
    self.diagnose(
      self.peek(),
      "unclosed_record",
      "expected closing record brace",
    )
  }
  let _ = kind
  let _ = tag
  fields
}

///|
/// | Consume tokens up to the next `,` `;` `}` that is not inside brackets.
fn Cursor::skip_constant_expression(self : Cursor) -> Unit {
  let mut depth = 0
  while !self.at_end() {
    let t = self.peek()
    if t.kind == @lex.Punct {
      match t.text {
        "(" | "[" | "{" => {
          depth = depth + 1
          let _ = self.next()
          continue
        }
        ")" | "]" | "}" => {
          if depth == 0 {
            return
          }
          depth = depth - 1
          let _ = self.next()
          continue
        }
        "," | ";" => if depth == 0 { return }
        _ => ()
      }
    }
    let _ = self.next()
  }
}

///|
/// | Parse `{ A = 1, B, ... }` and return the enumerators. Each name enters
/// the ordinary namespace immediately, so `enum { A = 1, B = A << 4 }` works
/// the way it does in a compiler.
fn Cursor::parse_enum_body(
  self : Cursor,
  tag : String,
) -> Array[@ast.CEnumItem] {
  let items : Array[@ast.CEnumItem] = []
  if !self.accept("{") {
    return items
  }
  let mut next : Int64 = 0L
  while !self.at_end() && !self.at("}") {
    let junk = Attrs::new()
    self.skip_attributes(junk)
    if self.peek().kind != @lex.Ident {
      let _ = self.next()
      continue
    }
    let name = self.next().text
    self.skip_attributes(Attrs::new())
    if self.accept("=") {
      let start = self.pos
      self.skip_constant_expression()
      let toks = self.tokens[start:self.pos].to_owned()
      match self.eval_const(toks) {
        Some(v) => next = v
        None => ()
      }
    }
    items.push(@ast.CEnumItem::{ name, value: next, })
    self.env[name] = next
    next = next + 1L
    if !self.accept(",") {
      break
    }
  }
  if !self.accept("}") {
    self.diagnose(self.peek(), "unclosed_enum", "expected closing enum brace")
  }
  let _ = tag
  items
}

///|
/// | Install anything the specifiers parsed but deferred: a record or enum
/// body, once any trailing attribute is known.
fn Cursor::commit_specs(self : Cursor, specs : Specs) -> Unit {
  match specs.tag {
    Some(tag) =>
      if specs.is_enum {
        match specs.pending_items {
          Some(items) =>
            self.module.define_enum(@ast.CEnumDecl::{
              tag,
              items,
              complete: true,
            })
          None => ()
        }
      } else {
        match specs.pending_fields {
          Some(fields) => {
            let packed = specs.attrs.packed
            let mut align = specs.attrs.align
            if packed && align == None {
              align = Some(1)
            }
            self.module.define_record(@ast.CRecordDecl::{
              tag,
              kind: match self.module.records.get(tag) {
                Some(r) => r.kind
                None => @ast.Struct
              },
              fields,
              complete: true,
              pack: if packed {
                Some(1)
              } else {
                self.pack
              },
              align,
            })
          }
          None => ()
        }
      }
    None => ()
  }
  specs.pending_fields = None
  specs.pending_items = None
}

///|
/// | Parse one specifier-qualifier list. Leaves the cursor at the declarator,
/// or at `;` when the declaration declares nothing.
fn Cursor::parse_specs(self : Cursor, specs : Specs, attrs : Attrs) -> Unit {
  while !self.at_end() {
    let t = self.peek()
    if t.kind == @lex.Pragma {
      let _ = self.next()
      continue
    }
    if t.kind == @lex.Punct {
      return
    }
    if t.kind != @lex.Ident {
      return
    }
    let text = t.text
    if text == "_Atomic" {
      self.diagnose(
        t, "unsupported_atomic", "atomic type representation is not supported",
      )
    }
    if is_attribute_keyword(text) {
      let _ = self.next()
      let inner = self.take_balanced("(", ")")
      if inner.any(tok => {
          [
            "vector_size", "__vector_size__", "mode", "ms_abi", "stdcall", "fastcall",
          ].contains(tok.text)
        }) {
        self.diagnose(
          t, "unsupported_attribute", "ABI-changing attribute is not supported",
        )
      }
      self.apply_attribute(inner, attrs)
      continue
    }
    if text == "_Static_assert" {
      let _ = self.next()
      let _ = self.take_balanced("(", ")")
      continue
    }
    if text == "__extension__" {
      let _ = self.next()
      continue
    }
    if is_declaration_noise(text) {
      let _ = self.next()
      continue
    }
    match text {
      "typedef" => {
        specs.storage = STypedef
        let _ = self.next()
      }
      "static" => {
        if specs.storage == SNone {
          specs.storage = SStatic
        }
        let _ = self.next()
      }
      "struct" | "union" => {
        if specs.tag != None || specs.named != None || specs.base != BUnset {
          return
        }
        self.parse_tagged_spec(specs)
      }
      "enum" => {
        if specs.tag != None || specs.named != None || specs.base != BUnset {
          return
        }
        specs.is_enum = true
        self.parse_tagged_spec(specs)
      }
      "void" => {
        specs.base = BVoid
        let _ = self.next()
      }
      "_Bool" | "bool" => {
        specs.base = BBool
        let _ = self.next()
      }
      "char" => {
        specs.base = BChar
        let _ = self.next()
      }
      "short" => {
        specs.short = specs.short + 1
        let _ = self.next()
      }
      "int" => {
        specs.base = BInt
        let _ = self.next()
      }
      "long" => {
        if specs.base == BDouble {
          self.diagnose(
            t, "unsupported_long_double", "long double cannot be approximated as double",
          )
        }
        specs.long = specs.long + 1
        let _ = self.next()
      }
      "float" => {
        specs.base = BFloat
        let _ = self.next()
      }
      "double" => {
        if specs.long > 0 {
          self.diagnose(
            t, "unsupported_long_double", "long double cannot be approximated as double",
          )
        }
        specs.base = BDouble
        let _ = self.next()
      }
      "signed" | "__signed" | "__signed__" => {
        specs.signed = Some(true)
        let _ = self.next()
      }
      "unsigned" | "__unsigned" | "__unsigned__" => {
        specs.signed = Some(false)
        let _ = self.next()
      }
      "_Complex" | "__complex__" => {
        self.diagnose(
          t, "unsupported_complex", "complex values cannot be approximated as scalars",
        )
        // Complex values are not part of the supported ABI surface; reading
        // the keyword keeps the declaration parseable as a plain type.
        let _ = self.next()
      }
      "__int8" | "__int16" | "__int32" | "__int64" | "__int128" => {
        // MSVC spells fixed-width integers this way. The width cannot be
        // recovered from `short`/`long`, so it is recorded outright.
        if text == "__int128" {
          self.diagnose(
            t, "unsupported_integer", "128-bit integer ABI is not supported",
          )
        }
        specs.exact_bits = Some(
          match text {
            "__int8" => 8
            "__int16" => 16
            "__int32" => 32
            _ => 64
          },
        )
        specs.base = BInt
        let _ = self.next()
      }
      _ => {
        // A typedef name used as a type specifier, or a declaration that ends
        // here because it declares nothing this parser models.
        if specs.tag == None &&
          specs.named == None &&
          specs.base == BUnset &&
          self.module.typedefs.contains(text) {
          specs.named = Some(text)
          let _ = self.next()
          continue
        }
        return
      }
    }
  }
}

///|
/// | Cheap lookahead: does a declaration start at the cursor?
fn Cursor::at_declaration_start(self : Cursor) -> Bool {
  let t = self.peek()
  if t.kind != @lex.Ident {
    return false
  }
  if is_type_keyword(t.text) ||
    is_declaration_noise(t.text) ||
    is_attribute_keyword(t.text) ||
    t.text == "typedef" ||
    t.text == "static" {
    return true
  }
  self.module.typedefs.contains(t.text)
}
