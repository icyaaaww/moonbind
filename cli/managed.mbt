///|
/// Managed file names are fixed; state files cannot redirect writes.
let managed_names : Array[String] = [
  "bindings.mbt", "strings.mbt", "stub.c", "moon.pkg", "moonbind-report.json",
]

///|
/// Pure conflict detection, also used by the filesystem writer and its tests.
pub fn update_conflicts(
  previous : Map[String, String],
  current : Map[String, String],
  desired : Map[String, String],
) -> Array[String] {
  let conflicts : Array[String] = []
  for name in managed_names {
    match current.get(name) {
      Some(now) =>
        if desired.get(name) != Some(now) && previous.get(name) != Some(now) {
          conflicts.push(name)
        }
      None => ()
    }
  }
  conflicts
}

///|
/// Save exact generated contents as the baseline; never use timestamps.
fn state_text(files : Map[String, String]) -> String {
  let entries : Array[Json] = []
  for name in managed_names {
    if files.get(name) is Some(contents) {
      entries.push({ "name": name, "contents": contents })
    }
  }
  let state : Json = { "schema_version": 1, "files": entries }
  state.stringify(indent=2) + "\n"
}

///|
fn read_state(text : String) -> Map[String, String] raise RunError {
  let state = read_json(text)
  let entries = match state {
    { "schema_version": Number(1), "files": Array(entries), .. } => entries
    _ =>
      raise Failed(
        "invalid .moonbind-state.json; restore it from version control",
      )
  }
  let files : Map[String, String] = Map([])
  for entry in entries {
    match entry {
      { "name": String(name), "contents": String(contents), .. } => {
        if !managed_names.contains(name) || files.contains(name) {
          raise Failed("invalid managed filename in state")
        }
        files[name] = contents
      }
      _ => raise Failed("invalid managed file entry")
    }
  }
  if files.size() != managed_names.length() {
    raise Failed("incomplete generated state")
  }
  files
}

///|
/// Preflight every file before writing anything. A state baseline is committed
/// last. Ordinary write errors trigger best-effort rollback; this is not a
/// transaction against power loss or concurrent writers.
fn write_managed(
  dir : String,
  desired : Map[String, String],
  check : Bool,
) -> Unit raise RunError {
  try {
    let state_path = dir + "/.moonbind-state.json"
    let old_state = if @fs.path_exists(state_path) {
      Some(@fs.read_file_to_string(state_path))
    } else {
      None
    }
    let previous = match old_state {
      Some(s) => read_state(s)
      None => Map([])
    }
    let current : Map[String, String] = Map([])
    for name in managed_names {
      let path = dir + "/" + name
      if @fs.path_exists(path) {
        current[name] = @fs.read_file_to_string(path)
      }
    }
    let conflicts = update_conflicts(previous, current, desired)
    if !conflicts.is_empty() {
      raise Failed(
        "edited or untracked generated files: " +
        conflicts.join(", ") +
        "; preserve your edits and regenerate into a new directory",
      )
    }
    let next_state = state_text(desired)
    if check {
      for name in managed_names {
        if current.get(name) != desired.get(name) {
          raise Failed("generated output is stale or missing: " + name)
        }
      }
      if old_state != Some(next_state) {
        raise Failed("generation state is missing or stale")
      }
      return
    }
    make_dirs(dir)
    let touched : Array[String] = []
    try {
      for name in managed_names {
        let value = desired.get(name).unwrap()
        if current.get(name) != Some(value) {
          touched.push(name)
          @fs.write_string_to_file(dir + "/" + name, value)
        }
      }
      @fs.write_string_to_file(state_path, next_state)
    } catch {
      @fs.IOError(err) => {
        let failures : Array[String] = []
        for name in touched {
          try {
            match current.get(name) {
              Some(value) => @fs.write_string_to_file(dir + "/" + name, value)
              None =>
                if @fs.path_exists(dir + "/" + name) {
                  @fs.remove_file(dir + "/" + name)
                }
            }
          } catch {
            _ => failures.push(name)
          }
        }
        try {
          match old_state {
            Some(value) => @fs.write_string_to_file(state_path, value)
            None =>
              if @fs.path_exists(state_path) {
                @fs.remove_file(state_path)
              }
          }
        } catch {
          _ => failures.push(".moonbind-state.json")
        }
        raise Failed(
          "write failed: " + err + "; rollback failures: " + failures.join(", "),
        )
      }
    }
  } catch {
    @fs.IOError(err) => raise Failed("cannot access generated package: " + err)
    Failed(message) => raise Failed(message)
    _ =>
      raise Failed(
        "unexpected filesystem error while updating generated package",
      )
  }
}
