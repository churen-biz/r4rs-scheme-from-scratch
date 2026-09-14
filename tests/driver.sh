#!/bin/sh
# tests/driver.sh
# Usage: ./tests/driver.sh tests/L00/001-fixed-return.scm [expected-file]
# Assemble and link ONLY checked-in .s files (no Python, no C, no HLL emit),
# run on Darwin arm64, compare stdout to the sibling .expected file.
# The .scm argument names the case and locates .expected; L00 does not
# interpret the Scheme source. Does not hard-code 42 in this script.
set -e

if [ -z "$1" ]; then
    echo "usage: $0 <input.scm> [expected]" >&2
    exit 2
fi

HERE=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)

IN=$1
case "$IN" in
    /*) ;;
    *) IN=$(pwd)/$IN ;;
esac

if [ ! -f "$IN" ]; then
    echo "driver: input not found: $IN" >&2
    exit 2
fi

if [ -n "${2-}" ]; then
    EXPECTED=$2
    case "$EXPECTED" in
        /*) ;;
        *) EXPECTED=$(pwd)/$EXPECTED ;;
    esac
else
    EXPECTED=${IN%.scm}.expected
fi

if [ ! -f "$EXPECTED" ]; then
    echo "driver: expected file not found: $EXPECTED" >&2
    exit 2
fi

CLANG=${CLANG:-clang}
RUNTIME_S=$ROOT/runtime/aarch64-apple/runtime.s
ENTRY_S=$ROOT/compiler/scheme_entry.s

if [ ! -f "$RUNTIME_S" ]; then
    echo "driver: missing $RUNTIME_S" >&2
    exit 2
fi
if [ ! -f "$ENTRY_S" ]; then
    echo "driver: missing $ENTRY_S" >&2
    exit 2
fi
if [ -f "$ROOT/runtime/aarch64-apple/runtime.c" ] || [ -f "$ROOT/runtime/aarch64-apple/scheme.h" ]; then
    echo "driver: C runtime files are forbidden (no-C policy)" >&2
    exit 2
fi
if find "$ROOT" -path "$ROOT/.git" -prune -o -type f \( \
    -name '*.py' -o -name '*.rb' -o -name '*.js' -o -name '*.pl' \
    \) -print | grep -q .; then
    echo "driver: HLL sources are forbidden (no-Python / no HLL-emitter policy)" >&2
    find "$ROOT" -path "$ROOT/.git" -prune -o -type f \( \
        -name '*.py' -o -name '*.rb' -o -name '*.js' -o -name '*.pl' \
        \) -print >&2
    exit 2
fi

BASE=$(mktemp -d)
trap 'rm -rf "$BASE"' EXIT

# Structural Darwin checks. Exact L00 skeleton lives in tests/test_l00_asm.sh.
check_asm() {
    f=$1
    norm=$(tr '\t' ' ' < "$f" | sed 's/  */ /g')
    echo "$norm" | grep -Fq '.globl _scheme_entry' || { echo "driver: missing .globl _scheme_entry" >&2; return 1; }
    echo "$norm" | grep -Fq '_scheme_entry:' || { echo "driver: missing _scheme_entry label" >&2; return 1; }
    if grep -v '^[[:space:]]*//' "$f" | grep -Fq 'svc'; then
        echo "driver: scheme_entry must not use svc" >&2
        return 1
    fi
}

check_asm "$ENTRY_S"

HOST_OS=$(uname -s)
HOST_ARCH=$(uname -m)

if [ "$HOST_OS" != "Darwin" ] || [ "$HOST_ARCH" != "arm64" ]; then
    echo "driver: native aarch64-apple run skipped (host is $HOST_OS $HOST_ARCH)." >&2
    echo "driver: using checked-in $ENTRY_S; Darwin symbol/asm contract checks passed." >&2
    echo "driver: on Apple Silicon: $0 $1" >&2
    if [ -n "${L00_KEEP_ASM-}" ]; then
        cp "$ENTRY_S" "${L00_KEEP_ASM}"
    fi
    exit 0
fi

# Assemble and link only .s files. clang is a driver, never a C compiler here.
"$CLANG" -arch arm64 -c "$RUNTIME_S" -o "$BASE/rt.o"
"$CLANG" -arch arm64 -c "$ENTRY_S" -o "$BASE/prog.o"
"$CLANG" -arch arm64 "$BASE/rt.o" "$BASE/prog.o" -o "$BASE/program"

if [ -n "${L00_KEEP_BIN-}" ]; then
    cp "$BASE/program" "$L00_KEEP_BIN"
fi

OUT=$BASE/out.txt
"$BASE/program" > "$OUT"
cat "$OUT"
diff -u "$EXPECTED" "$OUT"
