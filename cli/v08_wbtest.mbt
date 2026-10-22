///|
test "output contracts preserve error handles and compose NULL parameters" {
  let m = header(
    "struct R; int open(struct R **out, char **tail); int close(struct R *p);",
  )
  let (text, skips) = @codegen.generate(
    m,
    @layout.Target::sysv64(),
    status_codes=Map([("open", "0")]),
    out_params=Map([("open", "out")]),
    null_params=Map([("open", "tail")]),
  )
  assert_false(skips.any(s => s.reason.has_prefix("contract:")))
  assert_true(text.contains("Err((mb_code, mb_value))"))
  assert_true(text.contains("VoidPtr::null()"))
  assert_true(text.contains("pub fn open__checked()"))
}

///|
test "invalid call contracts refuse even plausible wrong signatures" {
  let m = header(
    "struct R; int open(struct R **out, int count); unsigned int wrong(void); int callback(int (*cb)(int), void *ctx);",
  )
  for
    statuses in [
      Map([("open", "2147483648")]),
      Map([("open", "0;abort()")]),
      Map([("wrong", "0")]),
    ] {
    let (_, skips) = @codegen.generate(
      m,
      @layout.Target::sysv64(),
      status_codes=statuses,
    )
    assert_true(skips.any(s => s.reason.has_prefix("contract:")))
  }
  let (_, out_errors) = @codegen.generate(
    m,
    @layout.Target::sysv64(),
    out_params=Map([("open", "out")]),
  )
  assert_true(out_errors.any(s => s.reason.has_prefix("contract:")))
  let (_, null_errors) = @codegen.generate(
    m,
    @layout.Target::sysv64(),
    null_params=Map([("open", "count")]),
  )
  assert_true(null_errors.any(s => s.reason.has_prefix("contract:")))
  let (_, cb_errors) = @codegen.generate(
    m,
    @layout.Target::sysv64(),
    callbacks=Map([("callback", "cb:ctx:1")]),
  )
  assert_true(cb_errors.any(s => s.reason.has_prefix("contract:")))
}

///|
test "synchronous callback emits retained context trampoline and deferred error" {
  let m = header("int visit(int (*cb)(void *, int), void *);")
  let (text, skips) = @codegen.generate(
    m,
    @layout.Target::sysv64(),
    callbacks=Map([("visit", "cb:#1:1")]),
  )
  assert_false(skips.any(s => s.reason.has_prefix("contract:")))
  assert_true(text.contains("if mb_state.error is Some(e) { raise e }"))
  let c = @codegen.call_adapters(
    m,
    "api.h",
    callbacks=Map([("visit", "cb:#1:1")]),
    trace=true,
  )
  assert_true(c.contains("moonbit_incref(s->context)"))
  assert_true(c.contains("moonbind_trace_visit"))
}

///|
test "Win64 LLP64 parsing and layouts differ from LP64" {
  let target = @layout.Target::win64()
  assert_eq(target.long_bytes(), 4)
  let cache = @source.SourceCache::in_memory()
  cache.insert("win.h", "struct M { char tag; long value; void *ptr; };")
  let defaults = @cparse.LoadOptions::new()
  let m = @cparse.load_header_with_cache(
    "win.h",
    { ..defaults, platform: platform_for(target), },
    cache,
  )
  assert_eq(
    @layout.record_row(target, m, "M"),
    Some("struct M  0 tag  4 value  8 ptr [sizeof=16, align=8]"),
  )
}
