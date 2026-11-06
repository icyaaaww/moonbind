#!/usr/bin/env python3
"""Exercise the public SQLite demo, including lifetime and nonzero exit regressions.

Each injected case compiles successfully into a fresh native build directory
before execution. Restoring SQLITE_STATIC must fail the same lifetime check
that the copying adapter passes; compiler errors cannot count as refusals.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import moonbind as d

SUCCESS = "PASS SQLite: asserted rows, SQLITE_DONE and clean close"


def replace_once(source, before, after):
    assert source.count(before) == 1, (before, source.count(before))
    return source.replace(before, after, 1)


def exercise(work, label, source, adapter, expected_error=None):
    project = work / "consumer"
    (project / "main/main.mbt").write_text(source, encoding="utf-8")
    (project / "main/adapter.c").write_text(adapter, encoding="utf-8")
    build = work / ("build-" + label)
    result = d.run(["moon", "build", "--target", "native", "--target-dir", build], cwd=project)
    (work / (label + "-build.log")).write_text(result["stdout"] + result["stderr"], encoding="utf-8")
    d.require(result)
    result = d.run(["moon", "run", "main", "--target", "native", "--target-dir", build], cwd=project)
    output = result["stdout"] + result["stderr"]
    (work / (label + "-run.log")).write_text(output, encoding="utf-8")
    if expected_error is None:
        assert result["exit_code"] == 0, result
        assert SUCCESS in result["stdout"] and "3 rows" in result["stdout"], result
    else:
        assert result["exit_code"] not in (0, -1), result
        assert expected_error in output, (label, expected_error, result)
        assert SUCCESS not in result["stdout"] and "3 rows" not in result["stdout"], result
        assert "database cleanup failed" not in output, result
    print("PASS", label, "exit", result["exit_code"], flush=True)
    return {"case": label, "compiled": True, "exit_code": result["exit_code"], "expected_error": expected_error,
            "success_marker": SUCCESS in result["stdout"], "output": output[-4000:]}


def main():
    (ROOT / "_build").mkdir(exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="sqlite-demo-", dir=ROOT / "_build"))
    print("Artifacts:", work, flush=True)
    # First execute the exact documented package, rather than only a template.
    result = d.require(d.run(["moon", "run", "examples/sqlite3-demo", "--target", "native",
                             "--target-dir", work / "documented-build"]))
    assert SUCCESS in result["stdout"], result
    project = work / "consumer"
    (project / "main").mkdir(parents=True)
    (project / "vendor").mkdir()
    (project / "moon.mod").write_text('name = "regression/sqlite_demo"\npreferred_target = "native"\n', encoding="utf-8")
    shutil.copytree(ROOT / "examples/sqlite3", project / "bindings")
    for name in ("sqlite3.c",):
        shutil.copy2(ROOT / "examples/sqlite3-demo" / name, project / "main" / name)
    shutil.copy2(ROOT / "testdata/sqlite/sqlite3.h", project / "vendor/sqlite3.h")
    package = (ROOT / "examples/sqlite3-demo/moon.pkg").read_text(encoding="utf-8")
    (project / "main/moon.pkg").write_text(package.replace("icyaaaww/moonbind/examples/sqlite3", "regression/sqlite_demo/bindings"), encoding="utf-8")
    source = (ROOT / "examples/sqlite3-demo/main.mbt").read_text(encoding="utf-8")
    adapter = (ROOT / "examples/sqlite3-demo/adapter.c").read_text(encoding="utf-8").replace("../../testdata/sqlite/sqlite3.h", "../vendor/sqlite3.h")
    results = [exercise(work, "normal", source, adapter)]
    # Destroy the input immediately after sqlite3_bind_text returns, before
    # any sqlite3_step. The MoonBit UTF-8 buffer is dynamically allocated.
    # A C-only mutation keeps this test compatible with immutable Bytes APIs.
    stressed = replace_once(source, '"Tycho"', '"月面🌙"')
    bind_call = "return sqlite3_bind_text(stmt, index, text, length, SQLITE_TRANSIENT);"
    stress_adapter = replace_once(adapter, bind_call,
        "int status = sqlite3_bind_text(stmt, index, text, length, SQLITE_TRANSIENT);\n"
        "  memset((void *)text, 'x', (size_t)length);\n  return status;")
    stress_adapter = "#include <string.h>\n" + stress_adapter
    results.append(exercise(work, "copied-text-after-overwrite", stressed, stress_adapter))
    static_adapter = replace_once(stress_adapter, "length, SQLITE_TRANSIENT)", "length, SQLITE_STATIC)")
    results.append(exercise(work, "static-mutation-must-fail", stressed, static_adapter, "FAILED:"))
    # A nonexistent parent makes sqlite3_open fail without creating a file.
    missing = (work / "missing-parent/database.sqlite").as_posix()
    opened = replace_once(source, 'b":memory:\\x00"', '@utf8.encode(' + json.dumps(missing + "\0") + ')')
    results.append(exercise(work, "open-failure", opened, adapter, "could not open a database"))
    invalid_sql = replace_once(source, '"SELECT name, craters FROM moons ORDER BY craters DESC;"', '"SELECT missing FROM absent_table;"')
    results.append(exercise(work, "prepare-failure", invalid_sql, adapter, "preparing statement failed"))
    constraint = replace_once(source, "name TEXT NOT NULL, craters INT NOT NULL", "name TEXT NOT NULL UNIQUE, craters INT NOT NULL")
    constraint = replace_once(constraint, '("Copernicus", 3)', '("Tycho", 3)')
    results.append(exercise(work, "insert-step-failure", constraint, adapter, "inserting a row failed"))
    query = replace_once(source, '"SELECT name, craters FROM moons ORDER BY craters DESC;"',
                         '"SELECT name, CASE WHEN craters = 2 THEN abs(-9223372036854775808) ELSE craters END FROM moons;"')
    results.append(exercise(work, "query-step-failure", query, adapter, "reading a row failed"))
    extra = replace_once(source, '"SELECT name, craters FROM moons ORDER BY craters DESC;"',
                         '\"SELECT name, craters FROM moons UNION ALL SELECT \'Extra\', 0 ORDER BY craters DESC;\"')
    results.append(exercise(work, "extra-row-failure", extra, adapter, "finishing query failed"))
    fewer = replace_once(source, '"SELECT name, craters FROM moons ORDER BY craters DESC;"',
                         '"SELECT name, craters FROM moons WHERE craters > 2 ORDER BY craters DESC;"')
    results.append(exercise(work, "missing-row-failure", fewer, adapter, "reading a row failed"))
    wrong = replace_once(source, '"SELECT name, craters FROM moons ORDER BY craters DESC;"',
                         '"SELECT name, craters + 1 FROM moons ORDER BY craters DESC;"')
    results.append(exercise(work, "wrong-value-failure", wrong, adapter, "FAILED:"))
    d.write_json(work / "summary.json", {"status": "passed", "documented_demo": "passed", "cases": results,
                  "scope": "Actual checked-in demo, copied consumer, explicit borrowed-buffer overwrite and runtime failure exits; generated bindings and handwritten lifetime policy are distinguished."})
    print("PASS SQLite demo lifetime and failure-exit acceptance; evidence:", work, flush=True)


if __name__ == "__main__":
    main()
