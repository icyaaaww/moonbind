//! Emitting a MoonBit package from a parsed C module.
//!
//! The shape of the output is fixed by what the MoonBit FFI actually accepts,
//! which was established by compiling each form rather than by reading a spec:
//!
//! - a C record that can be mirrored becomes `pub(all) struct`;
//! - any other record becomes an opaque `#external pub type`;
//! - every pointer gets its own opaque handle type, named after its target,
//!   plus `Handle::null()` and `Handle::is_null()` so a NULL is never mistaken
//!   for a live address;
//! - every function keeps its C name on the MoonBit side;
//! - every pointer-like, `Bytes` and by-value-struct parameter must be listed
//!   in a `#borrow(...)` attribute or the package does not compile.
//!
//! A declaration that cannot be expressed faithfully is left out and reported,
//! never emitted approximately. A binding that silently corrupts memory is
//! worse than a binding that is missing.

///|
/// | Append a line.
fn line(buf : StringBuilder, text : String) -> Unit {
  buf.write_string(text)
  buf.write_char('\n')
}

///|
/// | Append an empty line.
fn blank(buf : StringBuilder) -> Unit {
  buf.write_char('\n')
}

///|
/// | A declaration the generator could not express, and why.
pub(all) struct Skip {
  pub name : String
  pub reason : String
} derive(Debug, Eq)

///|
/// | Everything the emitter learns while writing one file.
struct Gen {
  target : @layout.Target
  module : @ast.CModule
  /// The MoonBit type name chosen for every record tag.
  record_types : Map[String, String]
  /// Every type name already declared, so that no two declarations collide.
  used_types : Map[String, Bool]
  /// Every value name already declared.
  used_values : Map[String, Bool]
  /// Opaque handle types mentioned by a signature, in the order they were
  /// first seen.
  handles : Array[String]
  /// Records that could not be mirrored, with the reason, for the report.
  refusals : Array[Skip]
  /// Functions left out, with the reason.
  skips : Array[Skip]
  /// Declarations written.
  emitted_names : Map[String, String]
  function_names : Map[String, String]
  mut emitted : Int32
}

///|
fn Gen::new(target : @layout.Target, module : @ast.CModule) -> Gen {
  // C libraries may typedef names such as Byte. Never redeclare MoonBit's
  // builtin types; scalar aliases already resolve to those builtin types.
  let used_types : Map[String, Bool] = Map([])
  for
    name in [
      "Unit", "Bool", "Byte", "Bytes", "Char", "String", "Int", "UInt", "Int16",
      "UInt16", "Int32", "UInt32", "Int64", "UInt64", "Float", "Double", "Json",
      "Result", "Error", "FuncRef",
    ] {
    used_types[name] = true
  }
  {
    target,
    module,
    record_types: Map([]),
    used_types,
    used_values: Map([
      ("copy_cstr", true),
      ("moonbind_copy_cstr", true),
      ("copy_cstr_array", true),
      ("moonbind_cstr_at", true),
    ]),
    handles: [],
    refusals: [],
    skips: [],
    function_names: Map([]),
    emitted_names: Map([]),
    emitted: 0,
  }
}

///|
/// | Take `want` as a type name, or the first free numbered variant of it.
fn Gen::claim_type(self : Gen, want : String) -> String {
  let mut name = want
  let mut n = 2
  while self.used_types.contains(name) {
    name = want + n.to_string()
    n = n + 1
  }
  self.used_types[name] = true
  name
}

///|
/// | Take `want` as a value name, or the first free numbered variant of it.
fn Gen::claim_value(self : Gen, want : String) -> String {
  let mut name = want
  let mut n = 2
  while self.used_values.contains(name) {
    name = want + "_" + n.to_string()
    n = n + 1
  }
  self.used_values[name] = true
  name
}

///|
/// | The MoonBit type name for a record tag.
fn Gen::record_type(self : Gen, tag : String) -> String {
  match self.record_types.get(tag) {
    Some(name) => name
    None => opaque_name(tag)
  }
}

///|
/// | Announce an opaque handle type and return its name.
fn Gen::handle(self : Gen, want : String) -> String {
  for h in self.handles {
    if h == want {
      return h
    }
  }
  let name = self.claim_type(want)
  self.handles.push(name)
  name
}

///|
/// | The type a parameter or return crosses with, claiming any handle type it
/// | needs. `None` means the type cannot be expressed faithfully.
fn Gen::declare_type(self : Gen, ty : @ast.CType, pos : Position) -> String? {
  // A record by value uses the name the generator actually reserved for it,
  // which is not necessarily the name derived from the tag.
  if strip_typedefs(self.module, ty) is @ast.Record(tag) {
    return Some(self.record_type(tag))
  }
  match moon_type(self.module, ty, pos) {
    "Unit"
    | "Int"
    | "UInt"
    | "Int32"
    | "UInt32"
    | "Int64"
    | "UInt64"
    | "Byte"
    | "Int16"
    | "UInt16"
    | "Float"
    | "Double" as scalar => Some(scalar)
    "Bytes" => Some("Bytes")
    text =>
      // A name the generator already declared is used as it stands.
      match self.used_types.get(text) {
        Some(_) => Some(text)
        // Every handle the type mapper invents ends in `Ptr`, and no other
        // name it returns does. A name that is neither declared nor shaped
        // like a handle is a type this generator does not understand, and the
        // function using it is left out rather than guessed at.
        None =>
          if text.has_suffix("Ptr") {
            Some(self.handle(text))
          } else {
            None
          }
      }
  }
}

///|
/// | True for the types that cross the boundary in a register and therefore
/// | must not be listed in `#borrow`.
fn is_scalar(ty : String) -> Bool {
  match ty {
    "Int"
    | "UInt"
    | "Int32"
    | "UInt32"
    | "Int64"
    | "UInt64"
    | "Byte"
    | "Int16"
    | "UInt16"
    | "Float"
    | "Double"
    | "Unit" => true
    _ => false
  }
}

///|
/// | Emit the header comment naming the input and the target.
fn emit_header(
  buf : StringBuilder,
  module : @ast.CModule,
  target : @layout.Target,
) -> Unit {
  let abi = match target.abi {
    @layout.SysV64 => "x86_64 SysV"
    @layout.Aapcs64 => "aarch64 AAPCS64"
    @layout.Win64 => "Windows x64 LLP64"
    @layout.Wasm32 => "wasm32"
  }
  line(buf, "// Generated by moonbind. Do not edit.")
  line(buf, "//")
  line(buf, "// Target: \{abi} (\{target.pointer_bits}-bit pointers)")
  if module.sources.length() > 0 {
    line(buf, "// Source: \{module.sources.join(", ")}")
  }
}

///|
/// | Emit a mirror `struct`, when the record's C layout equals the MoonBit one.
fn emit_mirror(buf : StringBuilder, gen : Gen, tag : String) -> Unit {
  let decl = gen.module.records.get(tag).unwrap()
  let name = gen.record_type(tag)
  let c_kind = match decl.kind {
    @ast.Struct => "struct"
    @ast.Union => "union"
  }
  line(buf, "/// C: \{c_kind} \{tag}")
  line(buf, "///")
  line(
    buf, "/// Same size and field offsets as the C type. This is a MoonBit value, not",
  )
  line(
    buf, "/// a wire format: the FFI passes every record by reference, so functions",
  )
  line(buf, "/// taking or returning this struct by value are left out.")
  // `pub(all)` already makes every field public, and `derive(Debug)` would
  // generate an `impl` the compiler then wants written as a method, so the
  // struct is plain. Anyone who wants it printable can derive it themselves.
  line(buf, "pub(all) struct \{name} {")
  for field in decl.fields {
    let ty = moon_type(gen.module, field.ty, Value)
    line(buf, "  \{field_name(field.name)} : \{ty}")
  }
  line(buf, "}")
  blank(buf)
}

///|
/// | Emit the opaque type for a record that cannot be mirrored.
fn emit_opaque(buf : StringBuilder, gen : Gen, tag : String) -> Unit {
  let decl = gen.module.records.get(tag).unwrap()
  let name = gen.record_type(tag)
  let c_kind = match decl.kind {
    @ast.Struct => "struct"
    @ast.Union => "union"
  }
  line(buf, "/// C: \{c_kind} \{tag}")
  let reason = match mirror_record(gen.target, gen.module, tag) {
    Err(why) => Some(refusal_text(why).to_string())
    Ok(_) => None
  }
  if reason is Some(text) {
    line(buf, "///")
    line(buf, "/// Opaque: " + text)
  }
  line(buf, "#external")
  line(buf, "pub type \{name}")
  blank(buf)
}

///|
/// | A one-line explanation of why a record is opaque.
fn refusal_text(reason : MirrorRefusal) -> String {
  match reason {
    Incomplete => "the definition is not in this translation unit"
    IsUnion => "a union's members share storage"
    Unrepresentable(why) => "no MoonBit representation: \{why}"
    LayoutMismatch(why) => "C and MoonBit disagree: \{why}"
  }
}

///|
/// | Emit an opaque handle type and the two questions a caller has to be able
/// | to ask about one: is this C's NULL, and how do I spell NULL myself.
/// |
/// | The type is a bare `#external` type rather than `Option[_]` because an
/// | `Option` is a box at the FFI boundary: `None` reaches C as the address of
/// | the box, and a C NULL coming back looks exactly like a box. A bare
/// | external type crosses as the address, so NULL survives both ways.
fn emit_handle(buf : StringBuilder, handle : String) -> Unit {
  let slug = handle.to_lower()
  line(buf, "/// Opaque C pointer. Compare with `is_null` before using it.")
  line(buf, "#external")
  line(buf, "pub type \{handle}")
  blank(buf)
  line(buf, "/// True when this handle is C's NULL.")
  line(buf, "#borrow(p)")
  line(
    buf,
    "extern \"C\" fn \{slug}_is_null(p : \{handle}) -> Int32 = \"moonbind_is_null\"",
  )
  blank(buf)
  line(buf, "/// The NULL value for this handle.")
  line(buf, "extern \"C\" fn \{slug}_null() -> \{handle} = \"moonbind_null\"")
  blank(buf)
  line(buf, "/// Whether this handle is C's NULL.")
  line(buf, "pub fn \{handle}::is_null(self : \{handle}) -> Bool {")
  line(buf, "  \{slug}_is_null(self) != 0")
  line(buf, "}")
  blank(buf)
  line(buf, "/// C's NULL, spelled as this handle's type.")
  line(buf, "pub fn \{handle}::null() -> \{handle} {")
  line(buf, "  \{slug}_null()")
  line(buf, "}")
  blank(buf)
  line(buf, "/// An empty slot for a C out-parameter, i.e. a `T **`.")
  line(buf, "///")
  line(
    buf, "/// Pass it where the header asks for `T **`, then read the result back",
  )
  line(
    buf, "/// with `read_slot`. The slot is rooted in MoonBit for the whole call, so",
  )
  line(buf, "/// nothing C writes through it can be collected.")
  line(buf, "pub fn \{handle}::slot() -> Bytes {")
  line(buf, "  \{slug}_make_slot()")
  line(buf, "}")
  blank(buf)
  line(buf, "/// The handle C wrote into a slot from `slot`.")
  line(buf, "#borrow(slot)")
  line(
    buf,
    "extern \"C\" fn \{slug}_read_slot(slot : Bytes) -> \{handle} = \"moonbind_read_slot\"",
  )
  blank(buf)
  line(buf, "/// Read back the pointer C stored in `slot`.")
  line(buf, "pub fn \{handle}::read_slot(slot : Bytes) -> \{handle} {")
  line(buf, "  \{slug}_read_slot(slot)")
  line(buf, "}")
  blank(buf)
  line(
    buf,
    "extern \"C\" fn \{slug}_make_slot() -> Bytes = \"moonbind_make_slot\"",
  )
  blank(buf)
}

///|
/// | Emit one function, or record why it was left out.
fn emit_function(buf : StringBuilder, gen : Gen, f : @ast.CFnDecl) -> Unit {
  if f.variadic {
    gen.skips.push({
      name: f.name,
      reason: "variadic, which MoonBit cannot call",
    })
    return
  }
  let ret = match gen.declare_type(f.ret, Returned) {
    Some(t) => t
    None => {
      gen.skips.push({
        name: f.name,
        reason: "return type has no MoonBit spelling",
      })
      return
    }
  }
  let params : Array[(String, String)] = []
  let borrowed : Array[String] = []
  for i, p in f.params {
    let ty = match gen.declare_type(p.ty, Value) {
      Some(t) => t
      None => {
        gen.skips.push({
          name: f.name,
          reason: "parameter \{i} has no MoonBit spelling",
        })
        return
      }
    }
    // A struct or union by value is refused even when the layouts agree.
    // Measured, not assumed: MoonBit passes every non-scalar by reference, so
    // a C function expecting a struct in registers reads a pointer's low words
    // instead. `struct {int x; int y;}` with x=3000, y=4000 reaches C as
    // `0 -1` — the tag and length of a box. No MoonBit source spelling of the
    // call fixes that, so the function is left out rather than emitted with a
    // signature the two sides read differently.
    if strip_typedefs(gen.module, p.ty) is @ast.Record(tag) {
      gen.skips.push({
        name: f.name,
        reason: "parameter \{i} passes \{tag} by value, and MoonBit passes records by reference",
      })
      return
    }
    let pname = param_name(p.name, i)
    params.push((pname, ty))
    // Every pointer-shaped parameter must say how it is lent. `Bytes` is a
    // pointer at runtime and the compiler demands the annotation for it too.
    if !is_scalar(ty) {
      borrowed.push(pname)
    }
  }
  // Same asymmetry on the way back: a MoonBit struct cannot hold what C
  // returns in registers, so a record return is refused for the same reason as
  // a record parameter, mirror or not.
  if strip_typedefs(gen.module, f.ret) is @ast.Record(tag) {
    gen.skips.push({
      name: f.name,
      reason: "returns \{tag} by value, and MoonBit returns records by reference",
    })
    return
  }
  let name = gen.claim_value(
    gen.function_names.get(f.name).unwrap_or(function_name(f.name)),
  )
  gen.emitted_names[f.name] = name
  line(buf, "/// C: \{moon_signature(f)}")
  if borrowed.length() > 0 {
    line(buf, "#borrow(\{borrowed.join(", ")})")
  }
  let sig = StringBuilder()
  for i, (pname, ty) in params {
    if i > 0 {
      sig.write_string(", ")
    }
    sig.write_string("\{pname} : \{ty}")
  }
  line(
    buf,
    "pub extern \"C\" fn \{name}(\{sig.to_string()}) -> \{ret} = \"\{f.name}\"",
  )
  blank(buf)
  gen.emitted = gen.emitted + 1
}

///|
/// | The C signature written as a doc comment, so the generated file can be
/// | read next to the header without a second window.
fn moon_signature(f : @ast.CFnDecl) -> String {
  let out = StringBuilder()
  out.write_string(f.name)
  out.write_char('(')
  if f.params.length() == 0 {
    out.write_string("void")
  }
  for i, p in f.params {
    if i > 0 {
      out.write_string(", ")
    }
    if p.name.length() > 0 {
      out.write_string(p.name)
      out.write_string(": ")
    }
    out.write_string(c_shape(p.ty))
  }
  if f.variadic {
    if f.params.length() > 0 {
      out.write_string(", ")
    }
    out.write_string("...")
  }
  out.write_char(')')
  out.to_string()
}

///|
/// | A C type written back out, only for doc comments.
fn c_shape(ty : @ast.CType) -> String {
  match ty {
    @ast.Void => "void"
    @ast.Int(@ast.CI8) => "signed char"
    @ast.Int(@ast.CU8) => "unsigned char"
    @ast.Int(@ast.CI16) => "short"
    @ast.Int(@ast.CU16) => "unsigned short"
    @ast.Int(@ast.CI32) => "int"
    @ast.Int(@ast.CU32) => "unsigned int"
    @ast.Int(@ast.CI64) => "long long"
    @ast.Int(@ast.CU64) => "unsigned long long"
    @ast.Float(@ast.F32) => "float"
    @ast.Float(@ast.F64) => "double"
    @ast.Pointer(inner) => c_shape(inner) + " *"
    @ast.Array(inner, n) => c_shape(inner) + "[\{n}]"
    @ast.Record(tag) => tag
    @ast.EnumType(tag) => "enum " + tag
    @ast.Named(name) => name
    @ast.Fn(_) => "function pointer"
  }
}

///|
/// | Emit an integer constant under the lower-case name MoonBit requires,
/// | keeping the C spelling visible.
fn emit_const(
  buf : StringBuilder,
  gen : Gen,
  c_name : String,
  value : Int64,
) -> Unit {
  let name = gen.claim_value(const_name(c_name))
  let (ty, literal) = if value >= -2147483648L && value <= 2147483647L {
    ("Int32", value.to_string())
  } else {
    ("Int64", value.to_string())
  }
  line(buf, "/// C: \{c_name} = \{value}")
  line(buf, "pub let \{name} : \{ty} = \{literal}")
  gen.emitted = gen.emitted + 1
}

///|
/// | Emit a scalar typedef as a MoonBit type alias, so a signature that names
/// | it in the header reads the same way here.
fn emit_typedef(
  buf : StringBuilder,
  gen : Gen,
  td : @ast.CTypedef,
  name : String,
) -> Unit {
  let underlying = strip_typedefs(gen.module, td.ty)
  let scalar = match underlying {
    @ast.Int(_) | @ast.Float(_) => true
    _ => false
  }
  if !scalar {
    return
  }
  if gen.used_types.contains(name) {
    // The record, enum or handle of the same name already says what this is.
    return
  }
  gen.used_types[name] = true
  line(buf, "/// C: typedef \{c_shape(td.ty)} \{td.name}")
  line(buf, "pub type \{name} = \{moon_type(gen.module, underlying, Value)}")
  gen.emitted = gen.emitted + 1
}

///|
/// | Every record type name, chosen up front so that functions and typedefs can
/// | refer to them.
fn claim_record_types(gen : Gen) -> Unit {
  for tag in gen.module.sorted_record_tags() {
    let name = gen.claim_type(opaque_name(tag))
    gen.record_types[tag] = name
  }
}

///|
/// | Generate the MoonBit source for `module` against `target`.
pub fn generate(
  module : @ast.CModule,
  target : @layout.Target,
  function_names~ : Map[String, String] = Map([]),
  ownership~ : Map[String, String] = Map([]),
  buffers~ : Map[String, String] = Map([]),
  status_codes~ : Map[String, String] = Map([]),
  out_params~ : Map[String, String] = Map([]),
  null_params~ : Map[String, String] = Map([]),
  callbacks~ : Map[String, String] = Map([]),
  copy_strings~ : Array[String] = [],
) -> (String, Array[Skip]) {
  let gen = Gen::new(target, module)
  for key, value in function_names {
    gen.function_names[key] = value
  }
  claim_record_types(gen)
  // `strings.mbt` is written into every generated package and its `copy_cstr`
  // takes a `VoidPtr`, so that handle has to exist even when the header never
  // mentions `void *`. Without this, a binding for a header with no pointer at
  // all fails to compile on the one function the generator wrote itself.
  ignore(gen.handle(void_ptr_name))

  let types = StringBuilder()
  let functions = StringBuilder()
  let consts = StringBuilder()

  for tag in module.sorted_record_tags() {
    match mirror_record(target, module, tag) {
      Ok(_) => emit_mirror(types, gen, tag)
      Err(reason) => {
        emit_opaque(types, gen, tag)
        gen.refusals.push({ name: tag, reason: refusal_text(reason), })
      }
    }
  }
  for name in module.sorted_typedef_names() {
    match module.typedefs.get(name) {
      Some(td) => emit_typedef(types, gen, td, type_name(name))
      None => ()
    }
  }
  for tag in module.sorted_enum_tags() {
    match module.enums.get(tag) {
      Some(decl) =>
        for item in decl.items {
          emit_const(consts, gen, item.name, item.value)
        }
      None => ()
    }
  }
  let macros = module.constants.copy()
  macros.sort_by((a, b) => a.name.compare(b.name))
  for c in macros {
    emit_const(consts, gen, c.name, c.value)
  }
  for f in module.exported_functions() {
    emit_function(functions, gen, f)
  }

  emit_call_contracts(
    functions, gen, status_codes, out_params, null_params, callbacks,
  )
  emit_contracts(functions, gen, ownership, buffers, copy_strings)
  let out = StringBuilder()
  emit_header(out, module, target)
  if !types.is_empty() {
    blank(out)
    out.write_string(types.to_string())
  }
  // Handles are discovered while writing the signatures, so they are declared
  // after the records and before the functions that use them.
  if gen.handles.length() > 0 {
    for handle in gen.handles {
      emit_handle(out, handle)
    }
  }
  if !consts.is_empty() {
    out.write_string(consts.to_string())
  }
  if !functions.is_empty() {
    out.write_string(functions.to_string())
  }
  let skipped = []
  for s in gen.skips {
    skipped.push(s)
  }
  for s in gen.refusals {
    skipped.push(s)
  }
  (out.to_string(), skipped)
}
