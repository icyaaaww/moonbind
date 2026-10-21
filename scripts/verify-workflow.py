#!/usr/bin/env python3
"""Black-box CLI regression checks; --native also runs SQLite and zlib.

Uses only the Python standard library. Every run gets a new directory under
_build so checked-in examples and user files are never regenerated in place.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import zlib

ROOT = Path(__file__).resolve().parents[1]


def run(args, cwd=ROOT, ok=True):
    result = subprocess.run(args, cwd=cwd, text=True, encoding="utf-8", errors="replace", capture_output=True)
    if (result.returncode == 0) != ok:
        raise AssertionError(f"Unexpected exit {result.returncode}: {args}\n{result.stdout}\n{result.stderr[-16000:]}")
    return result


def cli(*args, ok=True):
    return run(["moon", "run", "cmd/main", "--target", "wasm-gc", "--", *map(str, args)], ok=ok)


def contents(folder):
    return {p.name: p.read_bytes() for p in folder.iterdir() if p.is_file()}


def workflow(work):
    fixture = work / "input"
    fixture.mkdir()
    header = fixture / "api.h"
    header.write_text("struct Item { int value; }; int sum(int a, int b); int var(int n, ...);", encoding="utf-8")
    config = fixture / "moonbind.json"
    config.write_text(json.dumps({"header": "api.h", "out": "../generated", "allow_functions": ["sum", "var"]}), encoding="utf-8")
    output = work / "generated"
    report = json.loads(cli("--config", config, "--json").stdout)
    assert report["summary"] == {"generated_functions": 1, "skipped_functions": 1, "excluded_functions": 0}
    first = contents(output)
    cli("--config", config)
    assert contents(output) == first, "regeneration was not deterministic"
    cli("--config", config, "--check")
    (output / "handwritten.mbt").write_text("// leave this alone\n", encoding="utf-8")
    header.write_text("struct Item { long value; }; int sum(int a, int b); int var(int n, ...);", encoding="utf-8")
    before_check = contents(output)
    cli("--config", config, "--check", ok=False)
    assert contents(output) == before_check, "--check modified files"
    cli("--config", config)
    assert (output / "handwritten.mbt").read_text() == "// leave this alone\n"
    assert contents(output)["bindings.mbt"] != first["bindings.mbt"]
    edited = output / "moon.pkg"
    edited.write_text(edited.read_text() + "\n// user edit\n", encoding="utf-8")
    before_conflict = contents(output)
    header.write_text(header.read_text() + "\nvoid extra(void);", encoding="utf-8")
    failure = cli("--config", config, ok=False)
    assert "moon.pkg" in failure.stdout + failure.stderr
    assert contents(output) == before_conflict, "conflict caused a partial write"
    (output / ".moonbind-state.json").write_text("broken state", encoding="utf-8")
    before_bad_state = contents(output)
    cli("--config", config, ok=False)
    assert contents(output) == before_bad_state
    missing = work / "does-not-exist"
    cli(header, "--out", missing, "--check", ok=False)
    assert not missing.exists(), "--check created a directory"
    foreign = work / "foreign"
    foreign.mkdir()
    (foreign / "moon.pkg").write_text("// handwritten manifest", encoding="utf-8")
    before_foreign = contents(foreign)
    cli(header, "--out", foreign, ok=False)
    assert contents(foreign) == before_foreign
    config.write_text('{"header":"api.h","traget":"x86_64"}', encoding="utf-8")
    cli("--config", config, ok=False)
    cli(header, "--allow", "does_not_exist", ok=False)
    failed_json = json.loads(cli(header, "--allow", "does_not_exist", "--json", ok=False).stdout)
    assert failed_json["status"] == "failed"
    renamed = cli(header, "--allow", "sum", "--rename", "sum=add").stdout
    assert 'fn add(a : Int32, b : Int32) -> Int32 = "sum"' in renamed
    cli(header, "--rename", "sum=var", ok=False)
    diff = json.loads(cli("testdata/upgrade/v2.h", "--compare", "testdata/upgrade/v1.h", "--json").stdout)
    changes = {c["symbol"]: c for c in diff["changes"]}
    assert changes["record:Packet"]["change"] == "changed"
    assert changes["function:packet_legacy"]["after"] is None
    assert changes["function:packet_reset"]["before"] is None
    assert "packet_send" in diff["affected_functions"]
    assert diff == json.loads(cli("testdata/upgrade/v2.h", "--compare", "testdata/upgrade/v1.h", "--json").stdout)
    (work / "upgrade-report.json").write_text(json.dumps(diff, indent=2), encoding="utf-8")
    print("PASS config, deterministic updates, non-writing check, conflict preflight, corrupted state, allowlist and API comparison")


def native_project(work, name):
    project = work / name
    project.mkdir()
    (project / "moon.mod").write_text(f'name = "integration/{name}"\npreferred_target = "native"\n', encoding="utf-8")
    (project / "main").mkdir()
    return project


def sqlite(work):
    project = native_project(work, "sqlite")
    cli("testdata/sqlite/sqlite3.h", "--out", project / "bindings")
    cli("testdata/sqlite/sqlite3.h", "--out", project / "bindings", "--check")
    shutil.copy2(ROOT / "examples/sqlite3-demo/main.mbt", project / "main/main.mbt")
    shutil.copy2(ROOT / "examples/sqlite3-demo/sqlite3.c", project / "main/sqlite3.c")
    (project / "main/moon.pkg.json").write_text(json.dumps({
        "is-main": True, "supported-targets": ["native"],
        "import": [{"path": "integration/sqlite/bindings", "alias": "sqlite"}, "moonbitlang/core/encoding/utf8"],
        "native-stub": ["sqlite3.c"],
    }), encoding="utf-8")
    result = run(["moon", "run", "main", "--target", "native"], cwd=project)
    for row in ["Tycho — 5 craters", "Copernicus — 3 craters", "Kepler — 2 craters", "3 rows"]:
        assert row in result.stdout, result.stdout
    print("PASS SQLite: regenerated bindings -> native compile/link -> insert/query 3 rows")


def zlib_native(work):
    project = native_project(work, "zlib")
    cli("testdata/zlib/zlib.h", "--out", project / "bindings", "--allow", "adler32")
    expected = zlib.adler32(b"MoonBind 0.2")
    (project / "main/main.mbt").write_text(f'''///|
fn main raise {{
  let actual = @zlib.adler32(1, b"MoonBind 0.2", 12)
  assert_eq(actual, {expected})
  println("adler32: \\{{actual}}")
}}
''', encoding="utf-8")
    (project / "main/moon.pkg.json").write_text(json.dumps({
        "is-main": True, "supported-targets": ["native"],
        "import": [{"path": "integration/zlib/bindings", "alias": "zlib"}],
        "link": {"native": {"cc-link-flags": "-lz"}},
    }), encoding="utf-8")
    result = run(["moon", "run", "main", "--target", "native"], cwd=project)
    assert str(expected) in result.stdout, result.stdout
    print("PASS zlib: regenerated official-header bindings -> native compile/link -> adler32 matches Python zlib")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--native", action="store_true", help="also run SQLite and system zlib (Linux with C compiler and zlib development package)")
    args = parser.parse_args()
    (ROOT / "_build").mkdir(exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="workflow-", dir=ROOT / "_build"))
    print(f"Artifacts: {work}", flush=True)
    workflow(work)
    if args.native:
        sqlite(work)
        zlib_native(work)
