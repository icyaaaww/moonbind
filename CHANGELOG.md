# Changelog

## 0.3.0

- Add located diagnostics for known unsupported syntax and malformed declarations. Refuse generation/layout verification for diagnosed modules; strict mode also rejects skipped selected functions.
- Generate optional C adapters for simple records passed/returned by value and static function definitions, with explicit allocation/access/free helpers and compile-time layout assertions.
- Add comparison policies (`none`, `removed`, `changed`, `any`), exit code 3, and standalone escaped HTML review reports. Static declarations participate in comparisons; bodies are not compared.
- Preserve 0.2 managed-output migration and add `bridge.c` to the managed set.
- Add native bridge calls, C ASan/UBSan cycles, and deliberate layout-mismatch validation to CI; keep SQLite/zlib and clang layout regressions.
- Public API: add Diagnostic, CModule diagnostics/static_definitions, Bridge/generate_bridge, review functions and four Options fields. Fully specified struct literals require migration.
- Document bounded type support, absolute header paths, caller-owned lifetimes and the distinction between emitted checks and executed validation.

## 0.2.0

- Add strict JSON project configuration with config-relative paths.
- Protect edited generated files using a saved content baseline; add non-writing `--check` for CI.
- Add structured generation and error reports, function allowlists and explicit function renaming.
- Compare old and new headers for signature, record layout, enum, typedef, constant and binding-support changes; report transitively affected functions.
- Configure additional native C sources without editing the generated manifest.
- Fix record attributes after a struct body being ignored.
- Avoid redeclaring builtin MoonBit types for C aliases such as zlib's `Byte`.
- Use native target expression syntax in generated and example manifests.
- Add CLI workflow regression checks and fresh native SQLite/zlib integration projects to CI.
- Include a Chinese Mooncakes/GitHub README and the 0.2 usage guide.

Compatibility: the existing CLI usage still works, but generation now refuses to overwrite edited/untracked conflicting files. Public `Options` has new fields; consumers constructing it directly must supply them, or use `parse_args` / `prepare_args`. `generate` and `package_manifest` gain optional named parameters. Regenerate 0.1 packages into a new directory when migrating manual changes.

## 0.1.0

- Initial Mooncakes release: C preprocessing, declaration parsing, layout analysis and MoonBit native FFI code generation.
