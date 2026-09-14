#!/bin/sh
# Run all L00 tests: policy (no Python, no C), hand-written asm contract,
# per-file driver, repeatability. On Apple Silicon this assembles+links
# only .s files and compares stdout to .expected. On other hosts it still
# checks the checked-in Darwin/arm64 assembly contract.
set -e

HERE=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
cd "$ROOT"

echo "== L00 no-Python policy =="
./tests/test_no_python.sh

echo "== L00 no-C policy =="
./tests/test_no_c.sh

echo "== L00 hand-written scheme_entry (host-independent) =="
./tests/test_l00_asm.sh

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
    echo "checked-in compiler/scheme_entry.s is the L00 program (no HLL emit)"
    echo "asm contract already checked by tests/test_l00_asm.sh"
    echo "native aarch64-apple run skipped on $HOST_OS $HOST_ARCH"
    echo "on Apple Silicon (M-series): make test-L00   # expected stdout: 42"
fi

echo "L00 OK"
