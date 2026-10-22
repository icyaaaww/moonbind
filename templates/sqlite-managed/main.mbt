///|
suberror TrialError { Stop }

///|
fn main raise {
  let db = match @lib.sqlite3_open_managed(b":memory:\x00") { Ok(Some(p)) => p; _ => abort("open") }
  let stmt = db.with_handle(p => match @lib.sqlite3_prepare_v2_managed(p, b"SELECT 42;\x00", -1) { Ok(Some(s)) => s; _ => abort("prepare") })
  let busy = try { db.close(); false } catch { @lib.ResourceCloseFailed(5) => true; _ => false }
  assert_true(busy)
  assert_false(db.is_closed())
  assert_eq(stmt.with_handle(p => @lib.sqlite3_step(p)), @lib.sqlite_row)
  assert_eq(stmt.with_handle(p => @lib.sqlite3_column_int(p, 0)), 42)
  assert_true(try { db.with_handle(_ => { db.close() }); false } catch { @lib.ResourceBusy => true; _ => false })
  assert_true(try { db.with_handle(_ => { raise Stop }); false } catch { Stop => true; _ => false })
  stmt.close()
  db.close()
  assert_true(db.is_closed())
  assert_true(try { db.close(); false } catch { @lib.ResourceClosed => true; _ => false })
  assert_true(try { db.with_handle(_ => abort("must not execute")); false } catch { @lib.ResourceClosed => true; _ => false })
  println("PASS SQLite busy-close retention, retry, borrowed close prevention, error recovery, double-close/use-after-close")
}
