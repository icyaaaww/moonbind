# moonbind

`moonbind` generates type-safe [MoonBit](https://www.moonbitlang.com/) foreign
function interface bindings from C headers — the MoonBit counterpart of
`bindgen`. Point it at `sqlite3.h` and it decides, from the header alone, what
every struct looks like in memory, which type each parameter has on the wire,
and what to emit so that the result compiles and links.

The generated code is meant to be read and checked in, not regenerated at build
time: a binding you cannot inspect is a binding you cannot debug.

```sh
moonbind --header sqlite3.h --target native --out sqlite3.mbt
```

> **Status: 0.1.0 — parser release.** The lexer, preprocessor and C11
> declaration parser are complete and tested. Layout, code generation and the
> command line are in progress; see [Roadmap](#roadmap).

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
  LP64 and 32 on Windows. `struct { char c; int i; }` is 8 bytes on x86-64 and
  32 bytes in wasm32 only if you pack it. Bitfields, `__attribute__((packed))`,
  `_Alignas` and `#pragma pack` all move fields around.
- **Macros become constants.** A header's `#define`s are half its interface.

## Design

The pipeline is one direction, each stage a separate MoonBit package:

```text
source ──► lex ──► cp ──► cparse ──► layout ──► codegen
  │                  │        │          │          │
files,           tokenize,  parse     ABI       emit
builtin          #define,   C11       offsets   MoonBit
headers          #include  decls     & sizes
                                │
                                └──────► verify ◄── clang -ast-dump
                                         differential
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
| `verify`  | Differential testing against `clang -cc1 -fdump-record-layouts` |
| `cli`     | Argument parsing, target selection, file output |

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

## Building

MoonBit 0.1.20261016 or newer.

```sh
moon update
moon check --target wasm-gc
moon build --target wasm-gc
moon test  --target wasm-gc
```

## Roadmap

- [x] Tokenizer, preprocessor, C11 declaration parser
- [ ] Record layout for x86-64, AArch64, wasm32
- [ ] MoonBit code generation
- [ ] Command-line interface and runnable example
- [ ] Differential verification against clang
- [ ] Published to [mooncakes.io](https://mooncakes.io)

## License

Apache-2.0. See [LICENSE](LICENSE).
