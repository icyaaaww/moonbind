//! Run with `moon run examples/sqlite3-demo --target native`.
//! Generated bindings supply the handles and ordinary SQLite calls. The small
//! handwritten adapter supplies SQLITE_TRANSIENT and actual NULL optional
//! outputs; the generator cannot infer SQLite's retained-pointer contract.

///|
let setup_sql : String = "CREATE TABLE moons (name TEXT NOT NULL, craters INT NOT NULL);"

///|
let insert_sql : String = "INSERT INTO moons (name, craters) VALUES (?, ?);"

///|
let select_sql : String = "SELECT name, craters FROM moons ORDER BY craters DESC;"

///|
#borrow(sql)
extern "C" fn exec_sql(db : @sqlite.Sqlite3Ptr, sql : Bytes) -> Int32 = "moonbind_example_sqlite_exec"

///|
#borrow(sql, out)
extern "C" fn prepare_sql(
  db : @sqlite.Sqlite3Ptr,
  sql : Bytes,
  length : Int32,
  out : Bytes,
) -> Int32 = "moonbind_example_sqlite_prepare"

///|
// The adapter copies text before returning; SQLite never retains these Bytes.
#borrow(text)
extern "C" fn bind_text_copy(
  stmt : @sqlite.Sqlite3StmtPtr,
  index : Int32,
  text : Bytes,
  length : Int32,
) -> Int32 = "moonbind_example_sqlite_bind_text"

///|
fn check(
  db : @sqlite.Sqlite3Ptr,
  status : Int32,
  wanted : Int32,
  doing : String,
) -> Unit raise {
  if status != wanted {
    raise Failure(
      "\{doing} failed (\{status}): " +
      @utf8.decode(@sqlite.copy_cstr(@sqlite.sqlite3_errmsg(db))),
    )
  }
}

///|
fn[T] with_statement(
  db : @sqlite.Sqlite3Ptr,
  sql : String,
  action : (@sqlite.Sqlite3StmtPtr) -> T raise,
) -> T raise {
  let slot = @sqlite.Sqlite3StmtPtr::slot()
  let bytes = @utf8.encode(sql)
  let status = prepare_sql(db, bytes, bytes.length(), slot)
  let stmt = @sqlite.Sqlite3StmtPtr::read_slot(slot)
  if status != @sqlite.sqlite_ok || stmt.is_null() {
    if !stmt.is_null() {
      ignore(@sqlite.sqlite3_finalize(stmt))
    }
    check(db, status, @sqlite.sqlite_ok, "preparing statement")
    raise Failure("preparing statement returned NULL")
  }
  let result = action(stmt) catch {
    err => {
      // Finalize even after a failed step. Keep the original operation error.
      ignore(@sqlite.sqlite3_finalize(stmt))
      raise err
    }
  }
  check(
    db,
    @sqlite.sqlite3_finalize(stmt),
    @sqlite.sqlite_ok,
    "finalizing statement",
  )
  result
}

///|
fn main raise {
  let db_slot = @sqlite.Sqlite3Ptr::slot()
  let status = @sqlite.sqlite3_open(b":memory:\x00", db_slot)
  let db = @sqlite.Sqlite3Ptr::read_slot(db_slot)
  if status != @sqlite.sqlite_ok || db.is_null() {
    if !db.is_null() {
      ignore(@sqlite.sqlite3_close(db))
    }
    raise Failure("could not open a database")
  }
  try {
    check(
      db,
      exec_sql(db, @utf8.encode(setup_sql + "\u0000")),
      @sqlite.sqlite_ok,
      "creating the table",
    )
    let expected = [("Tycho", 5), ("Copernicus", 3), ("Kepler", 2)]
    with_statement(db, insert_sql, fn(insert) raise {
      for (name, craters) in expected {
        let text = @utf8.encode(name)
        check(
          db,
          bind_text_copy(insert, 1, text, text.length()),
          @sqlite.sqlite_ok,
          "binding a name",
        )
        check(
          db,
          @sqlite.sqlite3_bind_int(insert, 2, craters),
          @sqlite.sqlite_ok,
          "binding a count",
        )
        check(
          db,
          @sqlite.sqlite3_step(insert),
          @sqlite.sqlite_done,
          "inserting a row",
        )
        check(
          db,
          @sqlite.sqlite3_reset(insert),
          @sqlite.sqlite_ok,
          "resetting insert",
        )
      }
    })
    with_statement(db, select_sql, fn(query) raise {
      println("craters by size:")
      for (name, craters) in expected {
        check(
          db,
          @sqlite.sqlite3_step(query),
          @sqlite.sqlite_row,
          "reading a row",
        )
        let actual_name = @utf8.decode(
          @sqlite.copy_cstr(@sqlite.sqlite3_column_text(query, 0)),
        )
        let actual_craters = @sqlite.sqlite3_column_int(query, 1)
        assert_eq(actual_name, name)
        assert_eq(actual_craters, craters)
        println("  \{actual_name} — \{actual_craters} craters")
      }
      // Errors and extra rows must not be mistaken for end-of-query.
      check(
        db,
        @sqlite.sqlite3_step(query),
        @sqlite.sqlite_done,
        "finishing query",
      )
    })
  } catch {
    err => {
      let close_status = @sqlite.sqlite3_close(db)
      if close_status != @sqlite.sqlite_ok {
        raise Failure(
          "database cleanup failed (\{close_status}); original error: " +
          err.to_string(),
        )
      }
      raise err
    }
  }
  check(
    db,
    @sqlite.sqlite3_close(db),
    @sqlite.sqlite_ok,
    "closing the database",
  )
  // Print success only after row assertions, SQLITE_DONE and resource cleanup.
  println("3 rows")
  println("PASS SQLite: asserted rows, SQLITE_DONE and clean close")
}
