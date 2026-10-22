//! A whole program written against the generated sqlite3 bindings.
//!
//! The point of the example is not that sqlite works — it does — but that
//! nothing in this file mentions a C type, a pointer size or an offset. A
//! header was handed to `moonbind`, and this is what came out.
//!
//! Run it with `moon run examples/sqlite3-demo`.

///|
/// The SQL this program runs, in one place so that the flow is readable.
let setup_sql : String = "CREATE TABLE moons (name TEXT NOT NULL, craters INT NOT NULL);"

///|
let insert_sql : String = "INSERT INTO moons (name, craters) VALUES (?, ?);"

///|
let select_sql : String = "SELECT name, craters FROM moons ORDER BY craters DESC;"

///|
/// A row of the result, so the printing half of the program is separate from
/// the calling half.
struct Moon {
  name : String
  craters : Int32
}

///|
fn Moon::show(self : Moon) -> Unit {
  println("  \{self.name} — \{self.craters} craters")
}

///|
/// Stop the program with sqlite's own message. A binding that hides the error
/// text would be useless the first time something went wrong.
///
/// `wanted` is the status the call is supposed to return: most calls answer
/// `SQLITE_OK`, while a statement that runs to completion answers
/// `SQLITE_DONE`. Anything else is a failure.
fn check(
  db : @lib.Sqlite3Ptr,
  status : Int32,
  wanted : Int32,
  doing : String,
) -> Unit raise {
  if status != wanted {
    let message = @lib.sqlite3_errmsg(db)
    raise Failure(
      "\{doing} failed: " + @utf8.decode(@lib.copy_cstr(message)),
    )
  }
}

///|
fn main {
  let db_slot = @lib.Sqlite3Ptr::slot()
  let status = @lib.sqlite3_open(@utf8.encode(":memory:"), db_slot)
  let db = @lib.Sqlite3Ptr::read_slot(db_slot)
  if status != @lib.sqlite_ok || db.is_null() {
    println("could not open a database")
    return
  }
  try {
    // 1. A schema, executed as a whole statement.
    check(
      db,
      @lib.sqlite3_exec(
        db,
        @utf8.encode(setup_sql),
        @lib.VoidPtr::null(),
        @lib.VoidPtr::null(),
        b"",
      ),
      @lib.sqlite_ok,
      "creating the table",
    )

    // 2. Two inserts through a prepared statement. The `?` placeholders are
    //    bound by position, and `sqlite3_reset` makes the statement reusable.
    let stmt_slot = @lib.Sqlite3StmtPtr::slot()
    check(
      db,
      @lib.sqlite3_prepare_v2(
        db,
        @utf8.encode(insert_sql),
        -1,
        stmt_slot,
        b"",
      ),
      @lib.sqlite_ok,
      "preparing the insert",
    )
    let insert = @lib.Sqlite3StmtPtr::read_slot(stmt_slot)
    for row in [("Tycho", 5), ("Copernicus", 3), ("Kepler", 2)] {
      let (name, craters) = row
      check(
        db,
        @lib.sqlite3_bind_text(
          insert,
          1,
          @utf8.encode(name),
          -1,
          @lib.VoidPtr::null(),
        ),
        @lib.sqlite_ok,
        "binding a name",
      )
      check(
        db,
        @lib.sqlite3_bind_int(insert, 2, craters),
        @lib.sqlite_ok,
        "binding a count",
      )
      check(
        db,
        @lib.sqlite3_step(insert),
        @lib.sqlite_done,
        "inserting \{name}",
      )
      ignore(@lib.sqlite3_reset(insert))
    }
    ignore(@lib.sqlite3_finalize(insert))

    // 3. A query. `sqlite3_step` returns SQLITE_ROW once per row and
    //    SQLITE_DONE at the end, which is the whole cursor protocol.
    println("craters by size:")
    let query_slot = @lib.Sqlite3StmtPtr::slot()
    check(
      db,
      @lib.sqlite3_prepare_v2(
        db,
        @utf8.encode(select_sql),
        -1,
        query_slot,
        b"",
      ),
      @lib.sqlite_ok,
      "preparing the query",
    )
    let query = @lib.Sqlite3StmtPtr::read_slot(query_slot)
    let mut rows = 0
    while @lib.sqlite3_step(query) == @lib.sqlite_row {
      let name = @utf8.decode(
        @lib.copy_cstr(@lib.sqlite3_column_text(query, 0)),
      )
      let craters = @lib.sqlite3_column_int(query, 1)
      { name, craters, }.show()
      rows = rows + 1
    }
    ignore(@lib.sqlite3_finalize(query))
    println("\{rows} rows")

    check(
      db,
      @lib.sqlite3_close(db),
      @lib.sqlite_ok,
      "closing the database",
    )
  } catch {
    err => {
      println(err.to_string())
      ignore(@lib.sqlite3_close(db))
    }
  }
}
