///|
fn main raise {
  assert_eq(@lib.config_value(), 1)
  assert_eq(@lib.transform_bytes(b"abc\x00\xff", 5, 0), Ok(b"abc\x00\xff"))
  assert_eq(@lib.transform_bytes(b"", 0, 0), Ok(b""))
  assert_eq(@lib.transform_bytes(b"", 8, 1), Err(@lib.InvalidWrittenLength(9UL)))
  assert_eq(@lib.transform_bytes(b"", 8, 2), Err(@lib.InvalidWrittenLength(1099511627776UL)))
  assert_true(@lib.transform_bytes(b"abc", 1, 0) is Err(@lib.BufferCallFailed(_)))
  assert_eq(@lib.transform32_bytes(b"abc", 3), Ok(b"abc"))
  assert_eq(@lib.transform32_bytes(b"abc", 1), Err(@lib.BufferCallFailed(4294967295UL)))
  assert_eq(@lib.transform_bytes(b"", 65, 0), Err(@lib.InvalidCapacity(65)))
  assert_eq(@lib.transform_bytes(b"", -1, 0), Err(@lib.InvalidCapacity(-1)))
  assert_eq(@lib.live_count(), 0)
  let p = match @lib.resource_open_managed(1) { Ok(Some(p)) => p; _ => abort("open") }
  assert_true(try { p.close(); false } catch { @lib.ResourceCloseFailed(9) => true; _ => false })
  assert_false(p.is_closed())
  assert_eq(p.with_handle(h => @lib.resource_value(h)), 1)
  p.close()
  assert_true(p.is_closed())
  let count = @lib.close_count()
  assert_true(try { p.close(); false } catch { @lib.ResourceClosed => true; _ => false })
  assert_eq(@lib.close_count(), count)
  match @lib.resource_open_managed(2) { Err((7, Some(p))) => p.close(); _ => abort("error handle lost") }
  assert_true(@lib.resource_open_managed(3) is Err((7, None)))
  assert_eq(@lib.live_count(), 0)
  println("PASS 32/64-bit output contract guards, retained close, error handles and no duplicate C close")
}
