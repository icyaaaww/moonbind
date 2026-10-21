# Changelog

## 0.2.0

- Add strict JSON project configuration with config-relative paths.
- Protect edited generated files using a saved content baseline; add non-writing `--check` for CI.
- Add structured generation and error reports, function allowlists and explicit function renaming.
- Compare old and new headers for signature, record layout, enum, typedef, constant and binding-support changes; report transitively affected functions.
- Configure additional native C sources without editing the generated manifest.
- Fix record attributes after a struct body being ignored.
- Add CLI workflow regression checks and fresh native SQLite/zlib integration projects to CI.
- Include a Chinese Mooncakes/GitHub README and the 0.2 usage guide.

Compatibility: the existing CLI usage still works, but generation now refuses to overwrite edited/untracked conflicting files. Public `Options` has new fields; consumers constructing it directly must supply them, or use `parse_args` / `prepare_args`. `generate` and `package_manifest` gain optional named parameters. Regenerate 0.1 packages into a new directory when migrating manual changes.

## 0.1.0

- Initial Mooncakes release: C preprocessing, declaration parsing, layout analysis and MoonBit native FFI code generation.
