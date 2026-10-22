#!/usr/bin/env python3
"""Project-driver black-box checks and actual native 0.5 consumer validation."""
import argparse
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("moonbind_driver", ROOT / "moonbind.py")
d = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d)


def cli(*args, ok=True):
    p = subprocess.run([sys.executable, str(ROOT / "moonbind.py"), *map(str, args)], text=True, encoding="utf-8", capture_output=True)
    assert (p.returncode == 0) == ok, (p.stdout, p.stderr)
    return p


def checks(work, native=False):
    projects = {}
    for template in ("contracts", "nested", "sqlite", "zlib", "cjson"):
        project = work / template
        cli("init", project, "--template", template)
        cli("init", project, "--template", template, ok=False)
        cli("generate", project)
        cli("generate", project, "--check")
        d.require(d.run(["moon", "check", "--target", "native"], cwd=project))
        projects[template] = project
        if native:
            cli("validate", project)
            report = d.read_json(project / "reports/validation.json")
            assert report["status"] == "passed"
            assert all(stage["exit_code"] == 0 for stage in report["stages"].values())
            assert report["runtime_checks"][0]["exit_code"] == 0
            cli("report-check", project)
        print("PASS", template, "native runtime" if native else "generation/typecheck", flush=True)

    # No successful report may survive an input, config, test or generated edit.
    project = projects["contracts"]
    if native:
        for relative in ("vendor/owned.h", "main/main.mbt", "bindings/bindings.mbt", "moonbind.json"):
            path = project / relative
            before = path.read_bytes()
            path.write_bytes(before + b"\n ")
            stale = json.loads(cli("report-check", project, ok=False).stdout)
            assert relative in stale["changed_files"]["project"]
            path.write_bytes(before)
        cli("report-check", project)
        # A failing assertion overwrites a previous passing validation report.
        main = project / "main/main.mbt"
        original = main.read_text(encoding="utf-8")
        main.write_text(original.replace("Some(42)", "Some(999)"), encoding="utf-8")
        cli("validate", project, ok=False)
        assert d.read_json(project / "reports/validation.json")["status"] == "failed"
        cli("report-check", project, ok=False)
        main.write_text(original, encoding="utf-8")
        cli("validate", project)
        # Link errors remain distinct from runtime failures.
        source = project / "vendor/owned.c"
        original_c = source.read_text()
        source.write_text(original_c.replace("int resource_live(void)", "int resource_live_missing(void)"))
        cli("validate", project, ok=False)
        failed = d.read_json(project / "reports/validation.json")
        assert failed["stages"]["compile_link"]["exit_code"] != 0
        assert not failed.get("runtime_checks")
        source.write_text(original_c)
        cli("validate", project)

        # Relative bridge header + configured includes survive a project move.
        nested = projects["nested"]
        (nested / "vendor/common").mkdir()
        (nested / "vendor/common/marker.h").write_text("#define MOONBIND_MARKER 1\n")
        header = nested / "vendor/nested.h"
        header.write_text('#include <marker.h>\n' + header.read_text())
        config = d.read_json(nested / "moonbind.json")
        config["include_paths"] = ["vendor/common"]
        d.write_json(nested / "moonbind.json", config)
        cli("validate", nested)
        moved = work / "relocated"
        shutil.copytree(nested, moved, ignore=shutil.ignore_patterns("_build", ".mooncakes", "reports"))
        d.require(d.run(["moon", "run", "main", "--target", "native"], cwd=moved))
        cli("validate", moved)
        # The actual C compiler, not string matching, rejects an out-of-range field.
        harness = moved / "range.c"
        harness.write_text('#include "bindings/bridge.c"\nint main(void) { mb_Packet_new(40000, 0, 0, 0, 0, 0); return 0; }\n')
        exe = moved / "range-check"
        cc = shutil.which("clang") or "cc"
        d.require(d.run([cc, "-std=c11", "-I", moved / "vendor/common", harness, "-o", exe]))
        assert d.run([exe], cwd=moved)["exit_code"] != 0
        # Scoped cleanup paths under C Address/UndefinedBehavior sanitizers.
        # MoonBit runtime is validated above; sanitizer scope is generated C.
        harness.write_text('''#include "bindings/bridge.c"
#include <assert.h>
int main(void) {
  for(int i=0;i<1000;i++) {
    struct Packet *p=mb_Packet_new(-3,255,10,20,30,0);
    assert(p);
    struct Packet *q=moonbind_bridge_packet_step(p);
    assert(q && moonbind_bridge_packet_total(q)==320);
    mb_Packet_free(q); mb_Packet_free(p);
  }
  return 0;
}
''')
        d.require(d.run([cc, "-std=c11", "-I", moved / "vendor/common", "-fsanitize=address,undefined", "-fno-omit-frame-pointer", harness, "-o", exe]))
        d.require(d.run([exe], cwd=moved))
        print("PASS stale evidence, assertion/link failures, relocation/includes, narrow range guard, 1000 sanitizer cycles", flush=True)

    # Invalid contracts must refuse writes even without --strict.
    bad = work / "invalid-contract"
    cli("init", bad)
    config = d.read_json(bad / "moonbind.json")
    config["ownership"] = {"resource_new": "resource_live"}
    config["strict"] = False
    d.write_json(bad / "moonbind.json", config)
    cli("generate", bad, ok=False)
    assert not (bad / "bindings/bindings.mbt").exists()
    # An HTML report must treat header names and check descriptions as data.
    html = d.render_report({"status": "failed", "functions": [{"name": "<script>x</script>"}]})
    assert "<script>" not in html and "&lt;script&gt;" in html
    print("PASS invalid-contract refusal and report escaping", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--native", action="store_true")
    args = parser.parse_args()
    work = Path(tempfile.mkdtemp(prefix="v05-", dir=ROOT / "_build"))
    print("Artifacts:", work, flush=True)
    checks(work, args.native)
