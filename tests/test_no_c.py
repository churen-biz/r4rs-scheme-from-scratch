#!/usr/bin/env python3
"""Policy: no C sources anywhere the L00 build could pick up."""

from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FORBIDDEN_SUFFIXES = {".c", ".h", ".cc", ".cpp", ".hpp"}
SKIP_DIRS = {".git", "__pycache__", ".venv", "node_modules"}


def main():
    bad = []
    for path in ROOT.rglob("*"):
        if not path.is_file():
            continue
        if any(part in SKIP_DIRS for part in path.parts):
            continue
        if path.suffix.lower() in FORBIDDEN_SUFFIXES:
            bad.append(path.relative_to(ROOT).as_posix())

    runtime = ROOT / "runtime"
    if not (runtime / "aarch64-apple" / "runtime.s").is_file():
        raise SystemExit("missing runtime/aarch64-apple/runtime.s")

    text = (runtime / "aarch64-apple" / "runtime.s").read_text(encoding="utf-8")
    for needle in ("printf", "aligned_alloc", "stdio.h", "stdlib.h"):
        if needle in text:
            raise SystemExit(f"runtime.s must not mention {needle!r}")
    if "SYS_write" not in text and "SYS_WRITE" not in text:
        raise SystemExit("runtime.s must document/use SYS_write")
    if "SYS_mmap" not in text and "SYS_MMAP" not in text:
        raise SystemExit("runtime.s must document/use SYS_mmap")
    if "_scheme_entry" not in text:
        raise SystemExit("runtime.s must call _scheme_entry")
    if "_main:" not in text:
        raise SystemExit("runtime.s must define _main")

    if bad:
        listing = "\n".join(f"  {p}" for p in bad)
        raise SystemExit(f"no-C policy violated; forbidden files:\n{listing}")
    print("test_no_c: no .c/.h; runtime.s is pure asm")


if __name__ == "__main__":
    main()
