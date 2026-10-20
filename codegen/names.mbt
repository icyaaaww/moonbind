//! Names: what a C identifier becomes in MoonBit.
//!
//! C and MoonBit disagree about almost everything in a name. C is
//! case-sensitive but has no case discipline; MoonBit demands `PascalCase` for
//! types, lower case for values, and `UPPER_SNAKE` for `const`. C lets a name
//! begin with an underscore; MoonBit does not. C keywords and MoonBit keywords
//! are different sets, and a name may be reserved in one language but not the
//! other.
//!
//! Everything here is a pure function of its input so that the generated
//! module is byte-identical between runs.

///|
/// | MoonBit keywords and reserved words that cannot appear as a declared
/// | name. A C identifier that is one of these gets a trailing underscore.
let moonbit_keywords : Map[String, Bool] = Map::from_array([
  ("fn", true),
  ("let", true),
  ("mut", true),
  ("if", true),
  ("else", true),
  ("match", true),
  ("for", true),
  ("while", true),
  ("in", true),
  ("is", true),
  ("true", true),
  ("false", true),
  ("return", true),
  ("break", true),
  ("continue", true),
  ("pub", true),
  ("priv", true),
  ("struct", true),
  ("enum", true),
  ("trait", true),
  ("impl", true),
  ("test", true),
  ("extern", true),
  ("import", true),
  ("as", true),
  ("self", true),
  ("error", true),
  ("type", true),
  ("suberror", true),
  ("const", true),
  ("guard", true),
  ("async", true),
  ("init", true),
  ("main", true),
  ("with", true),
  ("module", true),
  ("open", true),
  ("using", true),
  ("derive", true),
  ("extend", true),
  ("typealias", true),
  ("_", true),
])

///|
/// | True if `name` may not be used bare as a MoonBit identifier.
pub fn is_moonbit_keyword(name : String) -> Bool {
  moonbit_keywords.contains(name)
}

///|
/// | Split an identifier into words at underscores and case boundaries, so
/// that `sqlite3_open_v2` and `SQLITE_OPEN_READONLY` and `sqlite3Stmt` all
/// come out as the words a human would read.
fn words(name : String) -> Array[String] {
  let out : Array[String] = []
  let cur = StringBuilder()
  for c in name {
    if c == '_' {
      if !cur.is_empty() {
        out.push(cur.to_string())
        cur.reset()
      }
    } else {
      cur.write_char(c)
    }
  }
  if !cur.is_empty() {
    out.push(cur.to_string())
  }
  out
}

///|
/// | `PascalCase` for a type name. MoonBit type names must begin with an
/// upper case letter and may not begin with an underscore, so a leading run of
/// underscores is dropped and every word is capitalised.
///
/// `sqlite3_stmt` -> `Sqlite3Stmt`, `__int128_t` -> `Int128T`.
pub fn type_name(name : String) -> String {
  let ws = words(name)
  let out = StringBuilder()
  for w in ws {
    if w.length() > 0 {
      out.write_string(w.substring(start=0, end=1).to_upper())
      out.write_string(w.substring(start=1).to_lower())
    }
  }
  let s = out.to_string()
  if s.is_empty() {
    // A name of nothing but underscores. `_` alone is not a legal C identifier
    // either, but a header may still contain it; give it a name rather than
    // emitting a type declaration that will not parse.
    "Unnamed"
  } else {
    s
  }
}

///|
/// | A field name. C field names are left as they are when they are already
/// | legal MoonBit lower-case identifiers, which keeps a mirror struct
/// | recognisable next to the header. A keyword gets a trailing underscore.
pub fn field_name(name : String) -> String {
  let mut n = name
  if n.is_empty() {
    n = "unnamed"
  }
  // MoonBit decides from the first letter whether a token is a name or a
  // type, and `iColumn` is a legal C member but starts upper case. Lowercase
  // it so the declaration parses; the rest of the spelling survives.
  if n.length() > 0 &&
    n.substring(start=0, end=1).to_lower() != n.substring(start=0, end=1) {
    n = n.substring(start=0, end=1).to_lower() + n.substring(start=1)
  }
  // MoonBit identifiers may start with an underscore in a field position, but
  // a bare `_` is the wildcard and is not an identifier.
  if n == "_" {
    n = "_field"
  }
  if is_moonbit_keyword(n) {
    n = n + "_"
  }
  n
}

///|
/// | A parameter name. The same rules as a field, but a missing name (legal in
/// | a prototype) becomes `arg<n>`.
pub fn param_name(name : String, index : Int32) -> String {
  if name.is_empty() {
    "arg\{index}"
  } else {
    field_name(name)
  }
}

///|
/// | An enum value or macro constant. MoonBit reserves `UPPER_CASE` for type
/// | parameters in a value position — `pub let FOO` is parsed as a type name —
/// | so a C constant is lower-cased to `snake_case`.
///
/// `SQLITE_OK` -> `sqlite_ok`. The original spelling is kept in the
/// generated doc comment so the header can still be searched for it.
pub fn const_name(name : String) -> String {
  let ws = words(name)
  let out = StringBuilder()
  let mut first = true
  for w in ws {
    if w.length() > 0 {
      if !first {
        out.write_char('_')
      }
      out.write_string(w.to_lower())
      first = false
    }
  }
  let s = out.to_string()
  if s.is_empty() {
    "unnamed"
  } else if is_moonbit_keyword(s) {
    s + "_"
  } else {
    s
  }
}

///|
/// | A function name. Kept verbatim when it is already a legal lower-case
/// | identifier, so that `sqlite3_open` reads the same on both sides of the
/// | boundary and a stack trace from C names the function MoonBit called.
pub fn function_name(name : String) -> String {
  field_name(name)
}

///|
/// | An opaque extern type: the MoonBit name for a C record that is never used
/// | by value.
pub fn opaque_name(tag : String) -> String {
  type_name(tag)
}
