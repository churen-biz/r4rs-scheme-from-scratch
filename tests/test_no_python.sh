#!/bin/sh
# Policy: no Python anywhere in the repo (sources, bytecode, caches, shebangs).
# Also reject other HLL code generators used to emit assembly (Ruby/JS/Perl/etc.).
# Allowed later: Scheme sources in compiler/ after the self-host threshold.
# Allowed now: hand-written Darwin/arm64 .s plus Makefile/sh glue.
#
# macOS /bin/sh is bash 3.2: a `case` pattern's `)` inside $(...) is parsed as
# the end of the substitution, so `continue ;;` becomes a syntax error.
# Skip with nested if / inverted match instead of case+continue.
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

# Scripting-language compilers must not live anywhere a build could pick them up.
hll=$(find . -path './.git' -prune -o -type f \( \
    -name '*.rb' -o -name '*.js' -o -name '*.mjs' -o -name '*.cjs' \
    -o -name '*.pl' -o -name '*.pm' -o -name '*.lua' -o -name '*.php' \
    -o -name '*.tcl' -o -name '*.rake' \
    \) -print)
if [ -n "$hll" ]; then
    echo "$hll" >&2
    fail "scripting-language sources are forbidden (no HLL assembler emitter)"
fi

# Allowed: .md|.expected|.scm|.s|.txt and this shell glue file.
# Empty leftover lines from find|grep are ignored so they cannot fail the test.
shebang=$(find . -path './.git' -prune -o -type f -print \
    | grep -Ev '/(\.git)(/|$)' \
    | grep -Ev '\.(md|expected|scm|s|txt)$' \
    | while IFS= read -r f; do
        if [ -n "$f" ] && [ "$f" != "./tests/test_no_python.sh" ]; then
            if head -n 1 "$f" 2>/dev/null | grep -Eq '^#!.*(python|python3|ruby|perl|node|lua)'; then
                echo "$f"
            fi
        fi
    done)
if [ -n "$shebang" ]; then
    echo "$shebang" >&2
    fail "HLL shebang is forbidden"
fi

echo "test_no_python: no .py / bytecode / HLL emitter; compiler/ has no HLL emitter"
