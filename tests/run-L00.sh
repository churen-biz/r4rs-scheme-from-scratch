#!/bin/sh
# Run all L00 tests: emit unit checks, per-file driver, repeatability.
# On Apple Silicon this assemble+links and compares stdout to .expected.
# On other hosts it still generates program.s and checks the L00 asm contract.
set -e

HERE=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
cd "$ROOT"

PYTHON=${PYTHON:-python3}

echo "== L00 emit (host-independent) =="
"$PYTHON" tests/test_l00_emit.py

echo "== L00 driver (each tests/L00/*.scm) =="
for scm in tests/L00/*.scm; do
    echo "-- $scm"
    ./tests/driver.sh "$scm"
done

echo "== L00 repeatability (001 twice, byte-identical) =="
HOST_OS=$(uname -s)
HOST_ARCH=$(uname -m)
A=$(mktemp)
B=$(mktemp)
trap 'rm -f "$A" "$B"' EXIT

if [ "$HOST_OS" = "Darwin" ] && [ "$HOST_ARCH" = "arm64" ]; then
    ./tests/driver.sh tests/L00/001-fixed-return.scm > "$A"
    ./tests/driver.sh tests/L00/001-fixed-return.scm > "$B"
    cmp -s "$A" "$B"
    echo "native stdout identical across two runs"
    echo "== L00 symbols (nm) =="
    KEEP=$(mktemp)
    L00_KEEP_BIN=$KEEP ./tests/driver.sh tests/L00/001-fixed-return.scm >/dev/null
    ./tests/check-symbols.sh "$KEEP"
    rm -f "$KEEP"
else
    # Compiler must emit identical assembly for the same ignored input, twice.
    "$PYTHON" compiler/compile.py tests/L00/001-fixed-return.scm "$A"
    "$PYTHON" compiler/compile.py tests/L00/001-fixed-return.scm "$B"
    cmp -s "$A" "$B"
    echo "generated program.s identical across two compiles"
    echo "native aarch64-apple run skipped on $HOST_OS $HOST_ARCH"
    echo "on Apple Silicon (M-series): make test-L00   # expected stdout: 42"
fi

echo "L00 OK"
