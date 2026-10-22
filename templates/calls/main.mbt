///|
suberror VisitError { Stop }

///|
fn main raise {
  assert_eq(@lib.item_live(), 0)
  match @lib.item_open_checked(0) { Ok(Some(p)) => assert_eq(@lib.item_close_checked(p), Ok(())); _ => abort("open success") }
  match @lib.item_open_checked(1) { Err((7, Some(p))) => assert_eq(@lib.item_close_checked(p), Ok(())); _ => abort("error handle lost") }
  match @lib.item_open_checked(2) { Err((7, None)) => (); _ => abort("null error") }
  assert_eq(@lib.optional_tail_checked(42), 42)
  assert_eq(@lib.with_item_new(0, _ => 42), Some(42))
  let clean_error = try { ignore(@lib.with_item_new(3, _ => 1)); false } catch { @lib.CleanupFailed(9) => true; _ => false }
  assert_true(clean_error)
  let both_error = try { ignore(@lib.with_item_new(3, _ => { raise Stop })); false } catch { @lib.CleanupDuringError(9, _) => true; _ => false }
  assert_true(both_error)
  assert_eq(@lib.item_live(), 0)
  let sum = Ref::new(0)
  for _ in 0..<1000 {
    assert_eq(@lib.visit_sync(10, n => { sum.val += n; 0 }), 0)
  }
  assert_eq(sum.val, 45000)
  let count = Ref::new(0)
  let stopped = try { ignore(@lib.visit_sync(10, _ => { count.val += 1; raise Stop })); false } catch { Stop => true; _ => false }
  assert_true(stopped)
  assert_eq(count.val, 1)
  assert_eq(@lib.visit_sync(0, _ => abort("zero callback")), 0)
  assert_eq(@lib.visit_sync(4, _ => 5), 5)
  assert_eq(@lib.visit_sync(1, _ => @lib.visit_sync(2, _ => 0)), 0)
  println("PASS output/status/NULL/cleanup, 10000 callbacks, error and reentrancy")
}
