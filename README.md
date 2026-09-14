# r4rs-scheme-from-scratch

从零、按层、每层都是**完整可运行系统**：做一个逼近 [R4RS](https://people.csail.mit.edu/jaffer/r4rs.html) 的 Scheme。方法来自 Abdulaziz Ghuloum 的 *An Incremental Approach to Compiler Construction*——不是先写完前端再碰机器，而是 **L00 就能 assemble → link → run**，以后每一层只在可测的系统上长一块能力。

- **默认机器**：`aarch64-apple`（Apple Silicon / M3 Pro）
- **架构**：芯片无关 IR + 可替换 [`backend/`](backend/README.md) 与 `runtime/`；换到 `x86_64-linux` 主要是加后端，不是重写各层
- **语言**：叙述用简体中文；标识符、Scheme 形式、汇编助记符、路径与代码保持英文
- **许可**：[MIT License](LICENSE)

**先读 CPU 手册：** 在这颗机器上手写 Darwin/arm64 汇编之前，请先读 [docs/aarch64-apple-cpu-manual.md](docs/aarch64-apple-cpu-manual.md)（寄存器锁、栈对齐、syscall、与 Scheme 运行时的接缝）。层文档默认你已经知道这些。

本仓库以教程文档为主，并附 L00 参考实现（**手写** Darwin/arm64 汇编 + 纯汇编 runtime）。文档与现实冲突时按 [CONTRIBUTING.md](CONTRIBUTING.md) 反馈，修订文档。

## 语言与工具边界（全仓库锁定）

1. **禁止 Python。** 仓库里不得出现 `.py`、`__pycache__`，也不得用 Python 生成汇编。
2. **禁止 C。** 不得出现为构建所需的 `.c` / `.h`。`clang` / `ld` 只当汇编器与链接器驱动。
3. **禁止用其它脚本语言当编译器。** 不得用 Ruby / JavaScript / Perl / Lua 等 emit 汇编。
4. **允许的胶水只有** `Makefile` 与 shell：汇编、链接、运行、比对期望输出。
5. **早期层（尚未自托管）**：所谓「编译器」就是检入仓库的手写 Darwin/arm64 `.s`。
6. **自托管阈值之后**：编译器用本教程的 Scheme 子集写；在那之前不要引入任何高级语言代码生成器。

## 怎么读

1. **先读 CPU 手册**：[docs/aarch64-apple-cpu-manual.md](docs/aarch64-apple-cpu-manual.md) — 默认机器 Apple M3 Pro / Darwin arm64 上的执行模型、寄存器、栈、指令速查与调试。
2. 读 [ARCHITECTURE.md](ARCHITECTURE.md)：标签、IR、调用约定、`emit_*`（自托管后的合同）、运行时边界。这是全层合同。
3. 读 [backend/README.md](backend/README.md)：Apple ARM64 ABI、在 macOS 上如何调用汇编器/链接器。
4. 按 [layers/README.md](layers/README.md) **严格从 L00 往上**。不要跳层：每一层都假设上一层的测例仍绿。
5. 打开当前层文档，按八节结构做：弄懂原理 → 改手写 `.s`（或自托管后改 Scheme 编译器）→ 写测例 → 对照验收标准。
6. 卡住时先看该层「常见坑」，再看 ARCHITECTURE 对应节。层间锁死的细节另见 [layers/_contract.md](layers/_contract.md)。

每一层文档路径：`layers/Lxx-<slug>.md`，结构固定为：目标、原理、与上一层的差异、代码骨架、测例清单、验收标准、常见坑、下一层预告。

## 前置条件

默认目标机是 **macOS + Apple Silicon**：

| 工具 | 用途 | 安装 |
|------|------|------|
| `clang` | **只**汇编 `.s`、链接 `.o`；不编译任何 `.c` | Xcode Command Line Tools：`xcode-select --install` |
| `as` / `ld` | 一般不必直接调用；由 `clang` 驱动 | 同上 |
| `make` / `sh` / `diff` / `grep` / `nm` | 胶水与测例 | 系统自带 |

**不需要** Python、Chez、Guile、Racket，也不需要任何会 emit 汇编的宿主编译器。早期层用手写 `.s`。

确认：

```sh
uname -m          # 期望 arm64
clang --version   # Apple clang
make test-L00     # Apple Silicon 上 stdout 含 42
```

在 x86_64 Mac 或 Linux 上可以读文档并跑政策检查（无 `.py` / 无 `.c`、汇编合同），但**不能执行 Mach-O**。默认测例与骨架按 aarch64-apple 写。换芯片见 ARCHITECTURE §9 与 backend README 末尾清单。

不需要预先会写很多汇编：L00 会把「最小可链接程序」摊开。需要会：在编辑器里改 `.s`、在终端跑 `make`、读一段寄存器约定。runtime 是纯汇编（syscalls / mmap）。

## 反馈循环

```
实现当前层  →  跑该层测例 + 全部旧测例  →  绿则进入下一层
         ↘ 红：是实现错还是文档错？
            实现错 → 修代码
            文档错 → 按 CONTRIBUTING 改文档或开 issue，再跑测例
```

教程故意写细早期层（L00–L12），让标签、堆指针、`if` 的假值规则这些「后面全靠它」的决定一次做对。若你发现某句会导致两种合理实现，把它写进文档——合同必须唯一。

## 路线图

分组与 R4RS 能力大致对应。链接进具体层文档。

### A. 立即数与出口

| 层 | 文档 | 一句话 |
|----|------|--------|
| L00 | [pipeline](layers/L00-pipeline.md) | 空/固定返回；打通 assemble→link→run |
| L01 | [fixnum](layers/L01-fixnum.md) | 定点数立即数与打标签 |
| L02 | [booleans](layers/L02-booleans.md) | `#t` `#f` |
| L03 | [empty-list](layers/L03-empty-list.md) | 空表 `()` |
| L04 | [char](layers/L04-char.md) | 字符立即数 |
| L05 | [type-predicates](layers/L05-type-predicates.md) | `fixnum?` `boolean?` `null?` `char?` |

### B. 原语与控制（无变量）

| 层 | 文档 | 一句话 |
|----|------|--------|
| L06 | [unary-primitives](layers/L06-unary-primitives.md) | 一元原语：`not`、`fxadd1`、`fxneg` 等 |
| L07 | [binary-arithmetic](layers/L07-binary-arithmetic.md) | 二元算术 `fx+` `fx-` `fx*` |
| L08 | [comparisons](layers/L08-comparisons.md) | `fx=` `fx<` `fx<=` 等 |
| L09 | [eq-eqv](layers/L09-eq-eqv.md) | 立即数上的 `eq?` / `eqv?` |
| L10 | [if](layers/L10-if.md) | `if`（含嵌套） |
| L11 | [and-or](layers/L11-and-or.md) | `and` / `or`（展开成 `if`） |

### C. 堆（无 GC）

| 层 | 文档 | 一句话 |
|----|------|--------|
| L12 | [bump-allocator](layers/L12-bump-allocator.md) | bump 分配器与堆指针约定 |
| L13 | [cons](layers/L13-cons.md) | `cons` / `pair?` |
| L14 | [car-cdr](layers/L14-car-cdr.md) | `car` / `cdr` |
| L15 | [set-car-cdr](layers/L15-set-car-cdr.md) | `set-car!` / `set-cdr!` |
| L16 | [basic-vector](layers/L16-basic-vector.md) | 基本 vector |
| L17 | [basic-string](layers/L17-basic-string.md) | 基本 string（可变，与 R4RS 一致） |

### D. 绑定与环境

| 层 | 文档 | 一句话 |
|----|------|--------|
| L18 | [variable-reference](layers/L18-variable-reference.md) | 变量引用 |
| L19 | [let-single](layers/L19-let-single.md) | 单绑定 `let` |
| L20 | [let-multiple](layers/L20-let-multiple.md) | 多绑定 `let` |
| L21 | [let-star](layers/L21-let-star.md) | `let*` |
| L22 | [begin](layers/L22-begin.md) | `begin` / 顺序求值 |
| L23 | [set-bang](layers/L23-set-bang.md) | `set!`（赋值转换 / 盒子） |

### E. 过程

| 层 | 文档 | 一句话 |
|----|------|--------|
| L24 | [top-level-lambda](layers/L24-top-level-lambda.md) | 顶层 `lambda` + 调用（无自由变量） |
| L25 | [multi-arg-arity](layers/L25-multi-arg-arity.md) | 多参数与 arity 策略 |
| L26 | [closures](layers/L26-closures.md) | 真闭包（自由变量） |
| L27 | [nested-closures](layers/L27-nested-closures.md) | 嵌套 / 返回闭包 |
| L28 | [letrec-single](layers/L28-letrec-single.md) | `letrec` 单递归 |
| L29 | [letrec-mutual](layers/L29-letrec-mutual.md) | `letrec` 互递归 |
| L30 | [internal-define](layers/L30-internal-define.md) | 内部 `define` → `letrec` |

### F. 调用约定升级

| 层 | 文档 | 一句话 |
|----|------|--------|
| L31 | [self-tail-calls](layers/L31-self-tail-calls.md) | 自尾调用 |
| L32 | [cross-tail-calls](layers/L32-cross-tail-calls.md) | 跨过程 / 互递归尾调用 |
| L33 | [rest-args](layers/L33-rest-args.md) | rest 参数 |
| L34 | [apply](layers/L34-apply.md) | `apply` |
| L35 | [values](layers/L35-values.md) | `values` / `call-with-values` |

### G. Continuation

| 层 | 文档 | 一句话 |
|----|------|--------|
| L36 | [escape-continuations](layers/L36-escape-continuations.md) | 仅逃逸 continuation |
| L37 | [full-call-cc](layers/L37-full-call-cc.md) | 完整 `call/cc` |
| L38 | [call-cc-interaction](layers/L38-call-cc-interaction.md) | `call/cc` + 闭包 + 赋值交互测例 |
| L39 | [dynamic-wind](layers/L39-dynamic-wind.md) | `dynamic-wind`（对齐 R4RS） |

### H. 语法与库

| 层 | 文档 | 一句话 |
|----|------|--------|
| L40 | [cond-case](layers/L40-cond-case.md) | `cond` / `case` 展开（含 `=>`） |
| L41 | [quasiquote](layers/L41-quasiquote.md) | quasiquote |
| L42 | [core-library](layers/L42-core-library.md) | 核心库：`list` `length` `map` `append` … |
| L43 | [reader](layers/L43-reader.md) | reader |
| L44 | [writer](layers/L44-writer.md) | writer / `display` `write` |
| L45 | [load](layers/L45-load.md) | `load` + 多文件 |
| L46 | [symbols](layers/L46-symbols.md) | 符号 / intern / `string->symbol` |

### I. 宏

| 层 | 文档 | 一句话 |
|----|------|--------|
| L47 | [unhygienic-macros](layers/L47-unhygienic-macros.md) | 可选的非卫生宏垫脚石 |
| L48 | [syntax-rules](layers/L48-syntax-rules.md) | `syntax-rules` 基础 |
| L49 | [hygiene](layers/L49-hygiene.md) | 卫生 / 遮蔽测例 |
| L50 | [rich-patterns](layers/L50-rich-patterns.md) | 递归与更丰富的模式 |

### J. 运行时硬化 → R4RS

| 层 | 文档 | 一句话 |
|----|------|--------|
| L51 | [mark-sweep-gc](layers/L51-mark-sweep-gc.md) | 停世界标记-压缩 GC |
| L52 | [gc-roots](layers/L52-gc-roots.md) | 赋值 + continuation 下的 GC 根 |
| L53 | [numeric-tower](layers/L53-numeric-tower.md) | 数值塔下一步：bignum（本文选择；不做浮点） |
| L54 | [r4rs-library-gap](layers/L54-r4rs-library-gap.md) | R4RS 库缺口清单 |
| L55 | [scheme-final](layers/L55-scheme-final.md) | 符合性清单 + 第三方小程序验收 |

## 仓库里有什么

```
README.md              本文件
docs/aarch64-apple-cpu-manual.md  默认机器 CPU / 汇编操作手册（先读）
ARCHITECTURE.md        IR、标签、ABI 抽象、后端接口
CONTRIBUTING.md        文档修订与测例命名
LICENSE                MIT
Makefile               make test-L00（只调 shell）
compiler/scheme_entry.s  L00 手写 _scheme_entry（返回未打标签的 42）
backend/README.md      aarch64-apple 细节；x86_64-linux 清单
runtime/aarch64-apple/runtime.s   纯汇编 runtime（mmap / write / exit）
tests/driver.sh        只汇编、只链接 .s
tests/test_no_python.sh  有 .py 则失败
layers/README.md       层索引
layers/_contract.md    层间锁死的编码与 ABI 细节
layers/Lxx-*.md        每一层的独立教程
```

L00 参考实现在 `compiler/scheme_entry.s`、`runtime/aarch64-apple/runtime.s`、`tests/`。更高层仍按文档实现：自托管前继续改手写 `.s`，自托管后才出现 Scheme 编译器源。runtime 必须是汇编，不得引入 C 或 Python。

## 参考

- Abdulaziz Ghuloum, *An Incremental Approach to Compiler Construction*（Scheme Workshop 2006）
- IEEE Std 1178-1990 / R4RS
- ARM AAPCS64 与 Apple ARM64 调用约定（见 backend README）
