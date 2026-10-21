#!/usr/bin/env bash
# Check moonbind's record layout table against the compiler's own.
#
# `moonbind verify` cannot spawn a compiler — MoonBit has no process API — so
# the two halves run side by side here and the diff is the check. Both sides
# are normalised to one row per record in the same form:
#
#   struct F1  0:0-25 a  4:0-6 b [sizeof=8, align=4]
#
# Missing clang is a skip, not a failure: the layout fixtures still carry the
# numbers clang printed for them, and the test suite compares against those on
# every platform. This script is the part that refuses to take the fixtures on
# faith, so it needs a clang to believe.
set -euo pipefail

cd "$(dirname "$0")/.."

CLANG="${CLANG:-clang}"
if ! command -v "$CLANG" >/dev/null 2>&1; then
  echo "clang not found; the recorded fixtures already cover these records" >&2
  exit 0
fi

# moonbind's own triple names, and the ones clang knows them by.
targets="sysv64:x86_64-unknown-linux-gnu aapcs64:aarch64-unknown-linux-gnu wasm32:wasm32-unknown-unknown"

# clang's verbose dump, one record per block, reduced to the compact row:
#
#   *** Dumping AST Record Layout
#            0 | struct F1
#       0:0-25 |   unsigned int a
#        4:0-6 |   unsigned int b
#              | [sizeof=8, align=4]
#
# The first `|` field of each line is the bit range, the second the member; the
# record line is the only one whose member names a type. Blocks for the builtin
# `__va_list_tag` and `__NSConstantString_tag` are dropped: they are not in the
# header, and `__`-prefixed tags are not something `moonbind` will ever emit.
from_clang() {
  # Force sizeof after the entire declaration has been parsed. The "complete"
  # dump can print a record before a trailing packed attribute is applied.
  # Names come from the independently recorded fixture rows, not our output.
  {
    printf '#include "%s/%s"\n' "$PWD" "$2"
    awk '/^\/\/ +(struct|union) / { print "int moonbind_force_" n++ "[sizeof(" $2 " " $3 ")];" }' "$2"
  } | "$CLANG" -cc1 -triple "$1" -x c -fdump-record-layouts -fsyntax-only - 2>&1 |
    awk '
      function flush() { if (keep && row != "") print row; row = ""; keep = 0 }
      /^ *[0-9]+ \| (struct|union) / {
        flush()
        row = $0; sub(/^ *[0-9]+ \| /, "", row)
        tag = row; sub(/^[a-z]+ +/, "", tag)
        keep = (tag !~ /^__/)
        next
      }
      /^ *\| \[sizeof=/ {
        s = $0; sub(/^ *\| /, "", s)
        row = row " " s
        flush()
        next
      }
      /^ *[0-9]+(:[0-9]+-[0-9]+)? \|   / {
        bits = $0; sub(/^ */, "", bits); sub(/ \|.*/, "", bits)
        # `unsigned int a` -> `a`: the name is all moonbind prints.
        member = $0; sub(/ *$/, "", member); sub(/^.* /, "", member)
        row = row "  " bits " " member
        next
      }
      /^\*\*\* Dumping/ { flush() }
      END { flush() }
    '
}

# The record name is the tag; the engine prints records sorted by tag and so
# does this, so a plain `diff` is meaningful.
for pair in $targets; do
  target="${pair%%:*}"
  triple="${pair#*:}"
  for header in testdata/layout/bitfields.h testdata/layout/packed.h; do
    want="$(from_clang "$triple" "$header" | sort)"
    got="$(moon run cmd/main -- --verify "$header" --target "$target" 2>/dev/null | sort)"
    # `moon run` narrates warnings on stderr; only the table is on stdout.
    if [ "$want" != "$got" ]; then
      echo "layout differs for $header on $target:" >&2
      diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") >&2 || true
      exit 1
    fi
    echo "ok  $header  $target  $(printf '%s\n' "$got" | grep -c . || true) records"
  done
done
