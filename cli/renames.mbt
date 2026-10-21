///|
/// Renames affect the MoonBit identifier only. The C linkage symbol is kept.
fn validate_renames(
  m : @ast.CModule,
  names : Map[String, String],
) -> Unit raise RunError {
  let functions = m.exported_functions()
  for original, name in names {
    if !functions.any(f => f.name == original) {
      raise Failed("rename names an unknown or excluded function: " + original)
    }
    if name.is_empty() ||
      name[0] < 'a' ||
      name[0] > 'z' ||
      @codegen.is_moonbit_keyword(name) {
      raise Failed("invalid MoonBit function name: " + name)
    }
    for c in name {
      if !(c >= 'a' && c <= 'z') &&
        !(c >= 'A' && c <= 'Z') &&
        !(c >= '0' && c <= '9') &&
        c != '_' {
        raise Failed("invalid MoonBit function name: " + name)
      }
    }
  }
  let claimed : Map[String, String] = Map([])
  for f in functions {
    let name = names.get(f.name).unwrap_or(@codegen.function_name(f.name))
    if claimed.get(name) is Some(other) {
      if names.contains(f.name) || names.contains(other) {
        raise Failed("function rename collision: " + name)
      }
    }
    claimed[name] = f.name
  }
}
