#!/usr/bin/env python3
"""MoonBind project driver. Python standard library; generation stays in MoonBit.

Run from the source release: python /path/to/moonbind/moonbind.py --help
No shell command strings are evaluated. Validation runs project MoonBit code.
"""
import argparse
import datetime
import hashlib
import html
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent
VERSION = "0.5.0"
IGNORE = {"_build", ".git", ".mooncakes", "__pycache__", "reports"}


def read_json(path):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError(f"Duplicate JSON key: {key}")
            result[key] = value
        return result
    return json.loads(Path(path).read_text(encoding="utf-8"), object_pairs_hook=unique)


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    # Atomic report replacement: never leave a truncated success report.
    staging = path.with_suffix(path.suffix + ".tmp")
    staging.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    staging.replace(path)


def inside(root, relative):
    if not isinstance(relative, str) or not relative:
        raise ValueError("Expected a nonempty project-relative path")
    path = (root / relative).resolve()
    if Path(relative).is_absolute() or not path.is_relative_to(root):
        raise ValueError(f"Path must stay inside project: {relative}")
    return path


def run(argv, cwd=ROOT, timeout=180):
    try:
        p = subprocess.run(list(map(str, argv)), cwd=cwd, text=True, encoding="utf-8",
                           errors="replace", capture_output=True, timeout=timeout)
        return {"command": list(map(str, argv)), "exit_code": p.returncode,
                "stdout": p.stdout, "stderr": p.stderr}
    except (OSError, subprocess.TimeoutExpired) as e:
        return {"command": list(map(str, argv)), "exit_code": -1, "stdout": "", "stderr": str(e)}


def require(result):
    if result["exit_code"]:
        raise RuntimeError(result["stderr"][-6000:] + "\n" + result["stdout"][-3000:])
    return result


def load_project(root):
    root = Path(root).resolve()
    p = read_json(root / "moonbind.project.json")
    if not isinstance(p, dict) or set(p) - {"schema_version", "binding_config", "runtime_checks", "template"}:
        raise ValueError("Unknown project configuration fields")
    if p.get("schema_version") != 1:
        raise ValueError("Expected project schema_version 1")
    config = inside(root, p.get("binding_config"))
    c = read_json(config)
    if not isinstance(c, dict):
        raise ValueError("Generator configuration must be a JSON object")
    # Paths in the generator config resolve relative to that config.
    for key in ("header", "out"):
        if key not in c:
            raise ValueError(f"Generator config requires {key}")
        inside(root, str(config.parent.relative_to(root) / c[key]))
    if inside(root, str(config.parent.relative_to(root) / c["out"])) == root:
        raise ValueError("Generated output must be a project subdirectory")
    for path in c.get("include_paths", []):
        inside(root, str(config.parent.relative_to(root) / path))
    output = (config.parent / c["out"]).resolve()
    for source in c.get("native_sources", []):
        resolved = (output / source).resolve()
        if not resolved.is_relative_to(root):
            raise ValueError("Native sources must stay within project")
    checks = p.get("runtime_checks", [])
    p["runtime_checks"] = checks
    if not isinstance(checks, list):
        raise ValueError("runtime_checks must be an array")
    names = set()
    for check in checks:
        if not isinstance(check, dict) or set(check) != {"name", "package", "functions", "verifies"}:
            raise ValueError("Each runtime check needs name/package/functions/verifies")
        if not all(isinstance(check[k], str) and check[k] for k in ("name", "package", "verifies")):
            raise ValueError("Check names, packages and descriptions must be nonempty strings")
        if check["name"] in names:
            raise ValueError("Duplicate runtime check name")
        names.add(check["name"])
        inside(root, check["package"])
        if not isinstance(check["functions"], list) or not all(isinstance(f, str) for f in check["functions"]):
            raise ValueError("Check functions must be a string array")
    return root, p, config, c


def host_target():
    return "aarch64" if platform.machine().lower() in {"arm64", "aarch64"} else "x86_64"


def doctor(root):
    root, p, config, c = load_project(root)
    moon = run(["moon", "version", "--all"])
    cc = os.environ.get("CC") or shutil.which("clang") or shutil.which("cc")
    checks = {"moon": moon, "compiler": run([cc, "--version"]) if cc else {"exit_code": -1, "stderr": "Install clang or set CC to its executable path"}}
    target = c.get("target", "x86_64")
    if cc:
        with tempfile.TemporaryDirectory(prefix="moonbind-doctor-") as temp:
            temp = Path(temp)
            source = temp / "probe.c"
            executable = temp / ("probe.exe" if os.name == "nt" else "probe")
            header = (config.parent / c["header"]).as_posix()
            source.write_text('#include <stdio.h>\n#include ' + json.dumps(header) + '\nint main(void) { printf("%zu %zu",sizeof(void*),sizeof(long)); return 0; }\n', encoding="utf-8")
            flags = []
            for include in c.get("include_paths", []):
                flags.extend(["-I", str(config.parent / include)])
            for define in c.get("defines", []):
                flags.append("-D" + define)
            checks["header_probe_compile"] = run([cc, "-std=c11", source, "-o", executable, *flags], cwd=root)
            if checks["header_probe_compile"]["exit_code"] == 0:
                checks["header_probe_run"] = run([executable], cwd=root)
    # The driver runs native binaries only. Windows LLP64 and cross compilation
    # are reported as unsupported rather than pretending SysV and Win64 agree.
    model = checks.get("header_probe_run", {}).get("stdout", "").strip()
    supported = os.name != "nt" and target == host_target() and model == "8 8"
    passed = supported and all(v.get("exit_code") == 0 for v in checks.values())
    result = {"schema_version": 1, "version": VERSION, "status": "passed" if passed else "failed",
              "host": {"system": platform.system(), "machine": platform.machine()}, "target": target,
              "native_model_supported": supported, "checks": checks,
              "scope": "Native LP64 Linux/macOS only; compiler/header probe does not prove library linkage or runtime behavior."}
    write_json(root / "reports/doctor.json", result)
    return result


def generate(root, check=False):
    root, p, config, c = load_project(root)
    # Invoke relative paths from generator root, avoiding checkout-specific C
    # includes. The C adapter itself includes relative to its source file.
    argv = ["moon", "run", "cmd/main", "--target", "wasm-gc", "--", "--config", str(config), "--json"]
    if check:
        argv.append("--check")
    result = require(run(argv))
    return json.loads(result["stdout"])


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def inventory(root, generator=False):
    result = {}
    for directory, dirs, files in os.walk(root):
        for d in dirs:
            if d not in IGNORE and (Path(directory) / d).is_symlink():
                raise ValueError("Snapshot requires real directories: " + str(Path(directory) / d))
        dirs[:] = sorted(d for d in dirs if d not in IGNORE)
        for name in sorted(files):
            # Moon updates these derived interfaces while checking/building.
            if not generator and name == "pkg.generated.mbti":
                continue
            path = Path(directory) / name
            relative = path.relative_to(root).as_posix()
            if path.is_symlink():
                raise ValueError(f"Snapshot requires regular files: {relative}")
            if generator and not (path.suffix in {".mbt", ".mbti", ".pkg", ".mod", ".py"}):
                continue
            if generator and relative.split("/")[0] in {"testdata", "templates", "examples", "docs"}:
                continue
            result[relative] = digest(path)
    return result


def render_report(report):
    rows = []
    for f in report.get("functions", []):
        cells = [f.get("name"), f.get("generation"), f.get("runtime"), f.get("checks"), f.get("source")]
        rows.append("<tr>" + "".join("<td>" + html.escape(json.dumps(v, ensure_ascii=False)) + "</td>" for v in cells) + "</tr>")
    return ('<!doctype html><html lang="en"><meta charset="utf-8">'
            '<meta http-equiv="Content-Security-Policy" content="default-src \'none\'; style-src \'unsafe-inline\'">'
            '<title>MoonBind validation</title><style>body{font:16px system-ui;max-width:1100px;margin:40px auto;padding:20px;color:#182530}table{border-collapse:collapse;width:100%}td,th{border:1px solid #ccd5dd;padding:10px;text-align:left}pre{white-space:pre-wrap;overflow-wrap:anywhere}h1{color:#184e77}</style>'
            '<h1>MoonBind 0.5 validation: ' + html.escape(report["status"]) + '</h1>'
            '<p>Compile/link results apply to the tested project. Function coverage below is declared by test authors, not automatically proven. Run report-check before relying on this snapshot.</p>'
            '<table><tr><th>Function</th><th>Generation</th><th>Runtime</th><th>Declared checks</th><th>Source</th></tr>'
            + "".join(rows) + '</table><h2>Evidence and SHA-256 snapshot</h2><pre>'
            + html.escape(json.dumps(report, ensure_ascii=False, indent=2)) + '</pre></html>')


def validate(root):
    root = Path(root).resolve()
    report = {"schema_version": 1, "generator_version": VERSION,
              "created_at": datetime.datetime.now(datetime.timezone.utc).isoformat(), "status": "failed",
              "stages": {}, "functions": [], "scope": "Recorded execution evidence for this input snapshot, not a general memory/ABI safety guarantee."}
    try:
        root, p, config, c = load_project(root)
        generated = generate(root)
        report["generation"] = generated
        generated_names = {f["name"] for f in generated.get("functions", []) if f.get("status") == "generated"}
        for test in p["runtime_checks"]:
            if set(test["functions"]) - generated_names:
                raise ValueError("Runtime check names functions that were not generated: " + test["name"])
        report["snapshot"] = {"project": inventory(root), "generator": inventory(ROOT, generator=True)}
        for source in generated.get("sources", []):
            if source.startswith("@builtin/"):
                continue
            source_path = Path(source).resolve()
            if not source_path.is_relative_to(root) or source_path.relative_to(root).as_posix() not in report["snapshot"]["project"]:
                raise ValueError("Parsed header is outside the captured project snapshot: " + source)
        report["doctor"] = doctor(root)
        if report["doctor"]["status"] != "passed":
            raise RuntimeError("Environment probe failed; inspect reports/doctor.json")
        # A fresh target directory prevents stale native objects from being
        # mistaken for validation of changed transitive C includes.
        (root / "_build").mkdir(exist_ok=True)
        build_dir = Path(tempfile.mkdtemp(prefix="validation-", dir=root / "_build"))
        build_flags = ["--target", "native", "--target-dir", str(build_dir)]
        report["build_directory"] = str(build_dir)
        for stage, command in [("typecheck", ["moon", "check", *build_flags]),
                               ("compile_link", ["moon", "build", *build_flags])]:
            result = run(command, cwd=root)
            report["stages"][stage] = result
            require(result)
        runtime = []
        report["runtime_checks"] = runtime
        for test in p["runtime_checks"]:
            result = run(["moon", "run", test["package"], *build_flags], cwd=root)
            runtime.append({**test, **result})
            require(result)
        if not runtime:
            report["status"] = "compiled_only"
        else:
            report["status"] = "passed"
        after = inventory(root)
        before = report["snapshot"]["project"]
        if before != after:
            changed = sorted(k for k in set(before) | set(after) if before.get(k) != after.get(k))
            report["changed_during_validation"] = changed
            raise RuntimeError("Project inputs changed during validation: " + ", ".join(changed))
        if report["snapshot"]["generator"] != inventory(ROOT, generator=True):
            raise RuntimeError("Generator changed during validation")
    except (RuntimeError, ValueError, OSError, KeyError) as e:
        report["status"] = "failed"
        report["error"] = str(e)
    for f in report.get("generation", {}).get("functions", []):
        tests = [t for t in report.get("runtime_checks", []) if f["name"] in t["functions"]]
        state = "not_tested" if not tests else ("declared_checks_passed" if all(t["exit_code"] == 0 for t in tests) else "failed")
        report["functions"].append({"name": f["name"], "generation": f["status"], "source": f.get("source"), "runtime": state,
                                    "checks": [{"name": t["name"], "verifies": t["verifies"]} for t in tests]})
    write_json(root / "reports/validation.json", report)
    (root / "reports/validation.html").write_text(render_report(report), encoding="utf-8")
    return report


def report_check(root):
    root, _, _, _ = load_project(root)
    report = read_json(root / "reports/validation.json")
    expected = report.get("snapshot", {})
    actual = {"project": inventory(root), "generator": inventory(ROOT, generator=True)}
    changes = {}
    for group in actual:
        old = expected.get(group, {})
        changes[group] = sorted(k for k in set(old) | set(actual[group]) if old.get(k) != actual[group].get(k))
    current = not any(changes.values()) and report.get("status") in {"passed", "compiled_only"}
    # This is a file snapshot check. It does not authenticate a user-edited
    # report, recheck dynamic system libraries, or certify another machine.
    return {"status": "current" if current else "stale_or_failed", "changed_files": changes,
            "scope": "Files only; rerun validate after OS/toolchain/system-library changes. Reports are unsigned."}


def init_project(destination, template, target):
    destination = Path(destination).resolve()
    if destination.exists():
        raise ValueError("Destination already exists; choose a new directory")
    target = target or host_target()
    if target not in {"x86_64", "aarch64"}:
        raise ValueError("Project templates support x86_64 or aarch64 LP64")
    # Stage the complete project next to destination; never overwrite user work.
    destination.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix="moonbind-init-", dir=destination.parent))
    try:
        (staging / "vendor").mkdir()
        (staging / "main").mkdir()
        (staging / "bindings").mkdir()
        config = {"header": "vendor/api.h", "out": "bindings", "target": target, "strict": True}
        module = "moonbind_examples/" + template
        pkg = 'import { "' + module + '/bindings" @lib, "moonbitlang/core/encoding/utf8" }\nsupported_targets = "native"\npkgtype(kind: "executable")\n'
        files = []
        if template == "contracts":
            files = [("testdata/contracts/owned.h", "vendor/owned.h"), ("testdata/contracts/owned.c", "vendor/owned.c")]
            config.update(header="vendor/owned.h", native_sources=["../vendor/owned.c"], ownership={"resource_new": "resource_free"},
                          buffers={"checksum": "data:length"}, copy_strings=["borrowed_text"])
            functions = ["resource_new", "resource_free", "resource_live", "resource_value", "checksum", "borrowed_text", "mutate_text"]
            verifies = "normal and error cleanup, NULL allocation, exact byte counts, copied borrowed text"
        elif template == "nested":
            files = [("testdata/bridge/nested.h", "vendor/nested.h")]
            config.update(header="vendor/nested.h", bridge=True, ownership={"mb_Packet_new": "mb_Packet_free"})
            functions = ["packet_step", "packet_total"]
            verifies = "nested record return, array field update, enum, signed narrow fields and cleanup"
        elif template == "sqlite":
            files = [("testdata/sqlite/sqlite3.h", "vendor/sqlite3.h"), ("examples/sqlite3-demo/sqlite3.c", "vendor/sqlite3.c"),
                     ("templates/sqlite/adapter.h", "vendor/adapter.h"), ("templates/sqlite/adapter.c", "vendor/adapter.c")]
            config.update(header="vendor/adapter.h", native_sources=["../vendor/sqlite3.c", "../vendor/adapter.c"])
            # Strict selection covers exactly the APIs used by the demo.
            code = (ROOT / "templates/sqlite/main.mbt").read_text(encoding="utf-8")
            functions = sorted(set(re.findall(r"@lib\.((?:sqlite3|demo_sqlite)_[a-z0-9_]+)\(", code)))
            config["allow_functions"] = functions
            verifies = "in-memory database, prepared insert/query and resource closure"
        elif template == "zlib":
            files = [("testdata/zlib/zlib.h", "vendor/zlib.h"), ("testdata/zlib/zconf.h", "vendor/zconf.h"), ("testdata/zlib/README.md", "vendor/README.md")]
            config.update(header="vendor/zlib.h", defines=["Z_SOLO=1"], allow_functions=["adler32"], buffers={"adler32": "buf:len"})
            pkg += 'options("link": {"native": {"cc-link-flags": "-lz"}})\n'
            functions = ["adler32"]
            verifies = "known ABC and empty-buffer Adler-32 values, byte count derived from Bytes"
        else:
            files = [("testdata/cjson/" + f, "vendor/" + f) for f in ("cJSON.h", "cJSON.c", "LICENSE", "README.md")]
            functions = ["cJSON_CreateArray", "cJSON_Delete", "cJSON_GetArraySize", "cJSON_Version"]
            config.update(header="vendor/cJSON.h", native_sources=["../vendor/cJSON.c"], allow_functions=functions,
                          ownership={"cJSON_CreateArray": "cJSON_Delete"}, copy_strings=["cJSON_Version"])
            verifies = "owned array creation/size/deletion and copied version 1.7.19"
        for source, dest in files:
            shutil.copy2(ROOT / source, staging / dest)
        if config.get("native_sources"):
            # Moon requires native stubs inside their package. A tiny include
            # translation unit keeps vendored sources and licenses together.
            translation_unit = "".join('#include ' + json.dumps(source) + '\n' for source in config["native_sources"])
            (staging / "bindings/library.c").write_text(translation_unit, encoding="utf-8")
            config["native_sources"] = ["library.c"]
        shutil.copy2(ROOT / "templates" / template / "main.mbt", staging / "main/main.mbt")
        (staging / "main/moon.pkg").write_text(pkg, encoding="utf-8")
        (staging / "moon.mod").write_text(f'name = "{module}"\npreferred_target = "native"\n', encoding="utf-8")
        write_json(staging / "moonbind.json", config)
        write_json(staging / "moonbind.project.json", {"schema_version": 1, "binding_config": "moonbind.json", "template": template,
                   "runtime_checks": [{"name": template + " smoke", "package": "main", "functions": functions, "verifies": verifies}]})
        (staging / ".gitignore").write_text("_build/\n.mooncakes/\nreports/\n", encoding="utf-8")
        (staging / "README.md").write_text("# MoonBind " + template + " example\n\nUse the MoonBind 0.5 source release driver:\n\n```sh\npython /path/to/moonbind/moonbind.py doctor .\npython /path/to/moonbind/moonbind.py validate .\npython /path/to/moonbind/moonbind.py report-check .\n```\n\nValidation executes this project's native code. Review contracts in moonbind.json and assertions in main/main.mbt before using your own library. reports/validation.html is an unsigned snapshot, not a general safety proof. Native templates target LP64 Linux/macOS; zlib requires development headers/library.\n", encoding="utf-8")
        staging.rename(destination)
    finally:
        if staging.exists():
            shutil.rmtree(staging)
    return {"status": "created", "project": str(destination), "template": template, "target": target}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", action="version", version=VERSION)
    commands = parser.add_subparsers(dest="command", required=True)
    init = commands.add_parser("init", help="Create a new runnable template; refuses existing directories")
    init.add_argument("project")
    init.add_argument("--template", choices=["contracts", "nested", "sqlite", "zlib", "cjson"], default="contracts")
    init.add_argument("--target", choices=["x86_64", "aarch64"])
    for name in ("doctor", "generate", "validate", "report-check"):
        sub = commands.add_parser(name)
        sub.add_argument("project", nargs="?", default=".")
        if name == "generate":
            sub.add_argument("--check", action="store_true")
    args = parser.parse_args()
    try:
        if args.command == "init":
            result = init_project(args.project, args.template, args.target)
        elif args.command == "generate":
            result = generate(args.project, args.check)
        else:
            result = {"doctor": doctor, "validate": validate, "report-check": report_check}[args.command](args.project)
        if args.command in {"doctor", "validate"}:
            print(json.dumps({"status": result["status"], "reports": str(Path(args.project).resolve() / "reports"), "error": result.get("error")}, ensure_ascii=False, indent=2))
        else:
            print(json.dumps(result, ensure_ascii=False, indent=2))
        return 1 if result.get("status") in {"failed", "stale_or_failed"} else 0
    except (RuntimeError, ValueError, OSError, KeyError) as e:
        print(json.dumps({"status": "failed", "error": str(e)}, ensure_ascii=False), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
