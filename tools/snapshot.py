#!/usr/bin/env python3
"""MoonBind integration demo: local snapshots through generated C bindings.

Python manages paths, SHA-256 and staging. SQLite/cJSON/Zstandard operations run
in the generated MoonBit native helper. Regular files and directories only.
"""
import argparse
from contextlib import contextmanager
import datetime
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import moonbind as d

MAX_FILE = 16 * 1024 * 1024
MAX_TOTAL = 256 * 1024 * 1024
MAX_FILES = 10000


def init_engine(destination):
    destination = Path(destination).resolve()
    if destination.exists():
        raise ValueError("Engine destination already exists")
    destination.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix="snapshot-engine-", dir=destination.parent))
    try:
        for name, recipe in (("sql", "sqlite"), ("z", "zstd"), ("cj", "cjson")):
            lib = stage / name
            d.init_project(lib, "contracts", None, recipe)
            for rel in ("moon.mod", "main", "file"):
                p = lib / rel
                if p.is_dir(): shutil.rmtree(p)
                elif p.exists(): p.unlink()
            config = d.read_json(lib / "moonbind.json")
            config["c_namespace"] = "snapshot_" + name
            if name == "sql":
                for f in ("adapter.h", "adapter.c"):
                    shutil.copy2(ROOT / "templates/sqlite" / f, lib / "vendor" / f)
                with (lib / "bindings/library.c").open("a", encoding="utf-8") as stream:
                    stream.write('#include "../vendor/adapter.c"\n')
                config.update(header="vendor/adapter.h", allow_functions=["sqlite3_open", "sqlite3_close", "sqlite3_finalize", "sqlite3_step", "sqlite3_column_text", "demo_sqlite_exec", "demo_sqlite_prepare", "demo_sqlite_bind_text"],
                              status_codes={"sqlite3_open":"0", "demo_sqlite_prepare":"0"}, out_params={"sqlite3_open":"ppDb", "demo_sqlite_prepare":"out"}, null_params={},
                              managed_outputs={"sqlite3_open":"sqlite3_close:0:retained", "demo_sqlite_prepare":"sqlite3_finalize:0:released"})
            elif name == "cj":
                config.update(allow_functions=["cJSON_Parse", "cJSON_PrintUnformatted", "cJSON_Delete", "cJSON_free"], ownership={}, copy_strings=[], trace_calls=True)
            d.write_json(lib / "moonbind.json", config)
        (stage / "main").mkdir()
        shutil.copy2(ROOT / "templates/snapshot/main.mbt", stage / "main/main.mbt")
        (stage / "moon.mod").write_text('name = "moonbind_examples/snapshot"\npreferred_target = "native"\nimport { "moonbitlang/x@0.5.5" }\n', encoding="utf-8")
        (stage / "main/moon.pkg").write_text('import { "moonbind_examples/snapshot/sql/bindings" @sql, "moonbind_examples/snapshot/z/bindings" @z, "moonbind_examples/snapshot/cj/bindings" @cj, "moonbitlang/core/env", "moonbitlang/core/json", "moonbitlang/core/encoding/utf8", "moonbitlang/x/fs" }\nsupported_targets = "native"\npkgtype(kind: "executable")\n', encoding="utf-8")
        stage.rename(destination)
    finally:
        if stage.exists(): shutil.rmtree(stage)
    for lib in ("sql", "z", "cj"):
        d.generate(destination / lib)
    d.require(d.run(["moon", "update"], cwd=destination))
    d.require(d.run(["moon", "build", "--target", "native"], cwd=destination))
    executable = destination / "_build/native/debug/build/main/main.exe"
    if not executable.is_file():
        raise ValueError("Native executable missing: " + str(executable))
    d.write_json(destination / "snapshot-engine.json", {"version": d.VERSION, "executable": str(executable.relative_to(destination)), "sha256": d.digest(executable)})
    return {"status": "created", "engine": str(destination)}


def helper(engine, *args):
    engine = Path(engine).resolve()
    info = d.read_json(engine / "snapshot-engine.json")
    executable = d.inside(engine, info["executable"])
    if d.digest(executable) != info["sha256"]:
        raise ValueError("Snapshot executable changed; rebuild a new engine")
    return d.require(d.run([executable, *args], cwd=engine))["stdout"]


@contextmanager
def lock(store):
    path = store / ".snapshot.lock"
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        raise ValueError("Store is busy or has an interrupted operation. Confirm no writer is active before removing .snapshot.lock")
    try:
        with os.fdopen(fd, "w") as f: f.write(str(os.getpid()))
        yield
    finally:
        path.unlink()


def regular(path):
    if path.is_symlink() or getattr(path, "is_junction", lambda: False)():
        raise ValueError("Links and junctions are not supported: " + str(path))


def store_path(value):
    path = Path(value).absolute()
    for p in (path, *path.parents): regular(p)
    path = path.resolve()
    if not path.is_dir() or not (path / "index.sqlite").is_file(): raise ValueError("Not a snapshot store")
    for p in (path / "index.sqlite", path / "objects"):
        regular(p)
    return path


def create_store(engine, destination):
    path = Path(destination).resolve()
    if path.exists(): raise ValueError("Store destination already exists")
    path.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix="store-", dir=path.parent))
    try:
        (stage / "objects").mkdir()
        helper(engine, "db-init", stage / "index.sqlite")
        stage.rename(path)
    finally:
        if stage.exists(): shutil.rmtree(stage)
    return {"status":"created", "store":str(path)}


def safe_name(name):
    if not isinstance(name, str):
        raise ValueError("Path must be a string")
    p = PurePosixPath(name)
    if not isinstance(name, str) or not name or p.is_absolute() or str(p) != name or any(part in {".", ".."} for part in p.parts):
        raise ValueError("Unsafe relative path")
    for part in p.parts:
        if any(ord(c) < 32 or c in '<>:"\\|?*' for c in part) or part.endswith((".", " ")) or part.split('.')[0].upper() in {"CON","PRN","AUX","NUL",*("COM"+str(i) for i in range(1,10)),*("LPT"+str(i) for i in range(1,10))}:
            raise ValueError("Path is not portable across supported platforms: " + name)
    return name


def validate_manifest(m):
    if not isinstance(m, dict) or set(m) != {"schema_version", "id", "created_at", "files", "directories"} or type(m["schema_version"]) is not int or m["schema_version"] != 1 or not isinstance(m["created_at"], str):
        raise ValueError("Unsupported snapshot manifest")
    if not isinstance(m["id"], str) or not re.fullmatch(r"[a-zA-Z0-9_-]{1,64}", m["id"]): raise ValueError("Invalid snapshot ID")
    if not isinstance(m["files"], list) or not isinstance(m["directories"], list) or len(m["files"]) + len(m["directories"]) > MAX_FILES:
        raise ValueError("Manifest entry limit exceeded")
    names, file_names, total = set(), set(), 0
    spellings = {}
    def record_spelling(path):
        for p in (PurePosixPath(path), *PurePosixPath(path).parents):
            text = str(p)
            key = text.casefold()
            if key in spellings and spellings[key] != text:
                raise ValueError("Case-colliding path component")
            spellings[key] = text
    for f in m["files"]:
        if not isinstance(f, dict) or set(f) != {"path", "size", "sha256"}: raise ValueError("Malformed file entry")
        safe_name(f["path"])
        record_spelling(f["path"])
        if type(f["size"]) is not int or not 0 <= f["size"] <= MAX_FILE or not isinstance(f["sha256"], str) or not re.fullmatch(r"[0-9a-f]{64}", f["sha256"]): raise ValueError("Invalid size or digest")
        key = f["path"].casefold()
        if key in names: raise ValueError("Duplicate/case-colliding path")
        names.add(key); file_names.add(key); total += f["size"]
    for directory in m["directories"]:
        safe_name(directory)
        record_spelling(directory)
        key = directory.casefold()
        if key in names: raise ValueError("Duplicate/case-colliding path")
        names.add(key)
    for name in names:
        if any(str(parent) in file_names for parent in PurePosixPath(name).parents): raise ValueError("File/directory path conflict")
    if total > MAX_TOTAL: raise ValueError("Snapshot total size limit exceeded")
    return m


def read_manifest(engine, store, identifier, work):
    if not re.fullmatch(r"[a-zA-Z0-9_-]{1,64}", identifier): raise ValueError("Invalid snapshot ID")
    path = work / "manifest.json"
    helper(engine, "db-get", store / "index.sqlite", identifier, path)
    if path.stat().st_size > 8 * 1024 * 1024: raise ValueError("Manifest too large")
    m = validate_manifest(d.read_json(path))
    if m["id"] != identifier: raise ValueError("Index/manifest ID mismatch")
    return m


def unpack(engine, store, entry, target):
    obj = store / "objects" / (entry["sha256"] + ".zst")
    regular(obj)
    if not obj.is_file() or obj.stat().st_size > 2 * MAX_FILE: raise ValueError("Missing/oversized object: " + entry["sha256"])
    helper(engine, "unpack", obj, target, entry["size"])
    if target.stat().st_size != entry["size"] or d.digest(target) != entry["sha256"]: raise ValueError("Restored content hash mismatch")


def save(engine, store, source, identifier=None):
    store = store_path(store)
    source = Path(source).absolute()
    for p in (source, *source.parents): regular(p)
    source = source.resolve()
    if not source.is_dir() or store.is_relative_to(source) or source.is_relative_to(store): raise ValueError("Source and store must be separate directories")
    identifier = identifier or datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ-") + uuid.uuid4().hex[:8]
    m = {"schema_version":1, "id":identifier, "created_at":datetime.datetime.now(datetime.timezone.utc).isoformat(), "files":[], "directories":[]}
    with lock(store), tempfile.TemporaryDirectory(prefix="snapshot-", dir=store) as temp:
        temp = Path(temp)
        total = 0
        for directory, dirs, files in os.walk(source, followlinks=False):
            dirs.sort(); files.sort()
            for name in dirs:
                p = Path(directory) / name; regular(p)
                m["directories"].append(safe_name(p.relative_to(source).as_posix()))
            for name in files:
                p = Path(directory) / name; regular(p)
                if not p.is_file(): raise ValueError("Only regular files are supported")
                before = p.stat()
                if before.st_size > MAX_FILE: raise ValueError("File exceeds 16 MiB: " + str(p))
                total += before.st_size
                if total > MAX_TOTAL: raise ValueError("Snapshot exceeds 256 MiB")
                # Bounded read protects against a file growing between stat and read.
                with p.open("rb") as stream: data = stream.read(MAX_FILE + 1)
                after = p.stat()
                if len(data) > MAX_FILE or (before.st_size,before.st_mtime_ns,before.st_ino) != (after.st_size,after.st_mtime_ns,after.st_ino) or len(data) != before.st_size:
                    raise ValueError("Source changed during snapshot; retry with a quiescent directory")
                entry = {"path":safe_name(p.relative_to(source).as_posix()), "size":len(data), "sha256":hashlib.sha256(data).hexdigest()}
                m["files"].append(entry)
                validate_manifest(m)
                obj = store / "objects" / (entry["sha256"] + ".zst")
                if obj.exists(): unpack(engine, store, entry, temp / "check.bin")
                else:
                    (temp / "input.bin").write_bytes(data)
                    helper(engine, "pack", temp / "input.bin", temp / "packed.zst", len(data))
                    # Verify the codec result before making it available in the store.
                    helper(engine, "unpack", temp / "packed.zst", temp / "check.bin", len(data))
                    if d.digest(temp / "check.bin") != entry["sha256"]: raise ValueError("Codec roundtrip mismatch")
                    os.link(temp / "packed.zst", obj)
                    (temp / "packed.zst").unlink()
            if len(m["files"]) + len(m["directories"]) > MAX_FILES: raise ValueError("Too many entries")
        validate_manifest(m)
        d.write_json(temp / "manifest.json", m)
        # SQLite insertion is atomic. An interrupted save can leave unreferenced
        # objects, but never advertises an incomplete snapshot as committed.
        helper(engine, "db-put", store / "index.sqlite", identifier, temp / "manifest.json")
    return {"status":"saved", "id":identifier, "files":len(m["files"]), "bytes":total}


def restore(engine, store, identifier, destination):
    store = store_path(store)
    dest = Path(destination).absolute()
    for p in (dest, *dest.parents): regular(p)
    dest = dest.resolve()
    if dest.exists() or dest.is_relative_to(store) or store.is_relative_to(dest): raise ValueError("Restore destination must be new and outside the store")
    dest.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix="restore-", dir=dest.parent))
    try:
        with lock(store), tempfile.TemporaryDirectory(prefix="read-", dir=store) as temp:
            m = read_manifest(engine, store, identifier, Path(temp))
            for directory in m["directories"]: (stage / directory).mkdir(parents=True, exist_ok=True)
            for entry in m["files"]:
                target = stage / entry["path"]; target.parent.mkdir(parents=True, exist_ok=True)
                unpack(engine, store, entry, target)
            if dest.exists(): raise ValueError("Restore destination appeared during operation")
            stage.rename(dest)
    finally:
        if stage.exists(): shutil.rmtree(stage)
    return {"status":"restored", "id":identifier, "destination":str(dest), "verified_files":len(m["files"])}


def inspect_snapshot(engine, store, identifier=None, other=None, output=None):
    store = store_path(store)
    with lock(store), tempfile.TemporaryDirectory(prefix="read-", dir=store) as temp:
        if identifier is None: return {"snapshots":json.loads(helper(engine,"db-list",store / "index.sqlite"))}
        a = read_manifest(engine, store, identifier, Path(temp))
        if other:
            b = read_manifest(engine, store, other, Path(temp))
            old = {f["path"]:f["sha256"] for f in a["files"]}; new = {f["path"]:f["sha256"] for f in b["files"]}
            return {"added":sorted(new.keys()-old.keys()), "removed":sorted(old.keys()-new.keys()), "changed":sorted(k for k in old.keys()&new.keys() if old[k]!=new[k]),
                    "directories_added":sorted(set(b["directories"])-set(a["directories"])), "directories_removed":sorted(set(a["directories"])-set(b["directories"]))}
        if output:
            with Path(output).open("x",encoding="utf-8") as stream: json.dump(a,stream,ensure_ascii=False,indent=2)
            return {"status":"exported", "output":str(output)}
        return a


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("--engine", required=True)
    sub=p.add_subparsers(dest="command",required=True)
    sub.add_parser("build")
    init=sub.add_parser("init");init.add_argument("store")
    create=sub.add_parser("save");create.add_argument("store");create.add_argument("source");create.add_argument("--id")
    ls=sub.add_parser("list");ls.add_argument("store")
    diff=sub.add_parser("diff");diff.add_argument("store");diff.add_argument("old");diff.add_argument("new")
    export=sub.add_parser("export");export.add_argument("store");export.add_argument("id");export.add_argument("output")
    r=sub.add_parser("restore");r.add_argument("store");r.add_argument("id");r.add_argument("destination")
    a=p.parse_args()
    try:
        if a.command=="build": result=init_engine(a.engine)
        elif a.command=="init": result=create_store(a.engine,a.store)
        elif a.command=="save": result=save(a.engine,a.store,a.source,a.id)
        elif a.command=="restore": result=restore(a.engine,a.store,a.id,a.destination)
        elif a.command=="diff": result=inspect_snapshot(a.engine,a.store,a.old,a.new)
        elif a.command=="export": result=inspect_snapshot(a.engine,a.store,a.id,output=a.output)
        else: result=inspect_snapshot(a.engine,a.store)
        print(json.dumps(result,ensure_ascii=False,indent=2));return 0
    except (ValueError,RuntimeError,OSError,KeyError,TypeError) as e:
        print(json.dumps({"status":"failed","error":str(e)},ensure_ascii=False),file=sys.stderr);return 1


if __name__=="__main__": sys.exit(main())
