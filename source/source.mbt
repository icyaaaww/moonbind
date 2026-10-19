//! Source acquisition and `#include` resolution.
//!
//! A binder reads headers from three places: the file system, an in-memory
//! overlay (used by tests and by `--define` style virtual headers), and a
//! small set of built-in replacements for the C standard headers. The third
//! exists because moonbind must work on machines with no C toolchain
//! installed, and because the real `<stdio.h>` drags in hundreds of
//! declarations and compiler intrinsics that no binding ever needs.

///|
/// | A resolved header: where it came from and what it contained.
pub(all) struct SourceText {
  pub path : String
  pub text : String
} derive(Debug)

///|
/// | Errors raised while acquiring a header.
pub(all) suberror SourceError {
  NotFound(String)
} derive(Debug)

///|
/// | Which spelling the `#include` used. Quoted includes search the
/// directory of the including file first; angled ones do not.
pub(all) enum IncludeKind {
  Quoted
  Angled
} derive(Debug, Eq)

///|
/// | Caches header text so that a header included from twenty places is read
/// once. The map is also the overlay for virtual headers.
pub(all) struct SourceCache {
  files : Map[String, String]
  /// When false, a miss in `files` raises instead of touching the disk.
  /// Tests use this to keep runs hermetic.
  allow_disk : Bool
}

///|
/// | An empty cache that does read from disk.
pub fn SourceCache::new() -> SourceCache {
  { files: Map([]), allow_disk: true, }
}

///|
/// | An empty cache that never reads from disk.
pub fn SourceCache::in_memory() -> SourceCache {
  { files: Map([]), allow_disk: false, }
}

///|
/// | Register a virtual header under `path`.
pub fn SourceCache::insert(
  self : SourceCache,
  path : String,
  text : String,
) -> Unit {
  self.files[normalize_path(path)] = text
}

///|
/// | Whether the cache already holds `path`.
pub fn SourceCache::has(self : SourceCache, path : String) -> Bool {
  self.files.contains(normalize_path(path))
}

///|
/// | Fetch a header, reading it from disk on first use and memoizing it.
pub fn SourceCache::load(
  self : SourceCache,
  path : String,
) -> SourceText raise SourceError {
  let key = normalize_path(path)
  match self.files.get(key) {
    Some(text) => SourceText::{ path: key, text, }
    None => {
      if !self.allow_disk {
        raise NotFound(key)
      }
      let text = @fs.read_file_to_string(key) catch { _ => raise NotFound(key) }
      self.files[key] = text
      SourceText::{ path: key, text, }
    }
  }
}

///|
/// | Normalize a path for use as a cache key: forward slashes only, no
/// repeated separators, and `..` components folded against their parent.
/// Windows drive letters are kept as-is so `C:/x` stays distinct from `/x`.
pub fn normalize_path(path : String) -> String {
  let slashed = path.replace_all(old="\\", new="/")
  let parts = []
  for seg in slashed.split("/") {
    let s = seg.to_owned()
    if s == "" || s == "." {
      continue
    }
    if s == ".." && parts.length() > 0 && parts[parts.length() - 1] != ".." {
      let _ = parts.pop()
      continue
    }
    parts.push(s)
  }
  let leading = slashed.length() > 0 && slashed[0] == '/'
  let body = parts.join("/")
  if leading {
    "/" + body
  } else {
    body
  }
}

///|
/// | The directory portion of a path, without a trailing slash. Returns `""`
/// for a bare file name.
pub fn dir_name(path : String) -> String {
  let p = normalize_path(path)
  match p.rev_find("/") {
    Some(idx) => if idx == 0 { "/" } else { p.substring(start=0, end=idx) }
    None => ""
  }
}

///|
/// | Join a directory and a relative path.
pub fn join_path(dir : String, name : String) -> String {
  if dir == "" {
    normalize_path(name)
  } else {
    normalize_path("\{dir}/\{name}")
  }
}

///|
/// | Resolve an `#include` against the including file and a search path.
/// The conventional order is: for `"...".` the includer's directory, then
/// every `-I` directory, then the built-ins; for `<...>` the `-I`
/// directories, then the built-ins. Returns a path key that `SourceCache`
/// understands; built-in headers resolve to `@builtin/<name>` which
/// `SourceCache::load` serves from the embedded table.
pub fn resolve_include(
  kind : IncludeKind,
  name : String,
  including_file : String,
  search : Array[String],
) -> String? {
  if kind == Quoted {
    let here = join_path(dir_name(including_file), name)
    if exists(here) {
      return Some(here)
    }
  }
  for dir in search {
    let candidate = join_path(dir, name)
    if exists(candidate) {
      return Some(candidate)
    }
  }
  let key = builtin_key(name)
  match builtin_header(name) {
    Some(_) => Some(key)
    None => None
  }
}

///|
/// | The cache key under which a built-in header is stored.
pub fn builtin_key(name : String) -> String {
  "@builtin/" + normalize_path(name)
}

///|
/// | The disk check used by resolution. Kept separate so that a future
/// variant can resolve against a manifest instead.
fn exists(path : String) -> Bool {
  @fs.path_exists(path) catch {
    _ => false
  }
}
