//! Regression tests against real headers.
//!
//! Every other test in this repository starts from a header written to make
//! one point. That is how the generator was built, and it is exactly why the
//! bugs that matter survived: a header written for a test says what the parser
//! is ready for. `sqlite3.h` says what a decade of callers needed, and the
//! first run over it found five assumptions that were simply false.
//!
//! These tests pin the outcome of that run. They do not compare the generated
//! text against a golden file — that would break on every improvement — but
//! assert the properties a real header forced onto the generator: constants
//! exist, handles are opaque rather than optional, out-parameters are slots,
//! and nothing is silently wrong.

///|
let sqlite_header : String = "testdata/sqlite/sqlite3.h"

///|
fn load_sqlite() -> @ast.CModule {
  let opts = @cparse.LoadOptions::new()
  try {
    @cparse.load_header(sqlite_header, opts)
  } catch {
    _ => abort("could not read " + sqlite_header + " from the module root")
  }
}

///|
test "a real header parses without losing whole categories of declaration" {
  let m = load_sqlite()
  // The numbers are not the point; the categories are. A header this size
  // that yields no constants, or no functions, means a stage silently did
  // nothing.
  assert_true(m.constants.length() > 300)
  assert_true(m.exported_functions().length() > 100)
  assert_true(m.records.size() > 10)
}

///|
test "macros become constants, and are not duplicated by their enum" {
  let m = load_sqlite()
  let names : Map[String, Bool] = Map([])
  for c in m.constants {
    // `SQLITE_OK` is both an enumerator and a `#define`. Publishing both
    // would give the generated package two values with one name.
    if names.contains(c.name) {
      abort("constant \{c.name} published twice")
    }
    names[c.name] = true
  }
  assert_true(names.contains("SQLITE_VERSION_NUMBER"))
}

///|
test "a real header generates source that uses no optional handles" {
  let m = load_sqlite()
  let (text, _) = @codegen.generate(m, @layout.Target::sysv64())
  // An `Option[_]` at the FFI boundary is a box, and a C NULL coming back
  // looks like one. Every handle is therefore a bare external type with
  // `is_null` and `null` beside it.
  assert_false(text.contains("Ptr?"))
  assert_true(text.contains("pub type Sqlite3Ptr"))
  assert_true(text.contains("pub fn Sqlite3Ptr::is_null"))
}

///|
test "out-parameters cross as slots, not as handles" {
  let m = load_sqlite()
  let (text, _) = @codegen.generate(m, @layout.Target::sysv64())
  // `sqlite3_open`'s second parameter is `sqlite3 **`. MoonBit never
  // dereferences it; it passes a rooted `Bytes` and reads the address back.
  assert_true(
    text.contains(
      "fn sqlite3_open(filename : Bytes, ppDb : Bytes) -> Int",
    ),
  )
  assert_true(text.contains("pub fn Sqlite3Ptr::slot() -> Bytes"))
  assert_true(text.contains("pub fn Sqlite3Ptr::read_slot(slot : Bytes) -> Sqlite3Ptr"))
}

///|
test "the generated sqlite3 package still says what the header said" {
  let m = load_sqlite()
  let (text, _) = @codegen.generate(m, @layout.Target::sysv64())
  // Spot checks across the three kinds of declaration a caller relies on: a
  // function with a struct-by-value argument, one that returns a `char *`, and
  // a constant whose value the caller compares against.
  assert_true(text.contains("= \"sqlite3_step\""))
  assert_true(text.contains("= \"sqlite3_column_text\""))
  assert_true(text.contains("pub let sqlite_ok : Int = 0"))
  assert_true(text.contains("pub let sqlite_row : Int = 100"))
}
