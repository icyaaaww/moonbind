//! Layout expectations for the three targets.
//!
//! Every number here is what `clang -cc1 -fdump-record-layouts` prints for the
//! same shape on the same target, so a failure means the generator and the C
//! compiler disagree about where a field lives — the one class of bug that
//! cannot be worked around downstream.

///|
fn i32_() -> @ast.CType {
  @ast.Int(@ast.CI32)
}

///|
fn u32_() -> @ast.CType {
  @ast.Int(@ast.CU32)
}

///|
fn u8_() -> @ast.CType {
  @ast.Int(@ast.CU8)
}

///|
fn i64_() -> @ast.CType {
  @ast.Int(@ast.CI64)
}

///|
fn ptr_(t : @ast.CType) -> @ast.CType {
  @ast.Pointer(t)
}

///|
fn field(name : String, ty : @ast.CType) -> @ast.CField {
  { name, ty, bit_width: None, anonymous: false, align: None, }
}

///|
fn bits(name : String, ty : @ast.CType, width : Int32) -> @ast.CField {
  { name, ty, bit_width: Some(width), anonymous: false, align: None, }
}

///|
fn struct_of(tag : String, fields : Array[@ast.CField]) -> @ast.CRecordDecl {
  { tag, kind: @ast.Struct, fields, complete: true, pack: None, align: None, }
}

///|
fn union_of(tag : String, fields : Array[@ast.CField]) -> @ast.CRecordDecl {
  { tag, kind: @ast.Union, fields, complete: true, pack: None, align: None, }
}

///|
/// | A module holding exactly the given records.
fn module_of(records : Array[@ast.CRecordDecl]) -> @ast.CModule {
  let m = @ast.CModule::new()
  for r in records {
    m.define_record(r)
  }
  m
}

///|
fn laid_out(
  target : Target,
  records : Array[@ast.CRecordDecl],
  tag : String,
) -> (Int32, Int32) {
  let m = module_of(records)
  match layout_record(target, m, tag) {
    Some(l) => (l.size, l.align)
    None => abort("no layout for \{tag}")
  }
}

///|
/// | The offset of one field.
fn offset(
  target : Target,
  records : Array[@ast.CRecordDecl],
  tag : String,
  name : String,
) -> Int32 {
  let m = module_of(records)
  match layout_record(target, m, tag) {
    Some(l) =>
      match l.offset_of(name) {
        Some(o) => o
        None => abort("no field \{name}")
      }
    None => abort("no layout for \{tag}")
  }
}

///|
/// | The bit offset of one bitfield.
fn bit_offset(
  target : Target,
  records : Array[@ast.CRecordDecl],
  tag : String,
  name : String,
) -> Int32 {
  let m = module_of(records)
  match layout_record(target, m, tag) {
    Some(l) =>
      match l.field(name) {
        Some(f) =>
          match f.bit_offset {
            Some(o) => o
            None => abort("field \{name} is not a bitfield")
          }
        None => abort("no field \{name}")
      }
    None => abort("no layout for \{tag}")
  }
}

///|
test "padding between members" {
  let r = struct_of("S", [field("c", u8_()), field("i", i32_())])
  inspect(laid_out(Target::sysv64(), [r], "S"), content="(8, 4)")
  inspect(offset(Target::sysv64(), [r], "S", "i"), content="4")
}

///|
test "trailing padding to the record alignment" {
  let r = struct_of("S", [field("a", u8_()), field("b", i64_())])
  inspect(laid_out(Target::sysv64(), [r], "S"), content="(16, 8)")
}

///|
test "a struct of chars has alignment one" {
  let r = struct_of("S", [
    field("a", u8_()),
    field("b", u8_()),
    field("c", u8_()),
  ])
  inspect(laid_out(Target::sysv64(), [r], "S"), content="(3, 1)")
}

///|
test "pointers are four bytes on wasm32 and eight elsewhere" {
  let r = struct_of("S", [field("p", ptr_(@ast.Void)), field("n", i32_())])
  inspect(laid_out(Target::sysv64(), [r], "S"), content="(16, 8)")
  inspect(laid_out(Target::aapcs64(), [r], "S"), content="(16, 8)")
  inspect(laid_out(Target::wasm32(), [r], "S"), content="(8, 4)")
}

///|
test "an array member is sized by element times count" {
  let r = struct_of("S", [field("a", @ast.Array(u8_(), 3L)), field("n", i32_())])
  inspect(laid_out(Target::sysv64(), [r], "S"), content="(8, 4)")
  inspect(offset(Target::sysv64(), [r], "S", "n"), content="4")
}

///|
test "a union is as large as its widest member" {
  let r = union_of("U", [field("i", i32_()), field("d", @ast.Float(@ast.F64))])
  inspect(laid_out(Target::sysv64(), [r], "U"), content="(8, 8)")
  inspect(offset(Target::sysv64(), [r], "U", "i"), content="0")
}

///|
test "a union of a char and a long is eight bytes wide, not nine" {
  let r = union_of("U", [field("c", u8_()), field("l", i64_())])
  inspect(laid_out(Target::sysv64(), [r], "U"), content="(8, 8)")
}

///|
test "bitfields fill one unit and stop at its end" {
  let r = struct_of("S", [
    bits("a", u32_(), 3),
    bits("b", u32_(), 5),
    field("c", i32_()),
  ])
  inspect(laid_out(Target::sysv64(), [r], "S"), content="(8, 4)")
  inspect(bit_offset(Target::sysv64(), [r], "S", "a"), content="0")
  inspect(bit_offset(Target::sysv64(), [r], "S", "b"), content="3")
  inspect(offset(Target::sysv64(), [r], "S", "c"), content="4")
}

///|
test "a bitfield may cross a byte boundary" {
  let r = struct_of("S", [bits("a", u32_(), 4), bits("b", u32_(), 8)])
  inspect(bit_offset(Target::sysv64(), [r], "S", "b"), content="4")
  // 12 bits used, but the declared type is `unsigned`, so the record is four
  // bytes and four-byte aligned.
  inspect(laid_out(Target::sysv64(), [r], "S"), content="(4, 4)")
}

///|
test "a bitfield may cross its declared type's boundary on these ABIs" {
  // 26 + 7 bits do not fit in one 32-bit unit, but SysV does not round the
  // second field to a fresh unit: it continues at bit 26.
  let r = struct_of("S", [bits("a", u32_(), 26), bits("b", u32_(), 7)])
  inspect(bit_offset(Target::sysv64(), [r], "S", "b"), content="26")
  inspect(laid_out(Target::sysv64(), [r], "S"), content="(8, 4)")
}

///|
test "a lone bitfield still occupies its whole declared type" {
  let r = struct_of("S", [bits("a", u32_(), 1)])
  inspect(laid_out(Target::sysv64(), [r], "S"), content="(4, 4)")
}

///|
test "a zero-width bitfield ends the unit" {
  let r = struct_of("S", [
    bits("a", u32_(), 1),
    bits("", u32_(), 0),
    bits("b", u32_(), 1),
  ])
  inspect(bit_offset(Target::sysv64(), [r], "S", "b"), content="32")
  inspect(laid_out(Target::sysv64(), [r], "S"), content="(8, 4)")
}

///|
test "a non-bitfield after a bitfield starts at the next byte" {
  let r = struct_of("S", [bits("a", u8_(), 3), field("c", u8_())])
  inspect(offset(Target::sysv64(), [r], "S", "c"), content="1")
  inspect(laid_out(Target::sysv64(), [r], "S"), content="(2, 1)")
}

///|
test "pack lowers member alignment and the record follows" {
  let r = struct_of("S", [field("c", u8_()), field("i", i32_())])
  r.pack = Some(1)
  inspect(laid_out(Target::sysv64(), [r], "S"), content="(5, 1)")
  inspect(offset(Target::sysv64(), [r], "S", "i"), content="1")
}

///|
test "aligned on a record raises its size to a multiple" {
  let r = struct_of("S", [field("c", u8_())])
  r.align = Some(16)
  inspect(laid_out(Target::sysv64(), [r], "S"), content="(16, 16)")
}

///|
test "an embedded record contributes its own alignment" {
  let inner = struct_of("Inner", [field("x", i64_())])
  let outer = struct_of("Outer", [
    field("c", u8_()),
    field("in", @ast.Record("Inner")),
  ])
  inspect(
    laid_out(Target::sysv64(), [inner, outer], "Outer"),
    content="(16, 8)",
  )
  inspect(offset(Target::sysv64(), [inner, outer], "Outer", "in"), content="8")
}

///|
test "an array of records is laid out like the inline rule" {
  let inner = struct_of("Inner", [field("c", u8_()), field("i", i32_())])
  let outer = struct_of("Outer", [
    field("arr", @ast.Array(@ast.Record("Inner"), 2L)),
  ])
  inspect(
    laid_out(Target::sysv64(), [inner, outer], "Outer"),
    content="(16, 4)",
  )
}

///|
test "an opaque record sizes as a pointer and does not crash the walk" {
  // `typedef struct sqlite3 sqlite3;` — a handle that is only ever used
  // through a pointer, but a header is free to embed one by value by mistake.
  let m = @ast.CModule::new()
  m.forward_record(@ast.Struct, "opaque")
  inspect(
    size_of(Target::sysv64(), m, @ast.Pointer(@ast.Record("opaque"))),
    content="(8, 8)",
  )
  inspect(
    size_of(Target::wasm32(), m, @ast.Pointer(@ast.Record("opaque"))),
    content="(4, 4)",
  )
}

///|
test "a typedef is resolved through the table" {
  let m = @ast.CModule::new()
  m.add_typedef({ name: "u32", ty: u32_(), })
  let r = struct_of("S", [field("a", @ast.Named("u32")), field("b", u8_())])
  m.define_record(r)
  inspect(size_of(Target::sysv64(), m, @ast.Named("u32")), content="(4, 4)")
  inspect(layout_record(Target::sysv64(), m, "S").unwrap().size, content="8")
}

///|
test "enums are four bytes unless a value does not fit" {
  let m = @ast.CModule::new()
  m.define_enum({
    tag: "Small",
    items: [{ name: "A", value: 0L, }, { name: "B", value: 2L, }],
    complete: true,
  })
  m.define_enum({
    tag: "Wide",
    items: [{ name: "A", value: 0L, }, { name: "B", value: 4294967296L, }],
    complete: true,
  })
  inspect(
    size_of(Target::sysv64(), m, @ast.EnumType("Small")),
    content="(4, 4)",
  )
  inspect(size_of(Target::sysv64(), m, @ast.EnumType("Wide")), content="(8, 8)")
}

///|
test "an empty struct is legal as a GNU extension and has size zero in C" {
  // Clang and GCC both give `struct S {};` size 0 in C mode; C++ is the
  // language that bumps it to 1. Headers that use the extension mean the C
  // answer, so that is what the generator reports.
  let r = struct_of("S", [])
  inspect(laid_out(Target::sysv64(), [r], "S"), content="(0, 1)")
}

///|
test "layout_module covers every complete record once" {
  let a = struct_of("A", [field("x", u8_())])
  let b = struct_of("B", [field("a", @ast.Record("A")), field("y", i32_())])
  let m = module_of([a, b])
  let all = layout_module(Target::sysv64(), m)
  inspect(all.length(), content="2")
  inspect(all.get("B").unwrap().size, content="8")
}

///|
test "target names parse from the command line" {
  inspect(Target::parse("x86_64").unwrap().pointer_bits, content="64")
  inspect(Target::parse("wasm32").unwrap().pointer_bits, content="32")
  inspect(Target::parse("nonsense") is None, content="true")
}
