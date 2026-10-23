///|
/// Require real filesystem headers and emit a relative include path. Keep the
/// header/output tree together when moving the project. No header or macro string is executed as a shell command here.
fn run_bridge(
  parsed : @ast.CModule,
  options : Options,
) -> String raise RunError {
  let dir = match options.out {
    Some(dir) => dir
    None => raise Failed("--bridge requires --out")
  }
  let cwd = @env.current_dir().unwrap_or("")
  let header = config_path(cwd, options.header)
  if !@fs.path_exists(header) {
    raise Failed("bridge needs an existing filesystem header")
  }
  let candidates = parsed.exported_functions()
  candidates.append(parsed.static_definitions)
  if options.c_namespace != "" &&
    candidates.any(f => f.name.has_prefix("moonbind_")) {
    raise Failed(
      "c_namespace reserves C function names starting with moonbind_; use an explicit adapter",
    )
  }
  for name in options.allow_functions {
    if !candidates.any(f => f.name == name) {
      raise Failed("unknown bridge function: " + name)
    }
  }
  let selected = {
    ..parsed,
    functions: parsed.functions.filter(f => {
      options.allow_functions.is_empty() ||
      options.allow_functions.contains(f.name)
    }),
    static_definitions: parsed.static_definitions.filter(f => {
      options.allow_functions.is_empty() ||
      options.allow_functions.contains(f.name)
    }),
  }
  let selectable = selected.exported_functions()
  selectable.append(
    selected.static_definitions.map(f => { ..f, internal: false, }),
  )
  validate_renames(
    { ..selected, functions: selectable, },
    options.rename_functions,
  )
  if options.trace_calls {
    raise Failed("trace-calls requires direct mode")
  }
  if !options.status_codes.is_empty() ||
    !options.out_params.is_empty() ||
    !options.output_buffers.is_empty() ||
    !options.managed_outputs.is_empty() ||
    !options.null_params.is_empty() ||
    !options.callbacks.is_empty() {
    raise Failed("call contracts require direct mode")
  }
  if !options.buffers.is_empty() || !options.copy_strings.is_empty() {
    raise Failed("buffer/string contracts require direct binding mode")
  }
  let result = @codegen.generate_bridge(
    selected,
    options.target,
    relative_path(config_path(cwd, dir), header),
    function_names=options.rename_functions,
    ownership=options.ownership,
  )
  if result.adapted.is_empty() {
    raise Failed(
      "no selected functions can be adapted by the simple-record bridge",
    )
  }
  for skip in result.skipped {
    if skip.reason.has_prefix("contract:") {
      raise Failed(skip.name + ": " + skip.reason)
    }
  }
  if options.strict && !result.skipped.is_empty() {
    raise Failed(result.skipped.map(s => s.name + ": " + s.reason).join("\n"))
  }
  let macros = StringBuilder()
  for define in options.defines {
    let parts = define.split("=").to_array()
    let name = parts[0].to_string()
    if name.is_empty() || define.contains("\n") || define.contains("\r") {
      raise Failed("invalid bridge macro")
    }
    for i, c in name {
      if !(c >= 'a' && c <= 'z') &&
        !(c >= 'A' && c <= 'Z') &&
        c != '_' &&
        !(i > 0 && c >= '0' && c <= '9') {
        raise Failed("invalid bridge macro name")
      }
    }
    let value = if parts.length() == 1 {
      "1"
    } else {
      parts[1:].to_owned().map(p => p.to_string()).join("=")
    }
    macros.write_string("#define " + name + " " + value + "\n")
  }
  let flags : Array[String] = []
  for path in options.include_paths {
    let absolute = config_path(cwd, path)
    if absolute.contains("\"") || absolute.contains("\n") {
      raise Failed("unsupported include directory characters")
    }
    flags.push(
      "-I\"" +
      relative_path(module_root(config_path(cwd, dir)), absolute) +
      "\"",
    )
  }
  let report : Json = {
    "schema_version": 1,
    "generator_version": version,
    "mode": "bridge",
    "target": target_name(options.target),
    "adapted_functions": result.adapted,
    "sources": parsed.sources,
    "functions": result.adapted.map(name => {
      let entry : Json = {
        "name": name,
        "status": "generated",
        "source": source_location(parsed, name),
      }
      entry
    }),
    "records": result.records,
    "skipped": result.skipped.map(s => { "name": s.name, "reason": s.reason }),
    "diagnostics": diagnostics_json(parsed),
    "validation": {
      "layout": "checks_emitted_not_executed",
      "link": "not_verified",
      "runtime": "not_verified",
    },
    "ownership": "*_new and record-return adapters allocate; check is_null then free exactly once using mb_<tag>_free; borrowed inputs are not freed; never use freed handles",
  }
  let sources = options.native_sources.copy()
  sources.push("bridge.c")
  let files : Map[String, String] = Map([
    ("moonbind-config.h", "#pragma once\n" + adapter_macros(options)),
    ("bindings.mbt", result.bindings),
    ("strings.mbt", @codegen.strings_source()),
    ("stub.c", @codegen.stub_source()),
    ("bridge.c", macros.to_string() + result.c_source),
    (
      "moon.pkg",
      @codegen.package_manifest(
        native_sources=sources,
        stub_flags=flags.join(" "),
      ),
    ),
    (
      "moonbind-report.json",
      with_context(report, options).stringify(indent=2) + "\n",
    ),
  ])
  namespace_helpers(files, options.c_namespace)
  write_managed(dir, files, options.check)
  if options.json {
    with_context(report, options).stringify(indent=2)
  } else if options.check {
    "Generated bridge files are up to date."
  } else {
    result.bindings
  }
}
