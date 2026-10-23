#!/usr/bin/env python3
"""Require explicit review of changes to the recorded 1.0 public interfaces."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
baseline = root / "compat/1.0"
for p in baseline.glob("*/pkg.generated.mbti"):
    actual = root / p.relative_to(baseline)
    assert actual.read_text(encoding="utf-8") == p.read_text(encoding="utf-8"), "Public API changed; review compatibility before intentionally updating the baseline: " + str(actual)
assert {p.parent.name for p in baseline.glob("*/pkg.generated.mbti")} == {"ast", "source", "lex", "cp", "cparse", "layout", "codegen", "cli"}
print("PASS recorded 1.0 public interfaces")
