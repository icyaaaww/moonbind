///|
fn expression(source : String) -> Int64? {
  let tokens = @lex.tokenize(source).filter(t => {
    t.kind != @lex.Eof && t.kind != @lex.Newline
  })
  evaluate(tokens, Map([]), Platform::lp64())
}

///|
test "constant expressions consume every token and validate defined operands" {
  for
    source in [
      "1 2", "1)", "1 +", "", "defined()", "defined(1)", "defined(NAME", "defined",
    ] {
    assert_eq(expression(source), None)
  }
  assert_eq(expression("defined(UNKNOWN)"), Some(0L))
}

///|
test "active division overflow and invalid shifts are diagnosed" {
  for
    source in [
      "1/0", "1%0", "(-9223372036854775807L - 1L) / -1L", "1 << -1", "1 << 64", "1 >> 64",
    ] {
    assert_eq(expression(source), None)
  }
  assert_eq(expression("12 / 3 + 7 % 4"), Some(7L))
}

///|
test "short circuit skips arithmetic errors but still validates syntax" {
  for
    (source, expected) in [
      ("0 && (1/0)", 0L),
      ("1 || (1/0)", 1L),
      ("1 ? 7 : (1/0)", 7L),
      ("0 ? (1/0) : 9", 9L),
      ("0 && (1 << 64)", 0L),
      ("1 || (0 ? 1 : 1/0)", 1L),
      ("0 || 1 && 3", 1L),
      ("1 && 0 || 2", 1L),
    ] {
    assert_eq(expression(source), Some(expected))
  }
  for
    source in ["0 && (1 + )", "1 || (1 + )", "1 ? 7 : (1 + )", "0 ? (1 + ) : 9"] {
    assert_eq(expression(source), None)
  }
}

///|
test "conditional operands share unsigned type even when one is skipped" {
  assert_eq(expression("(1 ? -1 : 1U) < 0"), Some(0L))
  assert_eq(expression("(0 ? 1U : -1) < 0"), Some(0L))
  assert_eq(expression("(1 ? -1 : 1) < 0"), Some(1L))
  assert_eq(expression("(1 ? -1 : (1U / 0U)) < 0"), Some(0L))
}

///|
test "undefined architecture names are zero after macro expansion" {
  assert_eq(
    expression("__aarch64__ || __x86_64__ || _WIN64 || __wasm32__"),
    Some(0L),
  )
}

///|
test "declaration constants reject names absent from their environment" {
  let tokens = @lex.tokenize("MISSING + 1").filter(t => t.kind != @lex.Eof)
  assert_eq(
    evaluate_with(tokens, Map([]), Platform::lp64(), fn(_) { None }),
    None,
  )
  assert_eq(
    evaluate_with(tokens, Map([]), Platform::lp64(), fn(_) { Some(3L) }),
    Some(4L),
  )
}

///|
test "public evaluators accept lexer whitespace and terminal EOF" {
  let tokens = @lex.tokenize("1 +\n2\n")
  assert_eq(evaluate(tokens, Map([]), Platform::lp64()), Some(3L))
  assert_eq(
    evaluate_with(tokens, Map([]), Platform::lp64(), fn(_) { None }),
    Some(3L),
  )
}
