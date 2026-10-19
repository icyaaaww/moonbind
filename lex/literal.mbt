//! Parsing and folding of C integer literals.
//!
//! Both the preprocessor (`#if FOO > 3`) and the declaration parser (array
//! bounds, enumerator values, bitfield widths) need to turn a token such as
//! `0x7fffffffUL` into a number. The rules follow C11 6.4.4.1: a literal's
//! suffix fixes its candidate type list, the base comes from its prefix, and
//! the first candidate that can represent the value wins.

///|
/// | A parsed integer literal: its value and the C type it would have.
pub(all) struct IntLiteral {
  pub value : Int64
  pub ty : @ast.CIntKind
} derive(Debug, Eq)

///|
/// | Parse a C integer literal (prefix and suffix included). Returns `None`
/// for a token that is not a valid integer constant, which is how the
/// expression evaluator rejects floating point values in integer contexts.
pub fn parse_integer_literal(text : String) -> IntLiteral? {
  let n = text.length()
  if n == 0 {
    return None
  }
  let mut i = 0
  let mut base = 10
  if n >= 2 && text[0] == '0' {
    let c1 = text[1]
    if c1 == 'x' || c1 == 'X' {
      base = 16
      i = 2
    } else if c1 == 'b' || c1 == 'B' {
      base = 2
      i = 2
    } else {
      base = 8
    }
  }
  let digits_start = i
  let mut value : Int64 = 0L
  let mut any = false
  while i < n {
    let c = text[i]
    let d = match c {
      '0'..<='9' => c.to_int() - 48
      'a'..<='f' => c.to_int() - 87
      'A'..<='F' => c.to_int() - 55
      _ => -1
    }
    if d < 0 || d >= base {
      break
    }
    value = value * Int64::from_int(base) + Int64::from_int(d)
    any = true
    i = i + 1
  }
  if !any {
    return None
  }
  // Suffixes, case-insensitive, in either order for `u` and `l`.
  let suffix = text[i:n].to_owned()
  let lower = suffix.to_lower()
  let mut unsigned = false
  let mut longs = 0
  for ch in lower {
    match ch {
      'u' => unsigned = true
      'l' => longs = longs + 1
      _ => return None
    }
  }
  let ty = choose_int_kind(value, base, unsigned, longs)
  Some({ value, ty, })
}

///|
/// | The C11 6.4.4.1 candidate lists, reduced to the widths this binder
/// models. `long` is 64 bits on every platform moonbind targets except
/// 32-bit Windows; `int` is 32 bits everywhere.
fn choose_int_kind(
  value : Int64,
  base : Int32,
  unsigned : Bool,
  longs : Int32,
) -> @ast.CIntKind {
  let fits_i32 = value >= 0L && value <= 2147483647L
  let fits_u32 = value >= 0L && value <= 4294967295L
  if unsigned {
    if longs == 0 && fits_u32 {
      if base == 10 {
        @ast.CU32
      } else {
        @ast.CU32
      }
    } else {
      @ast.CU64
    }
  } else if base == 10 {
    if fits_i32 {
      @ast.CI32
    } else {
      @ast.CI64
    }
  } else if fits_i32 {
    @ast.CI32
  } else if fits_u32 {
    @ast.CU32
  } else {
    @ast.CI64
  }
}

///|
/// | Decode a character literal such as `'a'` or `'\n'` to its integer
/// value. Multi-character literals are folded as GCC does (shift and add),
/// which is what real headers rely on for values like `'ABCD'`.
pub fn parse_char_literal(text : String) -> Int64? {
  if text.length() < 3 {
    return None
  }
  let body = decode_literal(text)
  if body == "" {
    return None
  }
  let chars = body.to_array()
  let mut v : Int64 = 0L
  for c in chars {
    v = v * 256L + Int64::from_int(c.to_int())
  }
  Some(v)
}
