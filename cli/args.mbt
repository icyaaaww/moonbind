//! What the command line means.
//!
//! Parsing is separated from doing so that every option combination can be
//! tested without touching a file. `parse_args` is a pure function of the
//! argument list — it reads no environment, no disk — and returns one of four
//! answers, which is also the whole error model: a bad invocation is reported,
//! never guessed at.

///|
/// | The version the binary reports. Kept in step with `moon.mod` by hand, and
/// | by a test that reads the manifest.
pub let version : String = "0.5.0"

///|
/// | A fully-resolved invocation.
pub(all) struct Options {
  /// The header to read: a path, or the name of an embedded standard header.
  pub header : String
  /// Where the package goes; `None` means standard output.
  pub out : String?
  pub target : @layout.Target
  pub include_paths : Array[String]
  pub defines : Array[String]
  /// Print the declarations that were left out, and why.
  pub report : Bool
  /// Print the record layout table instead of generating bindings.
  pub verify : Bool
  pub config : String?
  pub compare : String?
  pub json : Bool
  pub check : Bool
  pub allow_functions : Array[String]
  pub native_sources : Array[String]
  pub rename_functions : Map[String, String]
  pub strict : Bool
  pub bridge : Bool
  pub html : Bool
  pub ownership : Map[String, String]
  pub buffers : Map[String, String]
  pub copy_strings : Array[String]
  pub fail_on : String
} derive(Debug, Eq)

///|
/// | The outcome of parsing.
pub(all) enum Args {
  Help
  Version
  Run(Options)
  Bad(String)
} derive(Debug, Eq)

///|
/// | The text `--help` prints.
pub fn usage() -> String {
  let lines = [
    "moonbind — generate MoonBit FFI bindings from a C header", "", "Usage:", "  moonbind <header.h> [options]",
    "", "Options:", "  --out <dir>         write a complete package into <dir>",
    "  --target <name>     x86_64 (default), aarch64, or wasm32", "  --include <dir>     add a directory to the include search path",
    "  --define <M=V>      define a macro before parsing", "  --report            list the declarations that were left out, and why",
    "  --verify            print the record layout table instead of bindings", "  --version           print the version and exit",
    "  --help              print this text and exit", "", "A declaration is left out rather than emitted approximately: a binding",
    "whose layout differs from the header's is worse than a missing one.", "", "Project workflow:",
    "  --config <file>        load JSON configuration", "  --allow <function>     select a C function (repeatable)",
    "  --rename <C=MoonBit>    rename a generated function", "  --native-source <file> add a C source relative to generated package",
    "  --check                check output without writing", "  --json                 structured report",
    "  --strict               reject parser diagnostics and skipped selected functions",
    "  --bridge               generate a C adapter and compile-time layout checks",
    "  --compare <old.h>      compare current header against old header", "  --html                 offline comparison report on stdout",
    "  --own <create=free>    generate scoped cleanup (explicit contract)", "  --buffer <fn=ptr:len>  derive byte length from a Bytes parameter",
    "  --copy-string <fn>    copy a borrowed NUL string result immediately", "  --fail-on <rule>        none, removed, changed (includes removals), any",
  ]
  let buf = StringBuilder()
  for i, l in lines {
    if i > 0 {
      buf.write_char('\n')
    }
    buf.write_string(l)
  }
  buf.to_string()
}

///|
/// | Read one argument list. Later spells of the same option win, which is what
/// | a shell script appending to a base command expects.
pub fn parse_args(argv : Array[String]) -> Args {
  let mut header : String? = None
  let mut out : String? = None
  let mut target = @layout.Target::sysv64()
  let includes : Array[String] = []
  let defines : Array[String] = []
  let mut report = false
  let mut verify = false
  let mut config : String? = None
  let mut compare : String? = None
  let mut json = false
  let mut check = false
  let allow_functions : Array[String] = []
  let native_sources : Array[String] = []
  let rename_functions : Map[String, String] = Map([])
  let mut strict = false
  let mut bridge = false
  let mut html = false
  let ownership : Map[String, String] = Map([])
  let buffers : Map[String, String] = Map([])
  let copy_strings : Array[String] = []
  let mut fail_on = "none"
  let mut i = 0
  // A `--out` with no value is the one error that can be spotted in the loop;
  // everything else is checked once the whole list has been read.
  let mut missing : String? = None
  while i < argv.length() {
    let arg = argv[i]
    match arg {
      "--help" | "-h" => return Help
      "--version" | "-V" => return Version
      "--strict" => {
        strict = true
        i = i + 1
      }
      "--bridge" => {
        bridge = true
        i = i + 1
      }
      "--html" => {
        html = true
        i = i + 1
      }
      "--report" => {
        report = true
        i = i + 1
      }
      "--verify" => {
        verify = true
        i = i + 1
      }
      "--json" => {
        json = true
        i = i + 1
      }
      "--check" => {
        check = true
        i = i + 1
      }
      "--out"
      | "--target"
      | "--include"
      | "--define"
      | "--config"
      | "--compare"
      | "--allow"
      | "--native-source"
      | "--fail-on"
      | "--own"
      | "--buffer"
      | "--copy-string"
      | "--rename" =>
        if i + 1 >= argv.length() {
          missing = Some(arg)
          i = i + 1
        } else {
          let value = argv[i + 1]
          match arg {
            "--fail-on" => fail_on = value
            "--out" => out = Some(value)
            "--target" =>
              match @layout.Target::parse(value) {
                Some(t) => target = t
                None =>
                  return Bad(
                    "unknown target: " +
                    value +
                    " (expected x86_64, aarch64 or wasm32)",
                  )
              }
            "--copy-string" => copy_strings.push(value)
            "--own" | "--buffer" => {
              let parts = value.split("=").to_array()
              if parts.length() != 2 ||
                parts[0].is_empty() ||
                parts[1].is_empty() {
                return Bad(arg + " requires name=value")
              }
              if arg == "--own" {
                ownership[parts[0].to_string()] = parts[1].to_string()
              } else {
                buffers[parts[0].to_string()] = parts[1].to_string()
              }
            }
            "--rename" => {
              let parts = value.split("=").to_array()
              if parts.length() != 2 ||
                parts[0].is_empty() ||
                parts[1].is_empty() {
                return Bad("--rename requires c_name=moonbit_name")
              }
              rename_functions[parts[0].to_string()] = parts[1].to_string()
            }
            "--config" => config = Some(value)
            "--compare" => compare = Some(value)
            "--allow" => allow_functions.push(value)
            "--native-source" => native_sources.push(value)
            "--include" => includes.push(value)
            _ => defines.push(value)
          }
          i = i + 2
        }
      _ => {
        if arg.has_prefix("-") && arg != "-" {
          return Bad("unknown option: " + arg)
        }
        if header is Some(_) {
          return Bad("more than one header given: " + arg)
        }
        header = Some(arg)
        i = i + 1
      }
    }
  }
  match missing {
    Some(flag) => return Bad("option " + flag + " needs a value")
    None => ()
  }
  if !["none", "removed", "changed", "any"].contains(fail_on) {
    return Bad("--fail-on expects none, removed, changed or any")
  }
  if (html || fail_on != "none") && compare is None && config is None {
    return Bad("--html and --fail-on require --compare")
  }
  if html && json {
    return Bad("--html and --json are mutually exclusive")
  }
  if bridge && (verify || compare is Some(_)) {
    return Bad("--bridge cannot be combined with --verify or --compare")
  }
  if bridge && out is None && config is None {
    return Bad("--bridge requires --out")
  }
  if check && out is None && config is None {
    return Bad("--check requires --out")
  }
  if compare is Some(_) && (verify || check || out is Some(_)) {
    return Bad("--compare cannot be combined with --out, --check or --verify")
  }
  if verify && (json || check) {
    return Bad("--verify cannot be combined with --json or --check")
  }
  let header = match (header, config) {
    (None, Some(_)) => Some("")
    _ => header
  }
  match header {
    None => Bad("no header given")
    Some(h) =>
      Run({
        header: h,
        out,
        target,
        include_paths: includes,
        defines,
        report,
        verify,
        config,
        compare,
        json,
        check,
        allow_functions,
        native_sources,
        rename_functions,
        strict,
        bridge,
        html,
        fail_on,
        ownership,
        buffers,
        copy_strings,
      })
  }
}
