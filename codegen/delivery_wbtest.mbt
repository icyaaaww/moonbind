///|
fn buffer_fixture() -> @ast.CModule {
  let m = @ast.CModule::new()
  m.add_function(
    foreign("copy", u32_(), [
      param("dst", ptr_(@ast.Void)),
      param("cap", u32_()),
      param("src", ptr_(@ast.Void)),
      param("len", u32_()),
    ]),
  )
  m.add_function(foreign("failed", i32_(), [param("code", u32_())]))
  m
}

///|
test "output contract rejects ambiguous parameter slots" {
  for
    value in [
      "dst:cap:dst:len:failed:64", "dst:cap:missing:len:failed:64", "dst:cap:src:len:failed",
    ] {
    let (_, skips) = generate(buffer_fixture(), target(), output_buffers={
      "copy": value,
    })
    assert_true(skips.any(s => s.reason.has_prefix("contract:")))
  }
}

///|
test "output allocation limit rejects overflow negative zero and nondecimal" {
  for value in ["0", "-1", "2147483648", "999999999999999999999", "0x100", "01"] {
    let (_, skips) = generate(buffer_fixture(), target(), output_buffers={
      "copy": "dst:cap:src:len:failed:" + value,
    })
    assert_true(skips.any(s => s.reason.has_prefix("contract:")))
  }
}

///|
test "error predicate must match the unsigned result width" {
  let m = buffer_fixture()
  m.add_function(foreign("wrong", i32_(), [param("code", i64_())]))
  for pred in ["unknown", "wrong", "copy"] {
    let (_, skips) = generate(m, target(), output_buffers={
      "copy": "dst:cap:src:len:" + pred + ":64",
    })
    assert_true(skips.any(s => s.reason.has_prefix("contract:")))
  }
}

///|
test "output helper names cannot overwrite existing functions" {
  let m = buffer_fixture()
  m.add_function(foreign("copy_bytes", i32_(), []))
  let (_, skips) = generate(m, target(), output_buffers={
    "copy": "dst:cap:src:len:failed:64",
  })
  assert_true(skips.any(s => s.reason.contains("collision")))
}

///|
test "managed output requires checked creator and explicit close error policy" {
  let m = @ast.CModule::new()
  m.forward_record(@ast.Struct, "struct Item")
  let handle = ptr_(@ast.Record("struct Item"))
  m.add_function(foreign("open_item", i32_(), [param("out", ptr_(handle))]))
  m.add_function(foreign("close_item", i32_(), [param("value", handle)]))
  for
    value in [
      "close_item:0", "close_item:0:unknown", "close_item:99999999999:retained",
      "missing:0:retained",
    ] {
    let (_, skips) = generate(
      m,
      target(),
      out_params={ "open_item": "out" },
      status_codes={ "open_item": "0" },
      managed_outputs={ "open_item": value },
    )
    assert_true(skips.any(s => s.reason.has_prefix("contract:")))
  }
  let (_, skips) = generate(m, target(), managed_outputs={
    "open_item": "close_item:0:retained",
  })
  assert_true(skips.any(s => s.reason.has_prefix("contract:")))
}
