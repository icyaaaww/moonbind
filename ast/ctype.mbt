//! The C type model shared by every stage of the pipeline.
//!
//! Types are structural. Records and enums are referenced by tag rather than
//! by pointer so that forward declarations and mutually recursive types are
//! representable without any graph bookkeeping; the declaration table in
//! `@ast.CModule` resolves a tag to its definition on demand.

///|
/// | An integer kind, named by width and signedness.
/// The `CI`/`CU` prefixes keep the constructors from colliding with the
/// built-in `Int8`/`UInt32` style names, which MoonBit reserves for types and
/// would interpret as a type in constructor position.
pub(all) enum CIntKind {
  CI8
  CU8
  CI16
  CU16
  CI32
  CU32
  CI64
  CU64
} derive(Debug, Eq)

///|
/// | A floating point kind.
pub(all) enum CFloatKind {
  F32
  F64
} derive(Debug, Eq)

///|
/// | A C type as written in a declaration.
///
/// `Record` and `EnumType` hold a canonical tag such as `"struct timespec"`.
/// `Named` holds a typedef or alias name that the parser has not resolved
/// yet; the parser keeps names symbolic and lets `cparse` substitute them so
/// that a first pass over a header never needs the typedef table to be
/// complete.
pub(all) enum CType {
  Void
  Int(CIntKind)
  Float(CFloatKind)
  Pointer(CType)
  Array(CType, Int64)
  Record(String)
  EnumType(String)
  Fn(FnSig)
  Named(String)
} derive(Debug, Eq)

///|
/// | A function type: return type, parameter types, and whether the last
/// parameter is `...`.
pub(all) struct FnSig {
  pub ret : CType
  pub params : Array[CType]
  pub variadic : Bool
} derive(Debug, Eq)

///|
/// | Structural equality. `derive(Eq)` cannot be used here because `CType`
/// is recursive through `FnSig`.
pub fn CType::same(self : CType, other : CType) -> Bool {
  match (self, other) {
    (Void, Void) => true
    (Int(a), Int(b)) => a == b
    (Float(a), Float(b)) => a == b
    (Pointer(a), Pointer(b)) => a.same(b)
    (Array(a, an), Array(b, bn)) => an == bn && a.same(b)
    (Record(a), Record(b)) => a == b
    (EnumType(a), EnumType(b)) => a == b
    (Named(a), Named(b)) => a == b
    (Fn(a), Fn(b)) => a.same(b)
    _ => false
  }
}

///|
/// | Equality of two function signatures.
pub fn FnSig::same(self : FnSig, other : FnSig) -> Bool {
  if self.variadic != other.variadic {
    return false
  }
  if !self.ret.same(other.ret) {
    return false
  }
  if self.params.length() != other.params.length() {
    return false
  }
  for i, p in self.params {
    if !p.same(other.params[i]) {
      return false
    }
  }
  true
}

///|
/// | Number of bits in one value of this integer kind.
pub fn CIntKind::bits(self : CIntKind) -> Int32 {
  match self {
    CI8 | CU8 => 8
    CI16 | CU16 => 16
    CI32 | CU32 => 32
    CI64 | CU64 => 64
  }
}

///|
/// | Whether the integer kind is signed.
pub fn CIntKind::is_signed(self : CIntKind) -> Bool {
  match self {
    CI8 | CI16 | CI32 | CI64 => true
    CU8 | CU16 | CU32 | CU64 => false
  }
}

///|
/// | Number of bits in one value of this float kind.
pub fn CFloatKind::bits(self : CFloatKind) -> Int32 {
  match self {
    F32 => 32
    F64 => 64
  }
}

///|
/// | Whether the type is one of the integer kinds.
pub fn CType::is_integer(self : CType) -> Bool {
  match self {
    Int(_) => true
    _ => false
  }
}

///|
/// | Whether the type is `void`.
pub fn CType::is_void(self : CType) -> Bool {
  self is Void
}

///|
/// | Whether the type is a pointer of any kind.
pub fn CType::is_pointer(self : CType) -> Bool {
  self is Pointer(_)
}

///|
/// | Strip one level of pointer, if present.
pub fn CType::pointee(self : CType) -> CType? {
  match self {
    Pointer(inner) => Some(inner)
    _ => None
  }
}

///|
/// | Replace every unresolved `Named` alias using `resolve`. `resolve`
/// returns its argument unchanged when the name is unknown, so this is safe
/// to run before all typedefs have been seen.
pub fn CType::resolve_names(self : CType, resolve : (String) -> CType) -> CType {
  match self {
    Named(name) => {
      let target = resolve(name)
      match target {
        Named(again) if again == name => self
        Named(_) => target.resolve_names(resolve)
        _ => target.resolve_names(resolve)
      }
    }
    Pointer(inner) => Pointer(inner.resolve_names(resolve))
    Array(inner, n) => Array(inner.resolve_names(resolve), n)
    Fn(sig) => Fn(sig.resolve_names(resolve))
    _ => self
  }
}

///|
/// | Resolve aliases inside a function signature.
pub fn FnSig::resolve_names(self : FnSig, resolve : (String) -> CType) -> FnSig {
  {
    ret: self.ret.resolve_names(resolve),
    params: self.params.map(p => p.resolve_names(resolve)),
    variadic: self.variadic,
  }
}
