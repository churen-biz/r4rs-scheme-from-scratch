# L00 — 管道：空程序 / 固定返回

## 目标

打通 **generate → assemble → link → run** 整条出口。本层还没有 Scheme 语法、没有标签、没有堆。编译器读入一个（可忽略的）输入，**永远生成同一段汇编**：`scheme_entry` 把一个约定好的整数放进返回寄存器，然后回到 C。`runtime.c` 的 `main` 调用它并打印该整数。

做完本层，你必须能在 aarch64-apple 上一条命令跑出 `42`（或你在测例里锁定的那个常数）。以后每一层都只替换 `scheme_entry` 的函数体和 `rt_print` 的解码规则，**不再重新发明**链接方式。

本层范围之外：fixnum 标签、任何 Scheme 读入、错误处理、堆、栈上 Scheme 帧。输入文件可以存在但不解释。

## 原理

Ghuloum 方法的第一刀不是「词法分析器」，而是 **证明工具链听你的话**。若 L00 在链接符号、对齐、寄存器保存上是错的，后面所有层的失败都会被误诊成「标签算错了」。

### 进程里有谁

```
./program
  main (C)
    aligned_alloc 堆（本层分配了但不用）
    r = scheme_entry(heap, nbytes)   // 汇编，C ABI
    printf("%lld\n", (long long)r)   // 本层把返回值当裸整数
    return 0
```

`scheme_entry` 对 C 来说就是一个普通函数。在 Darwin/arm64 上：

- 调用方把第一参数（堆基址）放 `x0`，第二参数（字节数）放 `x1`。
- 被调用方必须保存它弄脏的 callee-saved 寄存器，最后 `ret` 时 `x0` 是返回值。
- Mach-O 要求汇编里的符号叫 `_scheme_entry`，对应 C 里的 `scheme_entry`。

本层返回值 **不打标签**。测例锁定返回 `42`，打印 `42\n`。L01 会改成 `42 << FX_SHIFT`，并改 `rt_print`。两层不要提前搅在一起。

### 汇编必须做的最小工作

1. 提供 `.globl _scheme_entry` 且 4 字节对齐（aarch64 指令对齐）。
2. 保存 `x29, x30`（帧指针与返回地址）。即使本层不用帧，Apple 崩溃栈也依赖这条链；养成习惯。
3. 把常数 `42` 写入 `x0`。aarch64 不能任意 64-bit 立即数塞进一条 `mov`：`42` 够小，`mov w0, #42` 即可。从 L01 起请改用通用的 `emit-imm`（`movz`/`movk`）。
4. 恢复 `x29, x30`，`ret`。
5. 本层可以 **不** 保存 `x19`——因为还没把 `HP` 放进去。但骨架里建议已经 `mov x19, x0` 再把它覆盖成返回值，这样 L12 只加一行而不是改序言。两种做法都合格，须在实现注释里写死你选了哪一种。

**可移植 IR（本层）**：

```
(imm 42)    ; 注意：此处 42 是裸整数，尚未打标签
```

前端可以忽略源文件，直接构造 `(imm 42)`。后端 `emit-program` 只认识这一种节点。

### 为何堆参数本层就要传入

C 侧从一开始就 `aligned_alloc`，汇编从一开始就按「`x0`=堆基址」的 ABI 进函数。若 L00 把 `scheme_entry` 定义成零参数，L12 就要改 C 原型、改所有旧测例的链接方式——违反「每层是完整系统、旧测例仍过」。所以 **C 原型本层就定死**：

```c
ptr scheme_entry(ptr *heap, uint64_t heap_nbytes);
```

汇编可以暂时不理 `x0`/`x1`。

## 与上一层的差异

没有上一层。本层从空仓库长出：编译器、runtime、驱动脚本、一个测例。

## 代码骨架

目录（芯片无关的名字；`runtime/aarch64-apple/` 是默认后端）：

```
compiler/compile.py           # 本仓库宿主：Python 3（ARCHITECTURE 允许）
backend/aarch64_apple.py     # 等价于骨架中的 aarch64-apple.scm
runtime/aarch64-apple/scheme.h
runtime/aarch64-apple/runtime.c
tests/driver.sh
tests/run-L00.sh
tests/L00/001-fixed-return.scm
tests/L00/001-fixed-return.expected
tests/L00/004-ignored-expr.scm
tests/L00/004-ignored-expr.expected
```

下面 Scheme 骨架仍是可移植合同；本仓库用 Python 实现同一套 `compile-program` / `emit-program` / `emit-imm` 接口。`001-fixed-return.scm` 内容写成字面量 `42`（L00 忽略它；L01 起解释它，输出仍是 `42`）。`004-ignored-expr.scm` 写 `(+ 1 2)`，证明前端本层不读源。

### 可移植：编译器驱动

```scheme
;; compiler/compile.scm
;; 宿主：任意能写文件的 Scheme。本层忽略 expr，固定 IR。
(load "backend/aarch64-apple.scm")

(define (compile-program expr)
  (emit-program '(imm 42)))

(define (compile-file in-path out-path)
  (call-with-output-file out-path
    (lambda (p)
      (display (compile-program 'ignored) p))))
```

把 `expr` 参数留着，是为了 L01 起真正读它。本层测例文件内容可以是空文件或注释，驱动不得依赖其内容。

### aarch64-apple：emit

```scheme
;; backend/aarch64-apple.scm
(define (emit-program ir)
  (string-append
    "\t.globl _scheme_entry\n"
    "\t.p2align 2\n"
    "_scheme_entry:\n"
    "\tstp x29, x30, [sp, #-16]!\n"
    "\tmov x29, sp\n"
    (emit-ir ir)
    "\tldp x29, x30, [sp], #16\n"
    "\tret\n"))

(define (emit-ir ir)
  (case (car ir)
    ((imm) (emit-imm (cadr ir)))
    (else (error "L00: unknown ir" ir))))

;; 本层只发小正整数；L01 换成 movz/movk 通用版
(define (emit-imm n)
  (string-append "\tmov x0, #" (number->string n) "\n"))
```

### aarch64-apple：runtime（打印裸整数）

```c
/* runtime/aarch64-apple/scheme.h */
#ifndef SCHEME_H
#define SCHEME_H
#include <stdint.h>
typedef int64_t ptr;
ptr scheme_entry(ptr *heap, uint64_t heap_nbytes);
void rt_print(ptr x);
void rt_error(const char *msg);
#endif
```

```c
/* runtime/aarch64-apple/runtime.c */
#include "scheme.h"
#include <stdio.h>
#include <stdlib.h>

void rt_error(const char *msg) {
    fprintf(stderr, "%s\n", msg);
    exit(1);
}

void rt_print(ptr x) {
    /* L00：尚未打标签，按有符号十进制打印 */
    printf("%lld\n", (long long)x);
}

int main(void) {
    size_t n = 64u * 1024u * 1024u;
    ptr *heap = aligned_alloc(8, n);
    if (!heap) rt_error("heap alloc failed");
    ptr r = scheme_entry(heap, n);
    rt_print(r);
    return 0;
}
```

`aligned_alloc` 要求 size 是 alignment 的倍数：64MiB 满足。不要用普通 `malloc` 然后假设 8 字节对齐（在 Apple 上通常对齐，但合同上不算数）。

### 驱动

```sh
#!/bin/sh
# tests/driver.sh
# 用法：./tests/driver.sh tests/L00/001-fixed-return.scm
set -e
IN="$1"
BASE=$(mktemp -d)
# 由你的宿主把 compile-file 跑起来，写出 $BASE/program.s
# 下面假设已经有 program.s
clang -arch arm64 -c runtime/aarch64-apple/runtime.c -o "$BASE/rt.o"
clang -arch arm64 -c "$BASE/program.s" -o "$BASE/prog.o"
clang -arch arm64 "$BASE/rt.o" "$BASE/prog.o" -o "$BASE/program"
"$BASE/program"
```

本仓库驱动调用 `python3 compiler/compile.py "$IN" "$BASE/program.s"`。不要在驱动里硬编码 `42`。非 Darwin arm64 宿主上驱动仍生成并检查 `program.s`，跳过 `clang -arch arm64` 链接/运行（该命令只在 Apple Silicon 真机上验收）。

## 测例清单

上一层全部测例仍须通过：无。

1. **固定返回 42**  
   输入：`tests/L00/001-fixed-return.scm`（内容为字面量 `42`；本层忽略源。空文件或 `; ignored` 同样合法）。  
   期望：标准输出恰好 `42\n`，退出码 0。文件：`001-fixed-return.expected`。

2. **可重复**  
   连续运行两次测例 1，两次输出字节级相同。排除「忘了初始化、读了栈垃圾」。由 `tests/run-L00.sh` 自动做。

3. **链接符号**  
   `nm program`（或 `nm $BASE/program`）能看到 `_scheme_entry` 与 `_main`。本测例可用手跑（`./tests/check-symbols.sh`），不强制进 `driver.sh`；在 Apple Silicon 上 `run-L00.sh` 会跑一次。

4. **错误路径尚未启用**  
   本层不要求对坏输入报错。`tests/L00/004-ignored-expr.scm` 写 `(+ 1 2)`——证明前端确实忽略内容。  
   期望：仍打印 `42\n`。

## 验收标准

- 在 Apple Silicon 上，上述测例 1、2、4 由驱动自动绿。
- `scheme_entry` 的 C 原型已是两参数，与 ARCHITECTURE 一致。
- 生成的汇编含 `.globl _scheme_entry`、`stp`/`ldp` 保存 `x29,x30`、`ret`。
- 没有在汇编里 `svc`，没有绕过 C 自己写 `main` 进汇编（允许，但不推荐；若你把 `main` 写在汇编，L01 改打印会更痛。请把 `main` 留在 C）。
- 文档中的常数 `42` 与 `.expected` 文件一致。

## 常见坑

- **少了下划线**：写成 `.globl scheme_entry` 会在链接期 `undefined symbol _scheme_entry`。Darwin 与 Linux 这里不兼容。
- **`sp` 不对齐**：`stp … [sp, #-16]!` 的 16 是必须的；写成 `#-8` 会在有的 CPU/OS 上立刻 SIGBUS。
- **用 `w0` 却不零扩展就当 64 位指针用**：本层返回 42 没问题；不要把这个习惯带进 L12 的指针。
- **在 x86 模拟器或 Rosetta 下编 arm64**：`clang -arch arm64` 在 Intel Mac 上是交叉编译，跑不了。默认合同是真机 arm64。
- **把 42 写进 `runtime.c`**：测例必须因 **汇编返回值** 而打印 42。若 `rt_print` 无视参数直接 `printf("42\n")`，L01 会全部假绿。

## 下一层预告

L01 要把返回值改成 **带 `FX_TAG` 的 fixnum**，并让 `rt_print` 右移解码后打印十进制。管道不再动。
