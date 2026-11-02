///|
test "target preprocessing distinguishes AArch64 from x86 LP64" {
  let source = "#if defined(__aarch64__)\nint arm(void);\n#elif defined(__x86_64__)\nint x86(void);\n#elif defined(_M_X64)\nint windows(void);\n#elif defined(__wasm32__)\nint wasm(void);\n#endif\n"
  for
    (target, expected) in [
      (@layout.Target::sysv64(), "x86"),
      (@layout.Target::aapcs64(), "arm"),
      (@layout.Target::win64(), "windows"),
      (@layout.Target::wasm32(), "wasm"),
    ] {
    let options = @cparse.LoadOptions::new()
    let cache = @source.SourceCache::in_memory()
    cache.insert("targets.h", source)
    let m = @cparse.load_header_with_cache(
      "targets.h",
      {
        ..options,
        platform: platform_for(target),
        defines: target_defines(target, []),
      },
      cache,
    )
    assert_true(m.diagnostics.is_empty())
    assert_eq(m.exported_functions().length(), 1)
    assert_eq(m.exported_functions()[0].name, expected)
  }
}

///|
test "invalid preprocessing and declaration constants are diagnosed" {
  for
    source in [
      "#if 1 2\nint f(void);\n#endif", "#if 1/0\nint f(void);\n#endif", "#if defined()\nint f(void);\n#endif",
      "#if defined(X\nint f(void);\n#endif", "enum E { BAD = 1/0 };", "enum E { BAD = MISSING };",
      "struct S { int field[1/0]; };", "struct S { int field[-1]; };", "struct S { unsigned field : 1/0; };",
      "struct S { unsigned field : -1; };",
    ] {
    assert_false(header(source).diagnostics.is_empty())
  }
}

///|
test "unevaluated constant branches preserve valid declarations" {
  let m = header(
    "#if 0 && (1/0)\nint bad(void);\n#elif (1 ? -1 : 1U) < 0\nint bad2(void);\n#else\nint correct(void);\n#endif\nenum E { GOOD = 1 ? 7 : (1/0) };\nstruct S { int flexible[]; };",
  )
  assert_true(m.diagnostics.is_empty())
  assert_eq(m.exported_functions()[0].name, "correct")
  assert_eq(m.enums["E"].items[0].value, 7L)
}
