#!/usr/bin/env python3
"""1.1 semantic regressions and native startup with Python UTF-8 mode disabled."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import moonbind as d


class WindowsEnvironmentTests(unittest.TestCase):
    def compiler(self, result):
        vswhere = {"exit_code": 0, "stdout": "C:/VS", "stderr": ""}
        with mock.patch.object(d.shutil, "which", side_effect=[None, "C:/VS/cl.exe"]), \
             mock.patch.object(d.Path, "exists", return_value=True), \
             mock.patch.object(d, "run", return_value=vswhere), \
             mock.patch.object(d.subprocess, "run", return_value=result) as setup:
            found = d.windows_compiler()
            self.assertIn(" /u ", setup.call_args.args[0])
            self.assertNotIn("text", setup.call_args.kwargs)
            return found

    def test_unicode_environment_does_not_depend_on_console_codepage(self):
        output = "PATH=C:/VS/bin\r\nUNICODE_VALUE=\u6d4b\u8bd5\U0001f318\r\nWITH_EQUALS=a=b\r\n=C:=C:/work\r\n"
        compiler, env = self.compiler(subprocess.CompletedProcess([], 0, output.encode("utf-16-le"), b""))
        self.assertEqual(compiler, "C:/VS/cl.exe")
        self.assertEqual(env["UNICODE_VALUE"], "\u6d4b\u8bd5\U0001f318")
        self.assertEqual(env["WITH_EQUALS"], "a=b")
        self.assertEqual(env["PATH"], "C:/VS/bin")

    def test_invalid_output_has_actionable_error(self):
        with self.assertRaisesRegex(ValueError, "UTF-16LE"):
            self.compiler(subprocess.CompletedProcess([], 0, b"x", b""))

    def test_failed_setup_does_not_expose_environment(self):
        with self.assertRaisesRegex(RuntimeError, "developer prompt") as error:
            self.compiler(subprocess.CompletedProcess([], 1, b"SECRET=private", b""))
        self.assertNotIn("SECRET", str(error.exception))


def invocation(program, header, target):
    return d.run(["moonrun", program, "--", header, "--target", target, "--strict", "--json"], timeout=20)


def clang_path():
    found = shutil.which("clang")
    if found:
        return found
    candidate = Path(os.environ.get("ProgramFiles", "C:/Program Files")) / "LLVM/bin/clang.exe"
    return str(candidate) if candidate.is_file() else None


def semantics(work):
    d.require(d.run(["moon", "build", "--target", "wasm-gc"]))
    program = ROOT / "_build/wasm-gc/debug/build/cmd/main/main.wasm"
    version = d.read_json(ROOT / "release-version.json")
    assert d.VERSION == version["product_version"]
    assert version["github_tag"] == "v" + d.VERSION
    module = (ROOT / "moon.mod").read_text(encoding="utf-8")
    assert re.search(r'^version = "([^"\n]+)"', module, re.MULTILINE).group(1) == version["mooncakes_version"]
    cli_version = d.require(d.run(["moonrun", program, "--", "--version"]))["stdout"].strip()
    assert cli_version == "moonbind " + d.VERSION, (cli_version, d.VERSION)
    compiler = clang_path()
    if not compiler:
        raise RuntimeError("clang is required for the 1.1 semantic comparisons")
    results = []
    header = work / "targets.h"
    # The two forms must agree, including on targets where a name is absent.
    header.write_text("""#if defined(__aarch64__) && __aarch64__ && !defined(__x86_64__) && !__x86_64__
int selected_arm(void);
#elif defined(_WIN64) && _WIN64 && defined(_M_X64)
int selected_windows(void);
#elif defined(__wasm32__) && __wasm32__ && !__x86_64__
int selected_wasm(void);
#elif defined(__x86_64__) && __x86_64__ && !defined(__aarch64__) && !__aarch64__
int selected_x86(void);
#else
int selected_wrong(void);
#endif
""", encoding="utf-8")
    for target, triple, expected in [
        ("x86_64", "x86_64-linux-gnu", "selected_x86"),
        ("aarch64", "aarch64-linux-gnu", "selected_arm"),
        ("win64", "x86_64-pc-windows-msvc", "selected_windows"),
        ("wasm32", "wasm32-unknown-unknown", "selected_wasm"),
    ]:
        report = json.loads(d.require(invocation(program, header, target))["stdout"])
        actual = [f["name"] for f in report["functions"]]
        reference = d.require(d.run([compiler, "-std=c11", "-E", "-x", "c", "--target=" + triple, header]))
        selected = re.findall(r"int (selected_\w+)\(void\);", reference["stdout"])
        assert actual == selected == [expected], (target, actual, selected)
        results.append({"target": target, "selected": actual, "clang_selected": selected})
    invalid = [
        "#if 1 2\nint f(void);\n#endif", "#if 1/0\nint f(void);\n#endif",
        "#if 1%0\nint f(void);\n#endif", "#if defined()\nint f(void);\n#endif",
        "#if defined(X\nint f(void);\n#endif", "enum E { BAD = 1/0 };",
        "enum E { BAD = MISSING };", "struct S { int field[1/0]; };",
        "struct S { unsigned field : 1/0; };",
        "#if 0 && (1 + )\nint f(void);\n#endif",
    ]
    for index, source in enumerate(invalid):
        header = work / ("invalid-" + str(index) + ".h")
        header.write_text(source + "\n", encoding="utf-8")
        result = invocation(program, header, "x86_64")
        reference = d.run([compiler, "-std=c11", "-fsyntax-only", "-x", "c", header])
        assert result["exit_code"] == 1 and reference["exit_code"] != 0, (source, result, reference)
        assert "panic" not in result["stderr"].lower(), result
        results.append({"invalid_case": index, "source": source, "exit_code": result["exit_code"], "clang_exit_code": reference["exit_code"]})
    for index, condition in enumerate([
        "(1 ? -1 : 1U) < 0", "(0 ? 1U : -1) < 0", "0 && (1/0)",
        "!(1 || (1/0))", "(1 ? 7 : 1/0) != 7", "(0 ? 1/0 : 9) != 9",
    ]):
        header = work / ("condition-" + str(index) + ".h")
        header.write_text("#if " + condition + "\nint selected_wrong(void);\n#else\nint selected_correct(void);\n#endif\n", encoding="utf-8")
        report = json.loads(d.require(invocation(program, header, "x86_64"))["stdout"])
        reference = d.require(d.run([compiler, "-std=c11", "-E", "-x", "c", header]))
        assert [f["name"] for f in report["functions"]] == ["selected_correct"], report
        assert "int selected_correct(void);" in reference["stdout"], reference
        results.append({"condition": condition, "selected": "selected_correct"})
    return results


def native(work):
    project = work / "native-startup"
    d.init_project(project, "delivery", None)
    # Invoke the real entry point. -X utf8=0 overrides the parent's
    # PYTHONUTF8=1 used by historical Windows acceptance jobs.
    env = os.environ.copy()
    env["MOONBIND_UNICODE_PROBE"] = "\u6d4b\u8bd5\U0001f318"
    for mode in ("0", "1"):
        result = d.require(d.run([sys.executable, "-X", "utf8=" + mode, ROOT / "moonbind.py", "doctor", project], env=env))
        report = json.loads(result["stdout"])
        assert report["status"] == "passed", report
    result = d.require(d.run([sys.executable, "-X", "utf8=0", ROOT / "moonbind.py", "validate", project], env=env))
    report = json.loads(result["stdout"])
    assert report["status"] == "passed", report
    assert d.VERSION in (project / "README.md").read_text(encoding="utf-8")
    assert d.report_check(project)["status"] == "current"
    return {"status": "passed", "target": d.host_target(), "python_utf8_modes": [0, 1]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native", action="store_true")
    args = parser.parse_args()
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(WindowsEnvironmentTests)
    if not unittest.TextTestRunner().run(suite).wasSuccessful():
        raise SystemExit(1)
    (ROOT / "_build").mkdir(exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="v11-", dir=ROOT / "_build"))
    report = {"status": "passed", "semantic_cases": semantics(work), "environment_tests": suite.countTestCases()}
    if args.native:
        report["native"] = native(work)
    d.write_json(work / "summary.json", report)
    print("PASS 1.1 semantic and environment regressions; evidence:", work)


if __name__ == "__main__":
    main()
