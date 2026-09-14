# L00 — 管道：空程序 / 固定返回

## 目标

打通 **generate → assemble → link → run** 整条出口。本层还没有 Scheme 语法、没有标签、没有堆上的 Scheme 对象。编译器读入一个（可忽略的）输入，**永远生成同一段汇编**：`_scheme_entry` 把一个约定好的整数放进 `x0`，然后 `ret` 回 runtime。runtime 是 **纯汇编**：进程入口、`mmap` 堆、用 `write` 系统调用打印返回值、再用 `exit` 退出。

**合同：从 L00 起，本仓库不允许任何 `.c` / `.h`。** `clang` / `ld` 只当汇编器与链接器驱动，绝不编译 C 源文件。Ghuloum 原文的 `runtime.c` 在本教程里被 `runtime/aarch64-apple/runtime.s` 取代。

做完本层，你必须能在 aarch64-apple 上一条命令跑出 `42`。以后每一层只替换 `_scheme_entry` 的函数体和 `_rt_print` 的解码规则，**不再重新发明**链接方式。

本层范围之外：fixnum 标签、任何 Scheme 读入、错误处理策略以外的报错、栈上 Scheme 帧。输入文件可以存在但不解释。堆在本层分配了但 `_scheme_entry` 还不 bump。

## 原理

Ghuloum 方法的第一刀不是「词法分析器」，而是 **证明工具链听你的话**。若 L00 在链接符号、对齐、寄存器保存上是错的，后面所有层的失败都会被误诊成「标签算错了」。

### 进程里有谁

```
./program
  _main          (runtime.s)
    mmap 64MiB 匿名页（本层分配了但不用）
    x0 = 堆基址，x1 = 字节数
    bl _scheme_entry          // 编译器生成的 program.s
    bl _rt_print              // 把 x0 当有符号十进制，write(1, …)
    SYS_exit(0)
```

`_scheme_entry` 对 runtime 来说就是一个普通函数，遵守 **Darwin/ARM64 整数调用约定**（参数 `x0`–`x7`，返回值 `x0`，callee-saved `x19`–`x28`，`x29`/`x30` 帧）。这与 AAPCS64 的整数部分相同，但这里没有 C 语言、没有 C 原型。

在 Darwin/arm64 上：

- 调用方把第一参数（堆基址）放 `x0`，第二参数（字节数）放 `x1`。
- 被调用方必须保存它弄脏的 callee-saved 寄存器，最后 `ret` 时 `x0` 是返回值。
- Mach-O 要求汇编里的符号带下划线：`_scheme_entry`、`_main`、`_rt_print`。

本层返回值 **不打标签**。测例锁定返回 `42`，打印 `42\n`。L01 会改成 `42 << FX_SHIFT`，并改 `_rt_print`。两层不要提前搅在一起。

### Darwin/arm64 系统调用（本层锁定）

XNU 用户态约定：

| 项 | 值 |
|----|----|
| 系统调用号 | `x16` |
| 参数 | `x0`–`x7` |
| 陷入 | `svc #0x80` |
| 成功 | 进位清、结果在 `x0` |
| 失败 | 进位置位、`x0` 为 errno |

本层用到的编号（`bsd/kern/syscalls.master`）：

| 名字 | 号 | 用途 |
|------|----|------|
| `SYS_exit` | 1 | 进程退出 |
| `SYS_write` | 4 | `write(fd, buf, nbyte)`：打印与报错 |
| `SYS_mmap` | 197 | 分配堆 |

`mmap` 参数：`addr=0`，`len=64MiB`，`prot=PROT_READ\|PROT_WRITE=3`，`flags=MAP_ANON\|MAP_PRIVATE=0x1002`，`fd=-1`，`offset=0`（64 位 `off_t` 在 `x5`）。

**禁止**在编译器生成的 `program.s` 里 `svc`。I/O 与堆分配只属于 runtime。

### 汇编必须做的最小工作（`_scheme_entry`）

1. 提供 `.globl _scheme_entry` 且 4 字节对齐（aarch64 指令对齐）。
2. 保存 `x29, x30`（帧指针与返回地址）。即使本层不用帧，Apple 崩溃栈也依赖这条链；养成习惯。
3. 把常数 `42` 写入 `x0`。aarch64 不能任意 64-bit 立即数塞进一条 `mov`：`42` 够小，`mov x0, #42` 即可。从 L01 起请改用通用的 `emit-imm`（`movz`/`movk`）。
4. 恢复 `x29, x30`，`ret`。
5. 本层可以 **不** 保存 `x19`——因为还没把 `HP` 放进去。但骨架里建议已经 `mov x19, x0` 再把它覆盖成返回值，这样 L12 只加一行而不是改序言。两种做法都合格，须在实现注释里写死你选了哪一种。本仓库参考实现选「本层只保存 `x29`/`x30`」。

**可移植 IR（本层）**：

```
(imm 42)    ; 注意：此处 42 是裸整数，尚未打标签
```

前端可以忽略源文件，直接构造 `(imm 42)`。后端 `emit-program` 只认识这一种节点。

### 为何堆参数本层就要传入

runtime 从一开始就 `mmap`，`_scheme_entry` 从一开始就按「`x0`=堆基址」进函数。若 L00 把入口定义成零参数，L12 就要改调用约定、改所有旧测例的链接方式——违反「每层是完整系统、旧测例仍过」。所以 **两参数入口本层就定死**：

```
_scheme_entry(x0 = heap_base, x1 = heap_nbytes) -> x0 = result
```

汇编可以暂时不理 `x0`/`x1`。

### 打印约定（L00）

`_rt_print`（runtime.s）：

- 入口：`x0` = 返回值，按 **有符号 64 位整数** 解释（尚未打标签）。
- 把十进制 ASCII（可带前导 `-`）和末尾 `\n` 写到 fd 1（`SYS_write`）。
- 不得把 `42` 写死在 runtime。测例必须因 `_scheme_entry` 的返回值而打印 42。
- 本层不必识别标签；未知编码也按裸整数打印。L01 起未知标签应报错。

## 与上一层的差异

没有上一层。本层从空仓库长出：编译器、纯汇编 runtime、驱动脚本、一个测例。

## 代码骨架

目录（芯片无关的名字；`runtime/aarch64-apple/` 是默认后端）：

```
compiler/compile.py            ; 或 compile.scm；本仓库用 Python 3
backend/aarch64_apple.py      ; 或 aarch64-apple.scm
runtime/aarch64-apple/runtime.s
tests/driver.sh
tests/L00/001-fixed-return.scm
tests/L00/001-fixed-return.expected
```

没有 `runtime.c`，没有 `scheme.h`。标签常量以后写在编译器与 `runtime.s` 顶部注释，数值必须相同。

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

本仓库参考实现是等价的 Python 3：`compiler/compile.py`。把 `expr` 参数留着，是为了 L01 起真正读它。本层测例文件内容可以是空文件、注释、或 `(+ 1 2)`，驱动不得依赖其内容。

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

### aarch64-apple：runtime（纯汇编）

进程入口 `_main`、堆、打印、退出都在 `runtime.s`。逻辑骨架：

```asm
        .text
        .globl  _main
        .globl  _rt_print
        .p2align 2

_main:
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        // mmap(0, 1<<26, PROT_READ|PROT_WRITE, MAP_ANON|MAP_PRIVATE, -1, 0)
        mov     x0, #0
        mov     x1, #1
        lsl     x1, x1, #26
        mov     x2, #3
        mov     x3, #0x1002
        mov     x4, #-1
        mov     x5, #0
        mov     x16, #197            // SYS_mmap
        svc     #0x80
        b.cs    .Lmmap_fail
        mov     x1, #1
        lsl     x1, x1, #26
        bl      _scheme_entry
        bl      _rt_print
        mov     x0, #0
        mov     x16, #1              // SYS_exit
        svc     #0x80
```

`_rt_print`：把 `x0` 转成十进制字节，`mov x16, #4` / `svc #0x80` 写到 stdout。不要调用 `printf`。

堆对齐：`mmap` 返回页对齐（Apple Silicon 上通常 16KiB），强于 8 字节。64MiB = `1<<26`，是 8 的倍数。不要改成「假设某处已有一块 `.bss`」除非你在实现注释里写死并同样把基址/长度传入 `_scheme_entry`；本教程锁定 **mmap**。

### 驱动

```sh
#!/bin/sh
# tests/driver.sh
# 用法：./tests/driver.sh tests/L00/001-fixed-return.scm
set -e
IN="$1"
BASE=$(mktemp -d)
# 由你的宿主把 compile-file 跑起来，写出 $BASE/program.s
clang -arch arm64 -c runtime/aarch64-apple/runtime.s -o "$BASE/rt.o"
clang -arch arm64 -c "$BASE/program.s" -o "$BASE/prog.o"
clang -arch arm64 "$BASE/rt.o" "$BASE/prog.o" -o "$BASE/program"
"$BASE/program"
```

也可以一步：`clang -arch arm64 runtime/aarch64-apple/runtime.s "$BASE/program.s" -o "$BASE/program"`。两条命令都只吃 `.s`。不要出现 `runtime.c`。

把实际「调用宿主编译器」的一行按你选的 Chez/Guile/Python 补上。不要在驱动里硬编码 `42`。

## 测例清单

上一层全部测例仍须通过：无。

1. **固定返回 42**  
   输入：任意（空文件、`; ignored`、或字面量 `42`）。  
   期望：标准输出恰好 `42\n`，退出码 0。

2. **可重复**  
   连续运行两次测例 1，两次输出字节级相同。排除「忘了初始化、读了栈垃圾」。

3. **链接符号**  
   `nm program` 能看到 `_scheme_entry` 与 `_main`。本测例可用手跑，不强制进驱动；但验收时必须做过一次。

4. **错误路径尚未启用**  
   本层不要求对坏输入报错。把「空输入」与「文件里写了 `(+ 1 2)`」都当测例 1 的合法输入——证明前端确实忽略内容。  
   期望：仍打印 `42\n`。

## 验收标准

- 在 Apple Silicon 上，上述测例 1、2、4 由驱动自动绿。
- `_scheme_entry` 已是两参数入口（`x0` 堆基址、`x1` 字节数），与 ARCHITECTURE 一致。
- 生成的汇编含 `.globl _scheme_entry`、`stp`/`ldp` 保存 `x29,x30`、`ret`。
- **生成代码里没有 `svc`。** runtime 里的 `svc` 是允许的，也是必须的。
- 仓库中 **没有** 为构建 L00 所需的 `.c` / `.h`。
- 文档中的常数 `42` 与 `.expected` 文件一致。
- `_rt_print` 不写死 42。

## 常见坑

- **少了下划线**：写成 `.globl scheme_entry` 会在链接期 `undefined symbol _scheme_entry`。Darwin 与 Linux 这里不兼容。
- **`sp` 不对齐**：`stp … [sp, #-16]!` 的 16 是必须的；写成 `#-8` 会在有的 CPU/OS 上立刻 SIGBUS。
- **用 `w0` 却不零扩展就当 64 位指针用**：本层返回 42 没问题；不要把这个习惯带进 L12 的指针。
- **在 x86 模拟器或 Rosetta 下编 arm64**：`clang -arch arm64` 在 Intel Mac 上是交叉编译，跑不了。默认合同是真机 arm64。
- **把 42 写进 `runtime.s` 的打印路径**：测例必须因 **汇编返回值** 而打印 42。若 `_rt_print` 无视参数直接 `write` 固定串 `42\n`，L01 会全部假绿。
- **在生成代码里 `svc`**：管道会被「自己打印自己退出」绕开，L01 改 `_rt_print` 时测例仍绿、语义已断。
- **误加回 `runtime.c`**：即使用 `clang` 只链 `.o`，只要构建仍编译 `.c`，就违反本层合同。
- **mmap 失败不看进位**：Darwin 用进位表示 syscall 错，不像 Linux 用负 errno。用 `b.cs` 走 `_rt_error`。

## 在 Apple Silicon（M3 等）上跑

```sh
uname -m          # arm64
make test-L00     # 或 ./tests/run-L00.sh
```

单测例：

```sh
./tests/driver.sh tests/L00/001-fixed-return.scm
# stdout: 42
./tests/driver.sh tests/L00/004-ignored-expr.scm
# 输入是 (+ 1 2)；stdout 仍是 42
```

手链：

```sh
python3 compiler/compile.py tests/L00/001-fixed-return.scm /tmp/program.s
clang -arch arm64 runtime/aarch64-apple/runtime.s /tmp/program.s -o /tmp/program
nm /tmp/program | grep -E '_scheme_entry|_main'
/tmp/program
# 42
```

非 Darwin / 非 arm64 的机器（包括本教程的 Linux CI）只跑宿主无关的 emit 检查，不执行 Mach-O。源文件仍按 Darwin/arm64 写。

## 下一层预告

L01 要把返回值改成 **带 `FX_TAG` 的 fixnum**，并让 `_rt_print` 算术右移解码后打印十进制。管道与「只链 `.s`」不再动。
