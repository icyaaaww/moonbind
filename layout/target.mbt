//! The data models moonbind can lay out records for.
//!
//! Only the properties that change a record's shape are modelled: how wide a
//! pointer and a `long` are, and how a floating point type is aligned. Calling
//! conventions are somebody else's problem; `moonbind` emits declarations,
//! not call sequences.

///|
/// Layout data models. Win64 covers ordinary records only; CLI rejects
/// bitfields, packing/alignment extensions and enums outside signed int.
pub(all) enum Abi {
  /// System V AMD64: `long` and pointers are 64 bits, `long double` is 16
  /// bytes with 16-byte alignment.
  SysV64
  /// AArch64 AAPCS64: scalars match SysV apart from `long double`, which is
  /// a real IEEE quad here.
  Aapcs64
  /// wasm32: 32-bit pointers, 32-bit `long`.
  Wasm32
  /// Windows x64: 64-bit pointers, 32-bit long.
  Win64
} derive(Debug, Eq)

///|
/// | A target's calling convention plus its integer model.
pub(all) struct Target {
  pub abi : Abi
  /// Pointer width in bits. Determines the width of `long` on the ILP32
  /// target and of every pointer.
  pub pointer_bits : Int32
} derive(Debug, Eq)

///|
pub fn Target::sysv64() -> Target {
  { abi: SysV64, pointer_bits: 64, }
}

///|
pub fn Target::aapcs64() -> Target {
  { abi: Aapcs64, pointer_bits: 64, }
}

///|
pub fn Target::wasm32() -> Target {
  { abi: Wasm32, pointer_bits: 32, }
}

///|
/// | Look a target up by the name used on the command line.
pub fn Target::parse(name : String) -> Target? {
  match name {
    "x86_64" | "sysv64" | "native" => Some(Target::sysv64())
    "aarch64" | "arm64" | "aapcs64" => Some(Target::aapcs64())
    "win64" => Some(Target::win64())
    "wasm32" | "wasm" => Some(Target::wasm32())
    _ => None
  }
}

///|
/// Width of C long. Win64 uses LLP64; pointer width alone is insufficient.
pub fn Target::long_bytes(self : Target) -> Int32 {
  if self.abi == Win64 {
    4
  } else {
    self.pointer_bits / 8
  }
}

///|
/// | Size and alignment in bytes of a scalar type. Records report their own
/// layout and are rejected here: a caller that has a `Record` should be
/// asking the layout engine about the tag.
pub fn Target::scalar_size(self : Target, kind : @ast.CIntKind) -> Int32 {
  match kind {
    CI8 | CU8 => 1
    CI16 | CU16 => 2
    CI32 | CU32 => 4
    CI64 | CU64 => 8
  }
}

///|
/// | Alignment of an integer kind is its size on every supported ABI.
pub fn Target::scalar_align(self : Target, kind : @ast.CIntKind) -> Int32 {
  self.scalar_size(kind)
}

///|
pub fn Target::win64() -> Target {
  { abi: Win64, pointer_bits: 64, }
}
