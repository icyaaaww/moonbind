# MoonBind

**用 MoonBit 解析 C 头文件，生成可检查、可纳入版本管理的 MoonBit FFI 绑定。**

[![CI](https://github.com/icyaaaww/moonbind/actions/workflows/ci.yml/badge.svg)](https://github.com/icyaaaww/moonbind/actions/workflows/ci.yml)
[![Mooncakes](https://img.shields.io/badge/Mooncakes-1.0.0-blue)](https://mooncakes.io/docs/icyaaaww/moonbind)
[![License](https://img.shields.io/badge/license-Apache--2.0-green)](LICENSE)

[English / 技术设计详解](README.mbt.md) · [Mooncakes 包文档](https://mooncakes.io/docs/icyaaaww/moonbind) · [示例代码](examples) · [反馈问题](https://github.com/icyaaaww/moonbind/issues)

手写 C 库绑定时，难点不仅是翻译函数名称：还要处理宏、包含路径、复杂声明、结构体对齐、指针和字符串。头文件更新后，这些工作还需要再检查一遍。

MoonBind 把这条流程组织成可复用的 MoonBit 包：读取头文件、预处理、解析声明、计算目标 ABI 的内存布局，再生成绑定。对当前无法正确表达的声明，生成器跳过它们，并通过 `--report` 解释原因。

当前版本为 **1.0.0**，支持建立独立消费项目、生成绑定和记录执行验证。接入真实 C 库后，仍需检查生成结果、配置链接，并验证内存所有权与运行行为。

## 1.0：稳定交付与三库实用应用

- **版本化配置与升级保护**：schema 1、迁移预览、候选验证、原文备份、过期报告拦截。
- **独立安装**：`install --prefix` 复制版本化源码，启动器不再依赖原始仓库；doctor 提供路径与修复建议。
- **多库组合**：`c_namespace` 隔离辅助 C 符号，SQLite、Zstandard、cJSON 可以一起链接运行。
- **目录快照参考应用**：保存、去重、历史差异、清单导出、摘要校验恢复；损坏数据拒绝，已有目标不覆盖。
- **发布基线**：登记公共 API，固定 MoonBit 工具链，三平台原生验收，生成源码包与 SHA-256 清单。

```sh
moon update
python tools/snapshot.py --engine ../snapshot-engine build
python tools/snapshot.py --engine ../snapshot-engine init ../snapshot-store
python tools/snapshot.py --engine ../snapshot-engine save ../snapshot-store ../my-documents --id first
python tools/snapshot.py --engine ../snapshot-engine restore ../snapshot-store first ../restored-documents
```

快照应用只支持普通文件/目录：单文件 16 MiB，总量 256 MiB，10,000 项；不保留权限/时间戳。Python 管理路径和摘要，三库操作通过生成的 MoonBit 绑定执行；SQLite 保留一层明确的手写适配器。详见 [1.0 安装、迁移、应用与支持边界](docs/v1.0.md)。[独立开发者试用](docs/user-trial-v1.md)仍待执行。

## 0.9：输出缓冲区、资源恢复与可复用配方

- **真实 Zstandard 压缩/解压**：生成输入/输出 Bytes 包装器，分配上限、错误判断、返回长度检查；提供二进制文件往返示例。
- **可恢复资源管理**：T** 工厂保留错误句柄，区分关闭失败后仍持有与已释放两种策略；检测重复关闭、关闭后使用和借用期间关闭。
- **三份库接入配方**：Zstandard 1.5.7、SQLite 3.45.0、cJSON 1.7.19；记录来源、许可证、文件摘要、宏与平台选项，校验 vendor 文件。
- **可操作的升级报告**：分类必须修改、人工复核和未检测到影响；定位配置、绑定声明及运行检查，参数改名给出待审配置建议。
- **延续 0.8 能力**：同步回调、C 入口记录、生成文件保护与 Windows LLP64 支持。

```sh
moon update
python moonbind.py init ../compression --recipe zstd
python moonbind.py validate ../compression
python moonbind.py report-check ../compression
cd ../compression
moon run file --target native -- compress input.bin output.zst
moon run file --target native -- decompress output.zst restored.bin
```

打开 `reports/validation.html` 查看执行证据。需要 Python 3.10+、MoonBit 与 C11 编译环境；Windows 需要 MSVC Build Tools 与 Windows SDK。文件示例将输入整体读入内存，适合小文件；输出分配上限 64 MiB。C 库仍须遵守容量和生命周期契约，包装器不构成完整内存安全保证。

详见 [0.9 使用指南与支持边界](docs/v0.9.md)、[0.8 回调与升级](docs/v0.8.md)、[更新记录](CHANGELOG.md)。[独立开发者试用](docs/user-trial-v09.md)尚待执行，自动化测试不计作真实用户反馈。

## 能解决什么问题

| 场景 | 用法 | 结果 |
| --- | --- | --- |
| 为 C 库建立 MoonBit 接口 | 输入头文件，使用 `--out` | 生成绑定、字符串辅助代码、C 辅助代码和包配置 |
| 检查结构体字段偏移 | 使用 `--verify` | 查看大小、对齐和字段布局表 |
| 了解哪些接口尚未绑定 | 使用 `--report` | 查看跳过的声明及原因 |
| 在自己的工具中处理 C 声明 | 从 Mooncakes 引入各阶段包 | 复用解析器、类型模型和布局计算接口 |

仓库提供 [SQLite 示例](examples/sqlite3-demo/main.mbt) 和 [小型 greet 示例](examples/greet-demo/main.mbt)，涵盖不透明句柄、字符串、输出参数和状态码等接口形式。

## 快速开始：运行生成器

需要 Git 和 MoonBit 工具链；本项目使用 `moon 0.1.20261016` 验证。运行原生示例还需要适配当前平台的 C 编译环境。

```sh
git clone https://github.com/icyaaaww/moonbind.git
cd moonbind
moon update
moon run cmd/main --target wasm-gc -- --help
```

先用仓库自带的头文件查看布局，无需准备外部库：

```sh
moon run cmd/main --target wasm-gc -- testdata/layout/packed.h --verify --target aarch64
```

生成小型示例的绑定到独立目录：

```sh
moon run cmd/main --target wasm-gc -- examples/greet/greet.h --out _build/generated-greet --report
```

输出目录包含：

```text
_build/generated-greet/
├── bindings.mbt   # 函数、类型和常量绑定
├── strings.mbt    # C 字符串复制辅助接口
├── stub.c         # C 侧辅助函数
├── moonbind-config.h # 与模板库编译单元同步的配置宏
├── moon.pkg       # 生成包的依赖和原生目标配置
├── moonbind-report.json # 结构化生成报告
└── .moonbind-state.json # 检测手工修改的生成基线
```

生成包不包含被绑定库的实现。接入项目时，可通过配置中的 `native_sources` 添加实际 C 源文件，或在消费方按所用工具链配置库链接。仓库中的 `examples/greet/moon.pkg` 演示了如何加入 `greet.c`。

> 命令中 `--` 前的 `--target wasm-gc` 选择生成器的运行后端；`--` 后的 `--target aarch64` 等参数选择所分析 C 类型的 ABI。生成的 `extern "C"` 绑定用于 MoonBit native 后端。选择 `wasm32` 布局不代表生成包可以直接在浏览器运行。

## 作为库使用

在已有 MoonBit 模块中安装：

```sh
moon add icyaaaww/moonbind@0.9.0
```

按需在调用方的 `moon.pkg` 中导入子包；模块根包不提供生成器 API：

```text
import {
  "icyaaaww/moonbind/source",
  "icyaaaww/moonbind/cparse",
  "icyaaaww/moonbind/layout",
}
```

例如，直接解析内存中的头文件并验证结构体布局。把下面代码保存到调用方包中的 `layout_wbtest.mbt`，执行 `moon test --target wasm-gc`：

```moonbit
///|
test "C record layout" {
  let cache = @source.SourceCache::in_memory()
  cache.insert("pair.h", "struct Pair { char tag; int value; };")
  let declarations = @cparse.load_header_with_cache(
    "pair.h",
    @cparse.LoadOptions::new(),
    cache,
  ) catch {
    _ => abort("failed to parse pair.h")
  }
  let record = @layout.layout_record(
    @layout.Target::sysv64(),
    declarations,
    "Pair",
  ).unwrap()
  assert_eq(record.size, 8)
  assert_eq(record.align, 4)
  assert_eq(record.offset_of("value"), Some(4))
}
```

`moon add` 安装的是库依赖，不会安装全局 `moonbind` 命令。使用 CLI 时，请按上面的源码运行方式操作。

## 命令行参数

调用格式：`moon run cmd/main --target wasm-gc -- <header.h> [options]`。

| 参数 | 作用 |
| --- | --- |
| `--out <dir>` | 写入完整绑定包；未指定时将生成代码输出到标准输出 |
| `--target <name>` | 选择布局：`x86_64`（默认）、`aarch64`、`wasm32` |
| `--include <dir>` | 添加头文件搜索目录，可重复指定 |
| `--define <M=V>` | 预定义宏，可重复指定 |
| `--bridge --strict` | 生成简单结构体/静态函数 C 适配层，拒绝跳过所选函数 |
| `--compare <old.h> --fail-on changed` | 比较旧头文件，修改/删除或解析诊断时返回退出码 3 |
| `--html` | 将比较结果输出为可离线打开的 HTML |
| `--report` | 报告跳过的声明及原因 |
| `--verify` | 输出布局表，不生成绑定；该选项本身不会调用 clang |
| `--version` / `--help` | 显示版本 / 帮助 |

## 示例与验证

运行仓库已有的原生示例：

```sh
moon run examples/greet-demo --target native
moon run examples/sqlite3-demo --target native
```

SQLite 示例创建表、使用预处理语句写入记录并查询输出；greet 示例展示句柄的创建和关闭、字符串传入与返回，以及空指针处理。

开发检查：

```sh
moon check --target wasm-gc
moon build --target wasm-gc
moon test --target wasm-gc
moon fmt --check
```

0.8 包含 **117 项 MoonBit 测试**，另有独立 CLI 与原生消费项目验证。新增 CI 配置覆盖 Linux/macOS/Windows；以当前提交实际运行结果为准。真实用户试用仍待执行，任务见 [试用说明](docs/user-trial.md)。

具备 Bash、clang、awk、sort 和 diff 的环境还可以运行：

```sh
bash scripts/verify-layout.sh
```

该脚本针对两组布局头文件，分别比较 SysV x86-64、AArch64 和 wasm32 的生成结果与 clang 输出。CI 会安装 clang 后运行这项检查；本地缺少 clang 时脚本会跳过，因此跳过不代表完成了对照验证。这些用例也不等同于所有 C 声明或所有平台都已验证。

## 当前边界

- 解析范围侧重 C11 声明及项目支持的预处理、布局特性，不是完整的 C/C++ 编译器；C++ 接口建议先提供 C 包装层。
- 普通绑定模式跳过变参及按值结构体函数；`--bridge` 可适配受限的嵌套结构体、固定数组、枚举及窄整数，具体范围见 [0.5 指南](docs/v0.5.md)。使用报告检查实际缺失的接口。
- 某些结构体不能生成可直接映射的 MoonBit 表示；不透明句柄与可直接访问字段的结构体是不同用法。
- `x86_64` 表示 SysV 布局，并不代表 Windows x64 ABI。布局目标应与实际被绑定库一致。
- 生成器不能从头文件完整推断资源释放时机、字符串生命周期和线程安全约束，调用代码仍需遵循 C 库文档。
- 当前工具链可能报告已有的弃用警告；测试通过并不表示没有编译警告。

## 项目结构

```text
source → lex → cp → cparse → layout → codegen
                  ast：各阶段共享的声明与类型模型
                  cli / cmd/main：命令行入口
```

| 目录 | 职责 |
| --- | --- |
| `source` / `lex` | 头文件读取、内置头文件和词法分析 |
| `cp` / `cparse` | 预处理、宏展开和 C 声明解析 |
| `ast` / `layout` | 类型模型及 ABI 布局计算 |
| `codegen` | 绑定代码和辅助文件生成 |
| `cli` / `cmd/main` | 参数解析与执行入口 |
| `examples` / `testdata` | 可读示例、真实头文件与回归用例 |
| `scripts` | clang 布局对照验证 |

## 后续方向与反馈

下一步希望扩大原生平台与真实库的回归覆盖，补充解析诊断，并探索把函数式宏转换为 MoonBit 函数。按值结构体调用需要结合 FFI 能力进一步设计，目前不属于已支持功能。

欢迎通过 [Issues](https://github.com/icyaaaww/moonbind/issues) 提交最小头文件、MoonBit 版本、完整命令、目标 ABI，以及预期和实际输出。修改代码前可参考 [开发约定](AGENTS.md) 和 [英文设计说明](README.mbt.md)。

## 许可证

项目采用 [Apache License 2.0](LICENSE)。仓库内的 SQLite 示例源文件使用其自身声明的许可说明。
