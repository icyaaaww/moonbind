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
  let parsed = try {
    @cparse.load_header(options.header, load_options)
  } catch {
    @cp.Failed(err) => raise Failed("could not read " + options.header + ": " + err)
  }
  let (text, skips) = @codegen.generate(parsed, options.target)
  if options.report {
    for s in skips {
      eprintln("left out: \{s.name} — \{s.reason}")
    }
  }
  match options.out {
    None => ()
    Some(dir) => write_package(dir, text)
  }
  text
}

///|
/// | Write the four files a usable package is made of. They are written as a
/// | set because a package that is missing its manifest will not build, and a
/// | half-written package is a confusing thing to debug.
fn write_package(dir : String, text : String) -> Unit raise RunError {
  try {
    make_dirs(dir)
    @fs.write_string_to_file(dir + "/moon.pkg", @codegen.package_manifest())
    @fs.write_string_to_file(dir + "/stub.c", @codegen.stub_source())
    @fs.write_string_to_file(dir + "/strings.mbt", @codegen.strings_source())
    @fs.write_string_to_file(dir + "/bindings.mbt", text)
  } catch {
    @fs.IOError(err) => raise Failed("could not write into " + dir + ": " + err)
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
