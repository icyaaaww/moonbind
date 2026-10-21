///|
fn header(text : String) -> @ast.CModule {
  let cache = @source.SourceCache::in_memory()
  cache.insert("test.h", text)
  let defaults = @cparse.LoadOptions::new()
  @cparse.load_header_with_cache(
    "test.h",
    { ..defaults, platform: @cp.Platform::lp64(), },
    cache,
  ) catch {
    _ => abort("test header did not parse")
  }
}

///|
test "configuration resolves paths and rejects typos and duplicate keys" {
  let args = config_args(
    "{\"header\":\"a.h\",\"out\":\"gen\",\"include_paths\":[\"inc\"],\"defines\":[\"A=1\"]}",
    "project",
  )
  assert_eq(args, [
    "project/a.h", "--out", "project/gen", "--include", "project/inc", "--define",
    "A=1",
  ])
  for
    bad in [
      "{}", "[]", "{\"header\":\"a.h\",\"traget\":\"x86_64\"}", "{\"header\":\"a.h\",\"header\":\"b.h\"}",
      "{\"header\":\"a.h\",\"defines\":[1]}",
    ] {
    let rejected = try {
      ignore(config_args(bad, ""))
      false
    } catch {
      _ => true
    }
    assert_true(rejected)
  }
  assert_eq(config_path("work", "D:\\headers\\a.h"), "D:/headers/a.h")
  assert_eq(config_path("work", "/usr/include/a.h"), "/usr/include/a.h")
}

///|
test "compare config suppresses generation output and flags are validated" {
  assert_eq(
    config_args("{\"header\":\"new.h\",\"out\":\"gen\"}", "", comparing=true),
    ["new.h"],
  )
  for
    args in [
      ["a.h", "--compare", "old.h", "--out", "gen"],
      ["a.h", "--check"],
      ["a.h", "--verify", "--json"],
    ] {
    assert_true(parse_args(args) is Bad(_))
  }
  assert_true(parse_args(["--config", "moonbind.json", "--check"]) is Run(_))
}

///|
test "safe updates allow untouched output and reject edits and foreign files" {
  let previous = Map([("bindings.mbt", "v1"), ("moon.pkg", "config")])
  let next = Map([("bindings.mbt", "v2"), ("moon.pkg", "config2")])
  assert_eq(update_conflicts(previous, previous, next), [])
  assert_eq(
    update_conflicts(
      previous,
      Map([("bindings.mbt", "manual"), ("moon.pkg", "config")]),
      next,
    ),
    ["bindings.mbt"],
  )
  assert_eq(
    update_conflicts(Map([]), Map([("moon.pkg", "handwritten")]), next),
    ["moon.pkg"],
  )
  assert_eq(update_conflicts(Map([]), next, next), [])
  assert_eq(update_conflicts(previous, Map([]), next), [])
}

///|
test "state roundtrip rejects unknown paths" {
  let files : Map[String, String] = Map([])
  for name in managed_names {
    files[name] = "Unicode 月亮 \"quotes\"\n"
  }
  let restored = read_state(state_text(files))
  assert_eq(restored, files)
  let rejected = try {
    ignore(
      read_state(
        "{\"schema_version\":1,\"files\":[{\"name\":\"../other\",\"contents\":\"x\"}]}",
      ),
    )
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
}

///|
test "generation report separates emitted skipped and excluded functions" {
  let m = header("int good(int n); int var(int n, ...); void other(void);")
  let report = generation_report(m, @layout.Target::sysv64(), ["good", "var"])
  assert_true(
    report
    is {
      "summary": {
        "generated_functions": Number(1),
        "skipped_functions": Number(1),
        "excluded_functions": Number(1),
        ..
      },
      ..
    },
  )
  assert_true(report.stringify().contains("variadic"))
}

///|
test "comparison ignores comments parameter names and declaration order" {
  let old = header("int a(int count); void b(void); struct S { int x; };")
  let new = header(
    "/* documentation */ struct S { int x; }; void b(void); int a(int n);",
  )
  assert_true(
    compare_headers(old, new, @layout.Target::sysv64(), [])
    is { "changes": Array([]), "affected_functions": Array([]), .. },
  )
}

///|
test "comparison detects field types even when layout size stays the same" {
  let old = header("struct S { int x; }; void use(struct S *s);")
  let new = header("struct S { unsigned int x; }; void use(struct S *s);")
  let result = compare_headers(old, new, @layout.Target::sysv64(), [])
  assert_true(
    result
    is {
      "changes": Array(
        [{ "symbol": String("record:S"), "change": String("changed"), .. }]
      ),
      "affected_functions": Array([String("use")]),
      ..
    },
  )
}

///|
test "comparison follows nested and cyclic record dependencies" {
  let old = header(
    "struct S { int x; struct S *next; }; struct Box { struct S *s; }; void use(struct Box *b);",
  )
  let new = header(
    "struct S { long x; struct S *next; }; struct Box { struct S *s; }; void use(struct Box *b);",
  )
  assert_true(
    compare_headers(old, new, @layout.Target::sysv64(), [])
    is { "affected_functions": Array([String("use")]), .. },
  )
}

///|
test "comparison detects additions removals and generation support changes" {
  let old = header("int gone(void); int change(int n);")
  let new = header("void added(void); int change(int n, ...);")
  let text = compare_headers(old, new, @layout.Target::sysv64(), []).stringify()
  for
    expected in [
      "function:gone", "function:added", "function:change", "removed", "generated",
      "skipped",
    ] {
    assert_true(text.contains(expected))
  }
}

///|
test "comparison catches constants enums packing and aliases" {
  let old = header(
    "#define LIMIT 4\nenum E { A = 1 }; typedef int Count; struct S { char c; int i; };",
  )
  let new = header(
    "#define LIMIT 8\nenum E { A = 2 }; typedef long Count; struct S { char c; int i; } __attribute__((packed));",
  )
  let text = compare_headers(old, new, @layout.Target::sysv64(), []).stringify()
  for expected in ["constant:LIMIT", "enum:E", "typedef:Count", "record:S"] {
    assert_true(text.contains(expected))
  }
}

///|
test "manifest escapes source paths and deduplicates stub entries" {
  let text = @codegen.package_manifest(native_sources=[
    "source.c", "source.c", "stub.c",
  ])
  assert_true(text.contains("[ \"stub.c\", \"source.c\" ]"))
}

///|
test "function renaming retains C linkage and rejects collisions" {
  let m = header("int library_add(int a, int b); int other(void);")
  let names = Map([("library_add", "add")])
  validate_renames(m, names)
  let (text, _) = @codegen.generate(
    m,
    @layout.Target::sysv64(),
    function_names=names,
  )
  assert_true(
    text.contains("fn add(a : Int32, b : Int32) -> Int32 = \"library_add\""),
  )
  for
    invalid in [
      Map([("missing", "add")]),
      Map([("library_add", "fn")]),
      Map([("library_add", "other")]),
      Map([("library_add", "bad-name")]),
    ] {
    let rejected = try {
      validate_renames(m, invalid)
      false
    } catch {
      _ => true
    }
    assert_true(rejected)
  }
  let args = config_args(
    "{\"header\":\"api.h\",\"rename_functions\":{\"library_add\":\"add\"}}", "",
  )
  assert_true(
    parse_args(args) is Run({ rename_functions: names, .. }) &&
    names.get("library_add") == Some("add"),
  )
}
