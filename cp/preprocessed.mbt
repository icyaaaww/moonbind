//! Results and configuration for preprocessing.

///|
/// | A macro definition.
pub(all) enum MacroKind {
  Object
  Function(Array[String], Bool)
} derive(Debug, Eq)

///|
/// | One entry of the macro table.
pub(all) struct Macro {
  pub kind : MacroKind
  pub body : Array[@lex.Token]
  /// True for compiler-provided macros (`__LINE__`, `__FILE__`), whose
  /// expansion is computed rather than substituted.
  pub builtin : Bool
} derive(Debug)

///|
/// | Data-model description of the target. `#if` evaluation and the built-in
/// headers both depend on it: a `long` is 64 bits on LP64 and 32 bits on
/// Windows, so `typedef long intptr_t` resolves differently per target.
pub(all) struct Platform {
  /// Pointer width in bits: 64 for every modern desktop target, 32 for
  /// `wasm32` when binding a C library compiled to WebAssembly.
  pub pointer_bits : Int32
  pub windows : Bool
  pub wasm : Bool
} derive(Debug, Eq)

///|
/// | A 64-bit LP64 target (Linux, macOS).
pub fn Platform::lp64() -> Platform {
  { pointer_bits: 64, windows: false, wasm: false, }
}

///|
/// | A 64-bit Windows target (LLP64: `long` is 32 bits).
pub fn Platform::win64() -> Platform {
  { pointer_bits: 64, windows: true, wasm: false, }
}

///|
/// | A 32-bit WebAssembly target.
pub fn Platform::wasm32() -> Platform {
  { pointer_bits: 32, windows: false, wasm: true, }
}

///|
/// | The platform a bare header most likely targets. Defaults to LP64 because
/// that is what the majority of portable C libraries are written against.
pub fn Platform::default() -> Platform {
  Platform::lp64()
}

///|
/// | The preprocessor's output.
pub(all) struct Preprocessed {
  /// The translation unit with directives resolved and macros expanded.
  /// Newline tokens are kept so that declaration parsing can recover line
  /// structure if it ever needs it; `lex::strip_newlines` drops them.
  pub tokens : Array[@lex.Token]
  /// Every object-like macro whose body was a single integer or string
  /// literal, in definition order. These become MoonBit constants.
  pub defines : Array[(String, String)]
  /// Locations where `#pragma pack` changed, as an index into `tokens` and
  /// the new packing value (`None` restores natural alignment).
  pub pack_events : Array[(Int32, Int32?)]
  /// Non-fatal problems: unknown pragmas, malformed directives, includes
  /// that were skipped because they were never found.
  pub diagnostics : Array[String]
  /// Every file that was read, in first-inclusion order.
  pub files : Array[String]
} derive(Debug)

///|
/// | An error that stops preprocessing: an unreadable `#include` when strict
/// mode is on, an unterminated conditional, or a malformed directive.
pub(all) suberror PreprocessError {
  Failed(String)
} derive(Debug)
