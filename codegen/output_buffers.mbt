///|
/// Explicit synchronous byte-in/byte-out contracts. C must respect capacity.
fn emit_output_buffers(
  out : StringBuilder,
  gen : Gen,
  contracts : Map[String, String],
) -> Unit {
  if contracts.is_empty() {
    return
  }
  if gen.used_types.contains("MoonBindBufferError") {
    contract_error(gen, "output_buffers", "MoonBindBufferError type collision")
    return
  }
  gen.used_types["MoonBindBufferError"] = true
  line(
    out, "pub(all) enum MoonBindBufferError { InvalidCapacity(Int); BufferCallFailed(UInt64); InvalidWrittenLength(UInt64) } derive(Debug, Eq)",
  )
  for name in contract_keys(contracts) {
    let parts = contracts.get(name).unwrap().split(":").to_array()
    let f = gen.module.function_named(name)
    let call = gen.emitted_names.get(name)
    if parts.length() != 6 || f is None || call is None {
      contract_error(
        gen, name, "output buffer requires selected function=dst:capacity:src:length:error_predicate:max_bytes",
      )
      continue
    }
    let f = f.unwrap()
    let call = call.unwrap()
    let indices = parts[:4].map(p => param_index(f, p.to_string()))
    let mut valid = true
    for i, n in indices {
      if n < 0 || indices[:i].contains(n) {
        valid = false
      }
    }
    let limit = parts[5].to_string()
    if !valid || !status_literal(limit) || limit.has_prefix("-") || limit == "0" {
      contract_error(
        gen, name, "buffer parameters must be distinct; max_bytes must be a positive signed 32-bit integer",
      )
      continue
    }
    let dst = indices[0]
    let cap = indices[1]
    let src = indices[2]
    let len = indices[3]
    for i in [dst, src] {
      match strip_typedefs(gen.module, f.params[i].ty) {
        @ast.Pointer(@ast.Void | @ast.Int(@ast.CI8 | @ast.CU8)) => ()
        _ => valid = false
      }
    }
    let size = strip_typedefs(gen.module, f.ret)
    let conversion = match size {
      @ast.Int(@ast.CU64) => ".to_uint64()"
      @ast.Int(@ast.CU32) => ".to_uint()"
      _ => {
        valid = false
        ""
      }
    }
    let pred = parts[4].to_string()
    let predicate = gen.module.function_named(pred)
    if strip_typedefs(gen.module, f.params[cap].ty) != size ||
      strip_typedefs(gen.module, f.params[len].ty) != size ||
      !gen.emitted_names.contains(pred) {
      valid = false
    }
    match predicate {
      Some(p) if p.params.length() == 1 && !p.variadic => {
        if strip_typedefs(gen.module, p.params[0].ty) != size {
          valid = false
        }
        match strip_typedefs(gen.module, p.ret) {
          @ast.Int(@ast.CI32 | @ast.CU32) => ()
          _ => valid = false
        }
      }
      _ => valid = false
    }
    if !valid {
      contract_error(
        gen, name, "output buffers need byte/void pointers, matching unsigned 32/64-bit lengths/return, and selected int/unsigned(size) error predicate",
      )
      continue
    }
    let wrapper = call + "_bytes"
    let raw = "mb_bytes_" + call
    if gen.used_values.contains(wrapper) || gen.used_values.contains(raw) {
      contract_error(gen, name, "output buffer wrapper name collision")
      continue
    }
    gen.used_values[wrapper] = true
    gen.used_values[raw] = true
    let params = ["mb_input : Bytes", "mb_capacity : Int"]
    let raw_params : Array[String] = []
    let args : Array[String] = []
    let borrowed : Array[String] = []
    for i, p in f.params {
      let arg = "mb_arg" + i.to_string()
      let ty = if i == dst || i == src {
        "Bytes"
      } else {
        gen.declare_type(p.ty, Value).unwrap()
      }
      raw_params.push(arg + " : " + ty)
      if !is_scalar(ty) {
        borrowed.push(arg)
      }
      if i == dst {
        args.push("mb_output")
      } else if i == cap {
        args.push("mb_capacity" + conversion)
      } else if i == src {
        args.push("mb_input")
      } else if i == len {
        args.push("mb_input.length()" + conversion)
      } else {
        params.push(arg + " : " + ty)
        args.push(arg)
      }
    }
    let ret = gen.declare_type(f.ret, Returned).unwrap()
    line(out, "#borrow(" + borrowed.join(", ") + ")")
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
    line(
      out, "/// Bounded allocation; returned length checked before copying. C must neither retain buffers nor exceed capacity.",
    )
    line(
      out,
      "pub fn " +
      wrapper +
      "(" +
      params.join(", ") +
      ") -> Result[Bytes, MoonBindBufferError] {",
    )
    line(
      out,
      "  if mb_capacity < 0 || mb_capacity > " +
      limit +
      " { return Err(InvalidCapacity(mb_capacity)) }",
    )
    line(out, "  let mb_output = Bytes::make(mb_capacity, b'\\x00')")
    line(out, "  let mb_size = " + raw + "(" + args.join(", ") + ")")
    let wide = if size == @ast.Int(@ast.CU32) {
      "mb_size.to_uint64()"
    } else {
      "mb_size"
    }
    line(
      out,
      "  if " +
      gen.emitted_names.get(pred).unwrap() +
      "(mb_size) != 0 { return Err(BufferCallFailed(" +
      wide +
      ")) }",
    )
    line(
      out,
      "  if mb_size > mb_capacity" +
      conversion +
      " { return Err(InvalidWrittenLength(" +
      wide +
      ")) }",
    )
    line(out, "  Ok(Bytes::makei(mb_size.to_int(), i => mb_output[i]))\n}\n")
  }
}
