///|
test "nested bridge flattens fields and arrays with widened narrow integers" {
  let m = header(
    "enum Mode { IDLE=0, ACTIVE=1 }; struct Inner { short x; unsigned char flag; }; struct Packet { struct Inner p; int a[3]; enum Mode mode; }; struct Packet step(struct Packet p);",
  )
  let b = @codegen.generate_bridge(m, @layout.Target::sysv64(), "packet.h")
  assert_eq(b.adapted, ["step"])
  assert_true(b.c_source.contains("offsetof(struct Packet, a[2]) == 12"))
  assert_true(b.c_source.contains("int32_t mb_Packet_get_p__x"))
  assert_true(b.c_source.contains("uint32_t mb_Packet_get_p__flag"))
  assert_true(b.c_source.contains("sizeof(((struct Packet*)0)->p.x) == 2"))
  assert_true(b.c_source.contains("value < -32768"))
}

///|
test "bridge refuses excessive arrays incomplete enums and flattened-name collisions" {
  for
    h in [
      "struct Huge { int a[100000]; }; int f(struct Huge p);", "enum E; int f(enum E e);",
      "enum E { BIG=4294967296 }; int f(enum E e);", "struct Inner { int x; }; struct Outer { struct Inner a; int a__x; }; int f(struct Outer p);",
    ] {
    assert_true(
      @codegen.generate_bridge(header(h), @layout.Target::sysv64(), "api.h").adapted.is_empty(),
    )
  }
}

///|
test "contracts follow selected function names and reject invalid ownership pairs" {
  let m = header(
    "struct R; struct R *open(int fail); void close(struct R *r); int bad_close(struct R *r);",
  )
  let (text, skips) = @codegen.generate(
    m,
    @layout.Target::sysv64(),
    function_names=Map([("open", "acquire")]),
    ownership=Map([("open", "close")]),
  )
  assert_false(skips.any(s => s.reason.has_prefix("contract:")))
  assert_true(text.contains("fn[T] with_acquire("))
  assert_true(text.contains("raise e"))
  let (_, rejected) = @codegen.generate(
    m,
    @layout.Target::sysv64(),
    ownership=Map([("open", "bad_close")]),
  )
  assert_true(rejected.any(s => s.reason.has_prefix("contract:")))
}

///|
test "buffer and borrowed text contracts are explicit and validated" {
  let m = header(
    "unsigned int sum(const unsigned char *data, unsigned int len); const char *text(void);",
  )
  let (s, errors) = @codegen.generate(
    m,
    @layout.Target::sysv64(),
    buffers=Map([("sum", "data:len")]),
    copy_strings=["text"],
  )
  assert_false(errors.any(s => s.reason.has_prefix("contract:")))
  assert_true(s.contains("mb_arg0.length().to_uint()"))
  assert_true(s.contains("fn text_bytes() -> Bytes?"))
  let (_, invalid) = @codegen.generate(
    m,
    @layout.Target::sysv64(),
    buffers=Map([("sum", "data:nope")]),
  )
  assert_true(invalid.any(s => s.reason.has_prefix("contract:")))
}

///|
test "relative bridge paths and declaration source locations" {
  assert_eq(
    relative_path("D:/project/bindings", "D:/project/vendor/api.h"),
    "../vendor/api.h",
  )
  assert_eq(
    relative_path("/tmp/project/bindings", "/tmp/project/api.h"),
    "../api.h",
  )
  let m = header("int one(void);\nint two(void);")
  assert_eq(m.function_locations.get("two").unwrap().line, 2)
  assert_true(
    generation_report(m, @layout.Target::sysv64(), [])
    .stringify()
    .contains("test.h"),
  )
}
