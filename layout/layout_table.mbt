//! The layout engine's answers, in a form a C compiler can be checked against.
//!
//! `moonbind verify` prints this table; CI prints the same records with
//! `clang -cc1 -fdump-record-layouts-complete` on the same header, normalises
//! both to one row per record, and diffs. Nothing here trusts the layout
//! engine: every number it computes has to survive a compiler that was not
//! told what the answer should be.
//!
//! One row per record, in the compact form used by the fixtures in
//! `testdata/layout`:
//!
//! ```text
//! struct F1   0:0-25 a   4:0-6 b   [sizeof=8, align=4]
//! ```
//!
//! A bitfield prints the byte it starts in, then the bit range within that
//! byte: `a` at bit 0 width 26 is `0:0-25`, `b` at bit 32 width 7 is `4:0-6`.
//! A plain field prints `byte:0-(8*size-1)`, which is how clang reports the
//! bits a member occupies.

///|
/// | One record as a table row, or `None` if it is incomplete.
pub fn record_row(
  target : Target,
  module : @ast.CModule,
  tag : String,
) -> String? {
  match layout_record(target, module, tag) {
    None => None
    Some(lay) => Some(layout_line(module, lay))
  }
}

///|
/// | One laid-out record as a table row.
fn layout_line(module : @ast.CModule, lay : RecordLayout) -> String {
  let kind = match module.records.get(lay.tag) {
    Some(decl) => if decl.kind == @ast.Union { "union" } else { "struct" }
    None => "struct"
  }
  let buf = StringBuilder()
  buf.write_string(kind)
  buf.write_char(' ')
  buf.write_string(lay.tag)
  for f in lay.fields {
    // Fields are separated by two spaces so that the row stays readable
    // without depending on a column width, and no row ends in a space: a
    // diff that trips on whitespace is not a layout bug.
    buf.write_string("  ")
    // A bitfield prints the byte it starts in, then the bit range within that
    // byte, so a 26-bit field at bit 0 is `0:0-25` and a 7-bit field at bit 26
    // is `3:2-8`. The high end is not reduced modulo 8 — it is how far into the
    // byte's bit numbering the field's last bit sits. A plain member prints its
    // offset alone, which is what clang's compact dump does: it has no bit
    // range to report and the size is implied by the declaration.
    match (f.bit_offset, f.bit_width) {
      (Some(start), Some(width)) => {
        let lo = start % 8
        buf.write_string("\{start / 8}:\{lo}-\{lo + width - 1} \{f.name}")
      }
      _ => buf.write_string("\{f.offset} \{f.name}")
    }
  }
  buf.write_string(" [sizeof=\{lay.size}, align=\{lay.align}]")
  buf.to_string()
}

///|
/// | Every complete record in `module`, one row each, sorted by tag so that
/// | two runs can be compared line by line.
pub fn layout_table(target : Target, module : @ast.CModule) -> String {
  let rows : Array[String] = []
  for tag in module.sorted_record_tags() {
    match record_row(target, module, tag) {
      Some(row) => rows.push(row)
      None => ()
    }
  }
  let buf = StringBuilder()
  for i, row in rows {
    if i > 0 {
      buf.write_char('\n')
    }
    buf.write_string(row)
  }
  buf.to_string()
}
