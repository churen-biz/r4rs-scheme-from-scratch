#!/bin/sh
# tests/driver.sh
# Usage: ./tests/driver.sh tests/L00/001-fixed-return.scm [expected-file]
# Compile Scheme/IR input via the Python compiler to program.s, then on
# Darwin arm64 assemble + link + run. Compares stdout to the sibling
# .expected file (or the optional second argument) and exits non-zero
# on mismatch. Does not hard-code 42.
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

PYTHON=${PYTHON:-python3}
CLANG=${CLANG:-clang}

BASE=$(mktemp -d)
trap 'rm -rf "$BASE"' EXIT

"$PYTHON" "$ROOT/compiler/compile.py" "$IN" "$BASE/program.s"

# Structural Darwin checks only. Exact L00 skeleton (including mov x0, #42)
# lives in tests/test_l00_emit.py so this driver can survive L01+.
check_asm() {
    f=$1
    grep -Fq '.globl _scheme_entry' "$f" || { echo "driver: missing .globl _scheme_entry" >&2; return 1; }
    grep -Fq '_scheme_entry:' "$f" || { echo "driver: missing _scheme_entry label" >&2; return 1; }
    if grep -Fq 'svc' "$f"; then
        echo "driver: generated asm must not use svc" >&2
        return 1
    fi
}

check_asm "$BASE/program.s"

HOST_OS=$(uname -s)
HOST_ARCH=$(uname -m)

if [ "$HOST_OS" != "Darwin" ] || [ "$HOST_ARCH" != "arm64" ]; then
    echo "driver: native aarch64-apple run skipped (host is $HOST_OS $HOST_ARCH)." >&2
    echo "driver: program.s generated; Darwin symbol/asm contract checks passed." >&2
    echo "driver: on Apple Silicon: $0 $1" >&2
    if [ -n "${L00_KEEP_ASM-}" ]; then
        cp "$BASE/program.s" "${L00_KEEP_ASM}"
    fi
    exit 0
fi

"$CLANG" -arch arm64 -c "$ROOT/runtime/aarch64-apple/runtime.c" -o "$BASE/rt.o"
"$CLANG" -arch arm64 -c "$BASE/program.s" -o "$BASE/prog.o"
"$CLANG" -arch arm64 "$BASE/rt.o" "$BASE/prog.o" -o "$BASE/program"

if [ -n "${L00_KEEP_BIN-}" ]; then
    cp "$BASE/program" "$L00_KEEP_BIN"
fi

OUT=$BASE/out.txt
"$BASE/program" > "$OUT"
cat "$OUT"
diff -u "$EXPECTED" "$OUT"
