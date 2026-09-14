# backend/

IR 到机器码的唯一出口。默认目标 **aarch64-apple**（Apple Silicon / M3 Pro，arm64，Darwin Mach-O）。

换芯片 = 新的 `emit_*` 实现 + 一份 `runtime/<triple>/`。不要改 `compiler/` 里的 IR 形状。标签数值与 [ARCHITECTURE.md](../ARCHITECTURE.md) §2 保持一致。

---

## 默认：`aarch64-apple`

### 工具链

在 macOS 上安装 Xcode Command Line Tools 即可（`clang`、`as`、`ld` 都由 Apple LLVM/cctools 提供）：

```sh
clang --version          # Apple clang，目标 arm64-apple-darwin
xcrun --show-sdk-path
```

推荐**全程用 `clang` 驱动**汇编与链接，不要手调 `ld` 的 Mach-O 参数：

```sh
clang -arch arm64 -c runtime/aarch64-apple/runtime.c -o runtime.o
clang -arch arm64 -c program.s -o program.o
clang -arch arm64 runtime.o program.o -o program
./program
```

也可用 `as`，但 Apple `as` 实际是 LLVM：

```sh
as -arch arm64 program.s -o program.o
```

若在非 Darwin 的 aarch64 上交叉编译到苹果，本教程不覆盖；请在真机或 `aarch64-apple-darwin` SDK 上做。

### ABI 要点（Apple ARM64 ≠ 教科书 AAPCS64）

与 Procedure Call Standard for ARM 64-bit（AAPCS64）相同的部分：

- 整数/指针参数：`x0`–`x7`，多余的走栈。
- 返回值：`x0`（128 位才用 `x1`）。
- callee-saved：`x19`–`x28`；`x29` 帧指针；`x30` 链接寄存器。
- 调用点 `sp` **16 字节对齐**。
- `q0`–`q7` 传浮点；本教程 L53 选 bignum，默认用不到 SIMD 传参。

Apple 相对 Linux aarch64 的差异（写后端时必须记住）：

| 项 | aarch64-apple (Darwin) | aarch64-linux |
|----|------------------------|---------------|
| 目标格式 | Mach-O | ELF |
| C 符号 | 汇编里 `_foo` 对应 C 的 `foo` | 汇编 `foo` 即 C `foo` |
| `x18` | **保留，编译器与系统使用，禁止占用** | 一般可用（Android 除外） |
| 帧指针 | 有帧就应维护 `x29` 链，便于 Instruments/崩溃栈 | 可省略帧指针 |
| 可变参数 | 更严格的对齐；栈上 8 字节槽 | AAPCS64 |
| 系统调用 | 不要从生成代码 `svc`；走 C | 同样建议走 C |
| 链接 | `clang` + 系统 `ld`（ld64） | `gcc`/`clang` + GNU/LLVM ld |

本教程寄存器合同（与 ARCHITECTURE §5 一致）：

- `x0` = Scheme 结果 / 第一参数
- `x19` = `HP`，`x20` = `HL`，`x21` = `SELF`
- 临时 `x9`–`x15`
- 不用 `x18`

### 立即数与指令选择

aarch64 逻辑立即数与 `mov` 的 16-bit 切片限制会坑 L01：一个 64 位已标签常数往往要 `movz` + 若干 `movk`。把「把任意 u64 装进 `x0`」写成一个 `emit-imm`，所有层复用。不要每层手写不同的拆法。

函数序言/跋最小形状：

```asm
    .globl _scheme_entry
    .p2align 2
_scheme_entry:
    stp     x29, x30, [sp, #-32]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    mov     x19, x0              ; heap base from C
    add     x20, x19, x1         ; HL = base + nbytes（若第二参是 size）
    ; ... 编译体，结果在 x0 ...
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret
```

从 L26 起还要保存 `x21`。栈帧大小永远是 16 的倍数。

### 与 Linux aarch64 共享什么

指令选择、`HP` 算法、IR 都可以共享。不能共享的是：符号前缀、文件头伪指令（`.globl` 仍可用）、`x18` 策略、链接命令。若你同时维护两个 aarch64 后端，把 `emit-imm` / 算术 / 访存抽成公共模块，把 `mangle-c-name` 做成参数。

---

## 以后加 `x86_64-linux` 的清单

IR、标签、测例文件**一行都不要改**。按下列清单做：

1. **ABI**：System V AMD64。参数 `rdi, rsi, rdx, rcx, r8, r9`；返回 `rax`；callee-saved `rbx rbp r12–r15`。建议 `r12=HP`，`r13=HL`，`r14=SELF`。
2. **符号**：ELF 无下划线。`scheme_entry` 在汇编与 C 同名。
3. **汇编语法**：选 AT&T（gas）或 Intel；与 `clang -c file.s` 一致即可。
4. **栈**：调用前 `rsp` 16 字节对齐；`call` 会再压 8 字节返回地址。
5. **立即数**：64 位立即数用 `movabs`，比 aarch64 简单。
6. **runtime**：复制 `runtime/aarch64-apple/runtime.c`，删 Darwin 假设；`scheme.h` 标签数值不变。可用 `mmap`/`aligned_alloc`。
7. **驱动**：`clang -c runtime.c && clang -c program.s && clang runtime.o program.o -o program`（Linux 上默认 host 即 x86_64 时不必 `-arch`）。
8. **验收**：先让 L00–L05（立即数）全绿，再往上。

不必为本教程实现该后端；本清单用来证明架构真的可换芯片。

---

## 文件应产出什么

`backend/<triple>.scm` 实现 [ARCHITECTURE.md](../ARCHITECTURE.md) §6 的 `emit-*`。  
`runtime/<triple>/runtime.c` 实现 `main`、`rt_print`、`rt_error`，并随层增补 `gc_*`、`intern`、端口。

后端**禁止**出现：解析 Scheme 语法、做宏展开、知道 `let*` 与 `let` 的区别。那些是前端的事。
