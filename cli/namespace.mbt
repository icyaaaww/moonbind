///|
/// Scope generated helper linkage, while preserving public MoonBit API names.
fn namespace_helpers(
  files : Map[String, String],
  prefix : String,
) -> Unit raise RunError {
  if prefix == "" {
    return
  }
  for i, c in prefix {
    if !(c >= 'a' && c <= 'z') &&
      !(c >= 'A' && c <= 'Z') &&
      c != '_' &&
      !(i > 0 && c >= '0' && c <= '9') {
      raise Failed("c_namespace must be a C identifier")
    }
  }
  for
    symbol in [
      "moonbind_copy_cstr", "moonbind_null", "moonbind_is_null", "moonbind_make_slot",
      "moonbind_read_slot", "moonbind_cstr_at",
    ] {
    for file in ["bindings.mbt", "strings.mbt"] {
      files[file] = files
        .get(file)
        .unwrap()
        .replace_all(
          old="= \"" + symbol + "\"",
          new="= \"" + prefix + "_" + symbol + "\"",
        )
    }
    files["stub.c"] = files
      .get("stub.c")
      .unwrap()
      .replace_all(old=symbol + "(", new=prefix + "_" + symbol + "(")
  }
}
