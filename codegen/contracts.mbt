///|
fn contract_error(gen : Gen, name : String, message : String) -> Unit {
  gen.skips.push({ name, reason: "contract: " + message, })
}

///|
fn contract_keys(values : Map[String, String]) -> Array[String] {
  let keys : Array[String] = []
  for key, _ in values {
    keys.push(key)
  }
  keys.sort()
  keys
}

///|
fn contract_signature(
  gen : Gen,
  f : @ast.CFnDecl,
  omit : String,
) -> (Array[String], Array[String]) {
  let params : Array[String] = []
  let args : Array[String] = []
  for i, p in f.params {
    let name = "mb_arg" + i.to_string()
    args.push(name)
    if p.name != omit || omit == "" {
      params.push(name + " : " + gen.declare_type(p.ty, Value).unwrap())
    }
  }
  (params, args)
}

///|
/// Contracts are supplied by the caller, never inferred from C names.
/// Scoped cleanup cannot prevent a caller from escaping or freeing a handle.
fn emit_contracts(
  out : StringBuilder,
  gen : Gen,
  ownership : Map[String, String],
  buffers : Map[String, String],
  copy_strings : Array[String],
) -> Unit {
  for create in contract_keys(ownership) {
    let free = ownership.get(create).unwrap()
    let f = gen.module.function_named(create)
    let d = gen.module.function_named(free)
    match (f, d, gen.emitted_names.get(create), gen.emitted_names.get(free)) {
      (Some(f), Some(d), Some(call), Some(dispose)) => {
        let ret = strip_typedefs(gen.module, f.ret)
        if !(ret is @ast.Pointer(_)) ||
          d.params.length() != 1 ||
          strip_typedefs(gen.module, d.ret) != @ast.Void ||
          strip_typedefs(gen.module, d.params[0].ty) != ret ||
          points_at_char(gen.module, ret) {
          contract_error(
            gen, create, "ownership needs a pointer-return creator and matching void(pointer) destructor; byte pointers are not owned handles",
          )
          continue
        }
        let ty = gen.declare_type(f.ret, Returned).unwrap()
        let wrapper = "with_" + call
        if gen.used_values.contains(wrapper) {
          contract_error(gen, create, "wrapper name collision: " + wrapper)
          continue
        }
        gen.used_values[wrapper] = true
        let (params, args) = contract_signature(gen, f, "")
        params.push("mb_action : (" + ty + ") -> T raise")
        line(
          out, "/// Scoped borrowed handle; do not free or retain it in mb_action. None means allocation failed.",
        )
        line(
          out,
          "pub fn[T] " + wrapper + "(" + params.join(", ") + ") -> T? raise {",
        )
        line(out, "  let mb_handle = " + call + "(" + args.join(", ") + ")")
        line(out, "  if mb_handle.is_null() { return None }")
        line(
          out,
          "  let mb_result = try { mb_action(mb_handle) } catch { e => { " +
          dispose +
          "(mb_handle); raise e } }",
        )
        line(out, "  " + dispose + "(mb_handle)")
        line(out, "  Some(mb_result)\n}\n")
      }
      _ =>
        contract_error(
          gen, create, "creator and destructor must both be selected, supported functions",
        )
    }
  }
  for name in contract_keys(buffers) {
    let pair = buffers.get(name).unwrap().split(":").to_array()
    match (gen.module.function_named(name), gen.emitted_names.get(name)) {
      (Some(f), Some(call)) if pair.length() == 2 => {
        let mut pi = -1
        let mut li = -1
        for i, p in f.params {
          if p.name == pair[0].to_string() {
            pi = i
          }
          if p.name == pair[1].to_string() {
            li = i
          }
        }
        if pi < 0 ||
          li < 0 ||
          pi == li ||
          !points_at_char(gen.module, f.params[pi].ty) {
          contract_error(
            gen, name, "buffer needs distinct byte-pointer and integer-length parameter names",
          )
          continue
        }
        let conversion = match strip_typedefs(gen.module, f.params[li].ty) {
          @ast.Int(@ast.CI32) => ""
          @ast.Int(@ast.CU32) => ".to_uint()"
          @ast.Int(@ast.CI64) => ".to_int64()"
          @ast.Int(@ast.CU64) => ".to_uint64()"
          _ => {
            contract_error(
              gen, name, "buffer length must be a 32/64-bit integer",
            )
            continue
          }
        }
        let wrapper = call + "_buffer"
        if gen.used_values.contains(wrapper) {
          contract_error(gen, name, "wrapper name collision")
          continue
        }
        gen.used_values[wrapper] = true
        let (params, args) = contract_signature(gen, f, pair[1].to_string())
        args[li] = args[pi] + ".length()" + conversion
        let ret = gen.declare_type(f.ret, Returned).unwrap()
        line(
          out, "/// Configured byte-count contract; C must not retain the buffer or access beyond its length.",
        )
        line(
          out,
          "pub fn " +
          wrapper +
          "(" +
          params.join(", ") +
          ") -> " +
          ret +
          " { " +
          call +
          "(" +
          args.join(", ") +
          ") }\n",
        )
      }
      _ =>
        contract_error(
          gen, name, "buffer contract expects selected function=pointer_parameter:length_parameter",
        )
    }
  }
  let names = copy_strings.copy()
  names.sort()
  for name in names {
    match (gen.module.function_named(name), gen.emitted_names.get(name)) {
      (Some(f), Some(call)) if points_at_char(gen.module, f.ret) => {
        let wrapper = call + "_bytes"
        if gen.used_values.contains(wrapper) {
          contract_error(gen, name, "wrapper name collision")
          continue
        }
        gen.used_values[wrapper] = true
        let (params, args) = contract_signature(gen, f, "")
        line(
          out, "/// Copies a borrowed NUL-terminated result immediately. None preserves NULL; no ownership transfer.",
        )
        line(
          out,
          "pub fn " + wrapper + "(" + params.join(", ") + ") -> Bytes? {",
        )
        line(out, "  let mb_ptr = " + call + "(" + args.join(", ") + ")")
        line(
          out, "  if mb_ptr.is_null() { None } else { Some(copy_cstr(mb_ptr)) }\n}\n",
        )
      }
      _ =>
        contract_error(
          gen, name, "copy-string needs a selected function returning a borrowed NUL-terminated char pointer",
        )
    }
  }
}
