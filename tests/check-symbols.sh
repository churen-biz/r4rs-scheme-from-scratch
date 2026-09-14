#!/bin/sh
# Documented L00 symbol check: Mach-O nm should show _scheme_entry and _main.
# Usage: ./tests/check-symbols.sh /path/to/program
set -e

if [ -z "$1" ] || [ ! -f "$1" ]; then
    echo "usage: $0 <program>" >&2
    exit 2
fi

SYMS=$(nm "$1")
echo "$SYMS" | grep -q '_scheme_entry' || {
    echo "check-symbols: _scheme_entry not found in $1" >&2
    echo "$SYMS" >&2
    exit 1
}
echo "$SYMS" | grep -q '_main' || {
    echo "check-symbols: _main not found in $1" >&2
    echo "$SYMS" >&2
    exit 1
}
echo "nm: _scheme_entry and _main present"
