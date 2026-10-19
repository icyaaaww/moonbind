//! A C tokenizer.
//!
//! The preprocessor and the declaration parser share this lexer. It emits
//! `Newline` tokens so that the preprocessor can tell where a directive ends;
//! the parser drops them later. Translation phases 1 and 3 are applied here:
//! backslash-newline splicing and comment removal.

///|
/// | Token categories. The preprocessor only cares about the spelling, so
/// `Number`, `Str` and `CharLit` are kept apart from `Ident` and `Punct`
/// purely to make the parser's job easier.
pub(all) enum TokKind {
  Ident
  Number
  Str
  CharLit
  Punct
  Newline
  Eof
  /// Produced only by the preprocessor, never by the scanner: a `#pragma`
  /// that survives into the declaration stream (`pack(n)`).
  Pragma
} derive(Debug, Eq)

///|
/// | One token with its physical source position. `file` is the path the
/// token came from, which stays meaningful after headers are spliced
/// together.
pub(all) struct Token {
  pub kind : TokKind
  pub text : String
  pub line : Int32
  pub col : Int32
  pub file : String
  /// True when whitespace or a comment separated this token from the
  /// previous one. The preprocessor needs it to tell `#define F(x)` from
  /// `#define F (x)`, which differ in meaning but not in spelling.
  pub space_before : Bool
} derive(Debug)

///|
fn is_digit(c : Int32) -> Bool {
  c >= 48 && c <= 57
}

///|
fn is_hex(c : Int32) -> Bool {
  (c >= 48 && c <= 57) || (c >= 97 && c <= 102) || (c >= 65 && c <= 70)
}

///|
fn is_ident_start(c : Int32) -> Bool {
  (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || c == 95 || c >= 128
}

///|
fn is_ident_char(c : Int32) -> Bool {
  is_ident_start(c) || is_digit(c)
}

///|
/// | Punctuators, longest first so that a greedy scan picks `<<=` before
/// `<<` before `<`.
let punctators : Array[String] = [
  "...", "<<=", ">>=", "->", "++", "--", "<<", ">>", "<=", ">=", "==", "!=", "&&",
  "||", "*=", "/=", "%=", "+=", "-=", "&=", "^=", "|=", "##", "::", "<:", ":>", "<%",
  "%>",
]

///|
/// | The scanning state. Positions are UTF-16 indices into the source string.
pub(all) struct Lexer {
  src : String
  file : String
  mut pos : Int32
  mut line : Int32
  mut col : Int32
  mut last_end : Int32
}

///|
/// | Create a lexer over `src`.
pub fn Lexer::new(src : String) -> Lexer {
  { src, file: "", pos: 0, line: 1, col: 1, last_end: 0, }
}

///|
/// | Create a lexer over `src` that tags every token with `file`.
pub fn Lexer::with_file(src : String, file : String) -> Lexer {
  { src, file, pos: 0, line: 1, col: 1, last_end: 0, }
}

///|
fn Lexer::tok(
  self : Lexer,
  kind : TokKind,
  text : String,
  line : Int32,
  col : Int32,
) -> Token {
  let start = self.pos - text.length()
  let space_before = start != self.last_end
  self.last_end = self.pos
  { kind, text, line, col, file: self.file, space_before, }
}

///|
fn Lexer::peek(self : Lexer, offset : Int32) -> Int32 {
  let i = self.pos + offset
  if i >= self.src.length() {
    -1
  } else {
    self.src[i].to_int()
  }
}

///|
/// | Consume one unit and return it, or `-1` at end of input.
fn Lexer::bump(self : Lexer) -> Int32 {
  let c = self.peek(0)
  if c == -1 {
    return -1
  }
  if c == 10 {
    self.line = self.line + 1
    self.col = 1
  } else {
    self.col = self.col + 1
  }
  self.pos = self.pos + 1
  c
}

///|
/// | Skip a backslash-newline pair if one starts at the current position.
/// Splicing happens before tokenization, but doing it lazily keeps the source
/// buffer unmodified and the line numbers honest.
fn Lexer::skip_splice(self : Lexer) -> Bool {
  if self.peek(0) == 92 {
    if self.peek(1) == 10 {
      let _ = self.bump()
      let _ = self.bump()
      return true
    }
    if self.peek(1) == 13 && self.peek(2) == 10 {
      let _ = self.bump()
      let _ = self.bump()
      let _ = self.bump()
      return true
    }
  }
  false
}

///|
/// | Tokenize the whole input, appending an `Eof` token.
pub fn Lexer::run(self : Lexer) -> Array[Token] {
  let out : Array[Token] = []
  while true {
    if self.skip_splice() {
      continue
    }
    let c = self.peek(0)
    let start_line = self.line
    let start_col = self.col
    if c == -1 {
      out.push(self.tok(Eof, "", start_line, start_col))
      break
    }
    if c == 10 {
      out.push(self.tok(Newline, "\n", start_line, start_col))
      let _ = self.bump()
      continue
    }
    if c == 32 || c == 9 || c == 11 || c == 12 || c == 13 {
      let _ = self.bump()
      continue
    }
    if c == 47 && self.peek(1) == 47 {
      while true {
        let d = self.peek(0)
        if d == -1 || d == 10 {
          break
        }
        let _ = self.bump()
      }
      continue
    }
    if c == 47 && self.peek(1) == 42 {
      let _ = self.bump()
      let _ = self.bump()
      while true {
        let d = self.peek(0)
        if d == -1 {
          break
        }
        if d == 42 && self.peek(1) == 47 {
          let _ = self.bump()
          let _ = self.bump()
          break
        }
        let _ = self.bump()
      }
      continue
    }
    if is_ident_start(c) {
      let start = self.pos
      while is_ident_char(self.peek(0)) {
        let _ = self.bump()
      }
      let text = self.src[start:self.pos].to_owned()
      // A string or character literal may carry a `L`, `u`, `U` or `u8`
      // prefix. Fold the prefix into the literal token.
      let prefixed = text == "L" || text == "u" || text == "U" || text == "u8"
      if self.peek(0) == 34 && prefixed {
        let lit_start = start
        let _ = self.bump()
        while true {
          let d = self.peek(0)
          if d == -1 || d == 10 {
            break
          }
          if d == 92 {
            let _ = self.bump()
            let _ = self.bump()
            continue
          }
          let _ = self.bump()
          if d == 34 {
            break
          }
        }
        out.push(
          self.tok(
            Str,
            self.src[lit_start:self.pos].to_owned(),
            start_line,
            start_col,
          ),
        )
      } else {
        out.push(self.tok(Ident, text, start_line, start_col))
      }
      continue
    }
    if is_digit(c) || (c == 46 && is_digit(self.peek(1))) {
      let start = self.pos
      let hex = c == 48 && (self.peek(1) == 120 || self.peek(1) == 88)
      if hex {
        let _ = self.bump()
        let _ = self.bump()
        while is_hex(self.peek(0)) || self.peek(0) == 46 {
          let _ = self.bump()
        }
        if self.peek(0) == 112 || self.peek(0) == 80 {
          let _ = self.bump()
          if self.peek(0) == 43 || self.peek(0) == 45 {
            let _ = self.bump()
          }
          while is_digit(self.peek(0)) {
            let _ = self.bump()
          }
        }
      } else {
        while is_digit(self.peek(0)) {
          let _ = self.bump()
        }
        if self.peek(0) == 46 {
          let _ = self.bump()
          while is_digit(self.peek(0)) {
            let _ = self.bump()
          }
        }
        if self.peek(0) == 101 || self.peek(0) == 69 {
          let _ = self.bump()
          if self.peek(0) == 43 || self.peek(0) == 45 {
            let _ = self.bump()
          }
          while is_digit(self.peek(0)) {
            let _ = self.bump()
          }
        }
      }
      // Integer and floating suffixes (`u`, `L`, `f`, `ULL`, ...).
      while is_ident_char(self.peek(0)) {
        let _ = self.bump()
      }
      out.push(
        self.tok(
          Number,
          self.src[start:self.pos].to_owned(),
          start_line,
          start_col,
        ),
      )
      continue
    }
    if c == 34 {
      let start = self.pos
      let _ = self.bump()
      while true {
        let d = self.peek(0)
        if d == -1 || d == 10 {
          break
        }
        if d == 92 {
          let _ = self.bump()
          let _ = self.bump()
          continue
        }
        let _ = self.bump()
        if d == 34 {
          break
        }
      }
      out.push(
        self.tok(
          Str,
          self.src[start:self.pos].to_owned(),
          start_line,
          start_col,
        ),
      )
      continue
    }
    if c == 39 {
      let start = self.pos
      let _ = self.bump()
      while true {
        let d = self.peek(0)
        if d == -1 || d == 10 {
          break
        }
        if d == 92 {
          let _ = self.bump()
          let _ = self.bump()
          continue
        }
        let _ = self.bump()
        if d == 39 {
          break
        }
      }
      out.push(
        self.tok(
          CharLit,
          self.src[start:self.pos].to_owned(),
          start_line,
          start_col,
        ),
      )
      continue
    }
    let mut matched = false
    for p in punctators {
      if self.starts_with(p) {
        for _ in 0..<p.length() {
          let _ = self.bump()
        }
        out.push(self.tok(Punct, p, start_line, start_col))
        matched = true
        break
      }
    }
    if matched {
      continue
    }
    // Any single character that is not part of a longer punctuator stands
    // for itself. Unknown bytes are passed through so that the parser can
    // report them with a position instead of the lexer silently eating them.
    let start = self.pos
    let _ = self.bump()
    out.push(
      self.tok(
        Punct,
        self.src[start:self.pos].to_owned(),
        start_line,
        start_col,
      ),
    )
  }
  out
}

///|
fn Lexer::starts_with(self : Lexer, pat : String) -> Bool {
  if self.pos + pat.length() > self.src.length() {
    return false
  }
  self.src[self.pos:self.pos + pat.length()] == pat
}

///|
/// | Convenience wrapper: tokenize a whole buffer.
pub fn tokenize(src : String) -> Array[Token] {
  Lexer::new(src).run()
}

///|
/// | Drop newline tokens. Used by the parser after preprocessing.
pub fn strip_newlines(tokens : Array[Token]) -> Array[Token] {
  tokens.filter(t => t.kind != Newline)
}

///|
/// | Decode the body of a C string or character literal, including the
/// surrounding quotes. Unknown escapes are kept verbatim so that a bad escape
/// survives to the code generator rather than silently changing meaning.
pub fn decode_literal(raw : String) -> String {
  let n = raw.length()
  if n < 2 {
    return raw
  }
  let out = StringBuilder()
  let mut i = 1
  let last = n - 1
  while i < last {
    let c = raw[i].to_int()
    if c != 92 {
      out.write_char(Char::from_int(c))
      i = i + 1
      continue
    }
    i = i + 1
    if i >= last {
      break
    }
    let e = raw[i].to_int()
    i = i + 1
    match e {
      110 => out.write_char('\n') // n
      116 => out.write_char('\t') // t
      114 => out.write_char('\r') // r
      48 => out.write_char('\u{0}') // 0
      92 => out.write_char('\\')
      39 => out.write_char('\'')
      34 => out.write_char('"')
      97 => out.write_char('\u{7}') // a
      98 => out.write_char('\u{8}') // b
      102 => out.write_char('\u{c}') // f
      118 => out.write_char('\u{b}') // v
      63 => out.write_char('?')
      120 => {
        // \xHH
        let mut v = 0
        let mut digits = 0
        while digits < 2 && i < last {
          let h = raw[i].to_int()
          if !is_hex(h) {
            break
          }
          v = v * 16 + hex_value(h)
          i = i + 1
          digits = digits + 1
        }
        out.write_char(Char::from_int(v))
      }
      117 => {
        // \uXXXX
        let mut v = 0
        let mut digits = 0
        while digits < 4 && i < last {
          let h = raw[i].to_int()
          if !is_hex(h) {
            break
          }
          v = v * 16 + hex_value(h)
          i = i + 1
          digits = digits + 1
        }
        out.write_char(Char::from_int(v))
      }
      _ =>
        if e >= 48 && e <= 55 {
          // Up to three octal digits, counting the one already read.
          let mut v = e - 48
          let mut digits = 1
          while digits < 3 && i < last {
            let o = raw[i].to_int()
            if o < 48 || o > 55 {
              break
            }
            v = v * 8 + (o - 48)
            i = i + 1
            digits = digits + 1
          }
          out.write_char(Char::from_int(v))
        } else {
          out.write_char('\\')
          out.write_char(Char::from_int(e))
        }
    }
  }
  out.to_string()
}

///|
fn hex_value(c : Int32) -> Int32 {
  if c >= 48 && c <= 57 {
    c - 48
  } else if c >= 97 && c <= 102 {
    c - 87
  } else {
    c - 55
  }
}
