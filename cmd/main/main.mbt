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
  let args : Array[String] = if argv.length() > 0 {
    argv[1:].to_owned()
  } else {
    []
  }
  let code = drive(args)
  if code != 0 {
    @sys.exit(code)
  }
}

///|
/// | Parse, run, report. Returns the status.
fn drive(argv : Array[String]) -> Int32 {
  let parsed_args = @cli.prepare_args(argv) catch {
    @cli.Failed(message) => {
      report_error(argv, message)
      return 2
    }
  }
  let options = match parsed_args {
    @cli.Help => {
      println(@cli.usage())
      return 0
    }
    @cli.Version => {
      println("moonbind " + @cli.version)
      return 0
    }
    @cli.Bad(message) => {
      report_error(argv, message)
      if !argv.contains("--json") {
        eprintln(@cli.usage())
      }
      return 2
    }
    @cli.Run(options) => options
  }
  let execution = if options.compare is Some(_) {
    { ..options, json: true, html: false, }
  } else {
    options
  }
  let raw = @cli.run(execution) catch {
    @cli.Failed(message) => {
      report_error(argv, message)
      return 1
    }
  }
  let mut blocked = false
  let text = if options.compare is Some(_) {
    let report = @json.parse(raw) catch {
      _ => {
        eprintln("invalid comparison report")
        return 1
      }
    }
    blocked = @cli.review_blocked(report, options.fail_on)
    if options.html {
      @cli.review_html(report)
    } else if options.json {
      raw
    } else {
      @cli.review_text(report)
    }
  } else {
    raw
  }
  // `--verify` produces a table to read, not a package to write, so it prints
  // whether or not `--out` was given.
  match options.out {
    None => println(text)
    Some(_) =>
      if options.verify || options.json || options.check {
        println(text)
      }
  }
  if blocked {
    return 3
  }
  0
}

///|
fn report_error(argv : Array[String], message : String) -> Unit {
  if argv.contains("--json") {
    println(@cli.failure_report(message))
  } else {
    eprintln("moonbind: " + message)
  }
}
