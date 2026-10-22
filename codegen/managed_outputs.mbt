///|
/// Stateful wrapper for an existing checked T** creator. Error handles survive.
fn emit_managed_outputs(
  out : StringBuilder,
  gen : Gen,
  contracts : Map[String, String],
  outputs : Map[String, String],
  statuses : Map[String, String],
  nulls : Map[String, String],
) -> Unit {
  if contracts.is_empty() {
    return
  }
  if gen.used_types.contains("MoonBindResourceError") {
    contract_error(
      gen, "managed_outputs", "MoonBindResourceError type collision",
    )
    return
  }
  gen.used_types["MoonBindResourceError"] = true
  line(
    out, "pub(all) suberror MoonBindResourceError { ResourceClosed; ResourceBusy; ResourceCloseFailed(Int) }",
  )
  for name in contract_keys(contracts) {
    let parts = contracts.get(name).unwrap().split(":").to_array()
    let f = gen.module.function_named(name)
    if parts.length() != 3 ||
      f is None ||
      !outputs.contains(name) ||
      !statuses.contains(name) ||
      !gen.emitted_names.contains(name) {
      contract_error(
        gen, name, "managed output requires a checked T** creator and destructor:success_code:retained|released",
      )
      continue
    }
    let f = f.unwrap()
    let call = gen.emitted_names.get(name).unwrap()
    let free = parts[0].to_string()
    let success = parts[1].to_string()
    let policy = parts[2].to_string()
    let oi = param_index(f, outputs.get(name).unwrap())
    let destructor = gen.module.function_named(free)
    if oi < 0 ||
      destructor is None ||
      !gen.emitted_names.contains(free) ||
      !status_literal(success) ||
      (policy != "retained" && policy != "released") ||
      !gen.used_values.contains(call + "_checked") {
      contract_error(
        gen, name, "managed output needs valid checked creator, selected destructor and explicit close-error ownership policy",
      )
      continue
    }
    let d = destructor.unwrap()
    let pointer = match strip_typedefs(gen.module, f.params[oi].ty) {
      @ast.Pointer(p) => p
      _ => @ast.Void
    }
    if !(pointer is @ast.Pointer(_)) ||
      points_at_char(gen.module, pointer) ||
      d.params.length() != 1 ||
      strip_typedefs(gen.module, d.params[0].ty) !=
      strip_typedefs(gen.module, pointer) ||
      strip_typedefs(gen.module, d.ret) != @ast.Int(@ast.CI32) {
      contract_error(
        gen, name, "managed output requires opaque T** and matching int(T*) destructor",
      )
      continue
    }
    let ty = gen.declare_type(pointer, Returned).unwrap()
    let managed = gen.claim_type("Managed" + type_name(call))
    let wrapper = call + "_managed"
    if gen.used_values.contains(wrapper) {
      contract_error(gen, name, "managed wrapper collision")
      continue
    }
    gen.used_values[wrapper] = true
    let omitted = nulls
      .get(name)
      .unwrap_or("")
      .split(",")
      .map(n => param_index(f, n.to_string()))
      .to_array()
    let params : Array[String] = []
    let args : Array[String] = []
    for i, p in f.params {
      if i == oi || omitted.contains(i) {
        continue
      }
      let arg = "mb_arg" + i.to_string()
      params.push(arg + " : " + gen.declare_type(p.ty, Value).unwrap())
      args.push(arg)
    }
    line(
      out,
      "pub struct " +
      managed +
      " { priv handle : " +
      ty +
      "; priv mut closed : Bool; priv mut busy : Int }",
    )
    line(
      out, "/// Explicit close is required. Raw handles borrowed by with_handle must not escape or be freed by the callback.",
    )
    line(
      out,
      "pub fn " +
      managed +
      "::is_closed(self : " +
      managed +
      ") -> Bool { self.closed }",
    )
    line(
      out,
      "pub fn[T] " +
      managed +
      "::with_handle(self : " +
      managed +
      ", action : (" +
      ty +
      ") -> T raise) -> T raise {",
    )
    line(out, "  if self.closed { raise ResourceClosed }; self.busy += 1")
    line(
      out, "  let value = try { action(self.handle) } catch { e => { self.busy -= 1; raise e } }",
    )
    line(out, "  self.busy -= 1; value\n}")
    line(
      out,
      "pub fn " + managed + "::close(self : " + managed + ") -> Unit raise {",
    )
    line(
      out, "  if self.closed { raise ResourceClosed }; if self.busy != 0 { raise ResourceBusy }",
    )
    line(
      out,
      "  let code = " + gen.emitted_names.get(free).unwrap() + "(self.handle)",
    )
    if policy == "released" {
      line(out, "  self.closed = true")
    }
    line(
      out,
      "  if code != " + success + " { raise ResourceCloseFailed(code) }",
    )
    if policy == "retained" {
      line(out, "  self.closed = true")
    }
    line(out, "}")
    line(
      out,
      "pub fn " +
      wrapper +
      "(" +
      params.join(", ") +
      ") -> Result[" +
      managed +
      "?, (Int, " +
      managed +
      "?)] {",
    )
    line(out, "  match " + call + "_checked(" + args.join(", ") + ") {")
    line(
      out, "    Ok(p) => Ok(p.map(h => { handle: h, closed: false, busy: 0 }))",
    )
    line(
      out, "    Err((code, p)) => Err((code, p.map(h => { handle: h, closed: false, busy: 0 })))\n  }\n}\n",
    )
  }
}
