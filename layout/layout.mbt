//! Record layout for SysV x86-64, AArch64 and wasm32.
//!
//! A C compiler is free to put a field anywhere it likes; what it must do is
//! agree with itself for every translation unit that includes the header. The
//! rules below are the ones GCC and Clang actually implement on the targets
//! moonbind supports:
//!
//! * A non-bitfield starts at the next offset that is a multiple of its
//!   natural alignment, and the cursor advances by its size.
//! * A bitfield occupies `width` consecutive bits at the cursor. It may span
//!   byte boundaries, and on these ABIs it may span the boundary of its own
//!   declared type — `struct { int a : 26; int b : 7; }` is 8 bytes, not 16.
//!   A bitfield still raises the record's alignment to that of its declared
//!   type, which is why `struct { int a : 1; }` is 4 bytes.
//! * A zero-width bitfield moves the cursor to the next multiple of its
//!   declared type's width without contributing alignment of its own.
//! * A record's alignment is the widest member alignment, capped by
//!   `#pragma pack` and raised by `__attribute__((aligned(n)))`, and its size
//!   is rounded up to that alignment so that an array of records stays
//!   aligned.
//! * A union places every member at offset 0 and takes the largest.
//! * An empty record — a GNU extension — is size 0 in C mode, unlike the 1
//!   C++ gives it.
//!
//! None of this is guessed: `moonbind verify` checks every number here against
//! `clang -cc1 -fdump-record-layouts` on the same header, and the fixtures in
//! `testdata/layout` record the expectations that check produces.

///|
/// |
/// | Where one field ended up.
pub(all) struct FieldLayout {
  pub name : String
  /// Byte offset from the start of the record.
  pub offset : Int32
  /// Size in bytes of the field's storage. For a bitfield this is the size of
  /// its declared type, not the width it occupies.
  pub size : Int32
  pub align : Int32
  /// Bit offset from the start of the record, for a bitfield.
  pub bit_offset : Int32?
  /// Width in bits, for a bitfield.
  pub bit_width : Int32?
} derive(Debug, Eq)

///|
/// |
/// | A laid-out record.
pub(all) struct RecordLayout {
  pub tag : String
  pub size : Int32
  pub align : Int32
  pub fields : Array[FieldLayout]
} derive(Debug, Eq)

///|
/// |
/// | Find a field by name.
pub fn RecordLayout::field(self : RecordLayout, name : String) -> FieldLayout? {
  for f in self.fields {
    if f.name == name {
      return Some(f)
    }
  }
  None
}

///|
/// |
/// | Offset of a named field, as the code generator needs it for
/// `offsetof`-style accessors.
pub fn RecordLayout::offset_of(self : RecordLayout, name : String) -> Int32? {
  match self.field(name) {
    Some(f) => Some(f.offset)
    None => None
  }
}

///|
/// |
/// | The layout engine. It holds the module so that a field whose type is
/// another record can be sized, and memoises each record it finishes.
priv struct Engine {
  target : Target
  decls : @ast.CModule
  done : Map[String, RecordLayout]
  /// Records currently being laid out. A record that contains itself by value
  /// is not legal C, but a header can contain one in a branch the
  /// preprocessor did not take, and the walk must not recurse forever.
  busy : Map[String, Bool]
}

///|
/// |
/// | Lay out every complete record in the module, keyed by tag.
pub fn layout_module(
  target : Target,
  decls : @ast.CModule,
) -> Map[String, RecordLayout] {
  let engine : Engine = { target, decls, done: Map([]), busy: Map([]), }
  for tag in decls.sorted_record_tags() {
    let _ = engine.record(tag)
  }
  engine.done
}

///|
/// |
/// | Lay out one record by tag, or `None` if the tag is unknown or incomplete.
pub fn layout_record(
  target : Target,
  decls : @ast.CModule,
  tag : String,
) -> RecordLayout? {
  let engine : Engine = { target, decls, done: Map([]), busy: Map([]), }
  engine.record(tag)
}

///|
/// |
/// | Size and alignment of a type in bytes, as `(size, align)`.
pub fn size_of(
  target : Target,
  decls : @ast.CModule,
  ty : @ast.CType,
) -> (Int32, Int32) {
  let engine : Engine = { target, decls, done: Map([]), busy: Map([]), }
  engine.measure(ty)
}

///|
fn Engine::record(self : Engine, tag : String) -> RecordLayout? {
  match self.done.get(tag) {
    Some(l) => Some(l)
    None =>
      if self.busy.contains(tag) {
        None
      } else {
        match self.decls.records.get(tag) {
          None => None
          Some(decl) =>
            if !decl.complete {
              None
            } else {
              self.busy[tag] = true
              let layout = self.build(tag, decl)
              let _ = self.busy.remove(tag)
              self.done[tag] = layout
              Some(layout)
            }
        }
      }
  }
}

///|
/// |
/// | Size and alignment of a type.
///
/// A reference that cannot be resolved — an opaque forward-declared record,
/// or an identifier that never got a typedef — is sized as a pointer. That is
/// what the type would be in practice for `void *`-shaped handles, and it
/// keeps one unbound name from collapsing the layout of everything containing
/// it. `moonbind verify` reports the unresolved name separately.
fn Engine::measure(self : Engine, ty : @ast.CType) -> (Int32, Int32) {
  match ty {
    @ast.Void => (1, 1)
    @ast.Int(kind) =>
      (self.target.scalar_size(kind), self.target.scalar_align(kind))
    @ast.Float(@ast.F32) => (4, 4)
    @ast.Float(@ast.F64) => (8, 8)
    @ast.Pointer(_) | @ast.Fn(_) => {
      let n = self.target.pointer_bits / 8
      (n, n)
    }
    @ast.Array(inner, count) => {
      let (size, align) = self.measure(inner)
      (size * count.to_int(), align)
    }
    @ast.EnumType(tag) =>
      match self.decls.enums.get(tag) {
        Some(decl) => self.enum_measure(decl)
        None => (4, 4)
      }
    @ast.Record(tag) =>
      match self.record(tag) {
        Some(l) => (l.size, l.align)
        None => {
          let n = self.target.pointer_bits / 8
          (n, n)
        }
      }
    @ast.Named(name) =>
      match self.decls.typedef_of(name) {
        Some(ty) => self.measure(ty)
        None => {
          let n = self.target.pointer_bits / 8
          (n, n)
        }
      }
  }
}

///|
/// |
/// | The size of an enum's underlying type. Without `-fshort-enums`, GCC and
/// Clang use `int` unless some enumerator does not fit, in which case they
/// widen to `long`/`unsigned long`.
fn Engine::enum_measure(self : Engine, decl : @ast.CEnumDecl) -> (Int32, Int32) {
  let mut min : Int64 = 0L
  let mut max : Int64 = 0L
  for item in decl.items {
    if item.value < min {
      min = item.value
    }
    if item.value > max {
      max = item.value
    }
  }
  if min >= -2147483648L && max <= 2147483647L {
    (4, 4)
  } else if min >= 0L && max <= 4294967295L {
    (4, 4)
  } else {
    let n = self.target.long_bytes()
    (n, n)
  }
}

///|
/// |
/// | The layout of one record.
fn Engine::build(
  self : Engine,
  tag : String,
  decl : @ast.CRecordDecl,
) -> RecordLayout {
  if decl.kind == @ast.Union {
    self.build_union(tag, decl)
  } else {
    self.build_struct(tag, decl)
  }
}

///|
fn Engine::build_union(
  self : Engine,
  tag : String,
  decl : @ast.CRecordDecl,
) -> RecordLayout {
  let fields : Array[FieldLayout] = []
  let mut size = 0
  let mut max_align = 1
  for field in decl.fields {
    let (fsize, falign) = self.measure(field.ty)
    let al = self.member_align(field, falign, decl.pack)
    if field.bit_width is Some(width) {
      // A bitfield member of a union still reserves its declared type; the
      // bits it uses do not shrink the union.
      fields.push({
        name: field.name,
        offset: 0,
        size: fsize,
        align: al,
        bit_offset: Some(0),
        bit_width: Some(width.to_int64().to_int()),
      })
    } else {
      fields.push(plain_field(field, 0, fsize, al))
    }
    if fsize > size {
      size = fsize
    }
    if al > max_align {
      max_align = al
    }
  }
  let align = record_align(max_align, decl.align)
  { tag, size: round_up(size, align), align, fields, }
}

///|
fn Engine::build_struct(
  self : Engine,
  tag : String,
  decl : @ast.CRecordDecl,
) -> RecordLayout {
  let fields : Array[FieldLayout] = []
  // The cursor is measured in bits so that bitfields need no unit bookkeeping:
  // they simply consume the bits between one byte-aligned field and the next.
  let mut cursor_bits = 0
  let mut max_align = 1
  for field in decl.fields {
    let (usize, ualign) = self.measure(field.ty)
    let al = self.member_align(field, ualign, decl.pack)
    if field.bit_width is Some(width) {
      let w = width.to_int64().to_int()
      if w == 0 {
        // A zero-width bitfield aligns the next field to its declared type
        // but, as GCC does, leaves the record's own alignment alone.
        cursor_bits = round_up(cursor_bits, usize * 8)
      } else {
        if al > max_align {
          max_align = al
        }
        fields.push({
          name: field.name,
          offset: cursor_bits / 8,
          size: usize,
          align: al,
          bit_offset: Some(cursor_bits),
          bit_width: Some(w),
        })
        cursor_bits = cursor_bits + w
      }
    } else {
      if al > max_align {
        max_align = al
      }
      cursor_bits = round_up(cursor_bits, al * 8)
      fields.push(plain_field(field, cursor_bits / 8, usize, al))
      cursor_bits = cursor_bits + usize * 8
    }
  }
  let align = record_align(max_align, decl.align)
  let size = round_up(ceil_div(cursor_bits, 8), align)
  { tag, size, align, fields, }
}

///|
/// |
/// | A member's alignment after `#pragma pack` and an explicit `aligned`
/// attribute. Packing can only lower an alignment; `aligned` can only raise
/// it, including past the packing limit, which is what GCC does.
fn Engine::member_align(
  self : Engine,
  field : @ast.CField,
  natural : Int32,
  pack : Int32?,
) -> Int32 {
  let _ = self
  let mut al = natural
  if pack is Some(n) {
    let limit = n.to_int64().to_int()
    if limit > 0 && limit < al {
      al = limit
    }
  }
  if field.align is Some(n) {
    let want = n.to_int64().to_int()
    if want > al {
      al = want
    }
  }
  if al < 1 {
    al = 1
  }
  al
}

///|
/// |
/// | A record's alignment: its widest member, raised by `aligned(n)` on the
/// record itself.
fn record_align(natural : Int32, explicit : Int32?) -> Int32 {
  if explicit is Some(n) {
    let want = n.to_int64().to_int()
    if want > natural {
      return want
    }
  }
  natural
}

///|
fn plain_field(
  field : @ast.CField,
  offset : Int32,
  size : Int32,
  align : Int32,
) -> FieldLayout {
  { name: field.name, offset, size, align, bit_offset: None, bit_width: None, }
}

///|
/// |
/// | Round `value` up to a multiple of `align`.
fn round_up(value : Int32, align : Int32) -> Int32 {
  if align <= 1 {
    value
  } else {
    ceil_div(value, align) * align
  }
}

///|
fn ceil_div(value : Int32, divisor : Int32) -> Int32 {
  (value + divisor - 1) / divisor
}
