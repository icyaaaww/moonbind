//! Tests for the generator.
//!
//! Three layers are tested separately: the name mapping, the type mapping with
//! its mirror decision, and the emitted text. The emitted-text tests check for
//! the shapes the MoonBit compiler demands — `#borrow` on every non-scalar
//! parameter, a body-less `#external` type for opaque records, lower-case
//! constant names — because those are the things that make a generated package
//! fail to build, and a generator whose output does not compile is worthless.

///|
fn i32_() -> @ast.CType {
  @ast.Int(@ast.CI32)
}

///|
fn u32_() -> @ast.CType {
  @ast.Int(@ast.CU32)
}

///|
fn i64_() -> @ast.CType {
  @ast.Int(@ast.CI64)
}

///|
fn u8_() -> @ast.CType {
  @ast.Int(@ast.CU8)
}

///|
fn f64_() -> @ast.CType {
  @ast.Float(@ast.F64)
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
fn bitfield(name : String, ty : @ast.CType, width : Int32) -> @ast.CField {
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
fn module_of(records : Array[@ast.CRecordDecl]) -> @ast.CModule {
  let m = @ast.CModule::new()
  for r in records {
    m.define_record(r)
  }
  m
}

///|
fn param(name : String, ty : @ast.CType) -> @ast.CParam {
  { name, ty, }
}

///|
fn foreign(
  name : String,
  ret : @ast.CType,
  params : Array[@ast.CParam],
) -> @ast.CFnDecl {
  { name, ret, params, variadic: false, internal: false, }
}

///|
fn target() -> @layout.Target {
  @layout.Target::sysv64()
}

// ---------------------------------------------------------------------------
// Names
// ---------------------------------------------------------------------------

///|
test "type names are PascalCase" {
  assert_eq(type_name("sqlite3_stmt"), "Sqlite3Stmt")
  assert_eq(type_name("__int128_t"), "Int128T")
  assert_eq(type_name("FILE"), "File")
  assert_eq(type_name("_"), "Unnamed")
}

///|
test "field names are kept as written unless reserved" {
  assert_eq(field_name("next"), "next")
  assert_eq(field_name("type"), "type_")
  assert_eq(field_name("match"), "match_")
  assert_eq(field_name("_"), "_field")
  assert_eq(field_name(""), "unnamed")
  // A leading underscore is legal in a field position and is kept.
  assert_eq(field_name("_reserved"), "_reserved")
  // A capital first letter is a type token to the parser, so it is lowered.
  assert_eq(field_name("iColumn"), "iColumn")
  assert_eq(field_name("N"), "n")
}

///|
test "constants become lower-case because MoonBit reads UPPER as a type" {
  assert_eq(const_name("SQLITE_OK"), "sqlite_ok")
  assert_eq(const_name("SQLITE_OPEN_READONLY"), "sqlite_open_readonly")
  assert_eq(const_name("EPERM"), "eperm")
  // A single word that happens to be a keyword still needs escaping.
  assert_eq(const_name("TRUE"), "true_")
}

///|
test "parameter names are made up when the prototype omits them" {
  assert_eq(param_name("db", 0), "db")
  assert_eq(param_name("", 2), "arg2")
  assert_eq(param_name("N", 0), "n")
}

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

///|
test "integer kinds map to the nearest MoonBit scalar" {
  assert_eq(int_type(@ast.CI8), "Byte")
  assert_eq(int_type(@ast.CU8), "Byte")
  assert_eq(int_type(@ast.CI16), "Int16")
  assert_eq(int_type(@ast.CU16), "UInt16")
  assert_eq(int_type(@ast.CI32), "Int32")
  assert_eq(int_type(@ast.CU32), "UInt32")
  assert_eq(int_type(@ast.CI64), "Int64")
  assert_eq(int_type(@ast.CU64), "UInt64")
}

///|
test "a char pointer is Bytes on the way in and opaque on the way out" {
  let m = @ast.CModule::new()
  let s = ptr_(u8_())
  assert_eq(moon_type(m, s, Value), "Bytes")
  // The callee owns a returned string; MoonBit must not claim it.
  assert_eq(moon_type(m, s, Returned), "VoidPtr")
}

///|
test "type aliases are followed to the real type" {
  let m = @ast.CModule::new()
  m.add_typedef({ name: "sqlite3", ty: @ast.Record("sqlite3"), })
  m.add_typedef({ name: "sqlite3_int64", ty: i64_(), })
  assert_eq(moon_type(m, @ast.Named("sqlite3_int64"), Value), "Int64")
  assert_eq(moon_type(m, ptr_(@ast.Named("sqlite3")), Value), "Sqlite3Ptr")
  // An alias to a pointer keeps the alias as the handle name, so a reader can
  // find the declaration behind `sqlite3_mutex *`.
  m.add_typedef({ name: "sqlite3_mutex_ptr", ty: ptr_(@ast.Void), })
  assert_eq(moon_type(m, @ast.Named("sqlite3_mutex_ptr"), Value), "VoidPtr")
}

///|
test "every pointer level gets its own handle name" {
  let m = @ast.CModule::new()
  assert_eq(handle_name(m, @ast.Void), "VoidPtr")
  assert_eq(handle_name(m, @ast.Record("stmt")), "StmtPtr")
  assert_eq(handle_name(m, ptr_(@ast.Record("stmt"))), "StmtPtrPtr")
  // A `T **` parameter is an out-parameter: C writes a pointer through it and
  // MoonBit only reads it back afterwards, so it crosses as a writable slot
  // rather than as a handle of its own. `char **` is no exception.
  assert_eq(moon_type(m, ptr_(ptr_(u8_())), Value), "Bytes")
  assert_eq(moon_type(m, ptr_(ptr_(@ast.Record("stmt"))), Value), "Bytes")
}

///|
test "slot sizes follow the native backend" {
  assert_eq(slot_size("Byte"), 4)
  assert_eq(slot_size("Int16"), 4)
  assert_eq(slot_size("Int"), 4)
  assert_eq(slot_size("Int32"), 4)
  assert_eq(slot_size("Int64"), 8)
  assert_eq(slot_size("Double"), 8)
  assert_eq(slot_size("StmtPtr"), 8)
}

// ---------------------------------------------------------------------------
// Mirroring
// ---------------------------------------------------------------------------

///|
test "a record whose C layout equals the MoonBit one is mirrored" {
  let m = module_of([
    struct_of("Pair", [field("a", i64_()), field("b", i64_())]),
    struct_of("Mixed", [field("d", f64_()), field("i", i32_())]),
    // Both of these put the `int` at offset 4, which is also its MoonBit slot.
    struct_of("Tail", [field("a", i32_()), field("c", u8_())]),
    struct_of("Head", [field("c", u8_()), field("a", i32_())]),
  ])
  for tag in ["Pair", "Mixed", "Tail", "Head"] {
    assert_eq(mirror_record(target(), m, tag), Ok(()))
  }
}

///|
test "a record the two languages lay out differently is refused" {
  // C: a at 0, b at 1, c at 4, size 8. MoonBit gives each field a four-byte
  // slot: a at 0, b at 4, c at 8, size 12. Passing this by value would read
  // `c` out of the wrong half of the struct.
  let m = module_of([
    struct_of("Bad", [field("a", u8_()), field("b", u8_()), field("c", i32_())]),
  ])
  assert_true(
    match mirror_record(target(), m, "Bad") {
      Err(LayoutMismatch(_)) => true
      _ => false
    },
  )
}

///|
test "a union and a bitfield are refused for reasons, not by accident" {
  let m = module_of([
    union_of("U", [field("a", i32_()), field("b", i64_())]),
    struct_of("B", [bitfield("a", u32_(), 3), field("b", i32_())]),
    struct_of("P", [field("p", ptr_(@ast.Void)), field("n", i32_())]),
  ])
  assert_eq(mirror_record(target(), m, "U"), Err(IsUnion))
  assert_true(
    match mirror_record(target(), m, "B") {
      Err(Unrepresentable(_)) => true
      _ => false
    },
  )
  assert_true(
    match mirror_record(target(), m, "P") {
      Err(Unrepresentable(_)) => true
      _ => false
    },
  )
}

///|
test "an incomplete record is refused" {
  let m = @ast.CModule::new()
  m.forward_record(@ast.Struct, "Opaque")
  assert_eq(mirror_record(target(), m, "Opaque"), Err(Incomplete))
  assert_eq(mirror_record(target(), m, "Missing"), Err(Incomplete))
}

// ---------------------------------------------------------------------------
// Emitted text
// ---------------------------------------------------------------------------

///|
fn has(text : String, needle : String) -> Bool {
  text.contains(needle)
}

///|
test "an opaque record becomes an extern type with the reason in its doc" {
  // `{Byte; Byte; Int}` is 8 bytes in C with the `int` at 4, and 12 bytes in
  // MoonBit with the `Int` at 8. `{Byte; Int}` would have matched.
  let m = module_of([
    struct_of("Bad", [field("a", u8_()), field("b", u8_()), field("i", i32_())]),
  ])
  let (out, _) = generate(m, target())
  assert_true(has(out, "#external"))
  assert_true(has(out, "pub type Bad"))
  assert_true(has(out, "Opaque: C and MoonBit disagree"))
  assert_false(has(out, "pub(all) struct Bad"))
}

///|
test "a mirrorable record becomes a struct with the header's field names" {
  let m = module_of([
    struct_of("Pair", [field("a", i64_()), field("b", i64_())]),
  ])
  let (out, _) = generate(m, target())
  assert_true(has(out, "pub(all) struct Pair {"))
  assert_true(has(out, "  a : Int64"))
  assert_true(has(out, "  b : Int64"))
}

///|
test "every non-scalar parameter is borrowed, and scalars are not" {
  let m = module_of([
    struct_of("Pair", [field("a", i64_()), field("b", i64_())]),
  ])
  m.add_function(
    foreign("take", i32_(), [
      param("p", ptr_(@ast.Void)),
      param("s", ptr_(u8_())),
      param("n", i32_()),
      param("pair", @ast.Record("Pair")),
    ]),
  )
  let (out, _) = generate(m, target())
  // `Bytes` is a pointer at runtime, so the compiler demands a borrow for it
  // as well; `n` crosses in a register and must not be listed.
  assert_true(has(out, "#borrow(p, s, pair)"))
  assert_true(
    has(
      out, "pub extern \"C\" fn take(p : VoidPtr, s : Bytes, n : Int32, pair : Pair) -> Int32 = \"take\"",
    ),
  )
}

///|
test "a function with only scalars carries no borrow attribute" {
  let m = @ast.CModule::new()
  m.add_function(
    foreign("add", i32_(), [param("a", i32_()), param("b", i32_())]),
  )
  let (out, _) = generate(m, target())
  assert_true(
    has(out, "pub extern \"C\" fn add(a : Int32, b : Int32) -> Int32 = \"add\""),
  )
  assert_false(has(out, "#borrow"))
}

///|
test "a pointer return is an optional handle, not Bytes" {
  let m = @ast.CModule::new()
  m.add_function(foreign("version", ptr_(u8_()), []))
  let (out, _) = generate(m, target())
  assert_true(has(out, "-> VoidPtr = \"version\""))
  assert_true(has(out, "#external\npub type VoidPtr"))
}

///|
test "a by-value parameter that cannot be mirrored is refused with a reason" {
  let m = module_of([
    struct_of("Bad", [field("a", u8_()), field("b", u8_()), field("i", i32_())]),
  ])
  m.add_function(foreign("take", i32_(), [param("b", @ast.Record("Bad"))]))
  let (out, skips) = generate(m, target())
  assert_false(has(out, "fn take"))
  // Two entries: the function, and the record it could not pass. Both are
  // things the caller has to be told about.
  assert_eq(skips.length(), 2)
  assert_eq(skips[0].name, "take")
  assert_true(skips[0].reason.contains("by value"))
}

///|
test "a variadic function is left out rather than emitted wrongly" {
  let m = @ast.CModule::new()
  let f = foreign("printf", i32_(), [param("fmt", ptr_(u8_()))])
  m.add_function({
    name: f.name,
    ret: f.ret,
    params: f.params,
    variadic: true,
    internal: f.internal,
  })
  let (out, skips) = generate(m, target())
  assert_false(has(out, "printf("))
  assert_eq(skips.length(), 1)
  assert_true(skips[0].reason.contains("variadic"))
}

///|
test "enumerators and macros become lower-case integer constants" {
  let m = @ast.CModule::new()
  m.define_enum({
    tag: "e",
    items: [
      { name: "SQLITE_OK", value: 0L, },
      { name: "SQLITE_ROW", value: 100L, },
    ],
    complete: true,
  })
  m.constants.push({
    name: "SQLITE_VERSION_NUMBER",
    ty: i32_(),
    value: 3045000L,
  })
  let (out, _) = generate(m, target())
  assert_true(has(out, "pub let sqlite_ok : Int32 = 0"))
  assert_true(has(out, "pub let sqlite_row : Int32 = 100"))
  assert_true(has(out, "pub let sqlite_version_number : Int32 = 3045000"))
  // The C spelling stays visible so the header can be searched for it.
  assert_true(has(out, "/// C: SQLITE_OK = 0"))
}

///|
test "a value too wide for Int is emitted as Int64" {
  let m = @ast.CModule::new()
  m.constants.push({ name: "BIG", ty: i64_(), value: 4294967296L, })
  let (out, _) = generate(m, target())
  assert_true(has(out, "pub let big : Int64 = 4294967296"))
}

///|
test "a scalar typedef becomes an alias, a record typedef does not" {
  let m = @ast.CModule::new()
  m.add_typedef({ name: "sqlite3_int64", ty: i64_(), })
  m.add_typedef({ name: "sqlite3", ty: @ast.Record("sqlite3"), })
  m.forward_record(@ast.Struct, "struct sqlite3")
  let (out, _) = generate(m, target())
  assert_true(has(out, "pub type Sqlite3Int64 = Int64"))
  // `Sqlite3` is already declared for the record; a second declaration at the
  // same name would not compile, and the alias would say nothing anyway.
  assert_false(has(out, "pub type Sqlite3 = "))
}

///|
test "two C names that collide in MoonBit get distinct declarations" {
  // A record and an enum tagged `sqlite3_stmt` and `SQLITE3_STMT` both want
  // the type name `Sqlite3Stmt`.
  let m = module_of([
    struct_of("sqlite3_stmt", [field("a", i32_())]),
    struct_of("SQLITE3_STMT", [field("b", i32_())]),
  ])
  let (out, _) = generate(m, target())
  assert_true(has(out, "pub(all) struct Sqlite3Stmt {"))
  assert_true(has(out, "pub(all) struct Sqlite3Stmt2 {"))
}

///|
test "the output names its target and its source" {
  let m = @ast.CModule::new()
  m.sources.push("sqlite3.h")
  let (out, _) = generate(m, target())
  assert_true(has(out, "// Generated by moonbind. Do not edit."))
  assert_true(has(out, "// Target: x86_64 SysV (64-bit pointers)"))
  assert_true(has(out, "// Source: sqlite3.h"))
}

///|
test "generation is deterministic" {
  let m = module_of([
    struct_of("B", [field("x", i32_())]),
    struct_of("A", [field("y", i64_())]),
  ])
  m.add_function(foreign("z", i32_(), []))
  m.add_function(foreign("a", i32_(), []))
  let (first, _) = generate(m, target())
  let (second, _) = generate(m, target())
  assert_eq(first, second)
}
