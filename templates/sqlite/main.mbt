///|
fn check(db : @lib.Sqlite3Ptr, status : Int, expected : Int) -> Unit raise {
  if status != expected {
    raise Failure(@utf8.decode(@lib.copy_cstr(@lib.sqlite3_errmsg(db))))
  }
}

///|
fn main raise {
  let slot = @lib.Sqlite3Ptr::slot()
  let status = @lib.sqlite3_open(b":memory:\x00", slot)
  let db = @lib.Sqlite3Ptr::read_slot(slot)
  if status != @lib.sqlite_ok || db.is_null() {
    if !db.is_null() { ignore(@lib.sqlite3_close(db)) }
    raise Failure("database open failed")
  }
  let mut insert = @lib.Sqlite3StmtPtr::null()
  let mut query = @lib.Sqlite3StmtPtr::null()
  try {
    check(db, @lib.demo_sqlite_exec(db, b"CREATE TABLE moons(name TEXT, craters INT);\x00"), @lib.sqlite_ok)
    let insert_sql = b"INSERT INTO moons VALUES (?, ?)"
    let stmt_slot = @lib.Sqlite3StmtPtr::slot()
    check(db, @lib.demo_sqlite_prepare(db, insert_sql, insert_sql.length(), stmt_slot), @lib.sqlite_ok)
    insert = @lib.Sqlite3StmtPtr::read_slot(stmt_slot)
    let expected = [("Tycho", 5), ("Copernicus", 3), ("Kepler", 2)]
    for (name, craters) in expected {
      let bytes = @utf8.encode(name)
      // SQLite copies these bytes before the adapter returns.
      check(db, @lib.demo_sqlite_bind_text(insert, 1, bytes, bytes.length()), @lib.sqlite_ok)
      check(db, @lib.sqlite3_bind_int(insert, 2, craters), @lib.sqlite_ok)
      check(db, @lib.sqlite3_step(insert), @lib.sqlite_done)
      check(db, @lib.sqlite3_reset(insert), @lib.sqlite_ok)
    }
    let finalized = @lib.sqlite3_finalize(insert)
    insert = @lib.Sqlite3StmtPtr::null()
    check(db, finalized, @lib.sqlite_ok)
    let sql = b"SELECT name, craters FROM moons ORDER BY craters DESC"
    check(db, @lib.demo_sqlite_prepare(db, sql, sql.length(), stmt_slot), @lib.sqlite_ok)
    query = @lib.Sqlite3StmtPtr::read_slot(stmt_slot)
    for (name, craters) in expected {
      check(db, @lib.sqlite3_step(query), @lib.sqlite_row)
      assert_eq(@utf8.decode(@lib.copy_cstr(@lib.sqlite3_column_text(query, 0))), name)
      assert_eq(@lib.sqlite3_column_int(query, 1), craters)
    }
    check(db, @lib.sqlite3_step(query), @lib.sqlite_done)
    let finalized = @lib.sqlite3_finalize(query)
    query = @lib.Sqlite3StmtPtr::null()
    check(db, finalized, @lib.sqlite_ok)
    check(db, @lib.sqlite3_close(db), @lib.sqlite_ok)
  } catch {
    err => {
      if !insert.is_null() { ignore(@lib.sqlite3_finalize(insert)) }
      if !query.is_null() { ignore(@lib.sqlite3_finalize(query)) }
      ignore(@lib.sqlite3_close(db))
      raise err
    }
  }
  println("PASS SQLite: 3 asserted rows, explicit text lifetime and resource cleanup")
}
