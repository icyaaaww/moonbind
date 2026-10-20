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
pub let version : String = "0.1.0"

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
    "whose layout differs from the header's is worse than a missing one.",
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
  let mut i = 0
  // A `--out` with no value is the one error that can be spotted in the loop;
  // everything else is checked once the whole list has been read.
  let mut missing : String? = None
  while i < argv.length() {
    let arg = argv[i]
    match arg {
      "--help" | "-h" => return Help
      "--version" | "-V" => return Version
      "--report" => {
        report = true
        i = i + 1
      }
      "--verify" => {
        verify = true
        i = i + 1
      }
      "--out" | "--target" | "--include" | "--define" =>
        if i + 1 >= argv.length() {
          missing = Some(arg)
          i = i + 1
        } else {
          let value = argv[i + 1]
          match arg {
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
      })
  }
}
