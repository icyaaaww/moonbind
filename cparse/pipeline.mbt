//! One call from a header name to a parsed module.
//!
//! This is the seam the CLI and the tests share, so that a test can exercise
//! exactly the pipeline a user gets: read the file (or a builtin), preprocess
//! it, parse it.

///|
/// | Options for loading a header.
pub(all) struct LoadOptions {
  /// Directory of the header; `#include "..."` is searched here first.
  pub include_paths : Array[String]
  /// Extra macros, as `NAME=VALUE`.
  pub defines : Array[String]
  pub platform : @cp.Platform
}

///|
/// | The defaults: no extra paths, no extra macros, the host data model.
pub fn LoadOptions::new() -> LoadOptions {
  { include_paths: [], defines: [], platform: @cp.Platform::default(), }
}

///|
/// | Preprocess and parse a header. `path` may be a path on disk or the name
/// of an embedded standard header such as `"stdint.h"`.
pub fn load_header(
  path : String,
  options : LoadOptions,
) -> @ast.CModule raise @cp.PreprocessError {
  load_header_with_cache(path, options, @source.SourceCache::new())
}

///|
/// | As `load_header`, reusing an existing source cache so that a run over
/// many headers reads each system header once.
pub fn load_header_with_cache(
  path : String,
  options : LoadOptions,
  cache : @source.SourceCache,
) -> @ast.CModule raise @cp.PreprocessError {
  let base = @cp.PreprocessOptions::new()
  let pp_opts = {
    ..base,
    include_paths: options.include_paths,
    defines: options.defines,
    platform: options.platform,
  }
  let pp = @cp.preprocess(path, cache, pp_opts)
  let module = parse_module_with_defines(
    pp.tokens,
    pp.defines,
    options.platform,
  )
  module.sources.clear()
  module.sources.append(pp.files)
  module
}
