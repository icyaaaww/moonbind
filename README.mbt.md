# moonbind

`moonbind` generates type-safe [MoonBit](https://www.moonbitlang.com/) foreign
function interface bindings from C headers — the MoonBit counterpart of
`bindgen`. Point it at `sqlite3.h` and it decides, from the header alone, what
every struct looks like in memory, which type each parameter has on the wire,
and what to emit so that the result compiles and links.

The generated code is meant to be read and checked in, not regenerated at build
time: a binding you cannot inspect is a binding you cannot debug.

```sh
moonbind sqlite3.h --out examples/sqlite3 --target x86_64
```

The header is the only positional argument. `--out` is a directory, and the
generator writes the whole MoonBit package into it: `bindings.mbt`,
`strings.mbt`, `stub.c` and `moon.pkg`. `--target` is the ABI the binding is
laid out for — `x86_64` (the default), `aarch64` or `wasm32` — because a
binding is only correct for the machine whose struct layout it mirrors.

> **Status: 0.1.0.** Lexer, preprocessor, C11 parser, record layout for three
> ABIs, code generation and the command line are complete and tested. What is
> left is a longer list of refusal reasons, not a missing stage; see
> [Roadmap](#roadmap).

## Why this is not a header-to-text script

A header is not a list of prototypes. It is a program, and the parts that
matter to an FFI generator are the parts a naive scanner gets wrong:

- **Declarators read outwards.** `int *a[3]` is an array of pointers;
  `int (*a)[3]` is a pointer to an array. `void (*signal(int, void (*)(int)))(int)`
  returns a function pointer that takes a function pointer. `moonbind` reduces
  a declarator to an ordered chain of constructors and folds it from the name
  outwards, so these are never confused.
- **The preprocessor runs first.** `#if defined(_WIN32)`, `#define SQLITE_VERSION 3045000`,
  recursive macros, `#include <stdint.h>` — the binding reflects the same
  translation unit the C compiler would see, with `__MOONBIND__` defined so a
  header can tell it is being analysed.
- **Layout is a property of the target, not the header.** `long` is 64 bits on
  LP64 and 32 on Windows. `struct { char c; int i; }` is 8 bytes on x86-64.
  Bitfields, `__attribute__((packed))`, `_Alignas` and `#pragma pack` all move
  fields around, and the generator computes the same offsets `clang` does
  before it writes a single line.
- **Macros become constants.** A header's `#define`s are half its interface.

## Design

The pipeline is one direction, each stage a separate MoonBit package:

```text
source ──► lex ──► cp ──► cparse ──► layout ──► codegen
  │                  │        │          │          │
files,           tokenize,  parse     ABI       emit
builtin          #define,   C11       offsets   MoonBit
headers          #include  decls     & sizes
```

| Package   | Responsibility |
|-----------|----------------|
| `ast`     | The declaration model: `CType`, `CRecordDecl`, `CFnDecl`, `CTypedef`, `CEnumDecl` |
| `source`  | Header acquisition: disk, embedded standard headers, include resolution |
| `lex`     | C tokenizer (translation phases 1–3: splicing, comments, punctuators) |
| `cp`      | Preprocessor (phase 4): directives, macro expansion, conditional inclusion |
| `cparse`  | C11 declarations: specifiers, declarators, records, enums, bitfields |
| `layout`  | Record layout for SysV x86-64, AArch64 and wasm32 |
| `codegen` | MoonBit emission: `extern` declarations, struct mirrors, constants |
| `cli`     | Argument parsing, target selection, file output |

Layout is checked against the real compiler rather than trusted. `--verify`
prints the generator's layout table for a header in clang's own compact form,
and `scripts/verify-layout.sh` produces the clang table with
`clang -cc1 -triple … -fdump-record-layouts-complete -fsyntax-only` and diffs
the two. The script skips cleanly when clang is not installed, so it is a
developer check rather than a build dependency.

```sh
moonbind testdata/layout/bitfields.h --verify
# struct F1  0:0-25 a  4:0-6 b [sizeof=8, align=4]
# struct F2  0:0-25 a  3:2-5 b [sizeof=4, align=4]
# struct F3  0:0-3 a  1:0-5 b [sizeof=2, align=1]
```

### Declarators as a constructor chain

The rule that makes C declarations hard to read is also the rule that makes
them easy to parse once stated: a declarator is read from the name outwards.
`moonbind` keeps that order explicitly instead of applying types as it scans.

```text
int *a[3]      chain: [CArr 3, CPtr]   fold: Array(Pointer(int), 3)
int (*a)[3]    chain: [CPtr, CArr 3]   fold: Pointer(Array(int, 3))
```

The function a name binds to is always `chain[0]`; everything further out
describes its return type. That single invariant recovers the `signal`
prototype above without special cases.

### Records are installed late

`struct S { ... } __attribute__((packed));` puts a layout-changing attribute
*after* the body, and `typedef struct { ... } Name;` gives the struct no tag at
all. Bodies are therefore parsed into a pending list and installed only when
the specifier list ends, which is where both facts are known.

### Refusing is a feature

Some C declarations cannot be bound correctly, and the honest thing is to say
so instead of emitting a call that corrupts memory. Every refusal is recorded
and printed with `--report`, so a gap in the binding is a line you can read,
not a link error three days later.

```console
$ moonbind testdata/sqlite/sqlite3.h --out /tmp/sqlite --report
left out: sqlite3_config — variadic, which MoonBit cannot call
left out: sqlite3_mprintf — variadic, which MoonBit cannot call
left out: sqlite3 — the definition is not in this translation unit
left out: fts5_api — no MoonBit representation: xCreateTokenizer: a pointer has no MoonBit slot
left out: sqlite3_vfs — no MoonBit representation: pNext: a pointer has no MoonBit slot
```

One refusal is worth spelling out because it is a fact about MoonBit's FFI and
not about C: **a struct passed or returned by value is always refused**, even
when its layout matches MoonBit's exactly. MoonBit passes every non-scalar
argument by reference, so a C function expecting `struct { int x; int y; }` in
registers instead receives the low words of a pointer to a box and reads
garbage. There is no spelling of the call that fixes it from MoonBit's side, so
`moonbind` leaves the function out and names the problem. Structs reached
through a pointer are unaffected and are bound normally.

## Usage

Three complete scenarios live in `examples/`, each one runnable with
`moon run --target native`:

### 1. A real library: SQLite

`examples/sqlite3` is `testdata/sqlite/sqlite3.h` (SQLite is in the public
domain) run through `moonbind` and checked in. `examples/sqlite3-demo` is a
program written against it that creates a table, inserts rows through a
prepared statement, and reads them back.

```console
$ moon run examples/sqlite3-demo --target native
craters by size:
  Tycho — 5 craters
  Copernicus — 3 craters
  Kepler — 2 craters
3 rows
```

Nothing in `main.mbt` mentions a pointer size, an offset or a C type. The
`sqlite3 *` handle, the `sqlite3_stmt *` resets and the `SQLITE_*` status codes
all came out of the header.

### 2. A header small enough to read

`examples/greet` is a forty-line header with a hand-written C implementation,
generated in one command:

```sh
moonbind examples/greet/greet.h --out examples/greet --report
```

(The generated `moon.pkg` names only the stub that `moonbind` itself writes;
this example's own `greet.c` is added to its `native-stub` list by hand, which
is what any project using the bindings would do for the library it is binding.)

It is the case that shows the awkward parts side by side: an opaque type that
is only ever named, a `const char *` going in as `Bytes`, a string coming back
as a `VoidPtr` that the generated `copy_cstr` copies into MoonBit memory, an
`int` that arrives as `Int32`, and a `greet_point_sum` that takes a struct by
value and is therefore reported and left out:

```console
$ moonbind examples/greet/greet.h --out examples/greet --report
left out: greet_point_sum — parameter 0 passes greet_point by value, and MoonBit passes records by reference
left out: greet_ctx — the definition is not in this translation unit
```

The second line is not a failure: `greet_ctx` is opaque on purpose, and what
the generator is reporting is that it could not mirror the *definition* — so it
emits an opaque handle instead. Run against that header:

```console
$ moon run examples/greet-demo --target native
library says: greet 1.0
moonbind greets Tycho
greet_hello returned 1
moonbind greets Kepler
greet_hello returned 2
count: 2
null count: -1
```

### 3. Inspecting a header without binding it

`--verify` prints the layout table and exits; nothing is written. This is what
you run first when a binding misbehaves, and what the CI job compares against
clang.

```console
$ moonbind testdata/layout/packed.h --verify --target aarch64
struct P1  0:0-25 a  3:2-8 b [sizeof=5, align=1]
struct P2  0:0-25 a  3:2-8 b [sizeof=6, align=2]
union P9  0 c  0:0-19 a [sizeof=4, align=4]
```

## Building

MoonBit 0.1.20261016 or newer.

```sh
moon update
moon check --target wasm-gc
moon build --target wasm-gc
moon test  --target wasm-gc
```

The tool itself builds for wasm-gc. The bindings it generates are `extern "C"`
declarations, so their packages declare `supported-targets = [ "native" ]` and
the demos are run with `--target native`.

## Roadmap

- [x] Tokenizer, preprocessor, C11 declaration parser
- [x] Record layout for x86-64, AArch64, wasm32
- [x] MoonBit code generation
- [x] Command-line interface and runnable examples
- [x] Differential verification against clang
- [ ] Published to [mooncakes.io](https://mooncakes.io)
- [ ] Struct returns by value, once the FFI can express them
- [ ] `#define` function-like macros as MoonBit functions

## License

Apache-2.0. See [LICENSE](LICENSE).
