#!/usr/bin/env python3
"""Host-independent L00 checks: IR (imm 42) and ignored source still emit 42."""

from __future__ import annotations

import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from backend.aarch64_apple import emit_program  # noqa: E402
from compiler.compile import compile_file, compile_program  # noqa: E402

EXPECTED_ASM = (
    "\t.globl _scheme_entry\n"
    "\t.p2align 2\n"
    "_scheme_entry:\n"
    "\tstp x29, x30, [sp, #-16]!\n"
    "\tmov x29, sp\n"
    "\tmov x0, #42\n"
    "\tldp x29, x30, [sp], #16\n"
    "\tret\n"
)


def assert_eq(got, want, msg):
    if got != want:
        raise AssertionError(f"{msg}\n--- got ---\n{got!r}\n--- want ---\n{want!r}")


def test_emit_program_matches_l00_skeleton():
    asm = emit_program(("imm", 42))
    assert_eq(asm, EXPECTED_ASM, "emit_program((imm 42)) must match L00 skeleton")


def test_compile_program_ignores_expr():
    a = compile_program(None)
    b = compile_program(("prim", "+", ("imm", 1), ("imm", 2)))
    assert_eq(a, EXPECTED_ASM, "compile_program must emit (imm 42)")
    assert_eq(b, EXPECTED_ASM, "compile_program must ignore expr")


def test_compile_file_ignores_source():
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        src = tmp / "junk.scm"
        out = tmp / "program.s"
        src.write_text("(+ 1 2)\n", encoding="utf-8")
        compile_file(str(src), str(out))
        assert_eq(out.read_text(encoding="utf-8"), EXPECTED_ASM, "junk Scheme still emits 42")


def test_no_tagging():
    asm = emit_program(("imm", 42))
    if "168" in asm:
        raise AssertionError("L00 must not emit tagged 42<<2 (168)")


def test_generated_asm_has_no_svc():
    asm = emit_program(("imm", 42))
    if "svc" in asm:
        raise AssertionError("generated scheme_entry must not syscall")


def main():
    test_emit_program_matches_l00_skeleton()
    test_compile_program_ignores_expr()
    test_compile_file_ignores_source()
    test_no_tagging()
    test_generated_asm_has_no_svc()
    print("test_l00_emit: 5 passed")


if __name__ == "__main__":
    main()
