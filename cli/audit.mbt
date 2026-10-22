///|
/// Stable structural type descriptions, independent of debug formatting.
fn type_text(ty : @ast.CType) -> String {
  match ty {
    Void => "void"
    Int(k) => (if k.is_signed() { "i" } else { "u" }) + k.bits().to_string()
    Float(k) => "f" + k.bits().to_string()
    Pointer(t) => "ptr(" + type_text(t) + ")"
    Array(t, n) => "array(" + type_text(t) + "," + n.to_string() + ")"
    Record(name) => "record:" + name
    EnumType(name) => "enum:" + name
    Named(name) => "typedef:" + name
    Fn(f) =>
      "fn(" +
      f.params.map(type_text).join(",") +
      (if f.variadic { ",..." } else { "" }) +
      ")->" +
      type_text(f.ret)
  }
}

///|
fn[T : ToJson] optional_json(value : T?) -> Json {
  match value {
    Some(value) => value.to_json()
    None => Json::null()
  }
}

///|
pub fn failure_report(message : String) -> String {
  let report : Json = {
    "schema_version": 1,
    "generator_version": version,
    "status": "failed",
    "error": message,
  }
  report.stringify(indent=2)
}

///|
/// Include the invocation context so a report cannot be mistaken for an
/// unconditional statement about every platform or macro configuration.
fn with_context(report : Json, options : Options) -> Json {
  match report {
    Object(fields) => {
      let fields = fields.copy()
      fields["analysis"] = {
        "header": options.header,
        "compare": optional_json(options.compare),
        "include_paths": options.include_paths,
        "defines": options.defines,
        "allow_functions": options.allow_functions,
        "rename_functions": options.rename_functions,
        "strict": options.strict,
        "bridge": options.bridge,
        "fail_on": options.fail_on,
        "ownership": options.ownership,
        "buffers": options.buffers,
        "status_codes": options.status_codes,
        "out_params": options.out_params,
        "output_buffers": options.output_buffers,
        "managed_outputs": options.managed_outputs,
        "null_params": options.null_params,
        "callbacks": options.callbacks,
        "trace_calls": options.trace_calls,
        "copy_strings": options.copy_strings,
      }
      Json::object(fields)
    }
    _ => report
  }
}

///|
fn function_text(f : @ast.CFnDecl) -> String {
  type_text(
    @ast.Fn({
      ret: f.ret,
      params: f.params.map(p => p.ty),
      variadic: f.variadic,
    }),
  )
}

///|
fn target_name(t : @layout.Target) -> String {
  match t.abi {
    SysV64 => "x86_64"
    Aapcs64 => "aarch64"
    Win64 => "win64"
    Wasm32 => "wasm32"
  }
}

///|
fn selected_module(m : @ast.CModule, allowed : Array[String]) -> @ast.CModule {
  if allowed.is_empty() {
    m
  } else {
    { ..m, functions: m.functions.filter(f => allowed.contains(f.name)), }
  }
}

///|
fn skip_reason(skips : Array[@codegen.Skip], name : String) -> String {
  for s in skips {
    if s.name == name {
      return s.reason
    }
  }
  "not emitted"
}

///|
/// Report includes function outcomes individually; opaque records are not
/// counted as missing functions. Excluded functions remain visible in the report.
pub fn generation_report(
  m : @ast.CModule,
  target : @layout.Target,
  allowed : Array[String],
) -> Json {
  let (text, skips) = @codegen.generate(selected_module(m, allowed), target)
  let functions : Array[Json] = []
  let mut emitted = 0
  let mut skipped = 0
  let mut excluded = 0
  for f in m.exported_functions() {
    let status = if !allowed.is_empty() && !allowed.contains(f.name) {
      excluded = excluded + 1
      "excluded"
    } else if text.contains("= \"" + f.name + "\"") {
      emitted = emitted + 1
      "generated"
    } else {
      skipped = skipped + 1
      "skipped"
    }
    let reason = if status == "skipped" {
      skip_reason(skips, f.name)
    } else {
      ""
    }
    functions.push({
      "name": f.name,
      "signature": function_text(f),
      "source": source_location(m, f.name),
      "status": status,
      "reason": reason,
    })
  }
  let records : Array[Json] = []
  for tag in m.sorted_record_tags() {
    let (status, reason) = match @codegen.mirror_record(target, m, tag) {
      Ok(_) => ("mirrored", "")
      Err(_) => ("opaque", skip_reason(skips, tag))
    }
    records.push({ "name": tag, "status": status, "reason": reason })
  }
  {
    "schema_version": 1,
    "generator_version": version,
    "target": target_name(target),
    "summary": {
      "generated_functions": emitted,
      "skipped_functions": skipped,
      "excluded_functions": excluded,
    },
    "sources": m.sources,
    "functions": functions,
    "records": records,
  }
}

///|
/// Collect transitive type dependencies, including records behind pointers.
/// These mark review candidates, not guaranteed ABI breakage.
fn dependencies(
  m : @ast.CModule,
  ty : @ast.CType,
  seen : Map[String, Bool],
) -> Unit {
  match ty {
    Pointer(t) | Array(t, _) => dependencies(m, t, seen)
    Fn(f) => {
      dependencies(m, f.ret, seen)
      for t in f.params {
        dependencies(m, t, seen)
      }
    }
    Record(tag) => {
      let key = "record:" + tag
      if !seen.contains(key) {
        seen[key] = true
        if m.records.get(tag) is Some(r) {
          for field in r.fields {
            dependencies(m, field.ty, seen)
          }
        }
      }
    }
    EnumType(tag) => seen["enum:" + tag] = true
    Named(name) => {
      let key = "typedef:" + name
      if !seen.contains(key) {
        seen[key] = true
        if m.typedefs.get(name) is Some(td) {
          dependencies(m, td.ty, seen)
        }
      }
    }
    _ => ()
  }
}

///|
fn api_entries(
  m : @ast.CModule,
  t : @layout.Target,
  allowed : Array[String],
) -> Map[String, Json] {
  let result : Map[String, Json] = Map([])
  let (generated, skips) = @codegen.generate(selected_module(m, allowed), t)
  for f in m.exported_functions() {
    let status = if !allowed.is_empty() && !allowed.contains(f.name) {
      "excluded"
    } else if m.static_definitions.any(s => s.name == f.name) {
      "requires_bridge"
    } else if generated.contains("= \"" + f.name + "\"") {
      "generated"
    } else {
      "skipped"
    }
    result["function:" + f.name] = {
      "signature": function_text(f),
      "parameters": f.params.map(p => {
        "name": p.name,
        "type": type_text(p.ty),
      }),
      "binding_status": status,
      "reason": if status == "skipped" {
        skip_reason(skips, f.name)
      } else {
        ""
      },
    }
  }
  for tag in m.sorted_record_tags() {
    let r = m.records.get(tag).unwrap()
    let fields : Array[Json] = r.fields.map(f => {
      "name": f.name,
      "type": type_text(f.ty),
      "bit_width": optional_json(f.bit_width),
      "align": optional_json(f.align),
    })
    let status = match @codegen.mirror_record(t, m, tag) {
      Ok(_) => "mirrored"
      Err(_) => "opaque"
    }
    result["record:" + tag] = {
      "kind": if r.kind == @ast.Struct {
        "struct"
      } else {
        "union"
      },
      "complete": r.complete,
      "pack": optional_json(r.pack),
      "align": optional_json(r.align),
      "fields": fields,
      "layout": optional_json(@layout.record_row(t, m, tag)),
      "binding_status": status,
    }
  }
  for name in m.sorted_typedef_names() {
    result["typedef:" + name] = type_text(m.typedefs.get(name).unwrap().ty).to_json()
  }
  for tag in m.sorted_enum_tags() {
    let e = m.enums.get(tag).unwrap()
    let items : Array[Json] = e.items.map(i => {
      "name": i.name,
      "value": i.value.to_string(),
    })
    result["enum:" + tag] = { "complete": e.complete, "items": items }
  }
  for c in m.constants {
    result["constant:" + c.name] = {
      "type": type_text(c.ty),
      "value": c.value.to_string(),
    }
  }
  result
}

///|
fn abi_identity(entry : Json) -> String {
  match entry {
    Object(fields) => {
      let copy = fields.copy()
      copy.remove("parameters")
      copy.to_json().stringify()
    }
    _ => entry.stringify()
  }
}

///|
/// Both headers must be parsed with the same ABI and macro settings. This is
/// a source-level review report, not a complete binary compatibility checker.
pub fn compare_headers(
  old : @ast.CModule,
  new : @ast.CModule,
  target : @layout.Target,
  allowed : Array[String],
) -> Json {
  let old = {
    ..old,
    functions: old.functions +
    old.static_definitions.map(f => { ..f, internal: false, }),
  }
  let new = {
    ..new,
    functions: new.functions +
    new.static_definitions.map(f => { ..f, internal: false, }),
  }
  let before = api_entries(old, target, allowed)
  let after = api_entries(new, target, allowed)
  let keys : Array[String] = []
  for key, _ in before {
    keys.push(key)
  }
  for key, _ in after {
    if !before.contains(key) {
      keys.push(key)
    }
  }
  keys.sort()
  let changed : Map[String, Bool] = Map([])
  let changes : Array[Json] = []
  let parameter_renames : Array[Json] = []
  for key in keys {
    let a = before.get(key)
    let b = after.get(key)
    // JSON values are constructed in fixed field order, so this comparison is
    // deterministic and does not depend on parser declaration order.
    if a.map(abi_identity) != b.map(abi_identity) {
      changed[key] = true
      let kind = if a is None {
        "added"
      } else if b is None {
        "removed"
      } else {
        "changed"
      }
      changes.push({
        "symbol": key,
        "change": kind,
        "before": a.unwrap_or(Json::null()),
        "after": b.unwrap_or(Json::null()),
        "review_required": kind != "added",
      })
    } else if key.has_prefix("function:") &&
      a.map(j => j.stringify()) != b.map(j => j.stringify()) {
      parameter_renames.push({
        "symbol": key,
        "change": "parameter_renamed",
        "before": a.unwrap_or(Json::null()),
        "after": b.unwrap_or(Json::null()),
      })
    }
  }
  let affected : Map[String, Bool] = Map([])
  for m in [old, new] {
    for f in m.exported_functions() {
      let deps : Map[String, Bool] = Map([])
      dependencies(m, f.ret, deps)
      for p in f.params {
        dependencies(m, p.ty, deps)
      }
      if changed.contains("function:" + f.name) {
        affected[f.name] = true
      }
      for key, _ in deps {
        if changed.contains(key) {
          affected[f.name] = true
        }
      }
    }
  }
  let names : Array[String] = []
  for name, _ in affected {
    names.push(name)
  }
  names.sort()
  {
    "schema_version": 1,
    "generator_version": version,
    "target": target_name(target),
    "scope": "parsed C declarations under the same ABI, include paths and macro settings; not a binary compatibility guarantee",
    "changes": changes,
    "parameter_renames": parameter_renames,
    "affected_functions": names,
    "suggested_checks": [
      "regenerate bindings", "review affected call sites and ownership contracts",
      "compile, link and run against the new C library",
    ],
  }
}

///|
pub fn review_text(report : Json) -> String {
  let out = StringBuilder()
  out.write_string(
    "MoonBind API change report (review candidates, not a binary compatibility verdict)\n",
  )
  match report {
    { "changes": Array(changes), "affected_functions": Array(names), .. } => {
      out.write_string("\{changes.length()} declaration changes\n")
      for change in changes {
        out.write_string(change.stringify(indent=2) + "\n")
      }
      out.write_string(
        "Affected functions: " + names.to_json().stringify() + "\n",
      )
      out.write_string(
        "Next: regenerate, review call sites, compile/link/run against the new library.\n",
      )
    }
    _ => ()
  }
  out.to_string()
}

///|
fn source_location(m : @ast.CModule, name : String) -> Json {
  match m.function_locations.get(name) {
    Some(d) =>
      {
        "file": d.file,
        "line": d.line,
        "column": d.column,
        "token": d.token,
        "scope": d.message,
      }
    None => Json::null()
  }
}
