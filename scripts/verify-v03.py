#!/usr/bin/env python3
"""Exercise 0.3 as a user, including negative cases. --native needs Linux/clang."""
import argparse
import json
from pathlib import Path
import shutil
import tempfile

from importlib.machinery import SourceFileLoader

w = SourceFileLoader("moonbind_workflow", str(Path(__file__).with_name("verify-workflow.py"))).load_module()


def checks(work):
    report = json.loads(w.cli("testdata/bridge/unsupported.h", "--json").stdout)
    assert report["status"] == "incomplete"
    assert {d["code"] for d in report["diagnostics"]} >= {"unsupported_complex", "unsupported_integer"}
    assert all(d["line"] > 0 and d["file"].endswith("unsupported.h") for d in report["diagnostics"])
    strict = w.cli("testdata/bridge/unsupported.h", "--strict", "--json", ok=False)
    assert strict.returncode == 1
    assert json.loads(strict.stdout)["status"] == "failed"
    output = work / "forbidden-output"
    w.cli("testdata/bridge/unsupported.h", "--out", output, ok=False)
    assert not output.exists()
    gate = w.cli("testdata/bridge/point-v2.h", "--compare", "testdata/bridge/point.h", "--fail-on", "changed", "--json", ok=False)
    assert gate.returncode == 3
    result = json.loads(gate.stdout)
    assert result["policy"]["blocked"] is True
    assert "point_sum" in result["affected_functions"]
    html = w.cli("testdata/bridge/point-v2.h", "--compare", "testdata/bridge/point.h", "--fail-on", "changed", "--html", ok=False)
    assert html.returncode == 3 and "<!doctype html>" in html.stdout
    (work / "upgrade-review.html").write_text(html.stdout, encoding="utf-8")
    clean = w.cli("testdata/bridge/point.h", "--compare", "testdata/bridge/point.h", "--fail-on", "any", "--json")
    assert json.loads(clean.stdout)["changes"] == []
    incomplete = w.cli("testdata/bridge/unsupported.h", "--compare", "testdata/bridge/unsupported.h", "--fail-on", "removed", "--json", ok=False)
    assert incomplete.returncode == 3
    assert json.loads(incomplete.stdout)["analysis_complete"] is False
    plain = work / "simple.h"
    plain.write_text("int api(int x);", encoding="utf-8")
    generated = work / "normal"
    w.cli(plain, "--out", generated, "--strict")
    w.cli(plain, "--out", generated, "--strict", "--check")
    # Simulate the 0.2 five-file baseline and verify non-destructive migration.
    state_path = generated / ".moonbind-state.json"
    state = json.loads(state_path.read_text())
    state["files"] = [f for f in state["files"] if f["name"] != "bridge.c"]
    state_path.write_text(json.dumps(state), encoding="utf-8")
    (generated / "bridge.c").unlink()
    w.cli(plain, "--out", generated, "--strict")
    w.cli(plain, "--out", generated, "--strict", "--check")
    print("PASS located diagnostics, strict refusal, no unsafe output, review gates (exit 3), offline HTML, unchanged/incomplete analysis")


def native(work):
    project = w.native_project(work, "pointbridge")
    header = project / "point.h"
    shutil.copy2(w.ROOT / "testdata/bridge/point.h", header)
    output = project / "bindings"
    args = [header, "--bridge", "--strict", "--out", output]
    report = json.loads(w.cli(*args, "--json").stdout)
    assert report["adapted_functions"] == ["point_add", "point_sum", "twice"]
    first = w.contents(output)
    w.cli(*args)
    assert w.contents(output) == first
    w.cli(*args, "--check")
    (project / "main/moon.pkg").write_text('''import { "integration/pointbridge/bindings" @point }
supported_targets = "native"
pkgtype(kind: "executable")
''', encoding="utf-8")
    (project / "main/main.mbt").write_text('''///|
fn main raise {
  let a = @point.mb_Point_new(3, 4)
  let b = @point.mb_Point_new(10, 20)
  assert_false(a.is_null())
  assert_false(b.is_null())
  let sum = @point.point_add(a, b)
  assert_false(sum.is_null())
  assert_eq(@point.mb_Point_get_x(sum), 13)
  assert_eq(@point.mb_Point_get_y(sum), 24)
  assert_eq(@point.point_sum(sum), 37)
  @point.mb_Point_set_x(sum, 100)
  assert_eq(@point.point_sum(sum), 124)
  assert_eq(@point.twice(21), 42)
  @point.mb_Point_free(sum)
  @point.mb_Point_free(a)
  @point.mb_Point_free(b)
  println("PASS bridge: by-value arguments, record return, inline call, read/write/free")
}
''', encoding="utf-8")
    result = w.run(["moon", "run", "main", "--target", "native"], cwd=project)
    assert "PASS bridge:" in result.stdout
    # Separate C harness exercises the generated adapters under ASan/UBSan.
    harness = project / "asan.c"
    harness.write_text('''#include "bindings/bridge.c"
#include <assert.h>
int main(void) {
  for (int i = 0; i < 1000; ++i) {
    struct Point *a = mb_Point_new(3, 4), *b = mb_Point_new(10, 20);
    assert(a && b);
    struct Point *s = moonbind_bridge_point_add(a, b);
    assert(s && mb_Point_get_x(s) == 13 && moonbind_bridge_point_sum(s) == 37);
    mb_Point_set_y(s, 30);
    assert(moonbind_bridge_point_sum(s) == 43);
    mb_Point_free(s); mb_Point_free(a); mb_Point_free(b);
  }
  return 0;
}
''', encoding="utf-8")
    executable = project / "asan-check"
    w.run(["clang", "-std=c11", "-fsanitize=address,undefined", "-fno-omit-frame-pointer", "-g", str(harness), "-o", str(executable)])
    w.run([str(executable)])
    # A library header changed without regeneration: compile-time assertions
    # must fail, rather than simply testing that an assertion string exists.
    header.write_text(header.read_text().replace("int x;", "long x;"), encoding="utf-8")
    rejected = w.run(["clang", "-std=c11", "-fsyntax-only", str(output / "bridge.c")], ok=False)
    assert "mismatch" in rejected.stderr
    evidence = {"platform": "Linux x86-64", "layout": "passed_then_rejected_changed_header", "link": "passed", "runtime": "passed", "asan_ubsan_c_harness": "passed", "iterations": 1000}
    (work / "validation-results.json").write_text(json.dumps(evidence, indent=2), encoding="utf-8")
    print("PASS bridge native compile/link/run, ASan/UBSan 1000 allocation cycles, rejected changed-header layout")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--native", action="store_true")
    args = parser.parse_args()
    work = Path(tempfile.mkdtemp(prefix="v03-", dir=w.ROOT / "_build"))
    print(f"Artifacts: {work}", flush=True)
    checks(work)
    if args.native:
        native(work)
