//! The layout table against recorded ground truth.
//!
//! `testdata/layout/bitfields.h` and `packed.h` each carry, in their comment
//! header, the exact rows `clang -cc1 -fdump-record-layouts-complete` printed
//! for them. Those rows were pasted from a real compiler run, not from this
//! engine, so comparing against them is a genuine check and not a tautology.
//!
//! Whitespace is normalised on both sides before comparing — clang pads its
//! columns, this tool does not — and the annotation clang appends after
//! `[sizeof=…, align=…]` (`#pragma pack(1)` and friends) is dropped, because
//! the numbers beside it already say what it did.

///|
/// | The rows a fixture says clang printed: its comment lines that start with
/// | `struct` or `union`, in order.
fn expected_rows(text : String) -> Array[String] {
  let rows : Array[String] = []
  for raw in text.split("\n") {
    let l = raw.trim().to_string()
    if !l.has_prefix("//") {
      continue
    }
    let body = l[2:].trim().to_string()
    if body.has_prefix("struct ") || body.has_prefix("union ") {
      rows.push(body)
    }
  }
  rows
}

///|
/// | Collapse runs of whitespace and cut anything after the size tag.
fn normalise(row : String) -> String {
  let buf = StringBuilder()
  let mut last_space = false
  for ch in row {
    if ch == '#' {
      // A trailing `#pragma pack(n)` note from clang.
      break
    }
    if ch == ' ' || ch == '\t' {
      if !last_space {
        buf.write_char(' ')
        last_space = true
      }
    } else {
      buf.write_char(ch)
      last_space = false
    }
  }
  let collapsed = buf.to_string().trim().to_string()
  // Everything after `]` is clang's prose, not layout.
  match collapsed.find("]") {
    Some(i) => collapsed[:i + 1].to_string()
    None => collapsed
  }
}

///|
/// | Every row the engine produces for a fixture, in the fixture's own order.
fn engine_rows(header : String, target : @layout.Target) -> Array[String] {
  let opts = @cparse.LoadOptions::new()
  let m = @cparse.load_header(header, opts) catch {
    _ => abort("could not read " + header)
  }
  let out : Array[String] = []
  for tag in m.sorted_record_tags() {
    match @layout.record_row(target, m, tag) {
      Some(row) => out.push(row)
      None => ()
    }
  }
  out
}

///|
/// | The tag a row is about: the second word, after `struct` or `union`.
fn tag_of(row : String) -> String {
  let mut seen = 0
  for w in row.split(" ") {
    if w.length() == 0 {
      continue
    }
    if seen == 1 {
      return w.to_string()
    }
    seen = seen + 1
  }
  ""
}

///|
/// | Compare one fixture against its recorded rows and name the first line
/// | that differs.
fn check_fixture(header : String, target : @layout.Target) -> Unit {
  let text = @fs.read_file_to_string(header) catch {
    _ => abort("could not read " + header)
  }
  let want = expected_rows(text)
  let got = engine_rows(header, target)
  if want.length() == 0 {
    abort(header + " has no recorded rows to compare against")
  }
  if got.length() != want.length() {
    let msg = "\{header}: want \{want.length()} rows, got \{got.length()}"
    eprintln(msg)
    for g in got {
      eprintln("got " + g)
    }
    abort(msg)
  }
  // The fixture lists records in declaration order, the engine in tag order;
  // a layout table is not a sequence, so the rows are matched by tag.
  let by_tag : Map[String, String] = Map([])
  for g in got {
    by_tag[tag_of(g)] = g
  }
  for w in want {
    let tag = tag_of(w)
    let g = match by_tag.get(tag) {
      Some(row) => normalise(row)
      None => abort(header + " has no layout for " + tag)
    }
    let e = normalise(w)
    if g != e {
      let msg = "\{header} \{tag}:\n  want \{e}\n  got  \{g}"
      eprintln(msg)
      abort(msg)
    }
  }
}

///|
test "bitfield unit placement matches clang on every target" {
  // The three targets agree on these ten records, which is why one fixture
  // serves all three.
  for
    t in [
      @layout.Target::sysv64(),
      @layout.Target::aapcs64(),
      @layout.Target::wasm32(),
    ] {
    check_fixture("testdata/layout/bitfields.h", t)
  }
}

///|
test "packing waives the unit check exactly as clang does" {
  for
    t in [
      @layout.Target::sysv64(),
      @layout.Target::aapcs64(),
      @layout.Target::wasm32(),
    ] {
    check_fixture("testdata/layout/packed.h", t)
  }
}

///|
test "rows name the record and end with its size and alignment" {
  let opts = @cparse.LoadOptions::new()
  let m = @cparse.load_header("testdata/layout/bitfields.h", opts) catch {
    _ => abort("could not read the fixture")
  }
  let row = @layout.record_row(@layout.Target::sysv64(), m, "F1").unwrap()
  assert_true(row.has_prefix("struct F1"))
  assert_true(row.has_suffix("[sizeof=8, align=4]"))
}
