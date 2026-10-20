//! From a C type to the MoonBit type that represents it, plus the decision of
//! whether a C record can be mirrored at all.
//!
//! # Why a mirror is not automatic
//!
//! A MoonBit `struct` is not laid out like a C `struct`. What the native
//! backend does — measured, not assumed — is give every field a slot of four
//! or eight bytes and align it to its slot:
//!
//! | MoonBit field type                              | slot |
//! |-------------------------------------------------|------|
//! | `Byte`, `Int16`, `UInt16`, `Int`, `UInt`, `Bool` | 4    |
//! | `Int64`, `UInt64`, `Double`, any pointer         | 8    |
//!
//! So `struct { Byte; Byte; Int }` is 12 bytes in MoonBit with the `Int` at
//! offset 8, while C makes it 8 bytes with the `int` at offset 4. Passing that
//! struct by value would corrupt the third field.
//!
//! A C record can be mirrored only when C's own layout happens to coincide
//! with that slot layout. That is decidable — `layout` computes the C side —
//! so this module decides it instead of guessing, and the generator refuses to
//! emit a by-value function whose record would not match.
//!
//! # Integers
//!
//! MoonBit has no signed 8-bit integer, so `signed char` and `unsigned char`
//! both become `Byte`. The bit pattern is right for a by-value mirror (which
//! copies bytes, not numbers), but a caller that wants the value has to widen
//! it deliberately; the generated doc comment says so rather than hiding it.
//!
//! # Pointers
//!
//! Every pointer becomes an opaque handle named after what it points at, with
//! a `Ptr` suffix so that a handle never collides with the mirror of the
//! record it points at. A `char *` is the exception: it is how C spells a
//! string or a buffer, and `Bytes` crosses the boundary as a plain data
//! pointer, so a `char *` parameter is `Bytes`. A `char *` return cannot be
//! `Bytes` — that memory does not belong to MoonBit — so it comes back as an
//! opaque handle.
//!
//! A handle is a plain `#external` type, never an `Option`. That was measured:
//! an `Option`-typed parameter arrives at C as a pointer to the boxed value,
//! so `None` reaches the callee as some non-null address rather than as
//! `NULL`, and a C `NULL` returned into `T?` is indistinguishable from a
//! legitimate `Some`. A bare external type crosses as the address itself, so
//! `NULL` survives in both directions. Nullable C pointers therefore carry
//! their nullability at the call site — `handle.is_null()` and
//! `Handle::null()` — rather than in the type.

///|
/// | The name of the opaque type used for `void *` and for function pointers.
pub let void_ptr_name : String = "VoidPtr"

///|
/// | How many bytes the native backend gives a field of this MoonBit type, and
/// | what it aligns it to. The two are always equal, which is why one number is
/// | enough.
pub fn slot_size(ty : String) -> Int {
  match ty {
    "Byte" | "Int16" | "UInt16" | "Int" | "UInt" | "Bool" => 4
    _ => 8
  }
}

///|
/// | The MoonBit scalar for a C integer kind.
pub fn int_type(kind : @ast.CIntKind) -> String {
  match kind {
    @ast.CI8 | @ast.CU8 => "Byte"
    @ast.CI16 => "Int16"
    @ast.CU16 => "UInt16"
    @ast.CI32 => "Int"
    @ast.CU32 => "UInt"
    @ast.CI64 => "Int64"
    @ast.CU64 => "UInt64"
  }
}

///|
/// | Where a type sits in a declaration, which changes only the `char *` rule.
pub(all) enum Position {
  /// A function parameter or a record member: a `char *` may be `Bytes`.
  Value
  /// A function return: a `char *` cannot be `Bytes`.
  Returned
} derive(Debug, Eq)

///|
/// | Follow typedefs to the type they eventually spell.
pub fn strip_typedefs(module : @ast.CModule, ty : @ast.CType) -> @ast.CType {
  match ty {
    @ast.Named(name) =>
      match module.typedef_of(name) {
        Some(inner) => strip_typedefs(module, inner)
        None => ty
      }
    _ => ty
  }
}

///|
/// | True when the type, once typedefs are followed, is a pointer to a `char`.
fn points_at_char(module : @ast.CModule, ty : @ast.CType) -> Bool {
  match strip_typedefs(module, ty) {
    @ast.Pointer(inner) =>
      // `char` parses as signed; `unsigned char` is what a header writes for a
      // raw buffer. Both are byte pointers, and both are what a C API means
      // when it takes a string.
      match strip_typedefs(module, inner) {
        @ast.Int(@ast.CI8) | @ast.Int(@ast.CU8) => true
        _ => false
      }
    _ => false
  }
}

///|
/// | The opaque handle name for a pointer whose target is `pointee`.
pub fn handle_name(module : @ast.CModule, pointee : @ast.CType) -> String {
  match strip_typedefs(module, pointee) {
    @ast.Void => void_ptr_name
    @ast.Record(tag) => opaque_name(tag) + "Ptr"
    @ast.EnumType(tag) => type_name(tag) + "Ptr"
    @ast.Fn(_) => void_ptr_name
    @ast.Pointer(inner) => handle_name(module, inner) + "Ptr"
    @ast.Int(kind) => type_name(int_type(kind)) + "Ptr"
    @ast.Float(kind) => type_name(float_type(kind)) + "Ptr"
    _ => void_ptr_name
  }
}

///|
/// | The MoonBit type for a C type.
pub fn moon_type(
  module : @ast.CModule,
  ty : @ast.CType,
  pos : Position,
) -> String {
  match ty {
    @ast.Void => "Unit"
    @ast.Int(kind) => int_type(kind)
    @ast.Float(kind) => float_type(kind)
    // An enum is an `int` unless an enumerator does not fit, and the layout
    // engine widens to eight bytes when one does; `Int` covers the common
    // case and the values are emitted as constants either way.
    @ast.EnumType(_) => "Int"
    // A function pointer cannot be called from MoonBit without a trampoline,
    // so it is carried as an opaque handle rather than pretending otherwise.
    @ast.Fn(_) => void_ptr_name
    @ast.Pointer(_) =>
      if points_at_char(module, ty) {
        match pos {
          Value => "Bytes"
          Returned => void_ptr_name
        }
      } else {
        match strip_typedefs(module, ty) {
          @ast.Pointer(inner) =>
            match strip_typedefs(module, inner) {
              // A second level is an out-parameter: C writes a pointer through
              // it and MoonBit never dereferences it. It crosses as a `Bytes`
              // slot of pointer size (`Handle::slot()`), which keeps the slot
              // rooted in MoonBit while C writes it, and `Handle::read_slot`
              // reads the value back afterwards.
              @ast.Pointer(_) =>
                match pos {
                  Value => "Bytes"
                  Returned => void_ptr_name
                }
              _ => handle_name(module, inner)
            }
          _ => void_ptr_name
        }
      }
    // An array only appears inside a record by value, which the mirror check
    // rejects; as a parameter it has decayed to a pointer before this point.
    @ast.Array(_) => void_ptr_name
    @ast.Record(tag) => type_name(tag)
    // A name that reaches here is a typedef the parser has not expanded. Follow
    // it now: the spelling in the header says nothing about how the value
    // crosses the boundary.
    @ast.Named(name) =>
      match module.typedef_of(name) {
        Some(inner) => moon_type(module, inner, pos)
        None => type_name(name)
      }
  }
}

///|
/// | The MoonBit type for a C integer kind as a scalar name, used when only the
/// | size matters.
pub fn float_type(kind : @ast.CFloatKind) -> String {
  match kind {
    @ast.F32 => "Float"
    @ast.F64 => "Double"
  }
}

///|
fn round_up(value : Int, align : Int) -> Int {
  if align <= 1 {
    value
  } else {
    (value + align - 1) / align * align
  }
}

///|
/// | Why a type has no MoonBit representation inside a by-value record.
fn unrepresentable(module : @ast.CModule, ty : @ast.CType) -> String? {
  match strip_typedefs(module, ty) {
    @ast.Void => Some("void has no storage")
    @ast.Pointer(_) => Some("a pointer has no MoonBit slot")
    @ast.Fn(_) => Some("a function pointer has no MoonBit slot")
    @ast.Array(_) => Some("an array has no MoonBit slot")
    @ast.Record(tag) => Some("an embedded struct " + type_name(tag) + " would need its own mirror")
    @ast.Named(name) => Some("unresolved type " + name)
    _ => None
  }
}

///|
/// | The offsets the native backend would give a record's fields, as
/// | `(offset, slot)` pairs, and the record's size — or `None` when a field has
/// | no MoonBit representation at all.
fn moonbit_mirror(
  module : @ast.CModule,
  decl : @ast.CRecordDecl,
) -> (Array[(Int, Int)], Int)? {
  let out : Array[(Int, Int)] = []
  let mut cursor = 0
  let mut align = 1
  for field in decl.fields {
    if field.bit_width is Some(_) {
      return None
    }
    match unrepresentable(module, field.ty) {
      Some(_) => return None
      None => ()
    }
    let slot = slot_size(moon_type(module, field.ty, Value))
    cursor = round_up(cursor, slot)
    out.push((cursor, slot))
    cursor = cursor + slot
    if slot > align {
      align = slot
    }
  }
  Some((out, round_up(cursor, align)))
}

///|
/// | Why a record cannot be mirrored.
pub(all) enum MirrorRefusal {
  /// The record is not complete in the translation unit.
  Incomplete
  /// A union has no MoonBit counterpart: every member shares storage.
  IsUnion
  /// A member has no MoonBit representation.
  Unrepresentable(String)
  /// Every member is representable, but C and MoonBit place them differently.
  LayoutMismatch(String)
} derive(Debug, Eq)

///|
/// | Decide whether a record may be emitted as a `pub(all) struct` whose bytes
/// | are the bytes C uses, so that it can be passed or returned by value.
pub fn mirror_record(
  target : @layout.Target,
  module : @ast.CModule,
  tag : String,
) -> Result[Unit, MirrorRefusal] {
  let decl = match module.records.get(tag) {
    Some(d) => d
    None => return Err(Incomplete)
  }
  if !decl.complete {
    return Err(Incomplete)
  }
  if decl.kind == @ast.Union {
    return Err(IsUnion)
  }
  let cl = match @layout.layout_record(target, module, tag) {
    Some(l) => l
    None => return Err(Incomplete)
  }
  let slots = match moonbit_mirror(module, decl) {
    Some(pair) => pair
    None => {
      let mut why = "unknown member"
      for field in decl.fields {
        if field.bit_width is Some(_) {
          why = field.name + " is a bitfield"
          break
        }
        match unrepresentable(module, field.ty) {
          Some(reason) => {
            why = field.name + ": " + reason
            break
          }
          None => ()
        }
      }
      return Err(Unrepresentable(why))
    }
  }
  let (offsets, mb_size) = slots
  if mb_size != cl.size.to_int64().to_int() {
    return Err(LayoutMismatch("size is \{mb_size} in MoonBit, \{cl.size} in C"))
  }
  if offsets.length() != cl.fields.length() {
    return Err(LayoutMismatch("field count differs"))
  }
  for i in 0..<offsets.length() {
    let (offset, _) = offsets[i]
    if offset != cl.fields[i].offset.to_int64().to_int() {
      return Err(
        LayoutMismatch(
          "field \{cl.fields[i].name} sits at \{offset} in MoonBit, \{cl.fields[i].offset} in C",
        ),
      )
    }
  }
  Ok(())
}

///|
/// | True when a record may be mirrored.
pub fn is_mirrorable(
  target : @layout.Target,
  module : @ast.CModule,
  tag : String,
) -> Bool {
  match mirror_record(target, module, tag) {
    Ok(_) => true
    Err(_) => false
  }
}
