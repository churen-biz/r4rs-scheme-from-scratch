#!/bin/sh
# Policy: no Python anywhere in the repo (sources, bytecode, or caches).
# Also reject other HLL code generators under compiler/ (Ruby/JS/Perl/etc.).
# Allowed later: Scheme sources in compiler/ after the self-host threshold.
# Allowed now: hand-written Darwin/arm64 .s plus Makefile/sh glue.
set -e

HERE=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
cd "$ROOT"

fail() {
    echo "test_no_python: $1" >&2
    exit 1
}

py=$(find . -path './.git' -prune -o \( \
    -name '*.py' -o -name '*.pyc' -o -name '*.pyo' -o -name '*.pyd' \
    -o -name '__pycache__' \
    \) -print)
if [ -n "$py" ]; then
    echo "$py" >&2
    fail "Python files or __pycache__ are forbidden"
fi

# compiler/ must not host a scripting-language assembler emitter.
if [ -d compiler ]; then
    hll=$(find compiler -type f \( \
        -name '*.rb' -o -name '*.js' -o -name '*.mjs' -o -name '*.cjs' \
        -o -name '*.pl' -o -name '*.pm' -o -name '*.lua' -o -name '*.php' \
        -o -name '*.tcl' -o -name '*.rake' \
        \))
    if [ -n "$hll" ]; then
        echo "$hll" >&2
        fail "compiler/ must not contain a non-Scheme HLL code generator"
    fi
fi

echo "test_no_python: no .py / bytecode; compiler/ has no HLL emitter"
