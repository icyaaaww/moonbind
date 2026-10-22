///|
pub(all) struct Bridge {
  bindings : String
  c_source : String
  adapted : Array[String]
  skipped : Array[Skip]
  records : Array[String]
}

///|
fn c_identifier(name : String) -> Bool {
  if name.is_empty() {
    return false
  }
  for i, c in name {
    if !(c >= 'a' && c <= 'z') &&
      !(c >= 'A' && c <= 'Z') &&
      c != '_' &&
      !(i > 0 && c >= '0' && c <= '9') {
      return false
    }
  }
  true
}

///|
/// Conservative: no anonymous/nested records, pointers, arrays, bitfields,
/// packed records or narrow integer fields in the first bridge version.
fn bridge_record(m : @ast.CModule, tag : String) -> Bool {
  if !c_identifier(tag) || tag.has_prefix("__anon_") {
    return false
  }
  match m.records.get(tag) {
    Some(r) =>
      r.complete &&
      r.kind == @ast.Struct &&
      r.pack is None &&
      r.align is None &&
      !r.fields.is_empty() &&
      r.fields.all(f => {
        c_identifier(f.name) &&
        !f.anonymous &&
        f.bit_width is None &&
        f.align is None &&
        bridge_scalar(strip_typedefs(m, f.ty))
      })
    None => false
  }
}

///|
fn bridge_scalar(ty : @ast.CType) -> Bool {
  match ty {
    @ast.Int(@ast.CI32 | @ast.CU32 | @ast.CI64 | @ast.CU64) | @ast.Float(_) =>
      true
    _ => false
  }
}

///|
fn bridge_type(m : @ast.CModule, ty : @ast.CType, result : Bool) -> Bool {
  let ty = strip_typedefs(m, ty)
  if bridge_scalar(ty) {
    return true
  }
  match ty {
    @ast.Void => result
    @ast.Record(tag) => bridge_record(m, tag)
    _ => false
  }
}

///|
fn c_record(m : @ast.CModule, tag : String) -> String {
  if m.typedefs.get(tag) is Some({ ty: @ast.Record(same), .. }) && same == tag {
    tag
  } else {
    "struct " + tag
  }
}

///|
fn bridge_c_type(m : @ast.CModule, ty : @ast.CType) -> String {
  match strip_typedefs(m, ty) {
    @ast.Void => "void"
    @ast.Int(k) =>
      (if k.is_signed() { "int" } else { "uint" }) + k.bits().to_string() + "_t"
    @ast.Float(@ast.F32) => "float"
    @ast.Float(@ast.F64) => "double"
    @ast.Record(tag) => c_record(m, tag)
    _ => "unsupported"
  }
}

///|
fn bridge_param(ty : @ast.CType, m : @ast.CModule) -> @ast.CType {
  match strip_typedefs(m, ty) {
    @ast.Record(tag) => @ast.Pointer(@ast.Record(tag))
    t => t
  }
}

///|
fn helper(
  name : String,
  ret : @ast.CType,
  params : Array[@ast.CParam],
) -> @ast.CFnDecl {
  { name, ret, params, variadic: false, internal: false, }
}

///|
/// The bridge owns only allocations returned by *_new and adapted record
/// returns. The caller must free each exactly once and never use it afterward.
/// header is an include path supplied by the CLI; C compiler checks are emitted
/// into the same translation unit, so compiling the bridge checks the layout.
pub fn generate_bridge(
  m : @ast.CModule,
  target : @layout.Target,
  header : String,
  function_names~ : Map[String, String] = Map([]),
) -> Bridge {
  if !m.diagnostics.is_empty() {
    return {
      bindings: "",
      c_source: "",
      adapted: [],
      skipped: [
        {
          name: "module",
          reason: "resolve parser diagnostics before generating a bridge",
        },
      ],
      records: [],
    }
  }
  let functions : Array[@ast.CFnDecl] = []
  let c = StringBuilder()
  c.write_string(
    "/* Generated MoonBind adapter. Compile against the same headers/macros. */\n#include <stdint.h>\n#include <stddef.h>\n#include <stdlib.h>\n#include " +
    header.to_json().stringify() +
    "\n",
  )
  c.write_string(
    "_Static_assert(sizeof(void*) == \{target.pointer_bits / 8}, \"MoonBind pointer width mismatch\");\n",
  )
  c.write_string(
    "_Static_assert(sizeof(long) == \{target.long_bytes()}, \"MoonBind long width mismatch\");\n",
  )
  let adapted : Array[String] = []
  let skips : Array[Skip] = []
  let used : Map[String, Bool] = Map([])
  let candidates = m.exported_functions()
  candidates.append(m.static_definitions)
  for f in candidates {
    if !c_identifier(f.name) ||
      f.name.has_prefix("moonbind_bridge_") ||
      f.name.has_prefix("mb_") ||
      f.variadic ||
      !bridge_type(m, f.ret, true) ||
      !f.params.all(p => bridge_type(m, p.ty, false)) {
      skips.push({
        name: f.name,
        reason: "bridge supports only void/scalars and simple complete records; no varargs, pointers, callbacks, packed or nested records; mb_ names are reserved",
      })
      continue
    }
    let params : Array[@ast.CParam] = []
    let cparams : Array[String] = []
    let callargs : Array[String] = []
    let guards = StringBuilder()
    for i, p in f.params {
      let name = "arg" + i.to_string()
      let ty = strip_typedefs(m, p.ty)
      params.push({ name, ty: bridge_param(ty, m), })
      if ty is @ast.Record(tag) {
        used[tag] = true
        cparams.push("const " + c_record(m, tag) + " *" + name)
        callargs.push("*" + name)
        guards.write_string("  if (!\{name}) abort();\n")
      } else {
        cparams.push(bridge_c_type(m, ty) + " " + name)
        callargs.push(name)
      }
    }
    let ret = strip_typedefs(m, f.ret)
    let call = f.name + "(" + callargs.join(", ") + ")"
    let symbol = "moonbind_bridge_" + f.name
    let sig = if cparams.is_empty() { "void" } else { cparams.join(", ") }
    if ret is @ast.Record(tag) {
      used[tag] = true
      let ct = c_record(m, tag)
      c.write_string(
        "\{ct} *\{symbol}(\{sig}) {\n" +
        guards.to_string() +
        "  \{ct} *out = malloc(sizeof(*out));\n  if (!out) return NULL;\n  *out = \{call};\n  return out;\n}\n",
      )
    } else {
      c.write_string(
        bridge_c_type(m, ret) +
        " " +
        symbol +
        "(" +
        sig +
        ") {\n" +
        guards.to_string() +
        "  " +
        (if ret is @ast.Void { "" } else { "return " }) +
        call +
        ";\n}\n",
      )
    }
    functions.push(helper(f.name, bridge_param(ret, m), params))
    adapted.push(f.name)
  }
  let tags : Array[String] = []
  for tag, _ in used {
    tags.push(tag)
  }
  tags.sort()
  for tag in tags {
    let r = m.records.get(tag).unwrap()
    let ct = c_record(m, tag)
    // Keep C tag casing in helper names to avoid collapsing Point/point.
    let prefix = "mb_" + tag
    let ptr = @ast.Pointer(@ast.Record(tag))
    let layout = @layout.layout_record(target, m, tag).unwrap()
    c.write_string(
      "_Static_assert(sizeof(\{ct}) == \{layout.size}, \"\{tag}: sizeof mismatch\");\n_Static_assert(_Alignof(\{ct}) == \{layout.align}, \"\{tag}: alignment mismatch\");\n",
    )
    let params : Array[@ast.CParam] = []
    let declarations : Array[String] = []
    let init = StringBuilder()
    for i, f in r.fields {
      let ty = strip_typedefs(m, f.ty)
      let arg = "arg" + i.to_string()
      params.push({ name: arg, ty, })
      declarations.push(bridge_c_type(m, ty) + " " + arg)
      init.write_string("  out->\{f.name} = \{arg};\n")
      let offset = layout.offset_of(f.name).unwrap()
      c.write_string(
        "_Static_assert(offsetof(\{ct}, \{f.name}) == \{offset}, \"\{tag}.\{f.name}: offset mismatch\");\n",
      )
      let getter = prefix + "_get_" + f.name
      let setter = prefix + "_set_" + f.name
      c.write_string(
        bridge_c_type(m, ty) +
        " \{getter}(const \{ct} *p) { if (!p) abort(); return p->\{f.name}; }\n",
      )
      c.write_string(
        "void \{setter}(\{ct} *p, " +
        bridge_c_type(m, ty) +
        " value) { if (!p) abort(); p->\{f.name} = value; }\n",
      )
      functions.push(helper(getter, ty, [{ name: "p", ty: ptr, }]))
      functions.push(
        helper(setter, @ast.Void, [
          { name: "p", ty: ptr, },
          { name: "value", ty, },
        ]),
      )
    }
    c.write_string(
      "\{ct} *\{prefix}_new(" +
      declarations.join(", ") +
      ") {\n  \{ct} *out = malloc(sizeof(*out));\n  if (!out) return NULL;\n" +
      init.to_string() +
      "  return out;\n}\n",
    )
    c.write_string("void \{prefix}_free(\{ct} *p) { free(p); }\n")
    functions.push(helper(prefix + "_new", ptr, params))
    functions.push(
      helper(prefix + "_free", @ast.Void, [{ name: "p", ty: ptr, }]),
    )
  }
  let transformed = { ..m, functions, static_definitions: [], }
  let symbols : Map[String, Bool] = Map([])
  let names : Map[String, Bool] = Map([])
  for f in functions {
    let name = function_names.get(f.name).unwrap_or(function_name(f.name))
    if symbols.contains(f.name) || names.contains(name) {
      return {
        bindings: "",
        c_source: "",
        adapted: [],
        skipped: [
          { name, reason: "bridge helper or renamed function collision", },
        ],
        records: [],
      }
    }
    symbols[f.name] = true
    names[name] = true
  }
  let (base, generator_skips) = generate(transformed, target, function_names~)
  let mut bindings = base
  for name, requested in function_names {
    if !base
      .split("\n")
      .any(line => {
        line.contains("fn " + requested + "(") &&
        line.has_suffix("= \"" + name + "\"")
      }) {
      return {
        bindings: "",
        c_source: "",
        adapted: [],
        skipped: [{ name, reason: "requested rename was not emitted exactly", }],
        records: [],
      }
    }
  }
  for name in adapted {
    bindings = bindings.replace(
      old="= \"" + name + "\"",
      new="= \"moonbind_bridge_" + name + "\"",
    )
  }
  // Opaque records are expected; function failures are not silently accepted.
  for skip in generator_skips {
    if functions.any(f => f.name == skip.name) {
      skips.push(skip)
    }
  }
  { bindings, c_source: c.to_string(), adapted, skipped: skips, records: tags, }
}
