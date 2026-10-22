# moonbind

[中文首页与快速开始](README.md) · [Mooncakes package](https://mooncakes.io/docs/icyaaaww/moonbind)

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

> **Status: 0.5.0.** A bounded C declaration/layout/binding tool with opt-in
> adapters, explicit call contracts and reproducible project validation. It is
> not a complete C compiler or an automatic memory-safety proof.
>
> Start with `python moonbind.py init ../demo --template cjson`, then
> `python moonbind.py validate ../demo`. See the [0.5 guide](docs/v0.5.md).
> The Python standard-library driver orchestrates tools; parsing, layout and
> all binding/adapter/wrapper generation remain implemented in MoonBit.

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
`clang -cc1 -triple … -fdump-record-layouts -fsyntax-only` after forcing record
sizes with `sizeof`, and diffs
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
not about C: **direct bindings refuse structs passed or returned by value**, even
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

## Project workflow and contracts in 0.5

`moonbind.py` provides init, doctor, generate, validate and report-check commands.
Five standalone templates cover SQLite, zlib, cJSON, ownership contracts and
nested records. Native validation targets LP64 Linux/macOS; Windows LLP64 is
explicitly rejected by the environment probe.

Generator options `--own create=free`, `--buffer fn=pointer:length`, and
`--copy-string fn` generate scoped cleanup, derived byte counts and immediate
copies of borrowed NUL strings. These are user-supplied contracts: scoped
cleanup does not enforce handle non-escape or protect against manually freeing
borrowed handles. Contract errors refuse CLI output even without strict mode.

Bridges support bounded nested structs, fixed arrays, narrow integers widened
to 32-bit adapter arguments, and signed-32-bit-range enums. Out-of-range narrow
writes abort. Unions, bitfields, pointers/callbacks and packing remain excluded.
Headers and include paths are relative to the generated source/module tree.

Validation records source token locations, phase exit codes and SHA-256 file
snapshots. Function-to-test associations are declared by test authors, not
inferred code coverage. Reports are unsigned; report-check detects file changes,
not dynamic-library or OS replacement. Rerun validate after environment changes.

## C adapters and upgrade checks introduced in 0.3

The opt-in `--bridge --out DIR` mode generates C adapters for scalar functions,
simple scalar-field records passed/returned by value, and static function
definitions. Returned records are allocated handles: check for null and free
exactly once. Pointer/callback/vararg and nested/packed record bridges are out
of scope. Existing direct pointer bindings remain available.

`--strict` rejects known parser diagnostics and skipped selected functions.
`--fail-on none|removed|changed|any` controls comparison gates (exit 3), while
`--html` creates a standalone, escaped, script-free review report. C layout
assertions are emitted, not executed during generation. In 0.5, adapters include relative header paths; preserve the project tree when moving it.

See the [0.3 guide](docs/v0.3.md) for contracts, limitations, migration and
validation. CI runs native Point adapters, a 1,000-cycle C ASan/UBSan harness,
and a deliberate header-layout mismatch, alongside SQLite and zlib regressions.

## Maintaining bindings in 0.2

See the [0.2 guide](docs/v0.2.md) for strict JSON configuration, edit protection,
`--check`, JSON reports, function selection/renaming and old/new header comparison.
Native CI regenerates SQLite and zlib bindings in fresh projects before compiling,
linking and running them. Header comparisons are source-level review aids, not
complete binary compatibility verdicts.

## Building

### Install the Mooncakes library

The published module is `icyaaaww/moonbind@0.5.0`:

```sh
moon add icyaaaww/moonbind@0.5.0
```

Import the stage you need, for example `"icyaaaww/moonbind/layout"` or
`"icyaaaww/moonbind/cparse"`, in your package's `moon.pkg`. Use the `wasm-gc`
target for the generator and its filesystem-dependent stages. The module's
root package has no generator API; the APIs live in the stage packages above.

For the CLI, clone https://github.com/icyaaaww/moonbind and run:

```sh
moon run cmd/main --target wasm-gc -- --help
moon run cmd/main --target wasm-gc -- testdata/layout/packed.h --verify
```

The abbreviated `moonbind` commands in this README refer to that CLI entry
point; adding the library does not install a global `moonbind` executable.

### Build from source

MoonBit 0.1.20261016 or newer.

```sh
moon update
moon check --target wasm-gc
moon build --target wasm-gc
moon test  --target wasm-gc
```

The tool itself builds for wasm-gc. The bindings it generates are `extern "C"`
declarations, so their packages declare `supported_targets = "native"` and
the demos are run with `--target native`.

## Roadmap

- [x] Tokenizer, preprocessor, C11 declaration parser
- [x] Record layout for x86-64, AArch64, wasm32
- [x] MoonBit code generation
- [x] Command-line interface and runnable examples
- [x] Differential verification against clang
- [x] Published as [icyaaaww/moonbind](https://mooncakes.io/docs/icyaaaww/moonbind) 0.5.0
- [x] Simple struct arguments/returns through opt-in C adapters (0.3)
- [ ] `#define` function-like macros as MoonBit functions

## License

Apache-2.0. See [LICENSE](LICENSE).
