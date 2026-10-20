//! Tests for the argument parser.
//!
//! The parser is a pure function of the argument list, which is exactly what
//! makes it worth testing: every combination is one array away.

///|
test "a header alone is enough" {
  match parse_args(["sqlite3.h"]) {
    Run(o) => {
      assert_eq(o.header, "sqlite3.h")
      assert_true(o.out is None)
      assert_eq(o.target, @layout.Target::sysv64())
      assert_false(o.report)
    }
    other => abort("expected a run")
  }
}

///|
test "every option takes the value that follows it" {
  match parse_args([
    "foo.h", "--out", "lib/foo.mbt", "--target", "wasm32", "--include", "inc",
    "--define", "NDEBUG=1", "--report",
  ]) {
    Run(o) => {
      assert_true(o.out is Some("lib/foo.mbt"))
      assert_eq(o.target, @layout.Target::wasm32())
      assert_eq(o.include_paths.length(), 1)
      assert_eq(o.include_paths[0], "inc")
      assert_eq(o.defines[0], "NDEBUG=1")
      assert_true(o.report)
    }
    other => abort("expected a run")
  }
}

///|
test "the last spell of an option wins" {
  match parse_args(["a.h", "--target", "wasm32", "--target", "aarch64"]) {
    Run(o) => assert_eq(o.target, @layout.Target::aapcs64())
    other => abort("expected a run")
  }
}

///|
test "help and version short-circuit" {
  assert_eq(parse_args(["--help"]), Help)
  assert_eq(parse_args(["a.h", "--version"]), Version)
  // A header that would not parse still reports help, rather than the error:
  // the user asked a question, not for a run.
  assert_eq(parse_args(["--help", "--bogus"]), Help)
}

///|
test "a wrong invocation is reported, never guessed at" {
  assert_true(match parse_args([]) {
    Bad(_) => true
    _ => false
  })
  assert_true(match parse_args(["a.h", "b.h"]) {
    Bad(m) => m.contains("more than one header")
    _ => false
  })
  assert_true(match parse_args(["a.h", "--target", "sparc"]) {
    Bad(m) => m.contains("unknown target")
    _ => false
  })
  assert_true(match parse_args(["a.h", "--out"]) {
    Bad(m) => m.contains("needs a value")
    _ => false
  })
  assert_true(match parse_args(["a.h", "--bogus"]) {
    Bad(m) => m.contains("unknown option")
    _ => false
  })
}

///|
test "a lone dash is a header, not an option" {
  assert_true(match parse_args(["-"]) {
    Run(o) => o.header == "-"
    _ => false
  })
}

///|
test "the usage text mentions every option the parser accepts" {
  let text = usage()
  for flag in ["--out", "--target", "--include", "--define", "--report", "--version", "--help"] {
    assert_true(text.contains(flag))
  }
}
