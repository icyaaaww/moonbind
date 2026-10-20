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
fn u16_() -> @ast.CType {
  @ast.Int(@ast.CU16)
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
test "an unpacked bitfield does not cross its declared type's unit" {
  // 26 + 7 do not fit in one 32-bit unit, so `b` starts the next unit.
  let r = struct_of("S", [bits("a", u32_(), 26), bits("b", u32_(), 7)])
  inspect(bit_offset(Target::sysv64(), [r], "S", "b"), content="32")
  inspect(laid_out(Target::sysv64(), [r], "S"), content="(8, 4)")
}

///|
test "an unpacked bitfield that fits stays in the unit" {
  let r = struct_of("S", [bits("a", u32_(), 26), bits("b", u32_(), 4)])
  inspect(bit_offset(Target::sysv64(), [r], "S", "b"), content="26")
  inspect(laid_out(Target::sysv64(), [r], "S"), content="(4, 4)")
}

///|
test "the unit is the declared type's width, not the record's" {
  // Both fields are `unsigned char`, so the unit is eight bits: `b` needs six
  // and only four are left. With `unsigned` instead, the same bits fit in the
  // 32-bit unit and `b` stays at bit 4.
  let narrow = struct_of("N", [bits("a", u8_(), 4), bits("b", u8_(), 6)])
  inspect(bit_offset(Target::sysv64(), [narrow], "N", "b"), content="8")
  inspect(laid_out(Target::sysv64(), [narrow], "N"), content="(2, 1)")
  let wide = struct_of("W", [bits("a", u8_(), 4), bits("b", u32_(), 6)])
  inspect(bit_offset(Target::sysv64(), [wide], "W", "b"), content="4")
  inspect(laid_out(Target::sysv64(), [wide], "W"), content="(4, 4)")
}

///|
test "a wider field following a narrower one uses its own unit" {
  // `a` is a byte, `b` a short. Once four bits are used, fourteen more do not
  // fit in a 16-bit unit, so `b` starts at byte 2. With only seven bits it
  // would have fitted at bit 4, which is the case the next test pins down.
  let r = struct_of("S", [bits("a", u8_(), 4), bits("b", u16_(), 14)])
  inspect(bit_offset(Target::sysv64(), [r], "S", "b"), content="16")
  inspect(laid_out(Target::sysv64(), [r], "S"), content="(4, 2)")
}

///|
test "a wider unit can be entered part way through" {
  // Bit 4 of a 16-bit unit leaves twelve bits, and seven fit.
  let r = struct_of("S", [bits("a", u8_(), 4), bits("b", u16_(), 7)])
  inspect(bit_offset(Target::sysv64(), [r], "S", "b"), content="4")
  inspect(laid_out(Target::sysv64(), [r], "S"), content="(2, 2)")
}

///|
test "three bitfields pack back to back while each fits its unit" {
  let r = struct_of("S", [
    bits("a", u32_(), 8),
    bits("b", u32_(), 9),
    bits("c", u32_(), 15),
  ])
  inspect(bit_offset(Target::sysv64(), [r], "S", "b"), content="8")
  inspect(bit_offset(Target::sysv64(), [r], "S", "c"), content="17")
  inspect(laid_out(Target::sysv64(), [r], "S"), content="(4, 4)")
}

///|
test "a long long unit absorbs bits a narrower unit would not" {
  // The 40-bit field does not affect the check for itself: it starts at 3
  // because it fits in its own 64-bit unit.
  let r = struct_of("S", [bits("a", i32_(), 3), bits("b", i64_(), 40)])
  inspect(bit_offset(Target::sysv64(), [r], "S", "b"), content="3")
  inspect(laid_out(Target::sysv64(), [r], "S"), content="(8, 8)")
}

///|
test "packing waives the unit check instead of shrinking the unit" {
  // The same fields clang lays out at bit 26 under any `#pragma pack`, and
  // under `__attribute__((packed))` as well.
  let p1 = struct_of("A", [bits("a", u32_(), 26), bits("b", u32_(), 7)])
  p1.pack = Some(1)
  inspect(bit_offset(Target::sysv64(), [p1], "A", "b"), content="26")
  inspect(laid_out(Target::sysv64(), [p1], "A"), content="(5, 1)")
  let p2 = struct_of("B", [bits("a", u32_(), 26), bits("b", u32_(), 7)])
  p2.pack = Some(2)
  inspect(bit_offset(Target::sysv64(), [p2], "B", "b"), content="26")
  inspect(laid_out(Target::sysv64(), [p2], "B"), content="(6, 2)")
  let p8 = struct_of("C", [bits("a", u32_(), 26), bits("b", u32_(), 7)])
  p8.pack = Some(8)
  inspect(bit_offset(Target::sysv64(), [p8], "C", "b"), content="26")
  inspect(laid_out(Target::sysv64(), [p8], "C"), content="(8, 4)")
}

///|
test "a packed bitfield takes no alignment from its declared type" {
  let r = struct_of("S", [bits("a", u32_(), 3)])
  r.pack = Some(1)
  inspect(laid_out(Target::sysv64(), [r], "S"), content="(1, 1)")
  // The wide unit is what makes the unpacked record four bytes.
  let loose = struct_of("T", [bits("a", u32_(), 3)])
  inspect(laid_out(Target::sysv64(), [loose], "T"), content="(4, 4)")
}

///|
test "a packed union sizes a bitfield by the bytes it occupies" {
  let packed = union_of("P", [field("c", u8_()), bits("a", u32_(), 20)])
  packed.pack = Some(1)
  inspect(laid_out(Target::sysv64(), [packed], "P"), content="(3, 1)")
  // Unpacked, the member reserves its declared type.
  let loose = union_of("L", [field("c", u8_()), bits("a", u32_(), 20)])
  inspect(laid_out(Target::sysv64(), [loose], "L"), content="(4, 4)")
  // `#pragma pack(2)` caps the alignment but does not shrink the storage.
  let capped = union_of("C", [field("c", u8_()), bits("a", u32_(), 20)])
  capped.pack = Some(2)
  inspect(laid_out(Target::sysv64(), [capped], "C"), content="(4, 2)")
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
