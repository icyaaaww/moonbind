"""Versioned configuration, reviewed edits and installation for MoonBind 1.x."""
import copy
import datetime
import html
import json
from pathlib import Path
import shutil
import sys
import tempfile


def candidate_check(d, root, config, settings):
    (root / "_build").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="config-check-", dir=root / "_build") as temp:
        temp = Path(temp)
        candidate = copy.deepcopy(settings)
        candidate["header"] = str((config.parent / settings["header"]).resolve())
        candidate["include_paths"] = [str((config.parent / p).resolve()) for p in settings.get("include_paths", [])]
        candidate["out"] = "bindings"
        (temp / "moon.mod").write_text('name = "moonbind_review/candidate"\n', encoding="utf-8")
        d.write_json(temp / "candidate.json", candidate)
        d.require(d.run(["moon", "run", "cmd/main", "--target", "wasm-gc", "--", "--config", temp / "candidate.json", "--json"]))


def save_config(d, root, config, original, desired):
    if config.read_bytes() != original:
        raise ValueError("Configuration changed during review; nothing written")
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    backup = root / "reports" / ("config-backup-" + stamp + ".json")
    backup.parent.mkdir(exist_ok=True)
    with backup.open("xb") as stream:
        stream.write(original)
    d.write_json(config, desired)
    return str(backup)


def migrate(d, root, apply=False):
    root, _, config, settings = d.load_project(root)
    original = config.read_bytes()
    desired = {"schema_version": 1, **settings}
    changes = [] if "schema_version" in settings else [{"op": "add", "path": "/schema_version", "value": 1}]
    result = {"status": "unchanged" if not changes else "preview", "config": str(config), "changes": changes,
              "note": "Versionless configurations retain schema-1 behavior. Generated bindings are not overwritten."}
    if apply and changes:
        candidate_check(d, root, config, desired)
        result.update(status="applied", backup=save_config(d, root, config, original, desired))
    return result


def apply_upgrade(d, root, apply=False):
    root, _, config, settings = d.load_project(root)
    report = d.read_json(root / "reports/upgrade.json")
    if report.get("snapshot") != d.inventory(root):
        raise ValueError("Upgrade report is stale; rerun upgrade --against before reviewing edits")
    edits = [e for action in report.get("actions", []) for e in action.get("suggested_config_edits", [])]
    desired = copy.deepcopy(settings)
    allowed = {"buffers", "output_buffers", "out_params", "null_params", "callbacks"}
    seen = set()
    for edit in edits:
        parts = edit.get("path", "").split("/")
        if len(parts) != 3 or parts[1] not in allowed or edit.get("op") != "replace":
            raise ValueError("Unsupported upgrade edit; review configuration manually")
        kind, function = parts[1], parts[2].replace("~1", "/").replace("~0", "~")
        if (kind, function) in seen or not isinstance(edit.get("value"), str):
            raise ValueError("Duplicate or malformed upgrade edit")
        seen.add((kind, function))
        if desired.get(kind, {}).get(function) != edit.get("expected_old_value"):
            raise ValueError("Upgrade edit old-value precondition failed")
        desired[kind][function] = edit["value"]
    result = {"status": "preview" if edits else "unchanged", "config": str(config), "edits": edits,
              "note": "Suggestions require semantic review; applying changes config only. Run generate and validate afterwards."}
    if apply and edits:
        original = config.read_bytes()
        candidate_check(d, root, config, desired)
        if report.get("snapshot") != d.inventory(root):
            raise ValueError("Project changed during candidate validation")
        result.update(status="applied", backup=save_config(d, root, config, original, desired))
    return result


def render_upgrade(report):
    esc = lambda x: html.escape(str(x))
    rows = []
    labels = {"must_change": "必须修改", "human_review": "人工复核", "no_detected_impact": "未检测到影响"}
    for a in report["actions"]:
        locations = "\n".join(c["file"] + "#" + c["json_pointer"] for c in a.get("configuration", []))
        generated = "\n".join(g["file"] + ":" + str(g["line"]) for g in a.get("generated_declarations", []))
        checks = "\n".join(t["name"] + " (" + t["package"] + ")" for t in a.get("runtime_checks", []))
        suggestions = json.dumps(a.get("suggested_config_edits", []), ensure_ascii=False, indent=2)
        cells = [labels[a["classification"]], a.get("function", "配置检查"), locations, generated, checks, a["action"], suggestions]
        rows.append("<tr>" + "".join("<td><pre>" + esc(c) + "</pre></td>" for c in cells) + "</tr>")
    return ('<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src \'none\'; style-src \'unsafe-inline\'">'
            '<title>MoonBind 升级审查</title><style>body{font:16px system-ui;margin:32px;color:#172c3c}table{border-collapse:collapse;width:100%}td,th{border:1px solid #bbc6ce;padding:10px;text-align:left;vertical-align:top}pre{white-space:pre-wrap;overflow-wrap:anywhere;font:inherit}details{margin-top:24px}</style>'
            '<h1>MoonBind 升级审查</h1><p>建议尚未应用。先检查生命周期与库语义，再执行 upgrade-apply 预览；加 --apply 才会备份并修改配置。生成文件保持原状。</p>'
            '<table><tr><th>分类</th><th>函数</th><th>配置位置</th><th>现有绑定</th><th>运行检查</th><th>处理建议</th><th>待审修改</th></tr>' + "".join(rows)
            + '</table><details><summary>完整证据与快照</summary><pre>' + esc(json.dumps(report, ensure_ascii=False, indent=2)) + '</pre></details></html>')


def install_copy(d, prefix):
    prefix = Path(prefix).resolve()
    destination = prefix / ("moonbind-" + d.VERSION)
    if destination.exists():
        raise ValueError("Version directory already exists; choose a new prefix. Existing installations are never replaced")
    prefix.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix="install-", dir=prefix))
    folders = {"ast", "source", "lex", "cp", "cparse", "layout", "codegen", "cli", "cmd", "testdata", "templates", "recipes", "examples", "scripts", "docs", "schemas", "compat", "tools"}
    try:
        for p in d.ROOT.iterdir():
            if p.is_dir() and p.name in folders:
                shutil.copytree(p, stage / p.name, ignore=shutil.ignore_patterns(*d.IGNORE, ".git"))
            elif p.is_file() and p.name != "installation.json" and (p.suffix in {".py", ".mod", ".md", ".json"} or p.name in {"LICENSE", ".gitattributes"}):
                shutil.copy2(p, stage / p.name)
        d.write_json(stage / "installation.json", {"version": d.VERSION, "files": d.inventory(stage)})
        stage.rename(destination)
    finally:
        if stage.exists():
            shutil.rmtree(stage)
    # Invoke the copied driver so the launcher points to the versioned copy.
    result = d.require(d.run([sys.executable, destination / "moonbind.py", "install", "--bin", prefix / "bin"]))
    return {"status": "installed", "version": d.VERSION, "directory": str(destination), "launcher": json.loads(result["stdout"])}
