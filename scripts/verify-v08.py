#!/usr/bin/env python3
"""Executable C/MoonBit contracts, callbacks, upgrade and trace regression checks."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("driver", ROOT / "moonbind.py")
d = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d)


def check(report):
    assert report["status"] == "passed", report.get("error", report)


def main():
    (ROOT / "_build").mkdir(exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="v08-", dir=ROOT / "_build"))
    print("Artifacts:", work, flush=True)
    projects = {}
    for template in ("calls", "sqlite-callback", "contracts", "nested", "cjson"):
        path = work / template
        d.init_project(path, template, None)
        check(d.validate(path))
        assert d.report_check(path)["status"] == "current"
        projects[template] = path
        print("PASS native", template, flush=True)
    p = projects["calls"]
    report = d.read_json(p / "reports/validation.json")
    counts = {f["name"]: f["adapter_entries"] for f in report["functions"]}
    assert counts["visit"] == 1005, counts
    assert counts["long_value"] == 0
    assert counts["item_close"] == 5
    # Header semantics/layout independently checked by the host C compiler.
    source = work / "model.c"
    source.write_text('#include <stddef.h>\n#include "calls/vendor/api.h"\n_Static_assert(sizeof(long)==%d,"long");\n_Static_assert(offsetof(struct Model,value)==%d,"offset");\n_Static_assert(sizeof(struct Model)==%d,"size");\nint main(void){return 0;}\n' % ((4,4,16) if os.name == "nt" else (8,8,24)), encoding="utf-8")
    if os.name == "nt":
        cc, env = d.windows_compiler()
        command = [cc, "/nologo", "/std:c11", source, "/Fo:"+str(work/"model.obj"), "/Fe:"+str(work/"model.exe")]
    else:
        cc, env = os.environ.get("CC", "clang"), None
        command = [cc,"-std=c11",source,"-o",work/"model"]
    d.require(d.run(command,cwd=work,env=env))
    generated = d.require(d.run(["moon","run","cmd/main","--target","wasm-gc","--",p/"vendor/api.h","--target",d.host_target(),"--verify"]))["stdout"]
    expected = "struct Model  0 tag  4 value  8 pointer [sizeof=16, align=8]" if os.name == "nt" else "struct Model  0 tag  8 value  16 pointer [sizeof=24, align=8]"
    assert expected in generated, generated
    # Relocation keeps relative adapter header paths and runtime configuration.
    moved = work / "relocated"
    shutil.copytree(p, moved, ignore=shutil.ignore_patterns("_build", "reports"))
    check(d.validate(moved))
    print("PASS C ABI model, exact trace counts, relocation", flush=True)
    old = work / "old.h"
    header = p / "vendor/api.h"
    original = header.read_text(encoding="utf-8")
    old.write_text(original, encoding="utf-8")
    baseline = d.inventory(p)
    assert d.upgrade_review(p,old)["status"] == "unchanged"
    assert d.inventory(p) == baseline
    # Return type change invalidates status contract and identifies tests.
    header.write_text(original.replace("int item_open", "void item_open"), encoding="utf-8")
    before = d.inventory(p)
    upgrade = d.upgrade_review(p,old)
    assert upgrade["status"] == "review_required"
    assert upgrade["current_contract_check"]["status"] == "invalid"
    assert upgrade["contracts_to_review"] and upgrade["affected_runtime_checks"]
    assert d.inventory(p) == before
    assert d.report_check(p)["status"] == "stale_or_failed"
    header.write_text(original,encoding="utf-8")
    # An actual failed assertion must replace prior success and retain evidence.
    mainfile = p / "main/main.mbt"
    program = mainfile.read_text(encoding="utf-8")
    mainfile.write_text(program.replace("45000", "45001"),encoding="utf-8")
    assert d.validate(p)["status"] == "failed"
    assert d.report_check(p)["status"] == "stale_or_failed"
    mainfile.write_text(program,encoding="utf-8")
    # Force an invalid callback contract without strict; no files overwritten.
    config = d.read_json(p / "moonbind.json")
    bad = dict(config)
    bad.update(strict=False, callbacks={"visit":"callback:count:1"})
    d.write_json(p / "moonbind.json",bad)
    before_binding = d.digest(p / "bindings/bindings.mbt")
    try:
        d.generate(p)
        raise AssertionError("invalid callback accepted")
    except RuntimeError:
        pass
    assert d.digest(p / "bindings/bindings.mbt") == before_binding
    d.write_json(p / "moonbind.json",config)
    check(d.validate(p))
    # Optional trace remains off unless explicitly requested.
    config["trace_calls"] = False
    d.write_json(p / "moonbind.json",config)
    no_trace = d.validate(p)
    check(no_trace)
    assert all(f["adapter_entries"] == 0 for f in no_trace["functions"])
    assert not no_trace["runtime_checks"][0]["trace_enabled"]
    config["trace_calls"] = True
    d.write_json(p / "moonbind.json",config)
    check(d.validate(p))
    launcher = d.install_launcher(work / "bin")
    command = [launcher["launcher"], "--version"]
    if os.name == "nt":
        command = ["cmd.exe", "/c", *command]
    assert d.require(d.run(command))["stdout"].strip() == d.VERSION
    print("PASS upgrade impact, invalid contract refusal, failed report replacement, trace opt-out, launcher", flush=True)
    d.write_json(work / "summary.json", {"status":"passed","version":d.VERSION,"host":d.host_target(),"projects":list(projects),"checks":["real SQLite callbacks","10000 repeated callbacks","reentrancy and delayed exceptions","error output handles","cleanup errors","C model assertions","actual C adapter entry counts","relocation","upgrade no-write/impact/invalid contract","failed assertions invalidate evidence","trace opt-out","launcher"]})


if __name__ == "__main__":
    main()
