///|
fn param_index(f : @ast.CFnDecl, name : String) -> Int32 {
  for i, p in f.params {
    if p.name == name || name == "#" + i.to_string() {
      return i
    }
  }
  -1
}

///|
fn status_literal(value : String) -> Bool {
  if value.is_empty() {
    return false
  }
  let mut digits = value
  if value.has_prefix("-") {
    digits = value[1:].to_string()
  }
  if digits.length() > 1 && digits.has_prefix("0") {
    return false
  }
  if digits.is_empty() || !digits.iter().all(c => c >= '0' && c <= '9') {
    return false
  }
  // Bounds are checked without overflow or compiler-dependent integer parsing.
  let limit = if value.has_prefix("-") { "2147483648" } else { "2147483647" }
  digits.length() < 10 || (digits.length() == 10 && digits.compare(limit) <= 0)
}

///|
fn emit_call_contracts(
  out : StringBuilder,
  gen : Gen,
  statuses : Map[String, String],
  outputs : Map[String, String],
  nulls : Map[String, String],
  callbacks : Map[String, String],
) -> Unit {
  let names : Map[String, String] = statuses.copy()
  for k, v in outputs {
    names[k] = v
  }
  for k, v in nulls {
    names[k] = v
  }
  for k, v in callbacks {
    names[k] = v
  }
  for name in contract_keys(names) {
    let f = match gen.module.function_named(name) {
      Some(f) => f
      None => {
        contract_error(gen, name, "unknown function")
        continue
      }
    }
    let call = match gen.emitted_names.get(name) {
      Some(n) => n
      None => {
        contract_error(gen, name, "function must be selected and supported")
        continue
      }
    }
    let success = statuses.get(name)
    if success is Some(v) &&
      (
        !status_literal(v) ||
        strip_typedefs(gen.module, f.ret) != @ast.Int(@ast.CI32)
      ) {
      contract_error(
        gen, name, "status requires signed int return and a signed 32-bit success code",
      )
      continue
    }
    let oi = match outputs.get(name) {
      Some(n) => param_index(f, n)
      None => -1
    }
    let mut handle = ""
    if outputs.contains(name) {
      if oi < 0 || success is None {
        contract_error(
          gen, name, "out-param needs an existing T** parameter and status code",
        )
        continue
      }
      match strip_typedefs(gen.module, f.params[oi].ty) {
        @ast.Pointer(inner) =>
          match strip_typedefs(gen.module, inner) {
            @ast.Pointer(_) =>
              handle = gen.declare_type(inner, Returned).unwrap_or("")
            _ => ()
          }
        _ => ()
      }
      if handle == "" {
        contract_error(gen, name, "out-param requires T**")
        continue
      }
    }
    let omitted : Array[Int32] = []
    let mut bad = false
    if nulls.get(name) is Some(list) {
      for n in list.split(",") {
        let i = param_index(f, n.to_string())
        if i < 0 || i == oi || omitted.contains(i) {
          bad = true
          continue
        }
        let t = strip_typedefs(gen.module, f.params[i].ty)
        if !(t is @ast.Pointer(_) || t is @ast.Fn(_)) {
          bad = true
          continue
        }
        omitted.push(i)
      }
    }
    if bad {
      contract_error(
        gen, name, "null-param requires distinct pointer parameters, separate from out-param",
      )
      continue
    }
    if callbacks.contains(name) {
      if oi >= 0 || success is Some(_) {
        contract_error(
          gen, name, "callback contract cannot combine with status/out contracts in 0.8",
        )
        continue
      }
      emit_callback(out, gen, f, call, callbacks.get(name).unwrap(), omitted)
      continue
    }
    let wrapper = call + "_checked"
    let raw = "mb_checked_" + call
    if gen.used_values.contains(wrapper) || gen.used_values.contains(raw) {
      contract_error(gen, name, "wrapper name collision")
      continue
    }
    gen.used_values[wrapper] = true
    gen.used_values[raw] = true
    let params : Array[String] = []
    let raw_params : Array[String] = []
    let args : Array[String] = []
    let borrowed : Array[String] = []
    for i, p in f.params {
      let arg = "mb_arg" + i.to_string()
      let ty = if omitted.contains(i) {
        "VoidPtr"
      } else {
        gen.declare_type(p.ty, Value).unwrap()
      }
      raw_params.push(arg + " : " + ty)
      if !is_scalar(ty) {
        borrowed.push(arg)
      }
      if omitted.contains(i) {
        args.push("VoidPtr::null()")
      } else if i == oi {
        args.push("mb_slot")
      } else {
        args.push(arg)
        params.push(arg + " : " + ty)
      }
    }
    let ret = gen.declare_type(f.ret, Returned).unwrap()
    if !borrowed.is_empty() {
      line(out, "#borrow(" + borrowed.join(", ") + ")")
    }
    line(
      out,
      "extern \"C\" fn " +
      raw +
      "(" +
      raw_params.join(", ") +
      ") -> " +
      ret +
      " = \"" +
      name +
      "\"",
    )
    let result = if oi >= 0 {
      "Result[" + handle + "?, (Int, " + handle + "?)]"
    } else if success is Some(_) {
      "Result[Unit, Int]"
    } else {
      ret
    }
    line(
      out, "/// Explicit call contract. An error output handle is preserved for caller cleanup.",
    )
    line(
      out,
      "pub fn " + wrapper + "(" + params.join(", ") + ") -> " + result + " {",
    )
    if oi >= 0 {
      line(out, "  let mb_slot = " + handle + "::slot()")
    }
    line(out, "  let mb_code = " + raw + "(" + args.join(", ") + ")")
    if oi >= 0 {
      line(out, "  let mb_handle = " + handle + "::read_slot(mb_slot)")
      line(
        out, "  let mb_value = if mb_handle.is_null() { None } else { Some(mb_handle) }",
      )
      line(
        out,
        "  if mb_code == " +
        success.unwrap() +
        " { Ok(mb_value) } else { Err((mb_code, mb_value)) }",
      )
    } else if success is Some(v) {
      line(out, "  if mb_code == " + v + " { Ok(()) } else { Err(mb_code) }")
    } else {
      line(out, "  mb_code")
    }
    line(out, "}\n")
  }
}

///|
fn callback_sig(m : @ast.CModule, ty : @ast.CType) -> @ast.FnSig? {
  match strip_typedefs(m, ty) {
    @ast.Fn(s) => Some(s)
    @ast.Pointer(t) =>
      match strip_typedefs(m, t) {
        @ast.Fn(s) => Some(s)
        _ => None
      }
    _ => None
  }
}

///|
fn emit_callback(
  out : StringBuilder,
  gen : Gen,
  f : @ast.CFnDecl,
  call : String,
  contract : String,
  omitted : Array[Int32],
) -> Unit {
  if strip_typedefs(gen.module, f.ret) != @ast.Int(@ast.CI32) {
    contract_error(
      gen,
      f.name,
      "callback outer function must return signed int status; owned return values need explicit cleanup",
    )
    return
  }
  let parts = contract.split(":").to_array()
  if parts.length() != 3 {
    contract_error(
      gen,
      f.name,
      "callback needs callback_parameter:context_parameter:abort_code",
    )
    return
  }
  let ci = param_index(f, parts[0].to_string())
  let di = param_index(f, parts[1].to_string())
  let abort_code = parts[2].to_string()
  if ci < 0 ||
    di < 0 ||
    ci == di ||
    omitted.contains(ci) ||
    omitted.contains(di) ||
    !status_literal(abort_code) ||
    strip_typedefs(gen.module, f.params[di].ty) != @ast.Pointer(@ast.Void) {
    contract_error(
      gen,
      f.name,
      "callback needs function pointer, distinct void* context, and int abort code",
    )
    return
  }
  let sig = match callback_sig(gen.module, f.params[ci].ty) {
    Some(s) => s
    None => {
      contract_error(
        gen,
        f.name,
        "callback parameter is not a function pointer",
      )
      return
    }
  }
  if sig.variadic ||
    sig.params.is_empty() ||
    strip_typedefs(gen.module, sig.params[0]) != @ast.Pointer(@ast.Void) ||
    strip_typedefs(gen.module, sig.ret) != @ast.Int(@ast.CI32) {
    contract_error(
      gen,
      f.name,
      "synchronous callback must return int and take void* context first",
    )
    return
  }
  let cbtypes : Array[String] = []
  for t in sig.params[1:] {
    let resolved = strip_typedefs(gen.module, t)
    match resolved {
      @ast.Int(@ast.CI32 | @ast.CU32 | @ast.CI64 | @ast.CU64)
      | @ast.Float(_)
      | @ast.Pointer(_) => cbtypes.push(gen.declare_type(t, Returned).unwrap())
      _ => {
        contract_error(
          gen,
          f.name,
          "callback payloads require 32/64-bit scalars or borrowed opaque pointers",
        )
        return
      }
    }
  }
  let state = gen.claim_type("Callback" + type_name(call))
  let wrapper = call + "_sync"
  let raw = "mb_sync_" + call
  if gen.used_values.contains(wrapper) || gen.used_values.contains(raw) {
    contract_error(gen, f.name, "callback name collision")
    return
  }
  gen.used_values[wrapper] = true
  gen.used_values[raw] = true
  let closure = "(" + cbtypes.join(", ") + ") -> Int raise"
  line(
    out,
    "priv struct " + state + " { action : " + closure + "; mut error : Error? }",
  )
  let params : Array[String] = []
  let raw_params : Array[String] = []
  let args : Array[String] = []
  let borrowed : Array[String] = []
  let refparams = [state]
  refparams.append(cbtypes)
  for i, p in f.params {
    let n = "mb_arg" + i.to_string()
    if i == ci {
      raw_params.push(n + " : FuncRef[(" + refparams.join(", ") + ") -> Int]")
      args.push("mb_trampoline")
    } else if i == di {
      raw_params.push(n + " : " + state)
      args.push("mb_state")
      borrowed.push(n)
    } else if omitted.contains(i) {
      raw_params.push(n + " : VoidPtr")
      args.push("VoidPtr::null()")
      borrowed.push(n)
    } else {
      let ty = gen.declare_type(p.ty, Value).unwrap()
      raw_params.push(n + " : " + ty)
      params.push(n + " : " + ty)
      args.push(n)
      if !is_scalar(ty) {
        borrowed.push(n)
      }
    }
  }
  let ret = gen.declare_type(f.ret, Returned).unwrap()
  if !borrowed.is_empty() {
    line(out, "#borrow(" + borrowed.join(", ") + ")")
  }
  line(
    out,
    "extern \"C\" fn " +
    raw +
    "(" +
    raw_params.join(", ") +
    ") -> " +
    ret +
    " = \"moonbind_sync_" +
    f.name +
    "\"",
  )
  params.push("mb_action : " + closure)
  line(
    out, "/// Synchronous same-thread callback only. C must neither retain callback/context nor invoke after return.",
  )
  line(
    out,
    "pub fn " + wrapper + "(" + params.join(", ") + ") -> " + ret + " raise {",
  )
  line(
    out,
    "  let mb_state : " + state + " = { action: mb_action, error: None }",
  )
  let cbargs = ["mb_context"]
  for i, _ in cbtypes {
    cbargs.push("mb_cb" + i.to_string())
  }
  line(
    out,
    "  let mb_trampoline : FuncRef[(" +
    refparams.join(", ") +
    ") -> Int] = fn(" +
    cbargs.join(", ") +
    ") {",
  )
  line(out, "    if mb_context.error is Some(_) { return " + abort_code + " }")
  line(
    out,
    "    try { (mb_context.action)(" +
    cbargs[1:].to_owned().join(", ") +
    ") } catch { e => { mb_context.error = Some(e); " +
    abort_code +
    " } }",
  )
  line(out, "  }")
  line(out, "  let mb_result = " + raw + "(" + args.join(", ") + ")")
  line(out, "  if mb_state.error is Some(e) { raise e }")
  line(out, "  mb_result\n}\n")
}

///|
fn c_decl(m : @ast.CModule, ty : @ast.CType, name : String) -> String {
  if ty is @ast.Named(n) {
    return n + " " + name
  }
  match strip_typedefs(m, ty) {
    @ast.Pointer(t) => {
      let inner = strip_typedefs(m, t)
      c_decl(
        m,
        inner,
        if inner is @ast.Fn(_) {
          "(*" + name + ")"
        } else {
          "*" + name
        },
      )
    }
    @ast.Fn(s) =>
      c_decl(
        m,
        s.ret,
        name +
        "(" +
        (if s.params.is_empty() {
          "void"
        } else {
          s.params.map(t => c_decl(m, t, "")).join(", ")
        }) +
        ")",
      )
    @ast.Record(tag) =>
      (if m.records.get(tag) is Some({ kind: @ast.Union, .. }) {
        "union " + tag
      } else {
        c_record(m, tag)
      }) +
      " " +
      name
    @ast.EnumType(tag) =>
      (if tag.has_prefix("enum ") { tag } else { "enum " + tag }) + " " + name
    @ast.Int(@ast.CI8) => "char " + name
    t => c_shape(t) + " " + name
  }
}

///|
/// Debug tracing records entry to the generated C adapter, not assertion coverage.
pub fn call_adapters(
  m : @ast.CModule,
  header : String,
  callbacks~ : Map[String, String] = Map([]),
  trace~ : Bool = false,
) -> String {
  let out = StringBuilder()
  line(
    out, "#include <stdint.h>\n#include <stdlib.h>\n#include <stdio.h>\n#include <moonbit.h>",
  )
  line(out, "#include " + header.to_json().stringify())
  if trace {
    line(
      out, "static void moonbind_trace(const char *name) { const char *path = getenv(\"MOONBIND_TRACE\"); if (!path) return; FILE *f = fopen(path, \"a\"); if (!f) return; fprintf(f, \"%s\\n\", name); fclose(f); }",
    )
  }
  for f in m.exported_functions() {
    if trace && !f.variadic {
      let ps : Array[String] = []
      let args : Array[String] = []
      for i, p in f.params {
        let n = "a" + i.to_string()
        ps.push(c_decl(m, p.ty, n))
        args.push(n)
      }
      line(
        out,
        c_decl(
          m,
          f.ret,
          "moonbind_trace_" +
          f.name +
          "(" +
          (if ps.is_empty() { "void" } else { ps.join(", ") }) +
          ")",
        ) +
        " {",
      )
      line(out, "moonbind_trace(\"" + f.name + "\");")
      line(
        out,
        (if strip_typedefs(m, f.ret) == @ast.Void { "" } else { "return " }) +
        f.name +
        "(" +
        args.join(", ") +
        ");\n}",
      )
    }
    if callbacks.get(f.name) is Some(contract) {
      let parts = contract.split(":").to_array()
      if parts.length() != 3 {
        continue
      }
      let ci = param_index(f, parts[0].to_string())
      let di = param_index(f, parts[1].to_string())
      if ci < 0 || di < 0 {
        continue
      }
      let sig = match callback_sig(m, f.params[ci].ty) {
        Some(s) => s
        None => continue
      }
      let prefix = "moonbind_sync_" + f.name
      line(
        out,
        "struct " +
        prefix +
        "_state { " +
        c_decl(m, f.params[ci].ty, "callback") +
        "; void *context; };",
      )
      let cps : Array[String] = []
      let cas : Array[String] = []
      for i, t in sig.params {
        let n = "c" + i.to_string()
        cps.push(c_decl(m, t, n))
        cas.push(if i == 0 { "s->context" } else { n })
      }
      line(
        out,
        "static int " +
        prefix +
        "_invoke(" +
        cps.join(", ") +
        ") { struct " +
        prefix +
        "_state *s = c0; moonbit_incref(s->context); return s->callback(" +
        cas.join(", ") +
        "); }",
      )
      let ps : Array[String] = []
      let args : Array[String] = []
      for i, p in f.params {
        let n = "a" + i.to_string()
        ps.push(c_decl(m, p.ty, n))
        args.push(
          if i == ci {
            prefix + "_invoke"
          } else if i == di {
            "&s"
          } else {
            n
          },
        )
      }
      line(out, c_decl(m, f.ret, prefix + "(" + ps.join(", ") + ")") + " {")
      line(
        out,
        "struct " +
        prefix +
        "_state s = { a" +
        ci.to_string() +
        ", a" +
        di.to_string() +
        " };",
      )
      if trace {
        line(out, "moonbind_trace(\"" + f.name + "\");")
      }
      line(
        out,
        (if strip_typedefs(m, f.ret) == @ast.Void { "" } else { "return " }) +
        f.name +
        "(" +
        args.join(", ") +
        ");\n}",
      )
    }
  }
  out.to_string()
}
