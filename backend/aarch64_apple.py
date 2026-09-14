"""aarch64-apple backend (Python equivalent of backend/aarch64-apple.scm).

L00 only understands IR node ``(imm n)`` represented as ``("imm", n)``.
``n`` is a bare integer, not a tagged fixnum.

Prologue choice (locked for this layer): save/restore only ``x29`` and
``x30``. Heap base arrives in ``x0`` and size in ``x1`` per the C ABI, but
this layer does not copy them into ``HP`` (``x19``). That wait-until-L12
choice is allowed by layers/L00-pipeline.md; L12 will add callee-saved
``x19``/``x20`` without changing the C prototype.
"""


def emit_imm(n):
    """Emit a small positive immediate into x0. L01 replaces this with movz/movk."""
    return f"\tmov x0, #{int(n)}\n"


def emit_ir(ir):
    if not ir or ir[0] != "imm":
        raise ValueError(f"L00: unknown ir {ir!r}")
    return emit_imm(ir[1])


def emit_program(ir):
    return (
        "\t.globl _scheme_entry\n"
        "\t.p2align 2\n"
        "_scheme_entry:\n"
        "\tstp x29, x30, [sp, #-16]!\n"
        "\tmov x29, sp\n"
        + emit_ir(ir)
        + "\tldp x29, x30, [sp], #16\n"
        "\tret\n"
    )
