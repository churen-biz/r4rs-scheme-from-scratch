# 层索引

按编号顺序实现。每一层结束时系统必须能跑通该层测例，并且 **L00 起到上一层的测例全部仍绿**。方法是 Ghuloum 式的：层是完整系统的快照，不是以后才粘起来的零件。

合同：[ARCHITECTURE.md](../ARCHITECTURE.md)。层间锁死的寄存器、原语名、GC/bignum 选择见 [_contract.md](_contract.md)。芯片相关只应出现在骨架里标了「aarch64-apple」的片段；求值规则与 IR 保持可移植。

**实现纪律：** 自托管阈值之前，每一层的可运行系统是手写 `.s`（加上纯汇编 runtime）。文档里的 Scheme `emit-*` / `compile.scm` 片段描述以后自托管编译器要遵守的合同。不要用 Python、Chez、Guile、Racket、Ruby 或 JavaScript 去生成汇编。胶水只有 `make` 与 `sh`。

| 层 | 文件 | 目标（一句） |
|----|------|----------------|
| L00 | [L00-pipeline.md](L00-pipeline.md) | 打通手写 `.s`→汇编→链接→运行，固定返回一个常数 |
| L01 | [L01-fixnum.md](L01-fixnum.md) | 把 fixnum 立即数打标签并打印十进制 |
| L02 | [L02-booleans.md](L02-booleans.md) | 立即数 `#t` `#f` |
| L03 | [L03-empty-list.md](L03-empty-list.md) | 立即数空表 `()` |
| L04 | [L04-char.md](L04-char.md) | 字符立即数（码点在高位，低 8 位 tag） |
| L05 | [L05-type-predicates.md](L05-type-predicates.md) | `fixnum?` `boolean?` `null?` `char?` |
| L06 | [L06-unary-primitives.md](L06-unary-primitives.md) | 一元原语：`not`、`fxadd1`、`fxsub1`、`fxneg` 等 |
| L07 | [L07-binary-arithmetic.md](L07-binary-arithmetic.md) | 二元 fixnum 算术 `fx+` `fx-` `fx*` |
| L08 | [L08-comparisons.md](L08-comparisons.md) | fixnum 比较，结果为布尔 |
| L09 | [L09-eq-eqv.md](L09-eq-eqv.md) | 立即数上的 `eq?` / `eqv?` |
| L10 | [L10-if.md](L10-if.md) | `if`，含嵌套；只有 `#f` 为假 |
| L11 | [L11-and-or.md](L11-and-or.md) | `and`/`or`：核心形式或展开成 `if` |
| L12 | [L12-bump-allocator.md](L12-bump-allocator.md) | `HP` bump 分配，尚无用户可见堆对象 |
| L13 | [L13-cons.md](L13-cons.md) | `cons` / `pair?` |
| L14 | [L14-car-cdr.md](L14-car-cdr.md) | `car` / `cdr` |
| L15 | [L15-set-car-cdr.md](L15-set-car-cdr.md) | `set-car!` / `set-cdr!` |
| L16 | [L16-basic-vector.md](L16-basic-vector.md) | `make-vector` / `vector-ref` / `vector-set!` |
| L17 | [L17-basic-string.md](L17-basic-string.md) | 可变 string 与 `string-ref` / `string-set!` |
| L18 | [L18-variable-reference.md](L18-variable-reference.md) | 环境中的变量引用（为 let 铺路） |
| L19 | [L19-let-single.md](L19-let-single.md) | 单绑定 `let` |
| L20 | [L20-let-multiple.md](L20-let-multiple.md) | 多绑定并行 `let` |
| L21 | [L21-let-star.md](L21-let-star.md) | `let*` 顺序绑定 |
| L22 | [L22-begin.md](L22-begin.md) | `begin` 顺序求值 |
| L23 | [L23-set-bang.md](L23-set-bang.md) | `set!`：盒子或可变栈槽 |
| L24 | [L24-top-level-lambda.md](L24-top-level-lambda.md) | 无自由变量的 `lambda` 与调用 |
| L25 | [L25-multi-arg-arity.md](L25-multi-arg-arity.md) | 多参数与 arity 检查策略 |
| L26 | [L26-closures.md](L26-closures.md) | 带自由变量的真闭包 |
| L27 | [L27-nested-closures.md](L27-nested-closures.md) | 嵌套闭包与返回闭包 |
| L28 | [L28-letrec-single.md](L28-letrec-single.md) | 单函数 `letrec` 递归 |
| L29 | [L29-letrec-mutual.md](L29-letrec-mutual.md) | 互递归 `letrec` |
| L30 | [L30-internal-define.md](L30-internal-define.md) | 内部 `define` 变换为 `letrec` |
| L31 | [L31-self-tail-calls.md](L31-self-tail-calls.md) | 同一过程的尾调用不涨栈 |
| L32 | [L32-cross-tail-calls.md](L32-cross-tail-calls.md) | 跨过程 / 互递归尾调用 |
| L33 | [L33-rest-args.md](L33-rest-args.md) | rest 参数（`.` / `#!rest`） |
| L34 | [L34-apply.md](L34-apply.md) | `apply` |
| L35 | [L35-values.md](L35-values.md) | `values` 与 `call-with-values` |
| L36 | [L36-escape-continuations.md](L36-escape-continuations.md) | 只向下逃逸的 continuation |
| L37 | [L37-full-call-cc.md](L37-full-call-cc.md) | 可多次调用、可向上返回的 `call/cc` |
| L38 | [L38-call-cc-interaction.md](L38-call-cc-interaction.md) | continuation × 闭包 × `set!` 交互 |
| L39 | [L39-dynamic-wind.md](L39-dynamic-wind.md) | `dynamic-wind` 与 R4RS 进出规则 |
| L40 | [L40-cond-case.md](L40-cond-case.md) | `cond` / `case` 宏或展开器 |
| L41 | [L41-quasiquote.md](L41-quasiquote.md) | quasiquote / unquote / splicing |
| L42 | [L42-core-library.md](L42-core-library.md) | `list` `length` `map` `append` 等核心库 |
| L43 | [L43-reader.md](L43-reader.md) | 从端口读入 datum |
| L44 | [L44-writer.md](L44-writer.md) | `write` / `display` |
| L45 | [L45-load.md](L45-load.md) | `load` 与多文件程序 |
| L46 | [L46-symbols.md](L46-symbols.md) | intern、`string->symbol`、`eq?` 符号 |
| L47 | [L47-unhygienic-macros.md](L47-unhygienic-macros.md) | 非卫生 `define-macro` 垫脚石 |
| L48 | [L48-syntax-rules.md](L48-syntax-rules.md) | `syntax-rules` 基础 |
| L49 | [L49-hygiene.md](L49-hygiene.md) | 卫生与遮蔽测例 |
| L50 | [L50-rich-patterns.md](L50-rich-patterns.md) | 递归宏与更丰富模式 |
| L51 | [L51-mark-sweep-gc.md](L51-mark-sweep-gc.md) | 停世界标记-清扫 |
| L52 | [L52-gc-roots.md](L52-gc-roots.md) | 根集：赋值、栈、continuation |
| L53 | [L53-numeric-tower.md](L53-numeric-tower.md) | 数值塔：引入 bignum；浮点不在本层 |
| L54 | [L54-r4rs-library-gap.md](L54-r4rs-library-gap.md) | 对照 R4RS 的库缺口清单 |
| L55 | [L55-scheme-final.md](L55-scheme-final.md) | 符合性清单与第三方小程序验收 |

层文档内部结构统一，见 [CONTRIBUTING.md](../CONTRIBUTING.md)。
