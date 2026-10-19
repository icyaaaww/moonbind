//! Parser tests.
//!
//! Each case is a header snippet and an assertion about what the parser made
//! of it. Types are printed in a compact C-like notation (`i32*`, `i32[3]`,
//! `f64(i32,...)`) so a failing case reads as the declaration that produced
//! it.

///|
fn parse_snippet(src : String) -> @ast.CModule {
  let cache = @source.SourceCache::in_memory()
  let opts = @cp.PreprocessOptions::new()
  let pp = @cp.preprocess_text(src, "t.h", cache, opts) catch {
    _ => abort("preprocess failed for snippet")
  }
  parse_module_with_defines(pp.tokens, pp.defines, opts.platform)
}

///|
fn show_ty(t : @ast.CType) -> String {
  match t {
    Void => "void"
    Int(@ast.CI8) => "i8"
    Int(@ast.CU8) => "u8"
    Int(@ast.CI16) => "i16"
    Int(@ast.CU16) => "u16"
    Int(@ast.CI32) => "i32"
    Int(@ast.CU32) => "u32"
    Int(@ast.CI64) => "i64"
    Int(@ast.CU64) => "u64"
    Float(@ast.F32) => "f32"
    Float(@ast.F64) => "f64"
    Pointer(inner) => show_ty(inner) + "*"
    Array(inner, n) => show_ty(inner) + "[\{n}]"
    Record(tag) => "struct " + tag
    EnumType(tag) => "enum " + tag
    Named(name) => name
    Fn(sig) => {
      let ps = sig.params.map(show_ty).join(", ")
      let dots = if sig.variadic { ",..." } else { "" }
      show_ty(sig.ret) + "(\{ps}\{dots})"
    }
  }
}

///|
fn field_ty(m : @ast.CModule, tag : String, field : String) -> String {
  let rec = match m.records.get(tag) {
    Some(r) => r
    None => abort("no record \{tag}")
  }
  for f in rec.fields {
    if f.name == field {
      return show_ty(f.ty)
    }
  }
  abort("no field \{field} in \{tag}")
}

///|
fn fn_sig(m : @ast.CModule, name : String) -> String {
  let f = match m.function_named(name) {
    Some(f) => f
    None => abort("no function \{name}")
  }
  let ps = f.params.map(p => show_ty(p.ty)).join(", ")
  let dots = if f.variadic { ",..." } else { "" }
  "\{show_ty(f.ret)}(\{ps}\{dots})"
}

///|
test "array of pointers versus pointer to array" {
  let src =
    #|struct S {
    #|  int *a[3];
    #|  int (*b)[3];
    #|  int **c;
    #|  char *(*d)[4];
    #|};
    #|
  let m = parse_snippet(src)
  inspect(
    field_ty(m, "S", "a"),
    content=(
      #|i32*[3]
    ),
  ) // i32*[3]
  inspect(
    field_ty(m, "S", "b"),
    content=(
      #|i32[3]*
    ),
  ) // i32[3]*
  inspect(
    field_ty(m, "S", "c"),
    content=(
      #|i32**
    ),
  ) // i32**
  inspect(
    field_ty(m, "S", "d"),
    content=(
      #|i8*[4]*
    ),
  ) // u8*[4]*
}

///|
test "function declarators and their return types" {
  let src =
    #|int f(char c, double d);
    #|void g(void);
    #|int printf(const char *fmt, ...);
    #|void (*signal(int sig, void (*handler)(int)))(int);
    #|
  let m = parse_snippet(src)
  inspect(
    fn_sig(m, "f"),
    content=(
      #|i32(i8, f64)
    ),
  )
  inspect(
    fn_sig(m, "g"),
    content=(
      #|void()
    ),
  )
  inspect(
    fn_sig(m, "printf"),
    content=(
      #|i32(i8*,...)
    ),
  )
  inspect(
    fn_sig(m, "signal"),
    content=(
      #|void(i32)*(i32, void(i32)*)
    ),
  )
}

///|
test "type specifier folding" {
  let src =
    #|struct T {
    #|  unsigned char a;
    #|  short b;
    #|  unsigned short c;
    #|  long d;
    #|  unsigned long e;
    #|  long long f;
    #|  unsigned long long g;
    #|  signed char h;
    #|  float i;
    #|  long double j;
    #|  _Bool k;
    #|};
    #|
  let m = parse_snippet(src)
  inspect(
    field_ty(m, "T", "a"),
    content=(
      #|u8
    ),
  )
  inspect(
    field_ty(m, "T", "f"),
    content=(
      #|i64
    ),
  )
  inspect(
    field_ty(m, "T", "j"),
    content=(
      #|f64
    ),
  )
}

///|
test "typedef names and anonymous records" {
  let src =
    #|typedef struct { int x; int y; } Point;
    #|typedef struct Named { int v; } Named;
    #|Point make(void);
    #|
  let m = parse_snippet(src)
  // The anonymous tag is replaced by the typedef name.
  inspect(
    m.records.contains("__anon_1"),
    content=(
      #|false
    ),
  )
  inspect(
    field_ty(m, "Point", "x"),
    content=(
      #|i32
    ),
  )
  inspect(
    field_ty(m, "Named", "v"),
    content=(
      #|i32
    ),
  )
  inspect(
    fn_sig(m, "make"),
    content=(
      #|struct Point()
    ),
  )
}

///|
test "enums and constants" {
  let src =
    #|enum Color { RED, GREEN = 5, BLUE };
    #|enum { FLAG_A = 1 << 2, FLAG_B = FLAG_A | 1 };
    #|struct E { enum Color c; int d; };
    #|
  let m = parse_snippet(src)
  let e = match m.enums.get("Color") {
    Some(e) => e
    None => abort("no enum Color")
  }
  inspect(
    e.items.map(i => "\{i.name}=\{i.value}").join(" "),
    content=(
      #|RED=0 GREEN=5 BLUE=6
    ),
  )
  inspect(
    field_ty(m, "E", "c"),
    content=(
      #|enum Color
    ),
  )
}

///|
test "bitfields and packed records" {
  let src =
    #|struct B {
    #|  unsigned a : 3;
    #|  unsigned b : 5;
    #|  int c;
    #|};
    #|struct __attribute__((packed)) P { char a; int b; };
    #|
  let m = parse_snippet(src)
  let b = match m.records.get("B") {
    Some(r) => r
    None => abort("no record B")
  }
  inspect(
    b.fields
    .map(f => {
      match f.bit_width {
        Some(w) => w.to_string()
        None => "-"
      }
    })
    .join(","),
    content=(
      #|3,5,-
    ),
  )
  let packed = match m.records.get("P") {
    Some(r) =>
      match r.pack {
        Some(n) => n
        None => 0
      }
    None => 0
  }
  inspect(
    packed,
    content=(
      #|1
    ),
  )
}

///|
test "function definitions are skipped" {
  let src =
    #|static int helper(int x) { return x + 1; }
    #|int exported(void);
    #|struct After { int v; };
    #|
  let m = parse_snippet(src)
  // `helper` is static, so it is not callable from a binding; the declaration
  // that follows the definition still parses.
  inspect(
    fn_sig(m, "exported"),
    content=(
      #|i32()
    ),
  )
  inspect(
    field_ty(m, "After", "v"),
    content=(
      #|i32
    ),
  )
}
