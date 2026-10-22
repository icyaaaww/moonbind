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
import time

ROOT = Path(__file__).resolve().parent
VERSION = "0.8.0"
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


def run(argv, cwd=ROOT, timeout=180, env=None):
    try:
        p = subprocess.run(list(map(str, argv)), cwd=cwd, text=True, encoding="utf-8",
                           errors="replace", capture_output=True, timeout=timeout, env=env)
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
    if os.name == "nt" and platform.machine().lower() in {"amd64", "x86_64"}:
        return "win64"
    return "aarch64" if platform.machine().lower() in {"arm64", "aarch64"} else "x86_64"


def windows_compiler():
    """Discover the MSVC toolchain used by Moon's Windows native backend."""
    environment = os.environ.copy()
    if shutil.which("cl"):
        return shutil.which("cl"), environment
    vswhere = Path(os.environ.get("ProgramFiles(x86)", "C:/Program Files (x86)")) / "Microsoft Visual Studio/Installer/vswhere.exe"
    if not vswhere.exists():
        return None, environment
    found = run([vswhere, "-latest", "-products", "*", "-requires", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64", "-property", "installationPath"])
    location = found["stdout"].strip()
    if not location:
        return None, environment
    vcvars = Path(location) / "VC/Auxiliary/Build/vcvars64.bat"
    if not vcvars.exists() or any(c in str(vcvars) for c in '\r\n"&|<>^%'):
        raise ValueError("Invalid MSVC setup path")
    proc = subprocess.run('cmd.exe /d /s /c ""' + str(vcvars) + '" >nul && set"', text=True, capture_output=True, timeout=60)
    setup = {"exit_code": proc.returncode, "stdout": proc.stdout, "stderr": proc.stderr}
    require(setup)
    for line in setup["stdout"].splitlines():
        if "=" in line and not line.startswith("="):
            key, value = line.split("=", 1)
            environment[key.upper()] = value
    return shutil.which("cl", path=environment.get("PATH")), environment


def doctor(root):
    root, p, config, c = load_project(root)
    moon = run(["moon", "version", "--all"])
    cc_env = None
    if os.name == "nt":
        cc, cc_env = windows_compiler()
    else:
        cc = os.environ.get("CC") or shutil.which("clang") or shutil.which("cc")
    checks = {"moon": moon, "compiler": run([cc, "/?"] if os.name == "nt" else [cc, "--version"], env=cc_env) if cc else {"exit_code": -1, "stderr": "Install MSVC Build Tools on Windows, or clang on Linux/macOS"}}
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
                flags.extend(["/I" if os.name == "nt" else "-I", str(config.parent / include)])
            for define in c.get("defines", []):
                flags.append(("/D" if os.name == "nt" else "-D") + define)
            command = [cc, "/nologo", "/std:c11", source, "/Fe:" + str(executable), "/Fo:" + str(temp / "probe.obj"), *flags] if os.name == "nt" else [cc, "-std=c11", source, "-o", executable, *flags]
            checks["header_probe_compile"] = run(command, cwd=temp, env=cc_env)
            if checks["header_probe_compile"]["exit_code"] == 0:
                checks["header_probe_run"] = run([executable], cwd=root)
    # Native validation must match the actual host architecture and C model.
    model = checks.get("header_probe_run", {}).get("stdout", "").strip()
    supported = target == host_target() and model == ("8 4" if target == "win64" else "8 8")
    passed = supported and all(v.get("exit_code") == 0 for v in checks.values())
    result = {"schema_version": 1, "version": VERSION, "status": "passed" if passed else "failed",
              "host": {"system": platform.system(), "machine": platform.machine()}, "target": target,
              "native_model_supported": supported, "checks": checks,
              "scope": "Native LP64 Linux/macOS and Windows x64 LLP64 with MSVC; header probe does not prove library linkage or runtime behavior."}
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
        cells = [f.get("name"), f.get("generation"), f.get("runtime"), f.get("checks"), f.get("adapter_entries"), f.get("source")]
        rows.append("<tr>" + "".join("<td>" + html.escape(json.dumps(v, ensure_ascii=False)) + "</td>" for v in cells) + "</tr>")
    return ('<!doctype html><html lang="en"><meta charset="utf-8">'
            '<meta http-equiv="Content-Security-Policy" content="default-src \'none\'; style-src \'unsafe-inline\'">'
            '<title>MoonBind validation</title><style>body{font:16px system-ui;max-width:1100px;margin:40px auto;padding:20px;color:#182530}table{border-collapse:collapse;width:100%}td,th{border:1px solid #ccd5dd;padding:10px;text-align:left}pre{white-space:pre-wrap;overflow-wrap:anywhere}h1{color:#184e77}</style>'
            '<h1>MoonBind 0.8 validation: ' + html.escape(report["status"]) + '</h1>'
            '<p>Compile/link results apply to the tested project. Function coverage below is declared by test authors, not automatically proven. Run report-check before relying on this snapshot.</p>'
            '<table><tr><th>Function</th><th>Generation</th><th>Runtime</th><th>Declared checks</th><th>C adapter entries</th><th>Source</th></tr>'
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
            trace_file = build_dir / ("trace-" + str(len(runtime)) + ".txt")
            environment = os.environ.copy()
            environment.pop("MOONBIND_TRACE", None)
            if c.get("trace_calls"):
                environment["MOONBIND_TRACE"] = str(trace_file)
            result = run(["moon", "run", test["package"], *build_flags], cwd=root, env=environment)
            observed = {}
            if c.get("trace_calls") and trace_file.exists():
                for name in trace_file.read_text(encoding="utf-8").splitlines():
                    if name not in generated_names:
                        raise ValueError("Unknown function in invocation trace: " + name)
                    observed[name] = observed.get(name, 0) + 1
            result["adapter_entries"] = observed
            result["trace_enabled"] = bool(c.get("trace_calls"))
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
                                    "adapter_entries": sum(t.get("adapter_entries", {}).get(f["name"], 0) for t in report.get("runtime_checks", [])),
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
    if target not in {"x86_64", "aarch64", "win64"}:
        raise ValueError("Project templates support x86_64/aarch64 LP64 or win64 LLP64")
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
        if template == "sqlite-callback":
            files = [("testdata/sqlite/sqlite3.h", "vendor/sqlite3.h"), ("examples/sqlite3-demo/sqlite3.c", "vendor/sqlite3.c")]
            functions = ["sqlite3_open", "sqlite3_close", "sqlite3_exec", "sqlite3_prepare_v2", "sqlite3_step", "sqlite3_column_int", "sqlite3_finalize"]
            config.update(header="vendor/sqlite3.h", native_sources=["../vendor/sqlite3.c"], allow_functions=functions, trace_calls=True,
                          status_codes={"sqlite3_open": "0", "sqlite3_close": "0", "sqlite3_prepare_v2": "0", "sqlite3_finalize": "0"},
                          out_params={"sqlite3_open": "ppDb", "sqlite3_prepare_v2": "ppStmt"},
                          null_params={"sqlite3_exec": "errmsg", "sqlite3_prepare_v2": "pzTail"}, callbacks={"sqlite3_exec": "callback:#3:1"})
            verifies = "real SQLite synchronous row callback, raised MoonBit error, C abort/error, generated output/NULL/status wrappers"
        elif template == "calls":
            files = [("testdata/calls/api.h", "vendor/api.h"), ("testdata/calls/api.c", "vendor/api.c")]
            config.update(native_sources=["../vendor/api.c"], trace_calls=True,
                          ownership={"item_new": "item_close:0"}, status_codes={"item_open": "0", "item_close": "0"},
                          out_params={"item_open": "out"}, null_params={"optional_tail": "tail"}, callbacks={"visit": "callback:context:1"})
            functions = ["item_open", "item_new", "item_close", "item_live", "optional_tail", "visit"]
            verifies = "output/error handles, cleanup errors, synchronous callback repetition/raise/reentrancy and C entry tracing"
        elif template == "contracts":
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
        (staging / "README.md").write_text("# MoonBind " + template + " example\n\nUse the MoonBind 0.8 source release driver:\n\n```sh\npython /path/to/moonbind/moonbind.py doctor .\npython /path/to/moonbind/moonbind.py validate .\npython /path/to/moonbind/moonbind.py report-check .\n```\n\nValidation executes this project's native code. Review contracts in moonbind.json and assertions in main/main.mbt before using your own library. reports/validation.html is an unsigned snapshot, not a general safety proof. Native templates target LP64 Linux/macOS and MSVC Windows x64 LLP64; zlib is validated only on Linux/macOS with development headers/library.\n", encoding="utf-8")
        for attempt in range(6):
            if destination.exists():
                raise ValueError("Destination appeared during initialization; refusing overwrite")
            try:
                staging.rename(destination)
                break
            except PermissionError:
                if os.name != "nt" or attempt == 5:
                    raise
                time.sleep(0.2 * (attempt + 1))
    finally:
        if staging.exists():
            shutil.rmtree(staging)
    return {"status": "created", "project": str(destination), "template": template, "target": target}


def upgrade_review(root, old_header):
    root, project, config, settings = load_project(root)
    before = inventory(root)
    old_header = Path(old_header).resolve()
    if not old_header.is_file():
        raise ValueError("Old header does not exist")
    result = require(run(["moon", "run", "cmd/main", "--target", "wasm-gc", "--", "--config", config,
                          "--compare", old_header, "--fail-on", "none", "--json"]))
    comparison = json.loads(result["stdout"])
    if comparison.get("status") == "incomplete" or comparison.get("analysis_complete") is False:
        raise ValueError("Header comparison is incomplete")
    affected = set(comparison.get("affected_functions", []))
    contracts = []
    for kind in ("ownership", "status_codes", "out_params", "null_params", "callbacks", "buffers", "copy_strings"):
        values = settings.get(kind, {})
        for function in values:
            value = values[function] if isinstance(values, dict) else True
            dependencies = {function}
            if kind == "ownership":
                dependencies.add(value.split(":", 1)[0])
            if dependencies & affected:
                contracts.append({"kind": kind, "function": function, "value": value,
                                  "action": "Review contract semantics and regenerate; header signatures cannot prove lifetime behavior."})
    # Generate only in a temporary project, so invalid contracts or managed
    # edits never overwrite the consuming project's bindings.
    (root / "_build").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="upgrade-", dir=root / "_build") as temp:
        temp = Path(temp)
        candidate = dict(settings)
        candidate["header"] = str((config.parent / settings["header"]).resolve())
        candidate["include_paths"] = [str((config.parent / p).resolve()) for p in settings.get("include_paths", [])]
        candidate["out"] = "bindings"
        (temp / "moon.mod").write_text('name = "moonbind_review/probe"\n', encoding="utf-8")
        write_json(temp / "candidate.json", candidate)
        checked = run(["moon", "run", "cmd/main", "--target", "wasm-gc", "--", "--config", temp / "candidate.json", "--json"])
        contract_check = {"status": "valid" if checked["exit_code"] == 0 else "invalid",
                          "exit_code": checked["exit_code"], "output": checked["stdout"], "diagnostics": checked["stderr"]}
    if before != inventory(root):
        raise RuntimeError("Project changed during upgrade review")
    status = "review_required" if affected or contract_check["status"] == "invalid" else "unchanged"
    report = {"schema_version": 1, "generator_version": VERSION, "status": status, "comparison": comparison,
              "contracts_to_review": contracts, "current_contract_check": contract_check,
              "affected_runtime_checks": [t for t in project["runtime_checks"] if affected & set(t["functions"])],
              "snapshot": before, "old_header_sha256": digest(old_header),
              "next_steps": ["Review listed contracts and call sites", "Edit configuration intentionally", "Run generate then validate"],
              "scope": "Source comparison under configured macros/ABI; old transitive includes must remain available. Does not infer semantic/lifetime compatibility."}
    write_json(root / "reports/upgrade.json", report)
    (root / "reports/upgrade.html").write_text(render_report(report), encoding="utf-8")
    return report


def install_launcher(directory):
    directory = Path(directory).resolve()
    directory.mkdir(parents=True, exist_ok=True)
    if os.name == "nt":
        path = directory / "moonbind.cmd"
        if any(c in str(ROOT) + sys.executable for c in '"%\r\n'):
            raise ValueError("Launcher path contains unsupported shell characters")
        content = '@echo off\r\nREM MoonBind managed launcher\r\n"' + sys.executable + '" "' + str(ROOT / "moonbind.py") + '" %*\r\n'
    else:
        import shlex
        path = directory / "moonbind"
        content = "#!/bin/sh\n# MoonBind managed launcher\nexec " + shlex.quote(sys.executable) + " " + shlex.quote(str(ROOT / "moonbind.py")) + ' "$@"\n'
    if path.exists() and "MoonBind managed launcher" not in path.read_text(encoding="utf-8"):
        raise ValueError("Refusing to overwrite an unrelated launcher")
    path.write_text(content, encoding="utf-8", newline="")
    if os.name != "nt":
        path.chmod(0o755)
    return {"status": "installed", "launcher": str(path), "source": str(ROOT),
            "note": "Keep this source checkout in place and add the launcher directory to PATH."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", action="version", version=VERSION)
    commands = parser.add_subparsers(dest="command", required=True)
    init = commands.add_parser("init", help="Create a new runnable template; refuses existing directories")
    init.add_argument("project")
    init.add_argument("--template", choices=["sqlite-callback", "calls", "contracts", "nested", "sqlite", "zlib", "cjson"], default="contracts")
    init.add_argument("--target", choices=["x86_64", "aarch64", "win64"])
    upgrade = commands.add_parser("upgrade", help="Review header upgrade and contracts without overwriting bindings")
    upgrade.add_argument("project")
    upgrade.add_argument("--against", required=True, help="Previous header; preserve its original transitive includes")
    install = commands.add_parser("install", help="Create a launcher pointing at this source checkout")
    install.add_argument("--bin", required=True, dest="bin_directory")
    for name in ("doctor", "generate", "validate", "report-check"):
        sub = commands.add_parser(name)
        sub.add_argument("project", nargs="?", default=".")
        if name == "generate":
            sub.add_argument("--check", action="store_true")
    args = parser.parse_args()
    try:
        if args.command == "init":
            result = init_project(args.project, args.template, args.target)
        elif args.command == "upgrade":
            result = upgrade_review(args.project, args.against)
        elif args.command == "install":
            result = install_launcher(args.bin_directory)
        elif args.command == "generate":
            result = generate(args.project, args.check)
        else:
            result = {"doctor": doctor, "validate": validate, "report-check": report_check}[args.command](args.project)
        if args.command in {"doctor", "validate"}:
            print(json.dumps({"status": result["status"], "reports": str(Path(args.project).resolve() / "reports"), "error": result.get("error")}, ensure_ascii=False, indent=2))
        else:
            print(json.dumps(result, ensure_ascii=False, indent=2))
        if result.get("status") == "review_required":
            return 3
        return 1 if result.get("status") in {"failed", "stale_or_failed"} else 0
    except (RuntimeError, ValueError, OSError, KeyError) as e:
        print(json.dumps({"status": "failed", "error": str(e)}, ensure_ascii=False), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
