#!/usr/bin/env python3
"""Deterministic malformed-input termination checks; not a full C fuzzer."""
import json
from pathlib import Path
import random
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import moonbind as d

(ROOT / "_build").mkdir(exist_ok=True)
work = Path(tempfile.mkdtemp(prefix="parser-corpus-", dir=ROOT / "_build"))
d.require(d.run(["moon", "build", "--target", "wasm-gc"]))
program = ROOT / "_build/wasm-gc/debug/build/cmd/main/main.wasm"
invalid = ["struct Bad { int x;", "int f(int x;", "struct Bad { mystery field; };", "static inline int f(int x) {", "#include <missing_moonbind_header.h>\nint f(void);", "long double f(void);"]
rng = random.Random(20261023)
tokens = ["int", "struct", "*", "(", ")", "{", "}", ";", "typedef", "x", ",", "[", "]", "42"]
corpus = [(s, True) for s in invalid]
corpus += [(" ".join(rng.choices(tokens, k=rng.randint(1, 90))), False) for _ in range(48)]
results = []
for i, (source, must_reject) in enumerate(corpus):
    header = work / (str(i) + ".h")
    header.write_text(source, encoding="utf-8")
    result = d.run(["moonrun", program, "--", header, "--strict", "--json"], timeout=10)
    assert result["exit_code"] in (0, 1), result
    assert "panic" not in result["stderr"].lower() and "stack overflow" not in result["stderr"].lower(), result
    if must_reject: assert result["exit_code"] == 1, result
    results.append({"case": i, "exit_code":result["exit_code"], "must_reject":must_reject})
d.write_json(work / "summary.json", {"status":"passed", "seed":20261023, "cases":results, "scope":"Bounded deterministic token mutations and known-invalid strict refusals; not exhaustive C fuzzing"})
print("PASS", len(results), "bounded parser cases; evidence:", work)
