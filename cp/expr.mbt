//! Expression evaluation for `#if` and `#elif`.
//!
//! C11 6.10.1 requires constant-expression syntax with a restricted
//! grammar: no assignment, no comma, no function calls other than a small
//! set of `defined`-adjacent operators. The evaluator still has to be
//! careful about signedness, because header conditions routinely test
//! `UINT64_MAX > 0` and a signed-only evaluator gets that wrong.

///|
/// | A value in a preprocessor expression: a 64-bit two's complement word
/// and the unsignedness that decides how comparisons and `/` treat it.
struct EvalValue {
  bits : UInt64
  unsigned : Bool
}

///|
fn EvalValue::of_int(v : Int64) -> EvalValue {
  { bits: v.to_uint64(), unsigned: false, }
}

///|
fn EvalValue::truthy(self : EvalValue) -> Bool {
  self.bits != 0UL
}

///|
/// | Build the value from an `@lex.IntLiteral`'s kind.
fn EvalValue::of_literal(lit : @lex.IntLiteral) -> EvalValue {
  { bits: lit.value.to_uint64(), unsigned: !lit.ty.is_signed(), }
}

///|
/// | The state of one evaluation pass.
struct EvalCtx {
  tokens : Array[@lex.Token]
  mut pos : Int32
  macros : Map[String, Macro]
  platform : Platform
  /// Resolves an identifier that is not a target macro. The declaration
  /// parser uses it for enumerators and `sizeof` results.
  lookup : (String) -> Int64?
  mut bad : Bool
}

///|
/// | Evaluate a token list as a constant expression. Returns `None` when the
/// list is not a valid expression; `#if` then treats the condition as false
/// and records a diagnostic, the way compilers do.
pub fn evaluate(
  tokens : Array[@lex.Token],
  macros : Map[String, Macro],
  platform : Platform,
) -> Int64? {
  let ctx : EvalCtx = {
    tokens,
    pos: 0,
    macros,
    platform,
    lookup: fn(_) { None },
    bad: false,
  }
  let v = ctx.parse_conditional()
  if ctx.bad {
    return None
  }
  Some(v.bits.to_int64())
}

///|
/// | Like `evaluate`, but `lookup` resolves identifiers the target macros do
/// not cover, such as enumerators already seen in the same translation unit.
pub fn evaluate_with(
  tokens : Array[@lex.Token],
  macros : Map[String, Macro],
  platform : Platform,
  lookup : (String) -> Int64?,
) -> Int64? {
  let ctx : EvalCtx = { tokens, pos: 0, macros, platform, lookup, bad: false, }
  let v = ctx.parse_conditional()
  if ctx.bad {
    return None
  }
  Some(v.bits.to_int64())
}

///|
fn EvalCtx::peek(self : EvalCtx) -> String {
  if self.pos >= self.tokens.length() {
    ""
  } else {
    self.tokens[self.pos].text
  }
}

///|
fn EvalCtx::at_end(self : EvalCtx) -> Bool {
  self.pos >= self.tokens.length()
}

///|
fn EvalCtx::next(self : EvalCtx) -> String {
  let t = self.peek()
  self.pos = self.pos + 1
  t
}

///|
fn EvalCtx::accept(self : EvalCtx, text : String) -> Bool {
  if self.peek() == text {
    self.pos = self.pos + 1
    true
  } else {
    false
  }
}

///|
fn EvalCtx::parse_conditional(self : EvalCtx) -> EvalValue {
  let cond = self.parse_binary(0)
  if self.accept("?") {
    let a = self.parse_conditional()
    if !self.accept(":") {
      self.bad = true
    }
    let b = self.parse_conditional()
    if cond.truthy() {
      a
    } else {
      b
    }
  } else {
    cond
  }
}

///|
/// | Precedence of a binary operator, or `-1` if `op` is not one.
fn binary_precedence(op : String) -> Int32 {
  match op {
    "||" => 1
    "&&" => 2
    "|" => 3
    "^" => 4
    "&" => 5
    "==" | "!=" => 6
    "<" | ">" | "<=" | ">=" => 7
    "<<" | ">>" => 8
    "+" | "-" => 9
    "*" | "/" | "%" => 10
    _ => -1
  }
}

///|
fn EvalCtx::parse_binary(self : EvalCtx, min_prec : Int32) -> EvalValue {
  let mut lhs = self.parse_unary()
  while true {
    let op = self.peek()
    let prec = binary_precedence(op)
    if prec < min_prec {
      break
    }
    self.pos = self.pos + 1
    // `&&` and `||` short-circuit, but C still requires the right operand
    // to be syntactically valid, so it is parsed unconditionally.
    let rhs = self.parse_binary(prec + 1)
    lhs = apply_binary(op, lhs, rhs)
  }
  lhs
}

///|
fn EvalCtx::parse_unary(self : EvalCtx) -> EvalValue {
  let op = self.peek()
  match op {
    "+" => {
      self.pos = self.pos + 1
      self.parse_unary()
    }
    "-" => {
      self.pos = self.pos + 1
      let v = self.parse_unary()
      { bits: 0UL - v.bits, unsigned: v.unsigned, }
    }
    "~" => {
      self.pos = self.pos + 1
      let v = self.parse_unary()
      { bits: v.bits.lnot(), unsigned: v.unsigned, }
    }
    "!" => {
      self.pos = self.pos + 1
      let v = self.parse_unary()
      EvalValue::of_int(if v.truthy() { 0L } else { 1L })
    }
    "(" => {
      self.pos = self.pos + 1
      let v = self.parse_conditional()
      if !self.accept(")") {
        self.bad = true
      }
      v
    }
    "defined" => {
      self.pos = self.pos + 1
      let parenthesized = self.accept("(")
      let name = self.next()
      if parenthesized {
        if !self.accept(")") {
          self.bad = true
        }
      }
      EvalValue::of_int(if self.macros.contains(name) { 1L } else { 0L })
    }
    _ => self.parse_primary()
  }
}

///|
fn EvalCtx::parse_primary(self : EvalCtx) -> EvalValue {
  let t = self.peek()
  if t == "" && self.at_end() {
    self.bad = true
    return EvalValue::of_int(0L)
  }
  self.pos = self.pos + 1
  let kind = self.tokens[self.pos - 1].kind
  match kind {
    Number =>
      match @lex.parse_integer_literal(t) {
        Some(lit) => EvalValue::of_literal(lit)
        None => {
          // A floating constant in an `#if` is invalid C; treat it as zero so
          // that the rest of the expression still parses.
          self.bad = true
          EvalValue::of_int(0L)
        }
      }
    CharLit =>
      match @lex.parse_char_literal(t) {
        Some(v) => EvalValue::of_int(v)
        None => {
          self.bad = true
          EvalValue::of_int(0L)
        }
      }
    Ident =>
      // An identifier that survived macro expansion is either a leftover
      // macro name (0) or one of the target-description macros.
      match t {
        "__LP64__" | "__MOONBIND_LP64" =>
          EvalValue::of_int(
            if !self.platform.windows && self.platform.pointer_bits == 64 {
              1L
            } else {
              0L
            },
          )
        "_WIN64" | "_WIN32" | "__WIN64__" =>
          EvalValue::of_int(if self.platform.windows { 1L } else { 0L })
        "__aarch64__" | "__x86_64__" =>
          EvalValue::of_int(
            if self.platform.pointer_bits == 64 {
              1L
            } else {
              0L
            },
          )
        "__wasm32__" | "__wasm__" =>
          EvalValue::of_int(if self.platform.wasm { 1L } else { 0L })
        "__MOONBIND__" => EvalValue::of_int(1L)
        _ =>
          match (self.lookup)(t) {
            Some(v) => EvalValue::of_int(v)
            None => EvalValue::of_int(0L)
          }
      }
    _ => {
      self.bad = true
      EvalValue::of_int(0L)
    }
  }
}

///|
fn apply_binary(op : String, a : EvalValue, b : EvalValue) -> EvalValue {
  let unsigned = a.unsigned || b.unsigned
  let bool_val = fn(v : Bool) -> EvalValue {
    EvalValue::of_int(if v { 1L } else { 0L })
  }
  match op {
    "||" => bool_val(a.truthy() || b.truthy())
    "&&" => bool_val(a.truthy() && b.truthy())
    "|" => { bits: a.bits.lor(b.bits), unsigned, }
    "^" => { bits: a.bits.lxor(b.bits), unsigned, }
    "&" => { bits: a.bits.land(b.bits), unsigned, }
    "==" => bool_val(a.bits == b.bits)
    "!=" => bool_val(a.bits != b.bits)
    "<" => bool_val(compare(a, b) < 0)
    ">" => bool_val(compare(a, b) > 0)
    "<=" => bool_val(compare(a, b) <= 0)
    ">=" => bool_val(compare(a, b) >= 0)
    "<<" => {
      let shift = b.bits.to_int64().to_int()
      { bits: a.bits.lsl(shift), unsigned: a.unsigned, }
    }
    ">>" => {
      let shift = b.bits.to_int64().to_int()
      if a.unsigned {
        { bits: a.bits.lsr(shift), unsigned: true, }
      } else {
        { bits: a.bits.to_int64().asr(shift).to_uint64(), unsigned: false, }
      }
    }
    "+" => { bits: a.bits + b.bits, unsigned, }
    "-" => { bits: a.bits - b.bits, unsigned, }
    "*" => { bits: a.bits * b.bits, unsigned, }
    "/" =>
      if b.bits == 0UL {
        { bits: 0UL, unsigned, }
      } else if unsigned {
        { bits: a.bits / b.bits, unsigned: true, }
      } else {
        {
          bits: (a.bits.to_int64() / b.bits.to_int64()).to_uint64(),
          unsigned: false,
        }
      }
    "%" =>
      if b.bits == 0UL {
        { bits: 0UL, unsigned, }
      } else if unsigned {
        { bits: a.bits % b.bits, unsigned: true, }
      } else {
        {
          bits: (a.bits.to_int64() % b.bits.to_int64()).to_uint64(),
          unsigned: false,
        }
      }
    _ => a
  }
}

///|
fn compare(a : EvalValue, b : EvalValue) -> Int32 {
  if a.unsigned || b.unsigned {
    a.bits.compare(b.bits)
  } else {
    a.bits.to_int64().compare(b.bits.to_int64())
  }
}
