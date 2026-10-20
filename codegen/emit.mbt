//! Emitting a MoonBit package from a parsed C module.
//!
//! The shape of the output is fixed by what the MoonBit FFI actually accepts,
//! which was established by compiling each form rather than by reading a spec:
//!
//! - a C record that can be mirrored becomes `pub(all) struct`;
//! - any other record becomes an opaque `#external pub type`;
//! - every pointer gets its own opaque handle type, named after its target;
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
  mut emitted : Int
}

///|
fn Gen::new(target : @layout.Target, module : @ast.CModule) -> Gen {
  {
    target,
    module,
    record_types: Map([]),
    used_types: Map([]),
    used_values: Map([]),
    handles: [],
    refusals: [],
    skips: [],
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
fn Gen::declare_type(
  self : Gen,
  ty : @ast.CType,
  pos : Position,
) -> String? {
  // A record by value uses the name the generator actually reserved for it,
  // which is not necessarily the name derived from the tag.
  if strip_typedefs(self.module, ty) is @ast.Record(tag) {
    return Some(self.record_type(tag))
  }
  match moon_type(self.module, ty, pos) {
    "Unit" | "Int" | "UInt" | "Int64" | "UInt64" | "Byte" | "Int16" | "UInt16" |
    "Float" | "Double" as scalar => Some(scalar)
    "Bytes" => Some("Bytes")
    text => {
      // A trailing `?` marks a handle. Everything else is a named type the
      // caller must already have declared, or a handle whose decl is missing.
      if text.has_suffix("?") {
        let base = text.substring(start=0, end=text.length() - 1)
        // A record or enum already owns its name; a `Ptr` suffix cannot
        // collide with it, so anything else is a handle to declare.
        if self.used_types.contains(base) {
          Some(base + "?")
        } else {
          Some(self.handle(base) + "?")
        }
      } else {
        match self.used_types.get(text) {
          Some(_) => Some(text)
          None => None
        }
      }
    }
  }
}

///|
/// | True for the types that cross the boundary in a register and therefore
/// | must not be listed in `#borrow`.
fn is_scalar(ty : String) -> Bool {
  match ty {
    "Int" | "UInt" | "Int64" | "UInt64" | "Byte" | "Int16" | "UInt16" | "Float" |
    "Double" | "Unit" => true
    _ => false
  }
}

///|
/// | Emit the header comment naming the input and the target.
fn emit_header(buf : StringBuilder, module : @ast.CModule, target : @layout.Target) -> Unit {
  let abi = match target.abi {
    @layout.SysV64 => "x86_64 SysV"
    @layout.Aapcs64 => "aarch64 AAPCS64"
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
  line(buf, "/// Laid out identically in C and MoonBit; safe to pass by value.")
  line(buf, "pub(all) struct \{name} {")
  for field in decl.fields {
    let ty = moon_type(gen.module, field.ty, Value)
    line(buf, "  pub \{field_name(field.name)} : \{ty}")
  }
  line(buf, "} derive(Debug)")
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
/// | Emit one function, or record why it was left out.
fn emit_function(buf : StringBuilder, gen : Gen, f : @ast.CFnDecl) -> Unit {
  if f.variadic {
    gen.skips.push({ name: f.name, reason: "variadic, which MoonBit cannot call" })
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
    // A struct or union by value must be mirrorable, or the call would hand C
    // bytes the two languages disagree about.
    if strip_typedefs(gen.module, p.ty) is @ast.Record(tag) {
      match mirror_record(gen.target, gen.module, tag) {
        Ok(_) => ()
        Err(reason) => {
          gen.skips.push({
            name: f.name,
            reason: "parameter \{i} passes \{tag} by value, and \{refusal_text(reason)}",
          })
          return
        }
      }
    }
    let pname = param_name(p.name, i)
    params.push((pname, ty))
    // `Bytes` is already a borrowed view of the caller's buffer, and listing it
    // again is rejected by the compiler.
    if !is_scalar(ty) && ty != "Bytes" {
      borrowed.push(pname)
    }
  }
  if strip_typedefs(gen.module, f.ret) is @ast.Record(tag) {
    match mirror_record(gen.target, gen.module, tag) {
      Ok(_) => ()
      Err(reason) => {
        gen.skips.push({
          name: f.name,
          reason: "returns \{tag} by value, and \{refusal_text(reason)}",
        })
        return
      }
    }
  }
  let name = gen.claim_value(function_name(f.name))
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
    ("Int", value.to_string())
  } else {
    ("Int64", value.to_string())
  }
  line(buf, "/// C: \{c_name} = \{value}")
  line(buf, "pub const \{name} : \{ty} = \{literal}")
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
) -> (String, Array[Skip]) {
  let gen = Gen::new(target, module)
  claim_record_types(gen)

  let types = StringBuilder()
  let functions = StringBuilder()
  let consts = StringBuilder()

  for tag in module.sorted_record_tags() {
    match mirror_record(target, module, tag) {
      Ok(_) => emit_mirror(types, gen, tag)
      Err(reason) => {
        emit_opaque(types, gen, tag)
        gen.refusals.push({ name: tag, reason: refusal_text(reason) })
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
      line(out, "#external")
      line(out, "pub type \{handle}")
      blank(out)
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
