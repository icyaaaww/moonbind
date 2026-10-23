#!/usr/bin/env python3
"""Actual native application and non-destructive maintenance acceptance checks."""
import copy
import json
import os
from pathlib import Path
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import moonbind as d
import moonbind_workflows as w
from tools import snapshot as s


def rejected(action):
    try:
        action()
    except (ValueError, RuntimeError, OSError):
        return
    raise AssertionError("Expected refusal")


def maintenance(work):
    project = work / "delivery"
    d.init_project(project, "delivery", None)
    config = project / "moonbind.json"
    settings = d.read_json(config)
    settings.pop("schema_version")
    d.write_json(config, settings)
    original = config.read_bytes()
    assert w.migrate(d, project)["status"] == "preview"
    assert config.read_bytes() == original
    result = w.migrate(d, project, True)
    assert Path(result["backup"]).read_bytes() == original
    assert w.migrate(d, project, True)["status"] == "unchanged"
    assert d.validate(project)["status"] == "passed"
    header = project / "vendor/api.h"
    old = work / "old.h"
    old.write_bytes(header.read_bytes())
    header.write_text(header.read_text(encoding="utf-8").replace("size_t capacity", "size_t available"), encoding="utf-8")
    d.upgrade_review(project, old)
    before = d.inventory(project)
    assert w.apply_upgrade(d, project)["status"] == "preview"
    assert d.inventory(project) == before
    original = config.read_bytes()
    result = w.apply_upgrade(d, project, True)
    assert Path(result["backup"]).read_bytes() == original
    assert "dst:available:" in d.read_json(config)["output_buffers"]["transform"]
    rejected(lambda: w.apply_upgrade(d, project, True))  # stale evidence
    assert d.validate(project)["status"] == "passed"
    settings = d.read_json(config)
    d.write_json(config, {**settings, "schema_version": 2})
    bad = d.doctor(project)
    assert bad["status"] == "failed" and bad["diagnostics"][0]["remedy"]
    rejected(lambda: w.migrate(d, project, True))
    d.write_json(config, settings)
    # Candidate generation failure cannot modify configuration or create a backup.
    settings.pop("schema_version")
    settings["output_buffers"]["transform"] = "invalid"
    d.write_json(config, settings)
    before = config.read_bytes()
    backups = list((project / "reports").glob("config-backup-*"))
    rejected(lambda: w.migrate(d, project, True))
    assert config.read_bytes() == before
    assert list((project / "reports").glob("config-backup-*")) == backups
    installed = w.install_copy(d, work / "installed")
    driver = Path(installed["directory"]) / "moonbind.py"
    assert d.require(d.run([sys.executable, driver, "--version"], cwd=work))["stdout"].strip() == d.VERSION
    copied = work / "copied-project"
    d.require(d.run([sys.executable, driver, "init", copied, "--template", "contracts"], cwd=work))
    d.require(d.run([sys.executable, driver, "generate", copied], cwd=work))
    rejected(lambda: w.install_copy(d, work / "installed"))
    print("PASS migration, candidate failure, upgrade backup/staleness, diagnostics and independent installed copy", flush=True)


def snapshots(work):
    engine = work / "engine"
    s.init_engine(engine)
    trace = work / "native-calls.txt"
    os.environ["MOONBIND_TRACE"] = str(trace)
    store, source = work / "store", work / "source"
    source.mkdir()
    (source / "empty-dir").mkdir()
    (source / "中文.txt").write_text("月亮 MoonBind\n", encoding="utf-8")
    (source / "binary.dat").write_bytes(bytes(range(256)) * 64)
    (source / "empty").write_bytes(b"")
    s.create_store(engine, store)
    s.save(engine, store, source, "first")
    objects = set((store / "objects").iterdir())
    s.save(engine, store, source, "same")
    assert objects == set((store / "objects").iterdir())
    rejected(lambda: s.save(engine, store, source, "first"))
    assert s.inspect_snapshot(engine, store)["snapshots"] == ["first", "same"]
    original = {p.name:p.read_bytes() for p in source.iterdir() if p.is_file()}
    (source / "中文.txt").write_text("修改\n", encoding="utf-8")
    (source / "binary.dat").unlink()
    (source / "new.txt").write_bytes(b"new")
    s.save(engine, store, source, "second")
    delta = s.inspect_snapshot(engine, store, "first", "second")
    assert delta["added"] == ["new.txt"] and delta["removed"] == ["binary.dat"] and delta["changed"] == ["中文.txt"]
    output = work / "manifest.json"
    s.inspect_snapshot(engine, store, "first", output=output)
    rejected(lambda: s.inspect_snapshot(engine, store, "first", output=output))
    manifest = s.validate_manifest(d.read_json(output))
    restored = work / "restored"
    s.restore(engine, store, "first", restored)
    assert (restored / "empty-dir").is_dir()
    assert {p.name:p.read_bytes() for p in restored.iterdir() if p.is_file()} == original
    before = d.inventory(restored)
    rejected(lambda: s.restore(engine, store, "second", restored))
    assert d.inventory(restored) == before
    entry = next(f for f in manifest["files"] if f["size"] > 0)
    obj = store / "objects" / (entry["sha256"] + ".zst")
    valid = obj.read_bytes()
    for data in (b"not zstandard", valid[:3], None):
        if data is None: obj.unlink()
        else: obj.write_bytes(data)
        dest = work / "must-not-exist"
        rejected(lambda: s.restore(engine, store, "first", dest))
        assert not dest.exists() and not list(work.glob("restore-*"))
    obj.write_bytes(valid)
    with s.lock(store):
        rejected(lambda: s.save(engine, store, source, "locked"))
    assert not (store / ".snapshot.lock").exists()
    for path in ("../escape", "/absolute", "CON", "x\\y", "a/../b", "a.", 42):
        bad = copy.deepcopy(manifest); bad["files"][0]["path"] = path
        rejected(lambda: s.validate_manifest(bad))
    bad = copy.deepcopy(manifest); bad["files"].append(copy.deepcopy(bad["files"][0]))
    rejected(lambda: s.validate_manifest(bad))
    bad = copy.deepcopy(manifest); bad["files"][0]["size"] = s.MAX_FILE + 1
    rejected(lambda: s.validate_manifest(bad))
    bad = copy.deepcopy(manifest); bad["schema_version"] = True
    rejected(lambda: s.validate_manifest(bad))
    # Digest validation catches valid compressed content under a false object ID.
    false_content = work / "false-content.bin"
    false_content.write_bytes(b"X" * entry["size"])
    false_frame = work / "false-frame.zst"
    s.helper(engine, "pack", false_content, false_frame, entry["size"])
    obj.write_bytes(false_frame.read_bytes())
    try:
        s.restore(engine, store, "first", work / "bad-digest")
    except ValueError as error:
        assert "hash mismatch" in str(error), error
    else:
        raise AssertionError("Valid same-length frame with false content was accepted")
    assert not (work / "bad-digest").exists()
    obj.write_bytes(valid)
    calls = set(trace.read_text(encoding="utf-8").splitlines())
    assert {"sqlite3_open", "sqlite3_step", "ZSTD_compress", "ZSTD_decompress", "cJSON_Parse", "cJSON_PrintUnformatted", "cJSON_Delete", "cJSON_free"} <= calls, calls
    os.environ.pop("MOONBIND_TRACE", None)
    print("PASS three-library snapshots, dedup, diff, export, Unicode/binary/empty restore, duplicate IDs, corrupted/missing objects, locks and path limits", flush=True)


if __name__ == "__main__":
    (ROOT / "_build").mkdir(exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="v1-", dir=ROOT / "_build"))
    print("Artifacts:", work, flush=True)
    maintenance(work)
    snapshots(work)
    d.write_json(work / "summary.json", {"status":"passed", "version":d.VERSION, "platform":d.host_target(), "scope":"Automated acceptance; independent user trials pending"})
