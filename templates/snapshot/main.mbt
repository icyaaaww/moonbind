///|
fn cstr(s : String) -> Bytes raise {
  if s.contains("\u0000") { raise Failure("NUL in C string") }
  @utf8.encode(s) + b"\x00"
}

///|
fn code(n : Int, expected : Int) -> Unit raise {
  if n != expected { raise Failure("SQLite status " + n.to_string()) }
}

///|
fn[T] database(path : String, action : (@sql.Sqlite3Ptr) -> T raise) -> T raise {
  let db = match @sql.sqlite3_open_managed(cstr(path)) {
    Ok(Some(db)) => db
    Err((n, p)) => { if p is Some(p) { p.close() }; raise Failure("SQLite open " + n.to_string()) }
    _ => raise Failure("SQLite returned NULL")
  }
  let result = try { db.with_handle(action) } catch { e => { db.close(); raise e } }
  db.close()
  result
}

///|
fn[T] statement(db : @sql.Sqlite3Ptr, query : Bytes, action : (@sql.Sqlite3StmtPtr) -> T raise) -> T raise {
  let stmt = match @sql.demo_sqlite_prepare_managed(db, query, query.length()) {
    Ok(Some(s)) => s
    Err((n, p)) => { if p is Some(p) { p.close() }; raise Failure("SQLite prepare " + n.to_string()) }
    _ => raise Failure("SQLite statement NULL")
  }
  let result = try { stmt.with_handle(action) } catch { e => { try { stmt.close() } catch { _ => () }; raise e } }
  stmt.close()
  result
}

///|
fn bind(stmt : @sql.Sqlite3StmtPtr, i : Int, text : String) -> Unit raise {
  let bytes = @utf8.encode(text)
  code(@sql.demo_sqlite_bind_text(stmt, i, bytes, bytes.length()), 0)
}

///|
fn normalized_manifest(path : String) -> String raise {
  let bytes = @fs.read_file_to_bytes(path)
  // MoonBit validates the complete JSON before the C parser is called.
  ignore(@json.parse(@utf8.decode(bytes), reject_duplicate_keys=true))
  let tree = @cj.cJSON_Parse(bytes + b"\x00")
  if tree.is_null() { raise Failure("cJSON parse failed") }
  let printed = @cj.cJSON_PrintUnformatted(tree)
  if printed.is_null() { @cj.cJSON_Delete(tree); raise Failure("cJSON print allocation failed") }
  let copy = @cj.copy_cstr(printed)
  @cj.cJSON_free(printed)
  @cj.cJSON_Delete(tree)
  @utf8.decode(copy)
}

///|
fn main raise {
  let args = @env.args()
  if args.length() < 3 { raise Failure("Snapshot helper: missing command and path") }
  let cmd = args[1]
  if cmd == "pack" || cmd == "unpack" {
    if args.length() != 5 { raise Failure("codec INPUT OUTPUT EXPECTED_SIZE") }
    let input = @fs.read_file_to_bytes(args[2])
    let mut expected = 0
    if args[4].is_empty() { raise Failure("Missing expected size") }
    for ch in args[4] {
      if ch < '0' || ch > '9' || expected > 1677721 { raise Failure("Invalid expected size") }
      expected = expected * 10 + ch.to_int() - 48
    }
    if expected < 0 || expected > 16777216 || input.length() > 33554432 { raise Failure("File limit exceeded") }
    let result = if cmd == "pack" {
      let bound = @z.zstd_compress_bound(input.length().to_uint64())
      if bound > 33554432UL { raise Failure("Compression bound exceeded") }
      @z.zstd_compress_bytes(input, bound.to_int(), 3)
    } else { @z.zstd_decompress_bytes(input, expected) }
    let bytes = match result { Ok(b) => b; Err(_) => raise Failure("Corrupt frame or insufficient capacity") }
    if cmd == "unpack" && bytes.length() != expected { raise Failure("Restored length mismatch") }
    @fs.write_bytes_to_file(args[3], bytes)
  } else if cmd == "db-init" {
    database(args[2], db => code(@sql.demo_sqlite_exec(db, b"CREATE TABLE snapshots(id TEXT PRIMARY KEY, manifest TEXT NOT NULL);\x00"), 0))
  } else if cmd == "db-put" {
    if args.length() != 5 { raise Failure("db-put DB ID MANIFEST") }
    let manifest = normalized_manifest(args[4])
    database(args[2], db => statement(db, b"INSERT INTO snapshots(id,manifest) VALUES (?,?)", stmt => {
      bind(stmt, 1, args[3]); bind(stmt, 2, manifest); code(@sql.sqlite3_step(stmt), 101)
    }))
  } else if cmd == "db-get" {
    if args.length() != 5 { raise Failure("db-get DB ID OUTPUT") }
    let manifest = database(args[2], db => statement(db, b"SELECT manifest FROM snapshots WHERE id=?", stmt => {
      bind(stmt, 1, args[3]); code(@sql.sqlite3_step(stmt), 100)
      @utf8.decode(@sql.copy_cstr(@sql.sqlite3_column_text(stmt, 0)))
    }))
    @fs.write_string_to_file(args[4], manifest)
  } else if cmd == "db-list" {
    let ids : Array[String] = []
    database(args[2], db => statement(db, b"SELECT id FROM snapshots ORDER BY rowid", stmt => {
      let mut n = @sql.sqlite3_step(stmt)
      while n == 100 {
        ids.push(@utf8.decode(@sql.copy_cstr(@sql.sqlite3_column_text(stmt, 0))))
        n = @sql.sqlite3_step(stmt)
      }
      code(n, 101)
    }))
    println(ids.to_json().stringify())
  } else { raise Failure("Unknown snapshot helper command") }
}
