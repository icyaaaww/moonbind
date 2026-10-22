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
  let (text, skips) = @codegen.generate(
    selected,
    options.target,
    function_names=options.rename_functions,
    ownership=options.ownership,
    buffers=options.buffers,
    copy_strings=options.copy_strings,
  )
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
      let files : Map[String, String] = Map([
        ("bindings.mbt", text),
        ("strings.mbt", @codegen.strings_source()),
        ("stub.c", @codegen.stub_source()),
        (
          "moon.pkg",
          @codegen.package_manifest(native_sources=options.native_sources),
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
