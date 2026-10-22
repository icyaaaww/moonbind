///|
/// Resolve paths relative to a configuration file, not the shell directory.
fn config_path(base : String, path : String) -> String {
  if path.has_prefix("/") ||
    path.has_prefix("\\") ||
    (path.length() > 1 && path[1] == ':') {
    @source.normalize_path(path)
  } else {
    @source.join_path(base, path)
  }
}

///|
fn read_json(text : String) -> Json raise RunError {
  @json.parse(text, reject_duplicate_keys=true) catch {
    _ => raise Failed("invalid JSON (duplicate keys are not allowed)")
  }
}

///|
/// Strict fields catch misspelled configuration instead of ignoring it.
pub fn config_args(
  text : String,
  base : String,
  comparing~ : Bool = false,
) -> Array[String] raise RunError {
  let fields = match read_json(text) {
    Object(fields) => fields
    _ => raise Failed("configuration must be a JSON object")
  }
  for key, _ in fields {
    if ![
        "header", "out", "target", "include_paths", "defines", "allow_functions",
        "native_sources", "rename_functions", "strict", "bridge", "fail_on", "ownership",
        "buffers", "copy_strings",
      ].contains(key) {
      raise Failed("unknown configuration field: " + key)
    }
  }
  let args : Array[String] = []
  match fields.get("header") {
    Some(String(s)) if s != "" => args.push(config_path(base, s))
    _ => raise Failed("configuration requires a nonempty header string")
  }
  for key in ["out", "target"] {
    match fields.get(key) {
      None => ()
      Some(String(s)) if s != "" =>
        if !(comparing && key == "out") {
          args.push("--" + key)
          args.push(if key == "out" { config_path(base, s) } else { s })
        }
      _ => raise Failed(key + " must be a nonempty string")
    }
  }
  for
    (key, flag) in [
      ("include_paths", "--include"),
      ("defines", "--define"),
      ("allow_functions", "--allow"),
      ("native_sources", "--native-source"),
      ("copy_strings", "--copy-string"),
    ] {
    match fields.get(key) {
      None => ()
      Some(Array(values)) =>
        for value in values {
          match value {
            String(s) if s != "" => {
              args.push(flag)
              args.push(
                if key == "include_paths" {
                  config_path(base, s)
                } else {
                  s
                },
              )
            }
            _ => raise Failed(key + " must contain nonempty strings")
          }
        }
      _ => raise Failed(key + " must be an array")
    }
  }
  match fields.get("rename_functions") {
    None => ()
    Some(Object(names)) => {
      let keys : Array[String] = []
      for key, _ in names {
        keys.push(key)
      }
      keys.sort()
      for key in keys {
        match names.get(key) {
          Some(String(value)) if value != "" && key != "" => {
            args.push("--rename")
            args.push(key + "=" + value)
          }
          _ =>
            raise Failed(
              "rename_functions must map C names to nonempty MoonBit names",
            )
        }
      }
    }
    _ => raise Failed("rename_functions must be an object")
  }
  for (key, flag) in [("ownership", "--own"), ("buffers", "--buffer")] {
    match fields.get(key) {
      None => ()
      Some(Object(values)) => {
        let names : Array[String] = []
        for name, _ in values {
          names.push(name)
        }
        names.sort()
        for name in names {
          match values.get(name) {
            Some(String(value)) if name != "" && value != "" => {
              args.push(flag)
              args.push(name + "=" + value)
            }
            _ =>
              raise Failed(key + " must map function names to nonempty strings")
          }
        }
      }
      _ => raise Failed(key + " must be an object")
    }
  }
  for key in ["strict", "bridge"] {
    match fields.get(key) {
      None | Some(False) => ()
      Some(True) => if !(comparing && key == "bridge") { args.push("--" + key) }
      _ => raise Failed(key + " must be a boolean")
    }
  }
  if comparing {
    match fields.get("fail_on") {
      None => ()
      Some(String(rule)) => {
        args.push("--fail-on")
        args.push(rule)
      }
      _ => raise Failed("fail_on must be a string")
    }
  } else if fields.get("fail_on") is Some(value) {
    match value {
      String(rule) if ["none", "removed", "changed", "any"].contains(rule) => ()
      _ => raise Failed("fail_on must be none, removed, changed or any")
    }
  }
  args
}

///|
/// Configuration defaults precede command-line overrides. Array flags append.
pub fn prepare_args(argv : Array[String]) -> Args raise RunError {
  let parsed = parse_args(argv)
  let options = match parsed {
    Run(o) => o
    _ => return parsed
  }
  let path = match options.config {
    Some(path) => path
    None => return parsed
  }
  if options.header != "" {
    raise Failed("with --config, set header in the configuration file")
  }
  let text = @fs.read_file_to_string(path) catch {
    _ => raise Failed("cannot read config: " + path)
  }
  let expanded = config_args(
    text,
    @source.dir_name(path),
    comparing=options.compare is Some(_),
  )
  let mut i = 0
  while i < argv.length() {
    if argv[i] == "--config" {
      i = i + 2
    } else {
      expanded.push(argv[i])
      i = i + 1
    }
  }
  parse_args(expanded)
}
