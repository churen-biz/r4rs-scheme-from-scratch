# 层间合同（实现者与写文档共用）

本文把 L06–L55 中容易写漂的决定钉死。各层文档必须遵守；细节仍写在该层「原理」里。

## 语言边界（全教程锁定）

- **禁止 C 源文件。** 仓库里不得出现为构建所需的 `.c` / `.h`。runtime 按后端提供纯汇编（默认 `runtime/aarch64-apple/runtime.s`）。
- `clang` / `ld` / `as` 只当汇编器与链接器驱动，绝不编译 C。
- 标签常量写在编译器与对应 `runtime.s` 注释中，数值与 ARCHITECTURE §2 一致。没有 `scheme.h`。
- 生成代码不 `svc`；`write` / `exit` / `mmap` 只属于 runtime 汇编。

## 标签（复习）

见 ARCHITECTURE.md。fixnum `<<2`；`#f=0x2F` `#t=0x6F` `()=0x3F`；char 低 8 位 `0x0F`，码点 bit[15:8]；pair `001` vector `010` string `011` box `100` symbol `101` closure `110`。

## 原语命名

算术与比较一律带 `fx` 前缀直到 L53（bignum 后才提供无前缀的 R4RS `+` 等，或让 `+` 在只有 fixnum 时转发）。L07–L08 的用户语法：

- `(fxadd1 x)` `(fxsub1 x)` `(fxneg x)` `(not x)` `(char->fixnum c)` `(fixnum->char n)`
- `(fx+ a b)` `(fx- a b)` `(fx* a b)`
- `(fx= a b)` `(fx< a b)` `(fx<= a b)` `(fx> a b)` `(fx>= a b)`
- `(eq? a b)` `(eqv? a b)` 在立即数阶段位型相等即真；L13 后 `eq?` 对 pair 是指针相等

L42 再提供 `+` `-` `*` `=` `<` 作为库或别名。测例在 L07 用 `fx+` 不是 `+`，以免与 R4RS 可变 arity 纠缠。

## `and`/`or`

L11 **展开**为 `if`，不在后端做短路指令。`and` 零个参数 → `#t`；`or` 零个 → `#f`。最后一个操作数在尾位置（为 L31 铺路：展开时保持尾）。

## 堆

- `HP` = `x19`，8 字节对齐 bump。`emit-alloc n`：对齐到 8，旧 HP 放入 `x0`（裸指针），`HP += n`。
- L12 只暴露一个测试原语 `(%alloc-bytes n)` 返回 **未标签** 的 0（或返回分配到的裸地址当 fixnum 看待——禁止，会破坏标签）。L12 更好的可观测性：`(%heap-bump-tag)` 分配 8 字节，写成 fixnum `1`，打上 PAIR_TAG，`pair?` 还没有。因此 L12 测例用 runtime 调试打印 HP 差值，或提供 `(%alloc8)` 返回 **fixnum 字节数已分配**（保存 HP0，bump 16，返回 `(HP-HP0)<<2`）。采用后者：用户可见原语 `(%heap-used)` 不强制。合同：**L12 提供 `(%bump n)`，n 为 fixnum 字节数（须正且已 8 对齐），返回带 PAIR_TAG 的指针但不保证 car/cdr 有意义**。L13 的 `cons` 建立在 `emit-alloc 16` 上。打印：L12 的 `rt_print` 对未知堆标签打印 `#<ptr>` 并允许测例只检查退出码；或 `%bump` 返回 fixnum `n` 证明 bump 发生。采用：**`(%bump n)` 返回 n 本身（fixnum），副作用是 HP += n**，另加 `(%hp-fixnum)` 把 HP 低 62 位当 fixnum 返回（仅测试）。两测例相减得 n。
- 字符串 **可变**。vector 元素槽是带标签字。

## 绑定

- L18：环境 `env` + IR `(ref id)`；用户语法仅 `(let ((x Lit)) x)`（body 必须是那个变量）。未绑定标识符编译期错。
- L19：`let` 单绑定，body 为任意表达式（含嵌套 `let`、原语）。并行语义尚无第二绑定。
- L20：多绑定 `let`，右值在绑定前全部求值（左到右），再入栈。
- L21：`let*` 展开为嵌套 `let`。
- L22：`begin`；单表达式 `begin` 恒等；空 `begin` 编译期错（R4RS 的 begin 至少在定义上下文特殊；表达式 begin 需要 ≥1 个表达式——本教程要求 ≥1）。
- L23：`set!` 对 let 绑定的变量。实现选 **可变栈槽**（当前帧内）+ 为 L26 预留 **box**：若变量被 `lambda` 捕获且被 `set!`，前端在本层可先拒绝「尚未有 lambda 的捕获」，只做栈槽。文档写死：本层盒子类型 `BOX_TAG` 实现 `(%box v)` / `(%unbox b)` / `(%set-box! b v)` 作为内部原语，`set!` 对本地变量直接 `str` 到槽；L26 捕获赋值变量时改分配 box。

## 过程

- 闭包布局：`[code-ptr][nfree:fixnum][fv0…]`，指针标签 `CLOSURE_TAG=0b110`。
- L24：无自由变量，`nfree=0`，`lambda` 出现在程序里可被 `call`。调用：(proc arg …) 的 proc 求值到闭包。
- 入口：去标签，`ldr x9, [raw]` `blr x9`；`SELF` 在 L26 才需要，L24 仍把闭包指针放 `x21` 以免 L26 改约定。
- Arity：L24 只测 0 或 1 个参数（二选一写死：**L24 允许 0 或 1 个参数**，错 arity 可先不查）。L25 多参数 + 检查：闭包或代码前再加一个 fixnum arity，或 code 槽旁。合同：code 指针指向的序言第一件事 `cmp` 传来的 `x8=argc`（用 `x8` 传 argc，不占 x0–x7）。Apple 上 `x8` 在平台 ABI 里是间接结果寄存器；本项目无 C，Scheme 内部仍用 `x8` 传 argc。文档写：`argc` 放 `x8`。
- 尾调用 L31/L32：不 `blr`，搬参数后 `br`。
- rest：L33 把多余参数 `cons` 成表。
- apply：L34 runtime 循环把表打进寄存器/栈再跳。
- values：L35 单值不分配；多值：`x0`=第一值，`x1`=剩余 list 或 值数目在 `x8` 的补码约定。合同：**`x7` 最高位不用**。采用：普通调用约定结束后 `x0`=值，若多值则 `nvalues` 在 `x9`（caller-saved），`x0…` 前几个，其余堆上 values 块。更简单且 R4RS 够用：**多值堆对象** tag 复用 vector 或专用。为少占标签：用 **list of values** + 一个「正在传多值」标志寄存器 `x22`（0=单值约定，n=值个数）。L35 写死 `x22=MV`，callee-saved，scheme_entry 置 0。`values` 设 `x22` 与 `x0…`。`call-with-values` 看 `x22`。

## Continuation

- L36：`call/cc` 只允许逃逸（向下），实现为栈指针+HP 快照，调用 continuation 时 `SP`/`HP` 复位（HP 复位会扔掉逃逸后分配的对象，本层接受；L51 再与 GC 协调）。不允许把 continuation 返回到调用方之后再调。
- L37：完整 `call/cc`：把 `[SP, FP, 栈字节拷贝, 寄存器窗口]` 做成 continuation 闭包；调用时恢复栈。可多次 invoke，可非本地返回后再 invoke（「往上」）。
- L38：测例层，实现改动应很小。
- L39：`dynamic-wind` before/after thunk 栈。

## 宏与库

- L40：`cond`/`case` 展开。
- L41：quasiquote 展开成 `cons`/`append`/`list`。
- L42：库过程用 Scheme 写，编译进程序或 runtime 预加载。
- L43：自有 reader。
- L44：`write`/`display`。
- L45：`load`。
- L46：intern 表在 runtime 汇编或后续 Scheme 里，不在 C。
- L47：`define-macro` 非卫生。
- L48–L50：`syntax-rules`。
- L51：mark-sweep，停世界。
- L52：根：寄存器、栈、全局、continuation 栈拷贝、boxes。
- L53：**bignum**（堆对象，标签可复用 vector 头里的 type 或占用未用编码）。**不实现 flonum**（范围之外写死）。
- L54/L55：清单，不是新 IR。

## 打印

pair：`(a . b)` 或适当 list 糖。L13 起 `rt_print` 认识 pair。环：L15 后可不检测直到 L44。

## 测例

每层含「上一层全部测例仍须通过」。编号从 1。含错误测例时写明编译期还是运行时。
