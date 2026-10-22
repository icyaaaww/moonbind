///|
suberror QueryError { Stop }

///|
fn main raise {
  let db = match @lib.sqlite3_open_checked(b":memory:\x00") {
    Ok(Some(db)) => db
    Err((code, handle)) => { if handle is Some(p) { ignore(@lib.sqlite3_close(p)) }; raise Failure("open code " + code.to_string()) }
    _ => abort("open returned NULL")
  }
  try {
    let count = Ref(0)
    let rows : Array[Bytes?] = []
    let result = @lib.sqlite3_exec_sync(db, b"SELECT 11 UNION ALL SELECT 22 UNION ALL SELECT 33;\x00", (columns, values, names) => {
      assert_eq(columns, 1)
      assert_false(values.is_null())
      assert_false(names.is_null())
      rows.append(@lib.copy_cstr_array(values, columns))
      count.val += 1
      0
    })
    assert_eq(result, @lib.sqlite_ok)
    assert_eq(count.val, 3)
    assert_eq(rows, [Some(b"11"), Some(b"22"), Some(b"33")])
    assert_eq(@lib.sqlite3_exec_sync(db, b"SELECT NULL;\x00", (n, values, _) => {
      assert_eq(@lib.copy_cstr_array(values, n), [None]); 0
    }), @lib.sqlite_ok)
    let stopped = try { ignore(@lib.sqlite3_exec_sync(db, b"SELECT 1 UNION ALL SELECT 2;\x00", (_,_,_) => { raise Stop })); false } catch { Stop => true; _ => false }
    assert_true(stopped)
    assert_eq(@lib.sqlite3_exec_sync(db, b"SELECT 1;\x00", (_,_,_) => 1), @lib.sqlite_abort)
    assert_eq(@lib.sqlite3_exec_sync(db, b"INVALID SQL;\x00", (_,_,_) => abort("bad SQL callback")), @lib.sqlite_error)
    let stmt = match @lib.sqlite3_prepare_v2_checked(db, b"SELECT 123;\x00", -1) { Ok(Some(p)) => p; _ => abort("prepare") }
    assert_eq(@lib.sqlite3_step(stmt), @lib.sqlite_row)
    assert_eq(@lib.sqlite3_column_int(stmt, 0), 123)
    assert_eq(@lib.sqlite3_finalize_checked(stmt), Ok(()))
  } catch { e => { ignore(@lib.sqlite3_close(db)); raise e } }
  assert_eq(@lib.sqlite3_close_checked(db), Ok(()))
  println("PASS real SQLite callbacks, error/abort/invalid SQL, generated open/prepare/close contracts")
}
