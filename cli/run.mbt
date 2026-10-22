//! Doing what the arguments asked for.

///|
/// | What went wrong, in the words a user needs.
pub(all) suberror RunError {
  Failed(String)
}

///|
/// | Turn a header into a MoonBit source file, and optionally write it.
/// | Returns the generated text so that a caller that passed no `--out` can
/// | print it.
pub fn run(options : Options) -> String raise RunError {
  let load = @cparse.LoadOptions::new()
  let load_options = {
    ..load,
    include_paths: options.include_paths,
    defines: options.defines,
    platform: platform_for(options.target),
  }
  let parsed = @cparse.load_header(options.header, load_options) catch {
    @cp.Failed(err) =>
      raise Failed("could not read " + options.header + ": " + err)
  }
  if options.target.abi == @layout.Win64 {
    for _, record in parsed.records {
      if record.complete &&
        (
          record.fields.is_empty() ||
          record.pack is Some(_) ||
          record.align is Some(_) ||
          record.fields.any(f => f.bit_width is Some(_))
        ) {
        raise Failed(
          "win64 supports ordinary records only; bitfields, packed/aligned and empty records need explicit adapters",
        )
      }
    }
    for _, e in parsed.enums {
      if e.items.any(i => i.value < -2147483648L || i.value > 2147483647L) {
        raise Failed("win64 enum values must fit signed int")
      }
    }
  }
  if options.strict && !parsed.diagnostics.is_empty() {
    raise Failed(diagnostic_text(parsed))
  }
  // `--verify` answers a different question — where the compiler will put each
  // field — so it neither generates bindings nor writes a package. It prints
  // the table the layout engine believes, which CI diffs against one produced
  // by clang on the same header.
  if options.verify {
    if !parsed.diagnostics.is_empty() {
      raise Failed(diagnostic_text(parsed))
    }
    return @layout.layout_table(options.target, parsed)
  }
  if options.compare is Some(old_header) {
    let old = @cparse.load_header(old_header, load_options) catch {
      @cp.Failed(err) =>
        raise Failed("could not read " + old_header + ": " + err)
    }
    if options.strict && !old.diagnostics.is_empty() {
      raise Failed(diagnostic_text(old))
    }
    let report = decorate_comparison(
      compare_headers(old, parsed, options.target, options.allow_functions),
      old,
      parsed,
      options,
    )
    return if options.html {
      review_html(report)
    } else if options.json {
      report.stringify(indent=2)
    } else {
      review_text(report)
    }
  }
  // Unknown syntax never produces potentially incorrect bindings. Non-strict
  // report-only mode can still show all diagnostics without writing a package.
  if !parsed.diagnostics.is_empty() {
    if options.json && options.out is None {
      let report : Json = {
        "schema_version": 1,
        "generator_version": version,
        "status": "incomplete",
        "diagnostics": diagnostics_json(parsed),
      }
      return report.stringify(indent=2)
    }
    raise Failed(diagnostic_text(parsed))
  }
  if options.bridge {
    return run_bridge(parsed, options)
  }
  for name in options.allow_functions {
    if !parsed.exported_functions().any(f => f.name == name) {
      raise Failed(
        "allow_functions names an unknown exported function: " + name,
      )
    }
  }
  let selected = selected_module(parsed, options.allow_functions)
  validate_renames(selected, options.rename_functions)
  let (raw_text, skips) = @codegen.generate(
    selected,
    options.target,
    function_names=options.rename_functions,
    ownership=options.ownership,
    buffers=options.buffers,
    output_buffers=options.output_buffers,
    managed_outputs=options.managed_outputs,
    status_codes=options.status_codes,
    out_params=options.out_params,
    null_params=options.null_params,
    callbacks=options.callbacks,
    copy_strings=options.copy_strings,
  )
  let mut text = raw_text
  for skip in skips {
    if skip.reason.has_prefix("contract:") {
      raise Failed(skip.name + ": " + skip.reason)
    }
  }
  if options.strict {
    for skip in skips {
      if selected.functions.any(f => f.name == skip.name) {
        raise Failed(
          "selected function unsupported: " + skip.name + ": " + skip.reason,
        )
      }
    }
  }
  for c_name, moon_name in options.rename_functions {
    if text.contains("= \"" + c_name + "\"") &&
      !text
      .split("\n")
      .any(line => {
        line.contains("fn " + moon_name + "(") &&
        line.has_suffix("= \"" + c_name + "\"")
      }) {
      raise Failed(
        "rename collides with another generated declaration: " + moon_name,
      )
    }
  }
  if options.trace_calls {
    for f in selected.exported_functions() {
      if skips.any(s => s.name == f.name) {
        raise Failed(
          "trace-calls requires all selected functions to be supported: " +
          f.name,
        )
      }
      text = text.replace_all(
        old="= \"" + f.name + "\"",
        new="= \"moonbind_trace_" + f.name + "\"",
      )
    }
  }
  if options.report && !options.json {
    for s in skips {
      eprintln("left out: \{s.name} — \{s.reason}")
    }
    eprintln(summary(selected, skips))
  }
  let report = with_context(
    generation_report(parsed, options.target, options.allow_functions),
    options,
  )
  match options.out {
    None => ()
    Some(dir) => {
      let adapter = if options.trace_calls || !options.callbacks.is_empty() {
        let cwd = @env.current_dir().unwrap_or("")
        adapter_macros(options) +
        @codegen.call_adapters(
          selected,
          relative_path(config_path(cwd, dir), config_path(cwd, options.header)),
          callbacks=options.callbacks,
          trace=options.trace_calls,
        )
      } else {
        ""
      }
      let files : Map[String, String] = Map([
        ("moonbind-config.h", "#pragma once\n" + adapter_macros(options)),
        ("bindings.mbt", text),
        ("strings.mbt", @codegen.strings_source()),
        ("stub.c", @codegen.stub_source() + "\n" + adapter),
        (
          "moon.pkg",
          @codegen.package_manifest(
            native_sources=options.native_sources,
            stub_flags=adapter_flags(options, dir),
          ),
        ),
        ("moonbind-report.json", report.stringify(indent=2) + "\n"),
        ("bridge.c", "/* Bridge disabled for this package. */\n"),
      ])
      write_managed(dir, files, options.check)
    }
  }
  if options.json {
    report.stringify(indent=2)
  } else if options.check {
    "Generated files are up to date."
  } else {
    text
  }
}

///|
/// | Create `dir` and every missing parent of it. `--out examples/sqlite3` is
/// | the normal way to use this tool, and failing because `examples` does not
/// | exist yet would be a poor first impression.
fn make_dirs(dir : String) -> Unit raise @fs.IOError {
  if @fs.path_exists(dir) {
    return
  }
  let parent = @source.dir_name(dir)
  if parent != "" && parent != dir && parent != "." && !@fs.path_exists(parent) {
    make_dirs(parent)
  }
  @fs.create_dir(dir)
}

///|
/// | The preprocessor's data model for a layout target. The two agree on the
/// | things a header branches on — pointer width, `long`, `size_t` — which is
/// | why the target is chosen once and used for both.
pub fn platform_for(target : @layout.Target) -> @cp.Platform {
  match target.abi {
    @layout.SysV64 => @cp.Platform::lp64()
    @layout.Aapcs64 => @cp.Platform::lp64()
    @layout.Win64 => @cp.Platform::win64()
    @layout.Wasm32 => @cp.Platform::wasm32()
  }
}

///|
/// | Phrase a summary of a run: what was read, what was written, what was
/// | dropped. Written for a person reading a terminal, and stable enough to
/// | compare between runs.
pub fn summary(parsed : @ast.CModule, skips : Array[@codegen.Skip]) -> String {
  let records = parsed.records.size()
  let funcs = parsed.exported_functions().length()
  let buf = StringBuilder()
  buf.write_string("\{funcs} functions, \{records} records")
  if skips.length() > 0 {
    buf.write_string(", \{skips.length()} declarations left out")
  }
  buf.to_string()
}

///|
fn adapter_macros(options : Options) -> String raise RunError {
  let out = StringBuilder()
  for define in options.defines {
    let parts = define.split("=").to_array()
    let name = parts[0].to_string()
    if name.is_empty() || define.contains("\n") || define.contains("\r") {
      raise Failed("invalid adapter macro")
    }
    for i, c in name {
      if !(c >= 'a' && c <= 'z') &&
        !(c >= 'A' && c <= 'Z') &&
        c != '_' &&
        !(i > 0 && c >= '0' && c <= '9') {
        raise Failed("invalid adapter macro name")
      }
    }
    let value = if parts.length() == 1 {
      "1"
    } else {
      parts[1:].to_owned().map(p => p.to_string()).join("=")
    }
    out.write_string("#define " + name + " " + value + "\n")
  }
  out.to_string()
}

///|
fn adapter_flags(options : Options, dir : String) -> String raise RunError {
  let cwd = @env.current_dir().unwrap_or("")
  let flags : Array[String] = []
  for path in options.include_paths {
    let absolute = config_path(cwd, path)
    if absolute.contains("\"") ||
      absolute.contains("\n") ||
      absolute.contains("\r") {
      raise Failed("unsupported include path")
    }
    flags.push(
      "-I\"" +
      relative_path(module_root(config_path(cwd, dir)), absolute) +
      "\"",
    )
  }
  flags.join(" ")
}
