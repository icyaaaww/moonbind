///|
test "missing includes propagate into module diagnostics" {
  let m = header("#include <missing_moonbind_header.h>\nint visible(void);")
  assert_true(m.diagnostics.any(d => d.code == "preprocessor"))
}

///|
test "chained macro types and replacement calls are rescanned" {
  let m = header(
    "#define BASE long\n#define ALIAS BASE\n#define ID(x) x\n#define TYPE ID(ALIAS)\nstruct Entry { TYPE offset; };\nint use(struct Entry p);",
  )
  assert_true(m.diagnostics.is_empty())
  assert_eq(
    @layout.layout_record(@layout.Target::sysv64(), m, "Entry").unwrap().size,
    8,
  )
  let recursive = header("#define A B\n#define B A\nA mystery;")
  assert_false(recursive.diagnostics.is_empty())
}

///|
test "malformed and ABI changing declarations are diagnosed" {
  for
    source in [
      "struct Bad { mystery field; };", "struct Bad { int x;", "int f(int x;", "static inline int f(int x) {",
      "long double f(void);", "double long f(void);", "__attribute__((vector_size(16))) int f(void);",
    ] {
    let m = header(source)
    assert_false(m.diagnostics.is_empty())
    assert_true(
      @codegen.generate_bridge(m, @layout.Target::sysv64(), "api.h").adapted.is_empty(),
    )
  }
}

///|
test "bridge rejects renames colliding with record helpers" {
  let m = header("struct Point { int x; }; int sum(struct Point p);")
  let b = @codegen.generate_bridge(
    m,
    @layout.Target::sysv64(),
    "api.h",
    function_names=Map([("sum", "mb_Point_new")]),
  )
  assert_true(b.adapted.is_empty())
  assert_true(b.bindings.is_empty())
}

///|
test "unsupported types and unknown declarations carry source diagnostics" {
  let m = header(
    "_Complex double f(void);\n__int128 g(void);\nunknown_type mystery(void);",
  )
  assert_true(
    m.diagnostics.any(d => d.code == "unsupported_complex" && d.line == 1),
  )
  assert_true(
    m.diagnostics.any(d => d.code == "unsupported_integer" && d.line == 2),
  )
  assert_true(
    m.diagnostics.any(d => d.code == "unknown_declaration" && d.line == 3),
  )
  assert_true(m.diagnostics.all(d => d.file == "test.h" && d.column > 0))
}

///|
test "static definitions are kept separately from externally linked functions" {
  let m = header(
    "static inline int add(int a, int b) { return a+b; } static int missing(int a); int visible(void);",
  )
  assert_eq(m.static_definitions.length(), 1)
  assert_eq(m.static_definitions[0].name, "add")
  assert_eq(m.exported_functions().length(), 1)
  assert_eq(m.exported_functions()[0].name, "visible")
}

///|
test "bridge emits allocation field access cleanup and compile time assertions" {
  let m = header(
    "struct Point { int x; int y; }; struct Point add(struct Point a, struct Point b);",
  )
  let b = @codegen.generate_bridge(m, @layout.Target::sysv64(), "/tmp/point.h")
  assert_eq(b.adapted, ["add"])
  assert_eq(b.skipped.length(), 0)
  for
    snippet in [
      "malloc(sizeof(*out))", "*out = add(*arg0, *arg1)", "void mb_Point_free", "offsetof(struct Point, y) == 4",
      "_Alignof(struct Point) == 4",
    ] {
    assert_true(b.c_source.contains(snippet))
  }
  assert_true(b.bindings.contains("= \"moonbind_bridge_add\""))
  assert_true(b.bindings.contains("-> PointPtr"))
}

///|
test "bridge refuses pointer fields bitfields nested records and varargs" {
  let m = header(
    "struct Bad { int *p; }; struct Bits { int a:2; }; struct Nested { struct Bad b; }; int bad(struct Bad v); int bits(struct Bits v); int nested(struct Nested v); int var(int n, ...);",
  )
  let b = @codegen.generate_bridge(m, @layout.Target::sysv64(), "api.h")
  assert_eq(b.adapted.length(), 0)
  assert_eq(b.skipped.length(), 4)
}

///|
test "bridge scalar inline function and explicit rename retain linkage" {
  let m = header("static inline int twice(int value) { return value * 2; }")
  let b = @codegen.generate_bridge(
    m,
    @layout.Target::sysv64(),
    "api.h",
    function_names=Map([("twice", "double_it")]),
  )
  assert_eq(b.adapted, ["twice"])
  assert_true(
    b.bindings.contains(
      "fn double_it(arg0 : Int32) -> Int32 = \"moonbind_bridge_twice\"",
    ),
  )
}

///|
test "review gates handle removal changes additions and incomplete analysis" {
  let added : Json = {
    "changes": [{ "change": "added" }],
    "analysis_complete": true,
  }
  let removed : Json = {
    "changes": [{ "change": "removed" }],
    "analysis_complete": true,
  }
  let changed : Json = {
    "changes": [{ "change": "changed" }],
    "analysis_complete": true,
  }
  assert_false(review_blocked(added, "changed"))
  assert_true(review_blocked(added, "any"))
  assert_true(review_blocked(removed, "removed"))
  assert_true(review_blocked(removed, "changed"))
  assert_false(review_blocked(changed, "removed"))
  assert_true(review_blocked(changed, "changed"))
  assert_true(
    review_blocked({ "changes": [], "analysis_complete": false }, "removed"),
  )
  assert_false(review_blocked(removed, "none"))
}

///|
test "offline report escapes untrusted header names and contains no script" {
  let report : Json = {
    "changes": [
      {
        "symbol": "<script>alert(1)</script>",
        "change": "changed",
        "before": "<img onerror=x>",
        "after": "&",
      },
    ],
    "affected_functions": [],
    "policy": { "blocked": true },
  }
  let html = review_html(report)
  assert_false(html.contains("<script>"))
  assert_false(html.contains("<img"))
  assert_true(html.contains("&lt;script&gt;"))
  assert_true(html.contains("阻止通过"))
}

///|
test "strict bridge and review flags are validated and configurable" {
  let args = config_args(
    "{\"header\":\"api.h\",\"out\":\"gen\",\"bridge\":true,\"strict\":true,\"fail_on\":\"changed\"}",
    "",
  )
  assert_true(parse_args(args) is Run({ bridge: true, strict: true, .. }))
  for
    invalid in [
      ["api.h", "--bridge"],
      ["api.h", "--html"],
      ["api.h", "--compare", "old.h", "--fail-on", "maybe"],
      ["api.h", "--compare", "old.h", "--json", "--html"],
    ] {
    assert_true(parse_args(invalid) is Bad(_))
  }
  for
    flag in [
      "--strict", "--bridge", "--html", "--fail-on", "--config", "--allow", "--rename",
      "--check", "--compare", "--json",
    ] {
    assert_true(usage().contains(flag))
  }
}
