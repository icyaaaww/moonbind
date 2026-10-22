//! Token cursor and attribute handling.
//!
//! The declaration parser never rewinds and never builds a separate AST for
//! expressions: everything it needs from a constant expression (array bound,
//! bitfield width, enumerator value) is evaluated in place by handing the
//! token range to the preprocessor's evaluator.

///|
/// | The parser's progress through the preprocessed translation unit.
struct Cursor {
  tokens : Array[@lex.Token]
  mut pos : Int32
  module : @ast.CModule
  platform : @cp.Platform
  /// Enumerator values and integer `#define`s visible to constant
  /// expressions, in C's ordinary scope.
  env : Map[String, Int64]
  /// Counter for synthesising tags for anonymous records and enums.
  mut anon : Int32
  /// The `#pragma pack` value in effect at the cursor, in bytes.
  mut pack : Int32?
}

///|
/// | Attributes accumulated on a record, member or declaration.
struct Attrs {
  mut packed : Bool
  /// Alignment override in bytes, from `aligned(n)` or `_Alignas(n)`.
  mut align : Int32?
}

///|
/// | An empty attribute set.
fn Attrs::new() -> Attrs {
  { packed: false, align: None, }
}

///|
/// | Storage class of a declaration, reduced to the two cases moonbind cares
/// about: `typedef` creates a name, `static` removes a name from the ABI.
/// `extern`, `auto`, `register` and `inline` are accepted and ignored.
enum Storage {
  SNone
  STypedef
  SStatic
} derive(Eq)

///|
/// | Which base type the specifiers name, before `short`/`long`/signedness
/// are folded in.
enum Base {
  /// No type specifier seen yet. With a storage class present this means
  /// C89's implicit `int`.
  BUnset
  BVoid
  BBool
  BChar
  BInt
  BFloat
  BDouble
} derive(Eq)

///|
/// | The declaration specifiers collected so far.
struct Specs {
  mut storage : Storage
  mut base : Base
  /// `None` means no signedness keyword was given, which decides whether a
  /// plain `char` is signed.
  mut signed : Bool?
  mut short : Int32
  mut long : Int32
  /// Width in bits when the type was named outright (`__int24`, `_Float32`)
  /// and cannot be recovered from `short`/`long`.
  mut exact_bits : Int32?
  /// A typedef name or other identifier used as a type specifier.
  mut named : String?
  /// The record or enum tag named by an inline definition.
  mut tag : String?
  mut is_enum : Bool
  /// Attributes that belong to a record defined in these specifiers.
  attrs : Attrs
  /// Members of a record body parsed by these specifiers but not yet
  /// registered: a trailing `__attribute__` may still change its layout, so
  /// the record is only defined when the specifier list ends.
  mut pending_fields : Array[@ast.CField]?
  /// Enumerators of a body parsed by these specifiers, held for the same
  /// reason.
  mut pending_items : Array[@ast.CEnumItem]?
  /// True when the tag was synthesised for a definition without a name.
  mut anon : Bool
}

///|
/// | Empty specifiers.
fn Specs::new() -> Specs {
  {
    storage: SNone,
    base: BUnset,
    signed: None,
    short: 0,
    long: 0,
    exact_bits: None,
    named: None,
    tag: None,
    is_enum: false,
    attrs: Attrs::new(),
    pending_fields: None,
    pending_items: None,
    anon: false,
  }
}

///|
/// | The type these specifiers name.
fn Specs::resolve(self : Specs, platform : @cp.Platform) -> @ast.CType {
  match self.tag {
    Some(tag) =>
      if self.is_enum {
        @ast.EnumType(tag)
      } else {
        @ast.Record(tag)
      }
    None =>
      match self.named {
        Some(name) => @ast.Named(name)
        None => self.resolve_base(platform)
      }
  }
}

///|
/// | Fold `short`, `long` and the signedness keyword into an integer kind.
fn Specs::resolve_base(self : Specs, platform : @cp.Platform) -> @ast.CType {
  let unsigned_ = self.signed == Some(false)
  match self.base {
    BUnset | BInt => {
      // `long` is 64 bits on LP64 and 32 bits on LLP64 (Windows) and on any
      // 32-bit target. `long long` is 64 bits everywhere.
      let long_bits = if platform.windows || platform.pointer_bits <= 32 {
        32
      } else {
        64
      }
      let bits = match self.exact_bits {
        Some(b) => b
        None =>
          if self.short > 0 {
            16
          } else if self.long >= 2 {
            64
          } else if self.long == 1 {
            long_bits
          } else {
            32
          }
      }
      @ast.Int(int_kind(bits, unsigned_))
    }
    BChar => @ast.Int(int_kind(8, unsigned_))
    BBool => @ast.Int(@ast.CU8)
    BVoid => @ast.Void
    BFloat => @ast.Float(@ast.F32)
    // `long double` is 80 bits on x86 but is passed and stored as 16 bytes;
    // modelling it as `double` matches how MoonBit and wasm treat it.
    BDouble => @ast.Float(@ast.F64)
  }
}

///|
/// | The integer kind of the given width and signedness.
fn int_kind(bits : Int32, unsigned_ : Bool) -> @ast.CIntKind {
  match (bits, unsigned_) {
    (8, false) => @ast.CI8
    (8, true) => @ast.CU8
    (16, false) => @ast.CI16
    (16, true) => @ast.CU16
    (32, false) => @ast.CI32
    (32, true) => @ast.CU32
    (_, false) => @ast.CI64
    (_, true) => @ast.CU64
  }
}

///|
/// | Keywords that may start a declaration specifier list.
fn is_type_keyword(name : String) -> Bool {
  match name {
    "void"
    | "char"
    | "short"
    | "int"
    | "long"
    | "float"
    | "double"
    | "signed"
    | "unsigned"
    | "_Bool"
    | "bool"
    | "struct"
    | "union"
    | "enum"
    | "_Complex"
    | "__int8"
    | "__int16"
    | "__int32"
    | "__int64"
    | "__int128"
    | "__signed"
    | "__signed__"
    | "__unsigned"
    | "__unsigned__"
    | "__complex__" => true
    _ => false
  }
}

///|
/// | Keywords that are consumed and discarded wherever they appear.
fn is_declaration_noise(name : String) -> Bool {
  match name {
    "const"
    | "volatile"
    | "restrict"
    | "__restrict"
    | "__restrict__"
    | "__const"
    | "__const__"
    | "__volatile"
    | "__volatile__"
    | "extern"
    | "auto"
    | "register"
    | "inline"
    | "__inline"
    | "__inline__"
    | "_Thread_local"
    | "__thread"
    | "_Noreturn" => true
    _ => false
  }
}

///|
/// | Whether a token sequence is a `__attribute__`-style attribute keyword.
fn is_attribute_keyword(name : String) -> Bool {
  match name {
    "__attribute__"
    | "__attribute"
    | "__declspec"
    | "_Alignas"
    | "__alignof__" => true
    _ => false
  }
}

// ---------------------------------------------------------------------------
// Cursor primitives
// ---------------------------------------------------------------------------

///|
fn Cursor::peek(self : Cursor) -> @lex.Token {
  if self.pos >= self.tokens.length() {
    self.tokens[self.tokens.length() - 1]
  } else {
    self.tokens[self.pos]
  }
}

///|
fn Cursor::peek_at(self : Cursor, offset : Int32) -> @lex.Token {
  let i = self.pos + offset
  if i >= self.tokens.length() {
    self.tokens[self.tokens.length() - 1]
  } else {
    self.tokens[i]
  }
}

///|
fn Cursor::at_end(self : Cursor) -> Bool {
  self.peek().kind == @lex.Eof
}

///|
fn Cursor::next(self : Cursor) -> @lex.Token {
  let t = self.peek()
  if self.pos < self.tokens.length() {
    self.pos = self.pos + 1
  }
  t
}

///|
fn Cursor::at(self : Cursor, text : String) -> Bool {
  self.peek().text == text
}

///|
fn Cursor::accept(self : Cursor, text : String) -> Bool {
  if self.at(text) {
    let _ = self.next()
    true
  } else {
    false
  }
}

///|
/// | Consume everything up to and including `close`, returning the tokens in
/// between. Used for attribute lists, array bounds and initializers, where
/// the contents are either re-evaluated later or ignored.
fn Cursor::take_balanced(
  self : Cursor,
  open : String,
  close : String,
) -> Array[@lex.Token] {
  let inner : Array[@lex.Token] = []
  if !self.accept(open) {
    return inner
  }
  let mut depth = 1
  while !self.at_end() {
    let t = self.next()
    if t.text == open {
      depth = depth + 1
    } else if t.text == close {
      depth = depth - 1
      if depth == 0 {
        break
      }
    }
    inner.push(t)
  }
  if depth != 0 {
    self.diagnose(self.peek(), "unclosed_group", "expected closing " + close)
  }
  inner
}

///|
/// | Skip qualifiers that appear after a `*` or between specifiers.
fn Cursor::skip_type_qualifiers(self : Cursor) -> Unit {
  while true {
    let t = self.peek()
    if t.kind != @lex.Ident {
      return
    }
    if t.text == "const" ||
      t.text == "volatile" ||
      t.text == "restrict" ||
      t.text == "__restrict" ||
      t.text == "__restrict__" ||
      t.text == "__const" ||
      t.text == "__const__" ||
      t.text == "__volatile" ||
      t.text == "__volatile__" ||
      t.text == "_Atomic" {
      if t.text == "_Atomic" {
        self.diagnose(
          t, "unsupported_atomic", "atomic qualifiers are not supported",
        )
      }
      let _ = self.next()
    } else {
      return
    }
  }
}

///|
/// | Consume any run of attributes and record the ones moonbind understands.
/// `aligned(n)` sets an alignment override, `packed` sets packing. Malformed
/// attribute contents are ignored rather than reported: a header that uses a
/// vendor attribute never changes the ABI of the declarations around it.
fn Cursor::skip_attributes(self : Cursor, attrs : Attrs) -> Unit {
  while !self.at_end() {
    let t = self.peek()
    if t.kind == @lex.Ident && is_attribute_keyword(t.text) {
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
    if t.kind == @lex.Ident &&
      (t.text == "__extension__" || t.text == "_Static_assert") {
      let _ = self.next()
      if t.text == "_Static_assert" {
        let _ = self.take_balanced("(", ")")
      }
      continue
    }
    // `__asm__("...")` after a declarator renames the symbol. The name is
    // not recoverable from the generated binding, which uses the C
    // identifier, so the assembler label is dropped.
    if t.kind == @lex.Ident && (t.text == "__asm__" || t.text == "asm") {
      self.diagnose(
        t, "symbol_alias", "assembler symbol renaming is not supported",
      )
      let save = self.pos
      let _ = self.next()
      if self.at("(") {
        let _ = self.take_balanced("(", ")")
        continue
      }
      self.pos = save
      return
    }
    return
  }
}

///|
/// | Interpret one attribute list. Only `packed`, `align`/`aligned(n)` and
/// `__declspec(align(n))` affect layout.
fn Cursor::apply_attribute(
  self : Cursor,
  inner : Array[@lex.Token],
  attrs : Attrs,
) -> Unit {
  let mut i = 0
  while i < inner.length() {
    let t = inner[i]
    if t.kind != @lex.Ident {
      i = i + 1
      continue
    }
    match t.text {
      "packed" | "__packed__" | "__packed" => attrs.packed = true
      "align" | "aligned" | "__aligned__" => {
        // `aligned(n)`; a bare `aligned` means the maximum useful alignment.
        if i + 1 < inner.length() && inner[i + 1].text == "(" {
          let mut j = i + 2
          let mut value = 0L
          while j < inner.length() && inner[j].text != ")" {
            match @lex.parse_integer_literal(inner[j].text) {
              Some(lit) => value = lit.value
              None => ()
            }
            j = j + 1
          }
          attrs.align = Some(if value <= 0L { 16 } else { value.to_int() })
          i = j + 1
          continue
        }
        attrs.align = Some(16)
      }
      _ => ()
    }
    i = i + 1
  }
}

///|
/// | Read one integer from a token list, or `None`.
fn literal_of(toks : Array[@lex.Token]) -> Int64? {
  if toks.length() == 1 {
    match @lex.parse_integer_literal(toks[0].text) {
      Some(v) => Some(v.value)
      None =>
        match @lex.parse_char_literal(toks[0].text) {
          Some(v) => Some(v)
          None => None
        }
    }
  } else {
    None
  }
}

///|
fn Cursor::diagnose(
  self : Cursor,
  token : @lex.Token,
  code : String,
  message : String,
) -> Unit {
  self.module.diagnostics.push({
    code,
    file: token.file,
    line: token.line,
    column: token.col,
    token: token.text,
    message,
  })
}
