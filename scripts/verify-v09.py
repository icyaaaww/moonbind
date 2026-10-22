#!/usr/bin/env python3
"""Native delivery checks: real libraries, malicious lengths, ownership and upgrades."""
import importlib.util
from pathlib import Path
import shutil
import tempfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("driver", ROOT / "moonbind.py")
d = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d)


def check(report):
    assert report["status"] == "passed", report.get("error", report)


def main():
    (ROOT / "_build").mkdir(exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="v09-", dir=ROOT / "_build"))
    print("Artifacts:", work, flush=True)
    for recipe in ("zstd", "sqlite", "cjson"):
        path = work / recipe
        d.init_project(path, "contracts", None, recipe)
        if recipe == "zstd":
            d.require(d.run(["moon", "update"], cwd=path))
        check(d.validate(path))
        assert d.report_check(path)["status"] == "current"
        lock = d.read_json(path / "moonbind.recipe.lock.json")
        f = path / lock["files"][0]["path"]
        original = f.read_bytes()
        f.write_bytes(original + b"\n/* modified */\n")
        check_failed = d.validate(path)
        assert check_failed["status"] == "failed" and "Recipe source changed" in check_failed["error"]
        f.write_bytes(original)
        check(d.validate(path))
        print("PASS recipe, native assertions and source pinning:", recipe, flush=True)
    path = work / "zstd"
    source = work / "binary.input"
    packed = work / "binary.zst"
    restored = work / "binary.restored"
    source.write_bytes(bytes(range(256)) * 4096)
    for action, src, dst in (("compress", source, packed), ("decompress", packed, restored)):
        d.require(d.run(["moon", "run", "file", "--target", "native", "--", action, src, dst], cwd=path))
    assert restored.read_bytes() == source.read_bytes()
    assert d.run(["moon", "run", "file", "--target", "native", "--", "compress", source, packed], cwd=path)["exit_code"] != 0
    print("PASS real file compression/decompression and existing-output refusal", flush=True)
    path = work / "delivery"
    d.init_project(path, "delivery", None)
    check(d.validate(path))
    counts = {f["name"]: f["adapter_entries"] for f in d.read_json(path / "reports/validation.json")["functions"]}
    assert counts["transform"] == 5 and counts["transform32"] == 2, counts
    assert counts["resource_close"] == 3, counts
    config = d.read_json(path / "moonbind.json")
    changed_macro = {**config, "defines": ["MB_DELIVERY_CONFIG=2"]}
    d.write_json(path / "moonbind.json", changed_macro)
    assert d.validate(path)["status"] == "failed", "Changed macro must reach library translation units and break the value assertion"
    d.write_json(path / "moonbind.json", config)
    for contract in ("dst:capacity:src:length:missing:64", "dst:capacity:dst:length:failed:64", "dst:capacity:src:length:failed:-1"):
        bad = {**config, "strict": False, "output_buffers": {"transform": contract}}
        d.write_json(path / "moonbind.json", bad)
        before = d.digest(path / "bindings/bindings.mbt")
        assert d.validate(path)["status"] == "failed"
        assert d.digest(path / "bindings/bindings.mbt") == before
    d.write_json(path / "moonbind.json", config)
    check(d.validate(path))
    released = work / "released"
    shutil.copytree(path, released, ignore=shutil.ignore_patterns("_build", "reports", ".mooncakes"))
    settings = d.read_json(released / "moonbind.json")
    settings["managed_outputs"]["resource_open"] = "resource_release:0:released"
    d.write_json(released / "moonbind.json", settings)
    project = d.read_json(released / "moonbind.project.json")
    project["runtime_checks"] = [{"name": "released close error", "package": "main",
                                 "functions": ["resource_open", "resource_release", "live_count", "close_count"],
                                 "verifies": "failed release closes the wrapper and frees the C object; repeated close/use never reenters C"}]
    d.write_json(released / "moonbind.project.json", project)
    (released / "main/main.mbt").write_text('''fn main raise {
      let p = match @lib.resource_open_managed(0) { Ok(Some(p)) => p; _ => abort("open") }
      assert_true(try { p.close(); false } catch { @lib.ResourceCloseFailed(9) => true; _ => false })
      assert_true(p.is_closed())
      assert_eq(@lib.live_count(), 0)
      assert_true(try { p.close(); false } catch { @lib.ResourceClosed => true; _ => false })
      assert_true(try { p.with_handle(_ => abort("closed")); false } catch { @lib.ResourceClosed => true; _ => false })
      assert_eq(@lib.close_count(), 1)
    }\n''', encoding="utf-8")
    check(d.validate(released))
    print("PASS macro propagation, length/overflow guards, invalid contracts, retained and released error policies", flush=True)
    header = path / "vendor/api.h"
    original = header.read_text(encoding="utf-8")
    old = work / "old.h"
    old.write_text(original, encoding="utf-8")
    same = d.upgrade_review(path, old)
    assert same["status"] == "unchanged"
    header.write_text(original.replace("size_t capacity", "size_t available"), encoding="utf-8")
    before = d.inventory(path)
    review = d.upgrade_review(path, old)
    assert review["classification_counts"]["must_change"] >= 1
    edits = [e for a in review["actions"] for e in a.get("suggested_config_edits", [])]
    assert any(e["value"] == "dst:available:src:length:failed:64" and not e["applied"] for e in edits), review
    assert any(a.get("generated_declarations") and a.get("runtime_checks") for a in review["actions"])
    assert d.inventory(path) == before
    shutil.copy2(path / "reports/upgrade.json", work / "parameter-rename-review.json")
    header.write_text(original.replace("int resource_close(struct Resource *value);", ""), encoding="utf-8")
    review = d.upgrade_review(path, old)
    assert any(a.get("function") == "resource_close" and a["classification"] == "must_change" for a in review["actions"])
    assert any(a.get("function") == "resource_open" and a["configuration"] for a in review["actions"])
    header.write_text(original, encoding="utf-8")
    check(d.validate(path))
    print("PASS upgrade classifications, parameter rename proposals, destructor dependencies and no overwrite", flush=True)
    d.write_json(work / "summary.json", {"status": "passed", "version": d.VERSION, "host": d.host_target(),
                 "projects": ["zstd", "sqlite", "cjson", "delivery", "released"],
                 "scope": "Automated integration evidence; independent user trials remain pending"})


if __name__ == "__main__":
    main()
