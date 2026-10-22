#include "sqlite3.h"
/* Explicit adapters: NULL optional outputs and SQLITE_TRANSIENT lifetime. */
int demo_sqlite_exec(sqlite3 *db, const char *sql);
int demo_sqlite_prepare(sqlite3 *db, const char *sql, int length, sqlite3_stmt **out);
int demo_sqlite_bind_text(sqlite3_stmt *stmt, int index, const char *text, int length);
