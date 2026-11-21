#!/usr/bin/env python3
"""Record non-gating parse/generation timings for representative public headers."""
import argparse
import json
import platform
from pathlib import Path
import statistics
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import moonbind as d

CASES = {
    "sqlite": ["testdata/sqlite/sqlite3.h"],
    "zlib": ["testdata/zlib/zlib.h", "--include", "testdata/zlib", "--define", "Z_SOLO=1"],
    "cjson": ["testdata/cjson/cJSON.h"],
    "zstd": [
        "testdata/zstd/lib/zstd.h",
        "--define", "ZSTD_DISABLE_ASM=1",
        "--define", "ZSTD_DISABLE_DEPRECATE_WARNINGS=1",
    ],
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repeats", type=int, default=3, help="measured runs per header (default: 3)")
    args = parser.parse_args()
    if args.repeats < 1:
        parser.error("--repeats must be at least 1")

    d.require(d.run(["moon", "build", "--target", "wasm-gc"]))
    program = ROOT / "_build/wasm-gc/debug/build/cmd/main/main.wasm"
    work_root = ROOT / "_build"
    work_root.mkdir(exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="performance-", dir=work_root))
    cases = []

    for name, arguments in CASES.items():
        header = ROOT / arguments[0]
        command = [
            "moonrun", program, "--", *arguments,
            "--target", "x86_64", "--report", "--json",
        ]
        samples = []
        function_count = None
        generated_count = None
        for run_index in range(args.repeats + 1):
            started = time.perf_counter()
            result = d.require(d.run(command, timeout=180))
            elapsed = time.perf_counter() - started
            report = json.loads(result["stdout"])
            functions = report.get("functions", [])
            function_count = len(functions)
            generated_count = sum(f.get("status") == "generated" for f in functions)
            if run_index:
                samples.append(elapsed)

        source = header.read_bytes()
        cases.append({
            "name": name,
            "header": header.relative_to(ROOT).as_posix(),
            "sha256": d.digest(header),
            "input_bytes": len(source),
            "input_lines": len(source.splitlines()),
            "functions": function_count,
            "generated_functions": generated_count,
            "target": "x86_64",
            "warmup_runs": 1,
            "samples_seconds": [round(value, 6) for value in samples],
            "median_seconds": round(statistics.median(samples), 6),
        })
        print("PASS", name, "median", cases[-1]["median_seconds"], "s", flush=True)

    summary = {
        "status": "recorded",
        "gate": "informational; no timing threshold",
        "repeats": args.repeats,
        "host": platform.platform(),
        "python": sys.version.split()[0],
        "moon": d.require(d.run(["moon", "version", "--all"]))["stdout"].strip(),
        "cases": cases,
    }
    d.write_json(work / "summary.json", summary)
    print("Performance baseline:", work / "summary.json", flush=True)


if __name__ == "__main__":
    main()
