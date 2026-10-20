//! The `moonbind` command.
//!
//! `main` is one line of policy: run, then exit with the code the run chose.
//! Everything else is in `drive`, which returns a status instead of calling
//! `exit` from deep inside a `try`, so each exit point is visible in one
//! place.

///|
/// | Exit codes: 0 success, 1 the input could not be processed, 2 the
/// | invocation was wrong. A script can tell "your header has nothing
/// | bindable" from "you typed the flag wrong".
fn main {
  // `@env.args()` is the raw C `argv`, so its first element is the program
  // itself. `parse_args` sees only what the user typed.
  let argv = @env.args()
  let args : Array[String] = if argv.length() > 0 { argv[1:].to_owned() } else { [] }
  let code = drive(args)
  if code != 0 {
    @sys.exit(code)
  }
}

///|
/// | Parse, run, report. Returns the status.
fn drive(argv : Array[String]) -> Int {
  let options = match @cli.parse_args(argv) {
    @cli.Help => {
      println(@cli.usage())
      return 0
    }
    @cli.Version => {
      println("moonbind " + @cli.version)
      return 0
    }
    @cli.Bad(message) => {
      eprintln("moonbind: " + message)
      eprintln("")
      eprintln(@cli.usage())
      return 2
    }
    @cli.Run(options) => options
  }
  let text = try {
    @cli.run(options)
  } catch {
    @cli.Failed(message) => {
      eprintln("moonbind: " + message)
      return 1
    }
  }
  match options.out {
    None => println(text)
    Some(_) => ()
  }
  0
}
