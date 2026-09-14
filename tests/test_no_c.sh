#!/bin/sh
# Policy: no C sources anywhere the L00 (or later) build could pick up.
set -e

HERE=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
cd "$ROOT"

fail() {
    echo "test_no_c: $1" >&2
    exit 1
}

bad=$(find . -path './.git' -prune -o -type f \( \
    -name '*.c' -o -name '*.h' -o -name '*.cc' -o -name '*.cpp' -o -name '*.hpp' \
    -o -name '*.cxx' -o -name '*.hxx' \
    \) -print)
if [ -n "$bad" ]; then
    echo "$bad" >&2
    fail "no-C policy violated; forbidden files listed above"
fi

RUNTIME=$ROOT/runtime/aarch64-apple/runtime.s
[ -f "$RUNTIME" ] || fail "missing runtime/aarch64-apple/runtime.s"

# Portable grep -F: reject libc C leftovers in the runtime.
for needle in printf aligned_alloc stdio.h stdlib.h; do
    if grep -Fq "$needle" "$RUNTIME"; then
        fail "runtime.s must not mention $needle"
    fi
done

grep -Eq 'SYS_write|SYS_WRITE' "$RUNTIME" || fail "runtime.s must document/use SYS_write"
grep -Eq 'SYS_mmap|SYS_MMAP' "$RUNTIME" || fail "runtime.s must document/use SYS_mmap"
grep -Fq '_scheme_entry' "$RUNTIME" || fail "runtime.s must call _scheme_entry"
grep -Fq '_main:' "$RUNTIME" || fail "runtime.s must define _main"

echo "test_no_c: no .c/.h; runtime.s is pure asm"
