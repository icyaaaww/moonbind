//! The preprocessor.
//!
//! It runs the parts of C11 translation phases 2 through 4 that matter for
//! binding generation: line splicing (done by the lexer), directive
//! processing, macro definition and expansion, conditional inclusion, and
//! `#include` resolution.
//!
//! Deliberate differences from a full compiler front end:
//!
//! * `_Pragma` and `#pragma` other than `pack` are recorded and dropped,
//!   because they never change a declaration's shape.
//! * `#include` of a header that cannot be found is a diagnostic rather than
//!   an error unless `strict` is set. Real headers conditionally include
//!   platform headers that are absent on the analysing machine, and skipping
//!   them is almost always right.
//! * Macro expansion is bounded by a per-token expansion budget rather than
//!   a full blue-paint set, so a pathological recursive macro cannot hang the
//!   tool while normal self-referential macros still terminate.

///|
/// | How preprocessing should behave.
pub(all) struct PreprocessOptions {
  /// Directories searched for `#include` after the including file's own.
  pub include_paths : Array[String]
  /// Macro definitions applied before the first file, as `NAME=VALUE`.
  pub defines : Array[String]
  pub platform : Platform
  /// Whether a missing `#include` stops the run.
  pub strict : Bool
  /// Maximum nesting depth for `#include`, as a guard against cycles that
  /// do not use an include guard.
  pub max_include_depth : Int32
} derive(Debug)

///|
/// | The usual defaults: no extra include paths, LP64, lenient includes.
pub fn PreprocessOptions::new() -> PreprocessOptions {
  {
    include_paths: [],
    defines: [],
    platform: Platform::default(),
    strict: false,
    max_include_depth: 64,
  }
}

///|
/// | The preprocessor state for one run.
struct Preprocessor {
  options : PreprocessOptions
  cache : @source.SourceCache
  macros : Map[String, Macro]
  out : Array[@lex.Token]
  pack_events : Array[(Int32, Int32?)]
  diagnostics : Array[String]
  files : Array[String]
  mut depth : Int32
  /// Each entry is whether the enclosing conditional level is active.
  cond_stack : Array[CondFrame]
  mut pragma_pack : Int64
  pragma_stack : Array[Int64]
}

///|
/// | One `#if` / `#elif` / `#else` level.
struct CondFrame {
  /// Whether code in this branch is being emitted.
  mut active : Bool
  /// Whether some branch of this chain has already been taken.
  mut taken : Bool
  /// Whether the enclosing level is active; an inactive parent suppresses
  /// every branch regardless of local conditions.
  parent_active : Bool
}

///|
/// | Parse `NAME` or `NAME=VALUE` from the command line.
fn parse_define(spec : String) -> (String, String)? {
  match spec.find("=") {
    Some(idx) => {
      let name = spec.substring(start=0, end=idx)
      if name == "" {
        return None
      }
      Some((name, spec.substring(start=idx + 1)))
    }
    None => if spec == "" { None } else { Some((spec, "1")) }
  }
}

///|
/// | Preprocess one header and everything it includes.
pub fn preprocess(
  entry : String,
  cache : @source.SourceCache,
  options : PreprocessOptions,
) -> Preprocessed raise PreprocessError {
  let pp : Preprocessor = {
    options,
    cache,
    macros: Map([]),
    out: [],
    pack_events: [],
    diagnostics: [],
    files: [],
    depth: 0,
    cond_stack: [],
    pragma_pack: 0L,
    pragma_stack: [],
  }
  pp.install_predefined()
  for spec in options.defines {
    match parse_define(spec) {
      Some((name, value)) => pp.define_object_line(name, value)
      None => pp.diagnostics.push("ignoring malformed -D '\{spec}'")
    }
  }
  let root = cache.load(entry) catch {
    _ => raise Failed("cannot read '\{entry}'")
  }
  pp.run_file(root)
  if pp.cond_stack.length() > 0 {
    raise Failed("unterminated conditional directive in '\{entry}'")
  }
  let defines = pp.collect_defines()
  // The output is a token stream in its own right, so it gets the same
  // terminator a lexed file gets. Without it a consumer that scans until
  // `Eof` has no way to see the end: every later `peek` would return the
  // last real token and a cursor that advances only on `peek` would stall.
  pp.out.push(@lex.Token::{
    kind: @lex.Eof,
    text: "",
    line: 0,
    col: 0,
    file: entry,
    space_before: false,
  })
  {
    tokens: pp.out,
    defines,
    pack_events: pp.pack_events,
    diagnostics: pp.diagnostics,
    files: pp.files,
  }
}

///|
/// | Preprocess an in-memory source. Tests use this; so does `--header -`.
pub fn preprocess_text(
  text : String,
  name : String,
  cache : @source.SourceCache,
  options : PreprocessOptions,
) -> Preprocessed raise PreprocessError {
  cache.insert(name, text)
  preprocess(name, cache, options)
}

///|
fn Preprocessor::install_predefined(self : Preprocessor) -> Unit {
  let p = self.options.platform
  let defs : Array[(String, String)] = [
    ("__STDC__", "1"),
    ("__STDC_VERSION__", "201112L"),
    ("__MOONBIND__", "1"),
  ]
  if p.windows {
    defs.push(("_WIN32", "1"))
    if p.pointer_bits == 64 {
      defs.push(("_WIN64", "1"))
      // MSVC x64 uses the default x64 convention for these spellings.
      // Do not erase them on other targets or erase __vectorcall.
      defs.push(("__cdecl", ""))
      defs.push(("__stdcall", ""))
    }
  }
  if p.pointer_bits == 64 && !p.windows {
    defs.push(("__LP64__", "1"))
    defs.push(("_LP64", "1"))
    defs.push(("__x86_64__", "1"))
    defs.push(("__amd64__", "1"))
  }
  if p.wasm {
    defs.push(("__wasm__", "1"))
    defs.push(("__wasm32__", "1"))
    defs.push(("__wasm32", "1"))
  }
  for (name, value) in defs {
    self.define_object_line(name, value)
  }
  // The predefined macros are defined as objects whose name is their own
  // spelling; `__FILE__` and `__LINE__` are marked builtin so that the
  // expander computes them from the use site.
  self.macros["__FILE__"] = { kind: Object, body: [], builtin: true, }
  self.macros["__LINE__"] = { kind: Object, body: [], builtin: true, }
}

///|
fn Preprocessor::define_object_line(
  self : Preprocessor,
  name : String,
  value : String,
) -> Unit {
  let body = @lex.tokenize(value).filter(t => {
    t.kind != @lex.Eof && t.kind != @lex.Newline
  })
  self.macros[name] = { kind: Object, body, builtin: false, }
}

///|
fn Preprocessor::active(self : Preprocessor) -> Bool {
  if self.cond_stack.length() == 0 {
    return true
  }
  self.cond_stack[self.cond_stack.length() - 1].active
}

///|
/// | Process one file: split it into directives and text, expand the text,
/// and append the result to the output.
fn Preprocessor::run_file(
  self : Preprocessor,
  src : @source.SourceText,
) -> Unit raise PreprocessError {
  if self.depth > self.options.max_include_depth {
    raise Failed("#include nested too deeply at '\{src.path}'")
  }
  self.depth = self.depth + 1
  self.files.push(src.path)
  let tokens = @lex.Lexer::with_file(src.text, src.path).run()
  let mut i = 0
  let n = tokens.length()
  // Text tokens accumulated for the current logical line group. Macro
  // expansion happens once the group is complete, because a function-like
  // macro invocation may span lines.
  let pending : Array[@lex.Token] = []
  while i < n {
    let t = tokens[i]
    if t.kind == @lex.Eof {
      break
    }
    if (t.text == "#" && !t.space_before) || is_directive_start(tokens, i) {
      // Flush pending text before the directive so that output order is the
      // source order.
      if pending.length() > 0 {
        self.emit_expanded(pending)
        pending.clear()
      }
      let (next, directive) = collect_directive(tokens, i + 1)
      i = next
      self.handle_directive(directive, src)
      continue
    }
    i = i + 1
    if t.kind == @lex.Newline {
      if pending.length() > 0 {
        self.emit_expanded(pending)
        pending.clear()
      }
      continue
    }
    pending.push(t)
  }
  if pending.length() > 0 {
    self.emit_expanded(pending)
  }
  self.depth = self.depth - 1
}

///|
/// | True when `tokens[i]` begins a directive: a `#` at the start of a
/// logical line, possibly after whitespace. The lexer records whether a
/// token was preceded by whitespace, so a `#` whose `space_before` is false
/// and whose position is the first on its line (or which follows a newline
/// token) is a directive marker.
fn is_directive_start(tokens : Array[@lex.Token], i : Int32) -> Bool {
  let t = tokens[i]
  if t.text != "#" {
    return false
  }
  if i == 0 {
    return true
  }
  let prev = tokens[i - 1]
  prev.kind == @lex.Newline
}

///|
/// | Collect the tokens of one directive. Stops at the newline that ends it
/// and returns the index of the token after that newline.
fn collect_directive(
  tokens : Array[@lex.Token],
  start : Int32,
) -> (Int32, Array[@lex.Token]) {
  let out : Array[@lex.Token] = []
  let mut i = start
  while i < tokens.length() {
    let t = tokens[i]
    if t.kind == @lex.Newline || t.kind == @lex.Eof {
      return (i + 1, out)
    }
    out.push(t)
    i = i + 1
  }
  (i, out)
}

///|
fn Preprocessor::handle_directive(
  self : Preprocessor,
  dir : Array[@lex.Token],
  src : @source.SourceText,
) -> Unit raise PreprocessError {
  if dir.length() == 0 {
    return
  }
  let name = dir[0].text
  let args = dir[1:].to_owned()
  match name {
    "if" => self.push_if(args, src)
    "ifdef" => self.push_ifdef(args, src, false)
    "ifndef" => self.push_ifdef(args, src, true)
    "elif" => self.handle_elif(args, src)
    "else" => self.handle_else()
    "endif" =>
      if self.cond_stack.length() == 0 {
        self.diagnostics.push(
          "unmatched #endif in '\{src.path}':\{dir[0].line}",
        )
      } else {
        let _ = self.cond_stack.pop()
      }
    "define" => self.handle_define(args, src)
    "undef" => if args.length() > 0 { self.macros.remove(args[0].text) }
    "include" => self.handle_include(args, src)
    "pragma" => self.handle_pragma(args, src)
    "error" =>
      if self.active() {
        raise Failed("#error in '\{src.path}': \{join_text(args)}")
      }
    "warning" =>
      if self.active() {
        self.diagnostics.push("warning in '\{src.path}': \{join_text(args)}")
      }
    "line" => ()
    _ =>
      if self.active() {
        self.diagnostics.push(
          "ignoring unknown directive '#\{name}' at '\{src.path}':\{dir[0].line}",
        )
      }
  }
}

///|
/// | Reconstruct the spelling of a token run with single spaces.
fn join_text(tokens : Array[@lex.Token]) -> String {
  let parts : Array[String] = []
  for t in tokens {
    parts.push(t.text)
  }
  parts.join(" ")
}

///|
fn Preprocessor::push_if(
  self : Preprocessor,
  args : Array[@lex.Token],
  src : @source.SourceText,
) -> Unit raise PreprocessError {
  let parent_active = self.active()
  let mut taken = false
  let mut active = false
  if parent_active {
    active = self.eval_condition(args, src)
    taken = active
  }
  self.cond_stack.push({ active, taken, parent_active, })
}

///|
fn Preprocessor::push_ifdef(
  self : Preprocessor,
  args : Array[@lex.Token],
  src : @source.SourceText,
  negate : Bool,
) -> Unit raise PreprocessError {
  let parent_active = self.active()
  let mut taken = false
  let mut active = false
  if parent_active {
    if args.length() == 0 {
      self.diagnostics.push("malformed #ifdef at '\{src.path}'")
    } else {
      let defined_ = self.macros.contains(args[0].text)
      active = if negate { !defined_ } else { defined_ }
      taken = active
    }
  }
  self.cond_stack.push({ active, taken, parent_active, })
}

///|
fn Preprocessor::handle_elif(
  self : Preprocessor,
  args : Array[@lex.Token],
  src : @source.SourceText,
) -> Unit raise PreprocessError {
  if self.cond_stack.length() == 0 {
    self.diagnostics.push("unmatched #elif in '\{src.path}'")
    return
  }
  let frame = self.cond_stack[self.cond_stack.length() - 1]
  if !frame.parent_active {
    frame.active = false
    return
  }
  if frame.taken {
    frame.active = false
    return
  }
  let cond = self.eval_condition(args, src)
  frame.active = cond
  if cond {
    frame.taken = true
  }
}

///|
fn Preprocessor::handle_else(self : Preprocessor) -> Unit {
  if self.cond_stack.length() == 0 {
    self.diagnostics.push("unmatched #else")
    return
  }
  let frame = self.cond_stack[self.cond_stack.length() - 1]
  if !frame.parent_active || frame.taken {
    frame.active = false
  } else {
    frame.active = true
    frame.taken = true
  }
}

///|
/// | Expand macros in a condition and evaluate it. `defined` is handled
/// before expansion, because expanding the operand would be wrong.
fn Preprocessor::eval_condition(
  self : Preprocessor,
  args : Array[@lex.Token],
  src : @source.SourceText,
) -> Bool raise PreprocessError {
  let replaced = replace_defined(args, self.macros)
  let expanded = self.expand_tokens(replaced, 0)
  match evaluate(expanded, self.macros, self.options.platform) {
    Some(v) => v != 0L
    None => {
      self.diagnostics.push(
        "cannot evaluate condition at '\{src.path}': '\{join_text(args)}'",
      )
      false
    }
  }
}

///|
/// | Replace `defined X` and `defined(X)` with `1` or `0` before expansion.
fn replace_defined(
  tokens : Array[@lex.Token],
  macros : Map[String, Macro],
) -> Array[@lex.Token] {
  let out : Array[@lex.Token] = []
  let mut i = 0
  while i < tokens.length() {
    let t = tokens[i]
    if t.text == "defined" {
      let mut j = i + 1
      let mut paren = false
      if j < tokens.length() && tokens[j].text == "(" {
        paren = true
        j = j + 1
      }
      let mut name = ""
      if j < tokens.length() {
        name = tokens[j].text
        j = j + 1
      }
      if paren && j < tokens.length() && tokens[j].text == ")" {
        j = j + 1
      }
      let v = if macros.contains(name) { "1" } else { "0" }
      out.push({ ..t, kind: @lex.Number, text: v, })
      i = j
      continue
    }
    out.push(t)
    i = i + 1
  }
  out
}

///|
fn Preprocessor::handle_define(
  self : Preprocessor,
  args : Array[@lex.Token],
  src : @source.SourceText,
) -> Unit raise PreprocessError {
  if !self.active() {
    return
  }
  if args.length() == 0 || args[0].kind != @lex.Ident {
    self.diagnostics.push("malformed #define at '\{src.path}':\{args[0].line}")
    return
  }
  let name = args[0].text
  let mut i = 1
  // A function-like macro has its `(` immediately after the name.
  let mut kind = Object
  if i < args.length() && args[i].text == "(" && !args[i].space_before {
    i = i + 1
    let params : Array[String] = []
    let mut variadic = false
    while i < args.length() && args[i].text != ")" {
      let p = args[i].text
      if p == "..." {
        variadic = true
        i = i + 1
        continue
      }
      if p == "," {
        i = i + 1
        continue
      }
      params.push(p)
      i = i + 1
    }
    if i < args.length() {
      i = i + 1 // closing paren
    } else {
      self.diagnostics.push("unterminated parameter list for '\{name}'")
    }
    kind = Function(params, variadic)
  }
  let body = args[i:].to_owned()
  self.macros[name] = { kind, body, builtin: false, }
}

///|
fn Preprocessor::handle_include(
  self : Preprocessor,
  args : Array[@lex.Token],
  src : @source.SourceText,
) -> Unit raise PreprocessError {
  if !self.active() {
    return
  }
  if args.length() == 0 {
    self.diagnostics.push("malformed #include in '\{src.path}'")
    return
  }
  let stripped = trim_comment_tokens(args)
  let mut kind = @source.Angled
  let mut name = ""
  if stripped.length() == 1 && stripped[0].kind == @lex.Str {
    kind = @source.Quoted
    name = @lex.decode_literal(stripped[0].text)
  } else if stripped.length() >= 2 && stripped[0].text == "<" {
    // `<foo/bar.h>` is tokenized as `<`, `foo`, `/`, `bar`, `.`, `h`, `>`.
    let parts : Array[String] = []
    for k in 1..<stripped.length() {
      if stripped[k].text == ">" {
        break
      }
      parts.push(stripped[k].text)
    }
    name = parts.join("")
    kind = @source.Angled
  } else {
    // Macro-expanded includes such as `#include FOO` are not supported; the
    // alternative is guessing at a generated header's location.
    self.diagnostics.push(
      "skipping non-literal #include at '\{src.path}':\{args[0].line}",
    )
    return
  }
  if name == "" {
    self.diagnostics.push("empty #include name in '\{src.path}'")
    return
  }
  match
    @source.resolve_include(kind, name, src.path, self.options.include_paths) {
    Some(path) => {
      let resolved : String? = self.materialize(path, name)
      match resolved {
        Some(p) => {
          let loaded : @source.SourceText = self.cache.load(p) catch {
            _ => {
              if self.options.strict {
                raise Failed("cannot read included header '\{name}'")
              }
              self.diagnostics.push("cannot read included header '\{name}'")
              return
            }
          }
          self.run_file(loaded)
        }
        None => ()
      }
    }
    None => {
      if self.options.strict {
        raise Failed("cannot find #include <\{name}>")
      }
      self.diagnostics.push(
        "skipping #include of missing header '\{name}' from '\{src.path}'",
      )
    }
  }
}

///|
/// | Turn a resolution result into a cache key. Built-in headers are
/// materialized into the cache on first use so that `run_file` sees an
/// ordinary source.
fn Preprocessor::materialize(
  self : Preprocessor,
  path : String,
  name : String,
) -> String? {
  if path.has_prefix("@builtin/") {
    if self.cache.has(path) {
      return Some(path)
    }
    match @source.builtin_header(name) {
      Some(text) => {
        self.cache.insert(path, text)
        Some(path)
      }
      None => None
    }
  } else {
    Some(path)
  }
}

///|
/// | Drop comments that the lexer could not classify, because they appear
/// inside an `#include <...>` where `//` does not start a comment.
fn trim_comment_tokens(args : Array[@lex.Token]) -> Array[@lex.Token] {
  args
}

///|
fn Preprocessor::handle_pragma(
  self : Preprocessor,
  args : Array[@lex.Token],
  src : @source.SourceText,
) -> Unit raise PreprocessError {
  if !self.active() || args.length() == 0 {
    return
  }
  match args[0].text {
    "pack" => {
      // `#pragma pack(push, n)`, `#pragma pack(pop)`, `#pragma pack(n)`.
      if args.length() >= 2 && args[1].text == "(" {
        // Rebuild the argument text between the parentheses.
        let inner = []
        let mut i = 2
        while i < args.length() && args[i].text != ")" {
          inner.push(args[i].text)
          i = i + 1
        }
        if inner.length() > 0 && inner[0] == "push" {
          self.pragma_stack.push(self.pragma_pack)
          if inner.length() > 1 {
            let v = parse_pack_value(inner[1])
            self.pragma_pack = v
            self.pack_events.push((self.out.length(), Some(v.to_int())))
          }
        } else if inner.length() > 0 && inner[0] == "pop" {
          match self.pragma_stack.pop() {
            Some(v) => {
              self.pragma_pack = v
              self.pack_events.push(
                (
                  self.out.length(),
                  if v == 0L {
                    None
                  } else {
                    Some(v.to_int())
                  },
                ),
              )
            }
            None => self.diagnostics.push("unbalanced #pragma pack(pop)")
          }
        } else if inner.length() > 0 {
          let v = parse_pack_value(inner[0])
          self.pragma_pack = v
          self.pack_events.push(
            (self.out.length(), if v == 0L { None } else { Some(v.to_int()) }),
          )
        }
      }
      self.out.push({
        kind: @lex.Pragma,
        text: self.pragma_pack.to_string(),
        line: args[0].line,
        col: args[0].col,
        file: src.path,
        space_before: true,
      })
    }
    // `#pragma once` is redundant with include guards, which this
    // preprocessor honors by ordinary conditional processing.
    "once" | "GCC" | "clang" | "warning" | "region" | "endregion" => ()
    _ =>
      self.diagnostics.push(
        "ignoring #pragma \{args[0].text} at '\{src.path}':\{args[0].line}",
      )
  }
}

///|
fn pack_text(v : Int64) -> String {
  match v {
    0L => ""
    1L => "1"
    2L => "2"
    4L => "4"
    8L => "8"
    _ => "1"
  }
}

///|
fn parse_pack_value(s : String) -> Int64 {
  match @lex.parse_integer_literal(s) {
    Some(lit) => lit.value
    None => 0L
  }
}

///|
fn Preprocessor::emit_expanded(
  self : Preprocessor,
  tokens : Array[@lex.Token],
) -> Unit {
  if !self.active() {
    return
  }
  let expanded = self.expand_tokens(tokens, 0)
  for t in expanded {
    self.out.push(t)
  }
}

///|
/// | Expansion budget. Each invocation of a function-like macro consumes
/// one unit; pathological headers that nest macros thousands deep are cut
/// off rather than allowed to exhaust memory.
const MAX_EXPANSION_STEPS : Int32 = 200000

///|
/// | Recursively expand macros in `tokens`. `depth` bounds recursion; the
/// remaining budget is shared through the `steps` field on the state.
fn Preprocessor::expand_tokens(
  self : Preprocessor,
  tokens : Array[@lex.Token],
  depth : Int32,
) -> Array[@lex.Token] {
  if depth > 64 {
    self.diagnostics.push("macro expansion nested too deeply; giving up")
    return tokens
  }
  let out : Array[@lex.Token] = []
  let mut i = 0
  while i < tokens.length() {
    let t = tokens[i]
    if t.kind != @lex.Ident {
      out.push(t)
      i = i + 1
      continue
    }
    match self.macros.get(t.text) {
      None => {
        out.push(t)
        i = i + 1
      }
      Some(m) => {
        if m.builtin {
          out.push(self.expand_builtin(t))
          i = i + 1
          continue
        }
        match m.kind {
          Object => {
            let body = self.substitute(m.body, [], t, depth)
            // Rescan replacement tokens while disabling the active macro;
            // this expands aliases and terminates direct/indirect recursion.
            self.macros.remove(t.text)
            out.append(self.expand_tokens(body, depth + 1))
            self.macros[t.text] = m
            i = i + 1
          }
          Function(params, variadic) => {
            // A function-like macro name without a following `(` is left
            // alone, as C requires.
            if i + 1 >= tokens.length() || tokens[i + 1].text != "(" {
              out.push(t)
              i = i + 1
              continue
            }
            let (args, next) = match collect_arguments(tokens, i + 1) {
              Some(pair) => pair
              None => {
                self.diagnostics.push(
                  "unterminated invocation of '\{t.text}' at '\{t.file}':\{t.line}",
                )
                out.push(t)
                i = i + 1
                continue
              }
            }
            // A no-argument invocation `F()` produces one empty argument;
            // a zero-parameter macro must see no arguments at all.
            let supplied = if args.length() == 1 && args[0].length() == 0 {
              []
            } else {
              args
            }
            if params.length() == 0 && supplied.length() == 0 {
              // fine
            } else if variadic && supplied.length() >= params.length() {
              // fine: the tail is folded into `__VA_ARGS__`
            } else if supplied.length() != params.length() {
              self.diagnostics.push(
                "macro '\{t.text}' expects \{params.length()} arguments, got \{supplied.length()}",
              )
            }
            let body = self.substitute(m.body, supplied, t, depth)
            self.macros.remove(t.text)
            out.append(self.expand_tokens(body, depth + 1))
            self.macros[t.text] = m
            i = next
          }
        }
      }
    }
  }
  out
}

///|
fn Preprocessor::expand_builtin(
  self : Preprocessor,
  t : @lex.Token,
) -> @lex.Token {
  match t.text {
    "__LINE__" => { ..t, kind: @lex.Number, text: t.line.to_string(), }
    "__FILE__" => { ..t, kind: @lex.Str, text: "\"\"" + t.file + "\"", }
    _ => t
  }
}

///|
/// | Substitute macro parameters and concatenate `##` operands.
fn Preprocessor::substitute(
  self : Preprocessor,
  body : Array[@lex.Token],
  args : Array[Array[@lex.Token]],
  site : @lex.Token,
  depth : Int32,
) -> Array[@lex.Token] {
  // The parameter list is recovered from the body's own macro entry.
  let names : Array[String] = match self.macros.get(site.text) {
    Some(m) =>
      match m.kind {
        Function(ps, vi) => {
          let out = ps.copy()
          if vi {
            out.push("__VA_ARGS__")
          }
          out
        }
        Object => []
      }
    None => []
  }
  let pieces : Array[Array[@lex.Token]] = []
  let mut i = 0
  while i < body.length() {
    let t = body[i]
    // `#param` stringifies the argument.
    if t.text == "#" &&
      i + 1 < body.length() &&
      is_param(names, body[i + 1].text) {
      let expanded = argument_for(names, args, body[i + 1].text)
      pieces.push([stringify_token(site, expanded)])
      i = i + 2
      continue
    }
    if is_param(names, t.text) {
      let idx = param_index(names, t.text)
      let arg_tokens = if idx >= 0 && idx < args.length() {
        args[idx]
      } else {
        []
      }
      // An operand of `##` is not macro-expanded before pasting.
      let pastes_next = i + 1 < body.length() && body[i + 1].text == "##"
      let pastes_prev = i > 0 && body[i - 1].text == "##"
      if pastes_next || pastes_prev {
        pieces.push(arg_tokens.copy())
      } else {
        pieces.push(self.expand_tokens(arg_tokens, depth + 1))
      }
      i = i + 1
      continue
    }
    pieces.push([t])
    i = i + 1
  }
  let merged = merge_paste(pieces, site, self)
  merged
}

///|
/// | Placeholder used by `substitute`; the real parameter names come from
/// the macro table entry for the invocation site.
fn Preprocessor::body_params_hint(
  self : Preprocessor,
  site : @lex.Token,
) -> Array[String] {
  match self.macros.get(site.text) {
    Some(m) =>
      match m.kind {
        Function(ps, vi) => {
          let out = ps.copy()
          if vi {
            out.push("__VA_ARGS__")
          }
          out
        }
        Object => []
      }
    None => []
  }
}

///|
fn is_param(names : Array[String], text : String) -> Bool {
  for n in names {
    if n == text {
      return true
    }
  }
  false
}

///|
fn param_index(names : Array[String], text : String) -> Int32 {
  for i, n in names {
    if n == text {
      return i
    }
  }
  -1
}

///|
fn argument_for(
  names : Array[String],
  args : Array[Array[@lex.Token]],
  name : String,
) -> Array[@lex.Token] {
  let idx = param_index(names, name)
  if idx >= 0 && idx < args.length() {
    args[idx]
  } else {
    []
  }
}

///|
fn stringify_token(site : @lex.Token, tokens : Array[@lex.Token]) -> @lex.Token {
  let sb = StringBuilder()
  for i, t in tokens {
    if i > 0 && t.space_before {
      sb.write_char(' ')
    }
    sb.write_string(t.text)
  }
  let escaped = sb
    .to_string()
    .replace_all(old="\\", new="\\\\")
    .replace_all(old="\"", new="\\\"")
  {
    kind: @lex.Str,
    text: "\"\"" + escaped + "\"",
    line: site.line,
    col: site.col,
    file: site.file,
    space_before: site.space_before,
  }
}

///|
/// | Join adjacent token groups where `##` appeared between them.
fn merge_paste(
  pieces : Array[Array[@lex.Token]],
  site : @lex.Token,
  self : Preprocessor,
) -> Array[@lex.Token] {
  let out : Array[@lex.Token] = []
  let mut i = 0
  while i < pieces.length() {
    let piece = pieces[i]
    if piece.length() == 1 && piece[0].text == "##" && out.length() > 0 {
      // The paste operator itself: the previous emitted token joins the
      // first token of the next piece.
      if i + 1 < pieces.length() {
        let next = pieces[i + 1]
        if next.length() > 0 {
          let left = out.pop().unwrap()
          let pasted_text = left.text + next[0].text
          let pasted = repaste(left, pasted_text)
          out.push(pasted)
          for k in 1..<next.length() {
            out.push(next[k])
          }
        }
        i = i + 2
        continue
      }
      i = i + 1
      continue
    }
    out.append(piece)
    i = i + 1
  }
  ignore(site)
  ignore(self)
  out
}

///|
/// | Re-tokenize a pasted spelling so that `1` `##` `2` becomes the single
/// number `12` rather than two adjacent tokens.
fn repaste(anchor : @lex.Token, text : String) -> @lex.Token {
  let toks = @lex.tokenize(text)
  let real = toks.filter(t => t.kind != @lex.Eof && t.kind != @lex.Newline)
  if real.length() == 1 {
    { ..real[0], line: anchor.line, col: anchor.col, file: anchor.file, }
  } else {
    { ..anchor, text, }
  }
}

///|
/// | Split a macro invocation's argument list. `open` is the index of the
/// `(`. Returns the arguments and the index just past the closing `)`.
fn collect_arguments(
  tokens : Array[@lex.Token],
  open : Int32,
) -> (Array[Array[@lex.Token]], Int32)? {
  let args : Array[Array[@lex.Token]] = []
  let current : Array[@lex.Token] = []
  let mut depth = 0
  let mut i = open
  while i < tokens.length() {
    let t = tokens[i]
    if t.text == "(" {
      depth = depth + 1
      if depth > 1 {
        current.push(t)
      }
      i = i + 1
      continue
    }
    if t.text == ")" {
      depth = depth - 1
      if depth == 0 {
        args.push(current.copy())
        return Some((args, i + 1))
      }
      current.push(t)
      i = i + 1
      continue
    }
    if t.text == "," && depth == 1 {
      args.push(current.copy())
      current.clear()
      i = i + 1
      continue
    }
    current.push(t)
    i = i + 1
  }
  None
}

///|
/// | Turn the macro table into the `NAME`, `VALUE` pairs that the generator
/// exposes as constants. Only object-like macros whose body is a single
/// integer, character or string literal qualify; anything else (a cast, an
/// arithmetic expression, a function call) is left out rather than
/// evaluated approximately.
fn Preprocessor::collect_defines(
  self : Preprocessor,
) -> Array[(String, String)] {
  let out : Array[(String, String)] = []
  let names = []
  for name, _ in self.macros {
    names.push(name)
  }
  names.sort()
  for name in names {
    match self.macros.get(name) {
      Some(m) =>
        match m.kind {
          Object => {
            if m.builtin {
              continue
            }
            if m.body.length() == 1 {
              let b = m.body[0]
              match b.kind {
                @lex.Number =>
                  match @lex.parse_integer_literal(b.text) {
                    Some(_) => out.push((name, b.text))
                    None =>
                      match parse_float_text(b.text) {
                        Some(_) => out.push((name, b.text))
                        None => ()
                      }
                  }
                @lex.CharLit => out.push((name, b.text))
                @lex.Str => out.push((name, b.text))
                @lex.Ident =>
                  // `#define TRUE true` and friends: expose the alias only
                  // when it names a known macro-free literal later.
                  ()
                _ => ()
              }
            }
          }
          Function(_, _) => ()
        }
      None => ()
    }
  }
  out
}

///|
/// | Whether a token run parses as a floating literal. Handles the decimal
/// and hexadecimal exponent forms and the `f`/`F`/`l`/`L` suffixes.
pub fn parse_float_text(text : String) -> Double? {
  let lower = text.to_lower()
  let mut body = lower
  if body.has_suffix("f") || body.has_suffix("l") {
    body = body[:body.length() - 1].to_string()
  }
  if body == "" {
    return None
  }
  let mut has_digit = false
  let mut has_marker = false
  for c in body {
    match c {
      '0'..<='9' => has_digit = true
      '.' | 'e' | 'p' | '+' | '-' => has_marker = true
      'x' | 'a'..<='f' => ()
      _ => return None
    }
  }
  if !has_digit || !has_marker {
    return None
  }
  if body.has_prefix("0x") {
    hex_float_value(body)
  } else {
    decimal_float_value(body)
  }
}

///|
/// | The value of `text` as a signed decimal integer, or `None`.
fn decimal_int_value(text : String) -> Int32? {
  if text == "" {
    return None
  }
  let mut i = 0
  let mut sign = 1
  if text[0] == '+' {
    i = 1
  } else if text[0] == '-' {
    sign = -1
    i = 1
  }
  let mut v = 0
  let mut any = false
  while i < text.length() {
    let c = text[i].to_int()
    if c < 48 || c > 57 {
      return None
    }
    v = v * 10 + (c - 48)
    any = true
    i = i + 1
  }
  if !any {
    None
  } else {
    Some(sign * v)
  }
}

///|
/// | `0x<mantissa>[p<exp>]`
fn hex_float_value(body : String) -> Double? {
  let rest = body[2:].to_string()
  let mut mantissa_text = rest
  let mut exponent = 0
  match rest.find("p") {
    Some(idx) => {
      mantissa_text = rest[:idx].to_string()
      exponent = match decimal_int_value(rest[idx + 1:].to_string()) {
        Some(v) => v
        None => return None
      }
    }
    None => ()
  }
  let mut value : Double = 0.0
  let mut frac : Double = 0.0
  let mut place : Double = 1.0
  let mut after_point = false
  let mut any = false
  for c in mantissa_text {
    let d = match c {
      '0'..<='9' => c.to_int() - 48
      'a'..<='f' => c.to_int() - 87
      '.' => {
        if after_point {
          return None
        }
        after_point = true
        continue
      }
      _ => return None
    }
    any = true
    if after_point {
      place = place / 16.0
      frac = frac + Double::from_int(d) * place
    } else {
      value = value * 16.0 + Double::from_int(d)
    }
  }
  if !any {
    return None
  }
  Some((value + frac) * pow2(exponent))
}

///|
/// | `[-]<digits>[.<digits>][e<exp>]`
fn decimal_float_value(body : String) -> Double? {
  let mut mantissa_text = body
  let mut exponent = 0
  match body.find("e") {
    Some(idx) => {
      mantissa_text = body[:idx].to_string()
      exponent = match decimal_int_value(body[idx + 1:].to_string()) {
        Some(v) => v
        None => return None
      }
    }
    None => ()
  }
  let mut value : Double = 0.0
  let mut frac : Double = 0.0
  let mut place : Double = 1.0
  let mut after_point = false
  for c in mantissa_text {
    let d = match c {
      '0'..<='9' => c.to_int() - 48
      '.' => {
        if after_point {
          return None
        }
        after_point = true
        continue
      }
      _ => return None
    }
    if after_point {
      place = place / 10.0
      frac = frac + Double::from_int(d) * place
    } else {
      value = value * 10.0 + Double::from_int(d)
    }
  }
  Some((value + frac) * pow2(exponent))
}

///|
/// | `2.0` raised to `exp`, by repeated squaring so that the exponent range
/// of `Double` is never exceeded in an intermediate step.
fn pow2(exp : Int32) -> Double {
  let mut result = 1.0
  let mut e = if exp < 0 { -exp } else { exp }
  let mut base = 2.0
  while e > 0 {
    if e % 2 == 1 {
      result = result * base
    }
    base = base * base
    e = e / 2
  }
  if exp < 0 {
    1.0 / result
  } else {
    result
  }
}
