#!/bin/sh
# Host-independent L00 checks on the checked-in hand-written scheme_entry.
# Replaces the former Python emit tests. No code generator is invoked.
set -e

HERE=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
ENTRY=$ROOT/compiler/scheme_entry.s

fail() {
    echo "test_l00_asm: $1" >&2
    exit 1
}

[ -f "$ENTRY" ] || fail "missing compiler/scheme_entry.s"

# Collapse whitespace on non-comment lines for structural needles.
code=$(grep -v '^[[:space:]]*//' "$ENTRY" | tr '\t' ' ' | sed 's/  */ /g')

echo "$code" | grep -Fq '.globl _scheme_entry' || fail "missing .globl _scheme_entry"
echo "$code" | grep -Fq '_scheme_entry:' || fail "missing _scheme_entry label"
echo "$code" | grep -Eq 'stp x29, x30,' || fail "must save x29,x30"
echo "$code" | grep -Eq 'ldp x29, x30,' || fail "must restore x29,x30"
echo "$code" | grep -Eq 'mov x0, #42' || fail "must mov x0, #42 (untagged)"
echo "$code" | grep -Eq '(^|[[:space:]])ret([[:space:]]|$)' || fail "must ret"

if grep -v '^[[:space:]]*//' "$ENTRY" | grep -Fq 'svc'; then
    fail "scheme_entry.s must not syscall (system calls belong in runtime.s)"
fi

# Tagged 42 would be 42<<2 = 168. Ignore comments; L00 instructions are untagged.
if grep -v '^[[:space:]]*//' "$ENTRY" | grep -E '(#|,|[[:space:]])168\b' >/dev/null; then
    fail "L00 must not emit tagged 42<<2 (168)"
fi

# No shebang / HLL in this file.
if head -n 1 "$ENTRY" | grep -Eq '^#!'; then
    fail "scheme_entry.s must be assembly, not a script"
fi

echo "test_l00_asm: hand-written _scheme_entry returns untagged 42"
