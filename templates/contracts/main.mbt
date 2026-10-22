///|
suberror TrialError { TrialError }

///|
fn main raise {
  assert_eq(@lib.resource_live(), 0)
  let result = @lib.with_resource_new(0, fn(p) { @lib.resource_value(p) })
  assert_eq(result, Some(42))
  assert_eq(@lib.resource_live(), 0)
  let failed = @lib.with_resource_new(1, fn(_) { abort("must not call action") })
  assert_eq(failed, None)
  let caught = try {
    ignore(@lib.with_resource_new(0, fn(_) { raise TrialError }))
    false
  } catch { TrialError => true; _ => false }
  assert_true(caught)
  assert_eq(@lib.resource_live(), 0)
  assert_eq(@lib.checksum_buffer(b"ABC"), 198U)
  assert_eq(@lib.checksum_buffer(b""), 0U)
  let copy = @lib.borrowed_text_bytes(0).unwrap()
  @lib.mutate_text()
  assert_eq(copy, b"hello")
  assert_eq(@lib.borrowed_text_bytes(1), None)
  println("PASS ownership normal/error/null, exact byte counts, borrowed string copied")
}
