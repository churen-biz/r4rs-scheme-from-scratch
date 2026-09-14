#!/usr/bin/env python3
"""L00 compile driver.

Host: Python 3 (ARCHITECTURE.md allows this when Chez/Guile are unavailable).
This layer ignores the source expression and always lowers to IR ``(imm 42)``.
The ``expr`` argument is kept so L01 can start reading it.

The compiler emits Darwin ARM64 assembly only. It never emits ``svc`` and
never produces C. Linking is the test driver's job (assemble+link ``.s``).
"""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from backend.aarch64_apple import emit_program  # noqa: E402


def compile_program(_expr):
    return emit_program(("imm", 42))


def compile_file(in_path, out_path):
    """Read ``in_path`` (must exist) but ignore contents; write assembly to ``out_path``."""
    if in_path != "-":
        # Existence check only; L00 does not interpret the bytes.
        Path(in_path).read_bytes()
    Path(out_path).write_text(compile_program(None), encoding="utf-8")


def main(argv):
    if len(argv) != 3:
        print(f"usage: {argv[0]} IN OUT", file=sys.stderr)
        return 2
    compile_file(argv[1], argv[2])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
