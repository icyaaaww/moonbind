/* Library-specific lifetime policy; this file is handwritten, not generated. */
#include "../../testdata/sqlite/sqlite3.h"

int moonbind_example_sqlite_exec(sqlite3 *db, const char *sql) {
  return sqlite3_exec(db, sql, 0, 0, 0);
}

int moonbind_example_sqlite_prepare(sqlite3 *db, const char *sql,
                                   int length, sqlite3_stmt **out) {
  return sqlite3_prepare_v2(db, sql, length, out, 0);
}

int moonbind_example_sqlite_bind_text(sqlite3_stmt *stmt, int index,
                                     const char *text, int length) {
  /* Bytes is borrowed only until this call returns. SQLite must copy it. */
  return sqlite3_bind_text(stmt, index, text, length, SQLITE_TRANSIENT);
}
