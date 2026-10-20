//! The translation unit.
//!
//! `parse_module` walks the preprocessed token stream and fills a `CModule`.
//! Only declarations matter to a binding generator, so function bodies,
//! initializers and `_Static_assert`s are skipped without being interpreted.

///|
/// | Entry point: parse a preprocessed translation unit.
pub fn parse_module(
  tokens : Array[@lex.Token],
  platform : @cp.Platform,
) -> @ast.CModule {
  parse_module_with_defines(tokens, [], platform)
}

///|
/// | As `parse_module`, with the integer macros the preprocessor collected.
/// Numeric `#define`s are visible to constant expressions, which is what
/// makes `#define SQLITE_MAX_LENGTH 1000000000` usable as an array bound.
pub fn parse_module_with_defines(
  tokens : Array[@lex.Token],
  defines : Array[(String, String)],
  platform : @cp.Platform,
) -> @ast.CModule {
  let module = @ast.CModule::new()
  let env : Map[String, Int64] = Map([])
  for pair in defines {
    let (name, text) = pair
    match integer_value(text) {
      Some(v) =>
        env[name] = v
      None => ()
    }
  }
  let cur : Cursor = {
    tokens,
    pos: 0,
    module,
    platform,
    env,
    anon: 0,
    pack: None,
  }
  cur.run_unit()
  module.resolve_all()
  // A `#define` with an integer body is a constant the header meant to be
  // used by name. The parser has no other place to record one, and the
  // preprocessor does not tell it the macro's type, so the narrowest type that
  // holds the value is used and the emitter decides how wide the literal is.
  //
  // A macro the header already spells as one of its enumerators is the same
  // constant twice — `SQLITE_OK` is both an enum member and a `#define` — and
  // publishing both would collide in the generated package.
  let published : Map[String, Bool] = Map([])
  for c in module.constants {
    published[c.name] = true
  }
  for pair in defines {
    let (name, text) = pair
    if published.contains(name) {
      continue
    }
    match integer_value(text) {
      Some(v) => {
        published[name] = true
        module.constants.push({
          name,
          ty: @ast.Int(@ast.CI32),
          value: v,
        })
      }
      None => ()
    }
  }
  module
}

///|
/// | Read a decimal or hexadecimal integer prefix of `text`, so a macro body
/// like `(1 << 3)` or `0x10` still contributes its literal value. Anything
/// that is not a plain integer is ignored.
fn integer_value(text : String) -> Int64? {
  let trimmed = text.trim().to_string()
  if trimmed.length() == 0 {
    return None
  }
  // A parenthesised body is unwrapped only when the whole body is the
  // integer; `(1 << 3)` has an operator and is left to `evaluate_with`.
  match @lex.parse_integer_literal(trimmed) {
    Some(lit) => Some(lit.value)
    None => None
  }
}

///|
/// | Consume declarations until the end of the token stream.
fn Cursor::run_unit(self : Cursor) -> Unit {
  while !self.at_end() {
    let start = self.pos
    self.run_one_declaration()
    // A malformed construct must not stall the walk: if a declaration parsed
    // without consuming anything, the token it stopped on is dropped. The
    // alternative is a hang on a header the tool was supposed to survive.
    if self.pos == start {
      let _ = self.next()
    }
  }
}

///|
/// | One item at file scope: a declaration, or noise to discard.
fn Cursor::run_one_declaration(self : Cursor) -> Unit {
  if self.at(";") {
    let _ = self.next()
    return
  }
  if self.peek().kind == @lex.Pragma {
    self.read_pragma(self.next().text)
    return
  }
  if self.at("extern") && self.peek_at(1).kind == @lex.Str {
    // `extern "C" { ... }` contributes its contents with C linkage, which
    // is what every declaration gets anyway.
    let _ = self.next()
    let _ = self.next()
    let _ = self.accept("{")
    return
  }
  if self.at("}") {
    // Closing brace of an `extern "C"` block.
    let _ = self.next()
    return
  }
  if self.at("_Static_assert") || self.at("static_assert") {
    let _ = self.next()
    let _ = self.take_balanced("(", ")")
    let _ = self.accept(";")
    return
  }
  if self.at("__asm__") || self.at("asm") {
    let _ = self.next()
    let _ = self.take_balanced("(", ")")
    let _ = self.accept(";")
    return
  }
  if !self.at_declaration_start() {
    // Unknown construct at file scope. Skipping to the next `;` keeps the
    // rest of the header parseable instead of failing the whole run.
    self.skip_to_semicolon()
    return
  }
  self.parse_declaration()
}

///|
/// | `#pragma pack` reaches the parser as a token whose text is the new value,
/// or empty when packing was restored to the natural alignment.
fn Cursor::read_pragma(self : Cursor, text : String) -> Unit {
  if text == "" {
    self.pack = None
  } else {
    match @lex.parse_integer_literal(text) {
      Some(lit) => self.pack = Some(lit.value.to_int())
      None => ()
    }
  }
}

///|
/// | Advance to just after the next `;` at bracket depth zero.
fn Cursor::skip_to_semicolon(self : Cursor) -> Unit {
  let mut depth = 0
  while !self.at_end() {
    let t = self.next()
    if t.kind != @lex.Punct {
      continue
    }
    match t.text {
      "(" | "[" | "{" => depth = depth + 1
      ")" | "]" | "}" => {
        if depth == 0 {
          return
        }
        depth = depth - 1
      }
      ";" => if depth == 0 { return }
      _ => ()
    }
  }
}

///|
/// | One declaration: specifiers, then one or more declarators.
fn Cursor::parse_declaration(self : Cursor) -> Unit {
  let specs = Specs::new()
  let attrs = Attrs::new()
  self.parse_specs(specs, attrs)
  self.skip_attributes(attrs)
  if self.accept(";") {
    // `struct S { ... };` declares the tag and nothing else.
    self.commit_specs(specs)
    return
  }
  let mut first = true
  while !self.at_end() {
    // `__attribute__` before the declarator applies to the declaration; the
    // only layout-relevant case is on a record, which the specifiers own.
    let attrs2 = Attrs::new()
    self.skip_attributes(attrs2)
    let d = self.parse_declarator()
    let trailing = Attrs::new()
    self.skip_attributes(trailing)
    if first {
      // The specifier list is finished only now: a trailing attribute may
      // still mark the record `packed`.
      self.commit_specs(specs)
      first = false
    }
    self.record_declarator(specs, d)
    if self.at("{") {
      // A function definition: the body is irrelevant, and so is everything
      // it declares.
      self.skip_braces()
      return
    }
    if self.accept("=") {
      self.skip_initializer()
    }
    if !self.accept(",") {
      break
    }
  }
  let _ = self.accept(";")
}

///|
/// | File what a declarator declared.
fn Cursor::record_declarator(
  self : Cursor,
  specs : Specs,
  d : Declarator,
) -> Unit {
  let base = specs.resolve(self.platform)
  match specs.storage {
    STypedef => {
      let mut ty = d.type_of(base)
      // `typedef struct { ... } Name;` names the record with the typedef.
      // Anonymous tags exist only to key the table, so adopting the typedef
      // name makes the generated binding read naturally.
      if specs.anon {
        match ty {
          @ast.Record(tag) => {
            let name = d.name
            self.module.rename_record(tag, name)
            ty = @ast.Record(name)
          }
          @ast.EnumType(tag) => {
            let name = d.name
            self.module.rename_enum(tag, name)
            ty = @ast.EnumType(name)
          }
          _ => ()
        }
      }
      self.module.add_typedef(@ast.CTypedef::{ name: d.name, ty, })
    }
    SStatic =>
      // A `static` declaration is not part of the ABI. A `static` function
      // definition was already skipped by the caller.
      ()
    SNone =>
      match d.fn_signature() {
        Some((params, variadic)) =>
          self.module.add_function(@ast.CFnDecl::{
            name: d.name,
            ret: d.ret_of(base),
            params: decay_params(params),
            variadic,
            internal: false,
          })
        None => self.record_variable(d, base)
      }
  }
}

///|
/// | A file-scope object. `extern int errno;` and `char *optarg;` declare
/// storage the binding does not own, and a tentative definition has no value
/// to import, so neither becomes part of the module. The hook exists so that
/// `moonbind` can start exporting objects once there is a way to bind them.
fn Cursor::record_variable(
  self : Cursor,
  d : Declarator,
  base : @ast.CType,
) -> Unit {
  let _ = d.type_of(base)
}

///|
/// | Skip an initializer: a balanced `{ ... }` or a run up to the next `,`
/// or `;` at depth zero.
fn Cursor::skip_initializer(self : Cursor) -> Unit {
  if self.at("{") {
    self.skip_braces()
    return
  }
  let mut depth = 0
  while !self.at_end() {
    let t = self.peek()
    if t.kind == @lex.Punct {
      match t.text {
        "(" | "[" | "{" => depth = depth + 1
        ")" | "]" | "}" => {
          if depth == 0 {
            return
          }
          depth = depth - 1
        }
        "," | ";" => if depth == 0 { return }
        _ => ()
      }
    }
    let _ = self.next()
  }
}

///|
/// | Skip a balanced `{ ... }` block.
fn Cursor::skip_braces(self : Cursor) -> Unit {
  let mut depth = 0
  while !self.at_end() {
    let t = self.next()
    if t.kind != @lex.Punct {
      continue
    }
    if t.text == "{" {
      depth = depth + 1
    } else if t.text == "}" {
      depth = depth - 1
      if depth <= 0 {
        return
      }
    }
  }
}
