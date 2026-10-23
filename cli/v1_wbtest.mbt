///|
test "schema one preserves versionless configuration" {
  assert_eq(
    config_args("{\"header\":\"a.h\"}", "."),
    config_args("{\"schema_version\":1,\"header\":\"a.h\"}", "."),
  )
  for version in ["0", "2", "true", "null", "\"1\"", "[]"] {
    assert_true(
      try {
        ignore(
          config_args(
            "{\"schema_version\":" + version + ",\"header\":\"a.h\"}",
            ".",
          ),
        )
        false
      } catch {
        _ => true
      },
    )
  }
}

///|
test "helper namespaces preserve public MoonBit names" {
  let files : Map[String, String] = {
    "bindings.mbt": "pub fn null() = \"moonbind_null\"",
    "strings.mbt": "pub fn copy_cstr() = \"moonbind_copy_cstr\"",
    "stub.c": "void *moonbind_null(void) {} void moonbind_copy_cstr(void) {}",
  }
  namespace_helpers(files, "snapshot_sql")
  assert_eq(
    files["bindings.mbt"],
    "pub fn null() = \"snapshot_sql_moonbind_null\"",
  )
  assert_true(files["stub.c"].contains("snapshot_sql_moonbind_copy_cstr("))
  for bad in ["1bad", "bad-name", "bad name", "x;exit"] {
    assert_true(
      try {
        namespace_helpers(files, bad)
        false
      } catch {
        _ => true
      },
    )
  }
  match
    parse_args(
      config_args("{\"header\":\"a.h\",\"c_namespace\":\"pkg_a\"}", "."),
    ) {
    Run(o) => assert_eq(o.c_namespace, "pkg_a")
    _ => abort("namespace configuration rejected")
  }
}
