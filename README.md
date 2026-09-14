# r4rs-scheme-from-scratch

从零、按层、每层都是**完整可运行系统**：做一个逼近 [R4RS](https://people.csail.mit.edu/jaffer/r4rs.html) 的 Scheme。方法来自 Abdulaziz Ghuloum 的 *An Incremental Approach to Compiler Construction*——不是先写完前端再碰机器，而是 **L00 就能 generate → assemble → link → run**，以后每一层只在可测的系统上长一块能力。

- **默认机器**：`aarch64-apple`（Apple Silicon / M3 Pro）
- **架构**：芯片无关 IR + 可替换 [`backend/`](backend/README.md) 与 `runtime/`；换到 `x86_64-linux` 主要是加后端，不是重写各层
- **语言**：叙述用简体中文；标识符、Scheme 形式、汇编助记符、路径与代码保持英文
- **许可**：[MIT License](LICENSE)

本仓库以教程文档为主，并从 L00 起收录参考实现。文档与现实冲突时按 [CONTRIBUTING.md](CONTRIBUTING.md) 反馈，修订文档。

## 怎么读

1. 读 [ARCHITECTURE.md](ARCHITECTURE.md)：标签、IR、调用约定、`emit_*`、运行时边界。这是全层合同。
2. 读 [backend/README.md](backend/README.md)：Apple ARM64 ABI、在 macOS 上如何调用汇编器/链接器。
3. 按 [layers/README.md](layers/README.md) **严格从 L00 往上**。不要跳层：每一层都假设上一层的测例仍绿。
4. 打开当前层文档，按八节结构做：弄懂原理 → 填骨架 → 写测例 → 对照验收标准。
5. 卡住时先看该层「常见坑」，再看 ARCHITECTURE 对应节。层间锁死的细节另见 [layers/_contract.md](layers/_contract.md)。

每一层文档路径：`layers/Lxx-<slug>.md`，结构固定为：目标、原理、与上一层的差异、代码骨架、测例清单、验收标准、常见坑、下一层预告。

## 前置条件

默认目标机是 **macOS + Apple Silicon**：

| 工具 | 用途 | 安装 |
|------|------|------|
| `clang` | 编译 `runtime.c`、汇编 `.s`、链接 | Xcode Command Line Tools：`xcode-select --install` |
| `as` / `ld` | 一般不必直接调用；由 `clang` 驱动 | 同上 |
| 宿主 Scheme 或 Python 3 | 写编译器（把 Scheme/IR 变成汇编文本） | Chez / Guile / Racket，或系统自带 `python3` |
| `diff` / 一个 shell | 测试驱动 | 系统自带 |

确认：

```sh
uname -m          # 期望 arm64
clang --version   # Apple clang
```

在 x86_64 Mac 或 Linux 上可以读文档，但**默认测例与骨架按 aarch64-apple 写**。换芯片见 ARCHITECTURE §9 与 backend README 末尾清单。

不需要预先会写汇编：L00 会把「最小可链接程序」摊开。需要会：在编辑器里改 Scheme/C、在终端跑命令、读一段寄存器约定。

## Running L00

本仓库 L00 参考实现：Python 3 编译器 + `runtime/aarch64-apple` + `tests/driver.sh`。在 **Apple Silicon（M3 等）** 上：

```sh
uname -m          # arm64
make test-L00     # 或 ./tests/run-L00.sh
```

单测例：

```sh
./tests/driver.sh tests/L00/001-fixed-return.scm
# 标准输出恰好：
# 42
```

`004-ignored-expr.scm` 内容是 `(+ 1 2)`，L00 仍打印 `42`（前端忽略源）。连续跑两次 `001` 的 stdout 必须字节级相同。

链接符号（验收测例 3，可手跑）：

```sh
python3 compiler/compile.py tests/L00/001-fixed-return.scm /tmp/program.s
clang -arch arm64 -c runtime/aarch64-apple/runtime.c -o /tmp/rt.o
clang -arch arm64 -c /tmp/program.s -o /tmp/prog.o
clang -arch arm64 /tmp/rt.o /tmp/prog.o -o /tmp/program
nm /tmp/program | grep -E '_scheme_entry|_main'
./tests/check-symbols.sh /tmp/program
```

`nm` 应看到 `_scheme_entry` 与 `_main`。Linux / 非 Darwin 上 `make test-L00` 仍检查生成的汇编合同，但无法执行 Mach-O arm64 二进制。

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
| L00 | [pipeline](layers/L00-pipeline.md) | 空/固定返回；打通 generate→assemble→link→run |
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
ARCHITECTURE.md        IR、标签、ABI 抽象、后端接口
CONTRIBUTING.md        文档修订与测例命名
LICENSE                MIT
Makefile               make test-L00
compiler/compile.py    L00 编译驱动（Python 3；忽略源，IR 为 (imm 42)）
backend/README.md      aarch64-apple 细节；x86_64-linux 清单
backend/aarch64_apple.py  L00 emit（.globl _scheme_entry，裸 42）
runtime/aarch64-apple/ scheme.h + runtime.c（C ABI 两参数堆，rt_print 裸整数）
tests/driver.sh        编译 →（Darwin arm64）汇编/链接/运行 → 比对 .expected
tests/run-L00.sh       L00 全套测例
layers/README.md       层索引
layers/_contract.md    层间锁死的编码与 ABI 细节
layers/Lxx-*.md        每一层的独立教程
```

L00 起仓库内带参考实现。更高层仍按 `layers/` 增量往上长。

## 参考

- Abdulaziz Ghuloum, *An Incremental Approach to Compiler Construction*（Scheme Workshop 2006）
- IEEE Std 1178-1990 / R4RS
- ARM AAPCS64 与 Apple ARM64 调用约定（见 backend README）
