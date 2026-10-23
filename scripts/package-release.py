#!/usr/bin/env python3
"""Package committed source with fixed ZIP metadata and per-file checksums."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import moonbind as d

def git(*args):
    return subprocess.check_output(["git", *args], cwd=ROOT)

def main():
    if git("status", "--porcelain").strip():
        raise SystemExit("Commit reviewed changes before packaging")
    commit = git("rev-parse", "HEAD").decode().strip()
    destination = ROOT / "_build" / ("release-v" + d.VERSION)
    destination.mkdir(parents=True, exist_ok=True)
    archive = destination / ("moonbind-" + d.VERSION + "-source.zip")
    entries = {}
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for name in sorted(git("ls-tree", "-r", "--name-only", "HEAD").decode().splitlines()):
            if any(part in {".git", "_build", "credentials.json", ".env"} for part in Path(name).parts):
                raise ValueError("Unexpected release path: " + name)
            content = git("show", "HEAD:" + name)
            info = zipfile.ZipInfo("moonbind-" + d.VERSION + "/" + name, date_time=(1980,1,1,0,0,0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            z.writestr(info, content)
            entries[name] = hashlib.sha256(content).hexdigest()
    d.write_json(destination / "release-manifest.json", {"version":d.VERSION, "commit":commit, "archive":archive.name, "sha256":d.digest(archive), "files":entries, "toolchain":d.read_json(ROOT / "toolchain.json"), "scope":"Committed source; rebuild requires pinned compiler, platform C toolchain and dependencies. Native binaries are not claimed bit-reproducible."})
    (destination / "SHA256SUMS").write_text("".join(d.digest(p)+"  "+p.name+"\n" for p in [archive,destination / "release-manifest.json"]), encoding="utf-8")
    print(destination)

if __name__ == "__main__": main()
