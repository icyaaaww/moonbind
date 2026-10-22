///|
fn diagnostics_json(m : @ast.CModule) -> Json {
  let items : Array[Json] = m.diagnostics.map(d => {
    "code": d.code,
    "file": d.file,
    "line": d.line,
    "column": d.column,
    "token": d.token,
    "message": d.message,
  })
  items.to_json()
}

///|
fn diagnostic_text(m : @ast.CModule) -> String {
  m.diagnostics
  .map(d => {
    "\{d.file}:\{d.line}:\{d.column} [\{d.code}] \{d.message} (\{d.token})"
  })
  .join("\n")
}

///|
/// Policy evaluates the JSON report, so CLI and external consumers share it.
/// Incomplete parsing blocks every enabled gate, even if no changes were found.
pub fn review_blocked(report : Json, rule : String) -> Bool {
  if rule == "none" {
    return false
  }
  if report is { "analysis_complete": False, .. } {
    return true
  }
  match report {
    { "changes": Array(changes), .. } =>
      changes.any(change => {
        match change {
          { "change": String(kind), .. } =>
            rule == "any" ||
            kind == "removed" ||
            (rule == "changed" && kind == "changed")
          _ => false
        }
      })
    _ => false
  }
}

///|
fn escape_html(text : String) -> String {
  let out = StringBuilder()
  for c in text {
    out.write_string(
      match c {
        '&' => "&amp;"
        '<' => "&lt;"
        '>' => "&gt;"
        '"' => "&quot;"
        '\'' => "&#39;"
        _ => c.to_string()
      },
    )
  }
  out.to_string()
}

///|
/// Standalone, script-free and escaped: headers may contain untrusted text.
pub fn review_html(report : Json) -> String {
  let out = StringBuilder()
  out.write_string(
    "<!doctype html><html lang=\"zh-CN\"><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'unsafe-inline'\"><title>MoonBind 升级审核</title><style>body{font:16px/1.65 system-ui;margin:40px auto;padding:0 24px;max-width:1080px;color:#182333;background:#f6f8fb}h1{font-size:32px}details{background:white;border:1px solid #dce2ea;border-radius:8px;padding:16px;margin:12px 0}summary{cursor:pointer;font-weight:600}pre{white-space:pre-wrap;overflow-wrap:anywhere;background:#eef2f7;padding:16px;border-radius:6px}small{color:#526174}</style><h1>MoonBind 升级审核</h1><p>声明与布局变化的复查提示，不是二进制兼容性证明。</p>",
  )
  if report is { "policy": { "blocked": True, .. }, .. } {
    out.write_string("<h2>审核结果：阻止通过</h2>")
  } else {
    out.write_string("<h2>审核结果：当前规则未阻止</h2>")
  }
  match report {
    { "changes": Array(changes), "affected_functions": affected, .. } => {
      out.write_string(
        "<p>\{changes.length()} 项声明变化。点击展开前后对比。</p><h2>受影响函数</h2><pre>" +
        escape_html(affected.stringify(indent=2)) +
        "</pre>",
      )
      for change in changes {
        match change {
          {
            "symbol": String(name),
            "change": String(kind),
            "before": before,
            "after": after,
            ..
          } =>
            out.write_string(
              "<details><summary>" +
              escape_html(name + " · " + kind) +
              "</summary><h3>旧版本</h3><pre>" +
              escape_html(before.stringify(indent=2)) +
              "</pre><h3>新版本</h3><pre>" +
              escape_html(after.stringify(indent=2)) +
              "</pre></details>",
            )
          _ => ()
        }
      }
    }
    _ => ()
  }
  out.write_string(
    "<h2>建议验证</h2><p>重新生成绑定，复查调用方与资源释放约定，使用新版 C 库编译、链接并运行测试。</p><details><summary>分析上下文、诊断与完整 JSON</summary><pre>" +
    escape_html(report.stringify(indent=2)) +
    "</pre></details></html>",
  )
  out.to_string()
}

///|
fn decorate_comparison(
  report : Json,
  old : @ast.CModule,
  new : @ast.CModule,
  options : Options,
) -> Json {
  match with_context(report, options) {
    Object(fields) => {
      let fields = fields.copy()
      fields["diagnostics"] = {
        "old": diagnostics_json(old),
        "new": diagnostics_json(new),
      }
      fields["analysis_complete"] = (old.diagnostics.is_empty() &&
      new.diagnostics.is_empty()).to_json()
      let partial = Json::object(fields)
      fields["policy"] = {
        "rule": options.fail_on,
        "blocked": review_blocked(partial, options.fail_on),
      }
      Json::object(fields)
    }
    _ => report
  }
}
