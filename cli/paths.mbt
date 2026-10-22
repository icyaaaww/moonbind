///|
/// Paths in generated C are relative to the C source, not the invocation cwd.
fn relative_path(base : String, path : String) -> String raise RunError {
  let a = @source.normalize_path(base)
    .split("/")
    .map(s => s.to_string())
    .to_array()
  let b = @source.normalize_path(path)
    .split("/")
    .map(s => s.to_string())
    .to_array()
  if a.length() == 0 || b.length() == 0 || a[0].to_lower() != b[0].to_lower() {
    raise Failed(
      "portable bridge requires output and headers on the same filesystem root",
    )
  }
  let mut common = 0
  while common < a.length() && common < b.length() && a[common] == b[common] {
    common = common + 1
  }
  let parts : Array[String] = []
  for _ in common..<a.length() {
    parts.push("..")
  }
  for i in common..<b.length() {
    parts.push(b[i])
  }
  if parts.is_empty() {
    "."
  } else {
    parts.join("/")
  }
}

///|
fn module_root(path : String) -> String raise RunError {
  let mut dir = path
  while dir != "" {
    if @fs.path_exists(dir + "/moon.mod") ||
      @fs.path_exists(dir + "/moon.mod.json") {
      return dir
    }
    let parent = @source.dir_name(dir)
    if parent == dir {
      break
    }
    dir = parent
  }
  raise Failed(
    "bridge include paths require output under a MoonBit module; initialize the project first",
  )
}
