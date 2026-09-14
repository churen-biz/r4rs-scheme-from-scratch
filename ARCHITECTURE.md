# 架构

本文是全教程的**唯一设计合同**。各层文档默认遵守这里的标签、IR、调用约定与目录划分。若某层必须偏离，须在该层「原理」中显式声明，并说明何时回到本合同。

读者实现时：先读本文件，再按 `layers/` 顺序做。自托管前改手写 `.s` 与 `runtime/`；换芯片时只换对应汇编，不改 IR 与各层求值规则。

---

## 1. 系统切分

一条 Scheme 表达式从源文本到进程退出，在**自托管之后**经过四段芯片无关代码和两段芯片相关代码：

```
源文本
  → [reader]        芯片无关  L43 才必须
  → [expand]        芯片无关  宏、derived syntax → 核心形式
  → [ir-lower]      芯片无关  核心形式 → IR
  → [backend/emit]  芯片相关  IR → 汇编文本（自托管编译器发出）
  → [assemble/link] 芯片相关  汇编 + runtime → 可执行文件
  → [run]           运行时    入口进入 scheme_entry，打印结果
```

**自托管阈值之前**没有「用高级语言 emit 汇编」这一步。每一层的可运行系统是：

```
手写 Darwin/arm64 .s（scheme_entry + 随层增长的代码）
  + runtime/*.s
  → Makefile/sh 汇编、链接、运行、比对
```

层文档里的 Scheme `emit-*` 骨架是**合同与以后自托管编译器的形状**，不是现在去用 Chez / Guile / Python / Ruby / JS 实现的许可证。

目录（L00 已存在；更高层逐步长出）：

```
compiler/
  scheme_entry.s       ; 早期层：手写 _scheme_entry；自托管后由 Scheme 编译器写出等价文件
  compile.scm          ; 仅自托管阈值之后：前端 expr → IR
  expand.scm           ; L11 / L30 / L40+ 逐步填（自托管后）
  ir.scm               ; IR 构造器与谓词（自托管后）
backend/
  README.md            ; ABI 与指令选择；自托管后的 emit_* 写在 Scheme 编译器里
runtime/
  aarch64-apple/
    runtime.s          ; 纯汇编：入口、mmap 堆、打印、exit；无 .c/.h
  x86_64-linux/        ; 以后加
tests/
  driver.sh            ; 汇编→链接→运行→比对（只吃 .s）
  test_no_python.sh    ; 有 .py 则失败
  L00/001-fixed-return.scm
  ...
```

**编译器从哪来（锁定）**：

- 禁止 Python、C，以及任何用脚本语言 emit 汇编的代码生成器。
- 早期层：人写 `.s`，检入仓库。
- 自托管阈值之后：编译器用本教程的 Scheme 子集写（R5RS 风格骨架）。在那之前不要引入 Chez / Guile / Racket / Python 当宿主编译器。
- `Makefile` 与 shell 只做胶水。

**默认目标**：[aarch64-apple](backend/README.md)（Apple Silicon，Mach-O，符号前缀 `_`）。

---

## 2. 值表示与标签（64 位）

机器字宽 **8 字节**。所有 Scheme 值都是一个 64 位字，放在寄存器或栈槽里。低位是类型标签。

指针堆对象按 **8 字节对齐**分配，因此地址低 3 位为 `000`，可 OR 上 3-bit 标签。定点数占用低 2 位为 `00` 的全部字，以便 `fx+` 不必先去标签（见 L01、L07）。

| 种类 | 低位模式 | 常量名 | 说明 |
|------|----------|--------|------|
| fixnum | `…xx00` | `FX_TAG=0b00`, `FX_SHIFT=2` | 有符号，有效 62 位 |
| pair | `…001` | `PAIR_TAG=0b001` | 指向 `{car, cdr}` 两字 |
| vector | `…010` | `VECTOR_TAG=0b010` | 见 L16 |
| string | `…011` | `STRING_TAG=0b011` | 见 L17，**可变** |
| box | `…100` | `BOX_TAG=0b100` | L23 起，一格可变槽 |
| symbol | `…101` | `SYMBOL_TAG=0b101` | L46 起 |
| closure | `…110` | `CLOSURE_TAG=0b110` | L24/L26 起 |
| immediate | `…111` | `IMM_TAG=0b111` | 非指针，靠低 8 位细分 |

立即数（低 8 位）——与 Ghuloum / Ikarus 同一套，便于对照论文：

| 对象 | 编码 | 常量名 |
|------|------|--------|
| `#f` | `0x2F` | `BOOL_F` |
| `#t` | `0x6F` | `BOOL_T` |
| `'()` | `0x3F` | `EMPTY_LIST` |
| `#\nul` 等 char | 低 8 位 `0x0F`，字符码在 bit[15:8] | `CHAR_TAG=0x0F`, `CHAR_SHIFT=8` |
| unspecified / void | `0x1F` | `VOID` |
| eof-object | `0x5F` | `EOF_OBJ` |

谓词用掩码，不要用一长串 `if`：

```
fixnum?  : (x & 0b11) == 0
pair?    : (x & 0b111) == PAIR_TAG
boolean? : (x & ~0x40) == BOOL_F     ; #t 与 #f 只差 bit 6
null?    : x == EMPTY_LIST
char?    : (x & 0xFF) == CHAR_TAG
imm?     : (x & 0b111) == 0b111
```

`#t` xor `#f` 等于 `0x40`。`not` 对 `#f` 返 `#t`，其余任何值返 `#f`（R4RS：只有 `#f` 为假）。

**堆对象布局**（地址为去标签后的裸指针）：

```
pair:     [ car:word ][ cdr:word ]

vector:   [ len:fixnum ][ elt0 ][ elt1 ]...   ; 元素已是带标签值

string:   [ len:fixnum ][ bytes... 垫齐到 8 字节 ]

box:      [ val:word ]

symbol:   [ string-ptr: tagged string ]       ; intern 表在 runtime

closure:  [ code:raw-ptr ][ nfree:fixnum ][ fv0 ][ fv1 ]...
```

L12 之前没有堆。L51 之前分配只 bump，不回收。对象头不加额外 type word：类型在指针标签里。GC 按标签走。

**本层不做的选择（全教程锁定）**：

- 不用 NaN-boxing，不用 32 位字。
- 字符串按 R4RS **可变**（`string-set!` 在 L17 或库层提供）。
- 不在标签里塞 flonum；浮点若做，走堆对象（L53 明确选择 bignum，浮点列为后续）。

---

## 3. 可移植 IR

后端**只吃 IR**，不吃完整 Scheme。前端把核心形式降到下列 s-expression（可用 record 实现，序列化形状保持一致）：

```
Ir ::=
  (imm <u64>)                          ; 已带标签的立即数
  (prim <name> Ir ...)                 ; 原语，name 为符号
  (if Ir Ir Ir)
  (seq Ir ...)                         ; 只保留最后值
  (let ((<id> Ir) ...) Ir)             ; 并行绑定，id 已卫生化
  (ref <id>)
  (assign <id> Ir)                     ; set! 之后
  (label <lid>)                        ; 代码或数据标签
  (code <lid> (formals ...) (fvs ...) Ir)  ; 一块可调用代码
  (close <lid> Ir ...)                 ; 分配闭包，后面是自由变量值
  (call Ir Ir ...)                     ; 普通调用，第一项是闭包或代码
  (tail-call Ir Ir ...)                ; 必须在尾位置
  (values Ir ...)                      ; L35
  (with-values Ir Ir)                  ; producer, consumer
```

约束：

- `<id>`、`<lid>` 由前端生成，后端当不透明字符串。
- `(imm n)` 的 `n` 是**已经打好标签**的机器字，后端原样 `mov`。
- `(prim …)` 的名字集合按层增加：`fxadd1`、`cons`、`vector-ref`… 未实现的 prim 必须在前端报错，不要让后端收到未知名。
- 复杂字面量（quoted pair/vector/string）在 L13+ 由前端建成 `prim`/`close` 图，或建成只读数据区 `(label)`；不要让后端解析 Scheme 字面量。

A-normalize 与否由前端决定。建议从 L10 起把 `if` 的 test 降成「结果在值位置」，避免后端处理复杂 test。骨架按「表达式结果一律在约定返回寄存器」即可。

---

## 4. 调用约定（抽象，芯片无关）

这是 IR 层的约定。具体寄存器名见下一节与 `backend/README.md`。

| 角色 | 抽象名 | 含义 |
|------|--------|------|
| 返回值 / 第一参数 | `RES` / `ARG0` | 同一物理寄存器 |
| 第 2…k 参数 | `ARG1`… | k 由后端定（aarch64 用 8 个通用参数寄存器） |
| 堆 bump 指针 | `HP` | callee-saved；指向下一空闲字节 |
| 堆上限 | `HL` | callee-saved；L12 可先不检查，L51 起用于 GC 触发 |
| 当前闭包 | `SELF` | callee-saved；L26 起，自由变量从这里加载 |
| 帧指针 | `FP` | 本帧局部变量、溢出参数 |
| 栈指针 | `SP` | 调用前对齐（aarch64：16 字节） |
| 返回地址 | `LR` | 非尾调用必须保存 |

规则：

1. `scheme_entry` 由 **汇编 runtime 入口**（Darwin 上 `_main`）调用：参数 0 = 堆基址，参数 1 = 堆字节数（或上限指针），走 Darwin/ARM64 整数调用约定（`x0`/`x1`）。汇编保存被调用者保存寄存器，把堆基址写入 `HP`，`HL = HP + size`，然后执行编译出来的顶层 IR，结果留在 `RES`，恢复寄存器，返回 runtime。
2. Scheme 过程调用：闭包在 `ARG0`（或先求值到 `RES` 再移），实参从左到右进 `ARG0…`，溢出的放栈。Arity 检查在 L25 引入。
3. 尾调用：不新开帧，把实参搬到当前帧的参数槽 / 参数寄存器，跳到目标代码。L31 先做自尾调用，L32 做跨过程。
4. 多返回值（L35）：单值仍只占 `RES`；多值用「第一个值 + 值个数 + 溢出栈/堆块」。具体编码在 L35 锁定。
5. runtime 辅助函数（`_rt_print`、`_rt_error`、`_gc_collect` 等）也是汇编，由后端 `emit-rt-call` 发出 `bl _rt_name`。整数参数/返回值占用与 Darwin 整数约定相同的寄存器（`x0`–`x7` / `x0`）。Scheme 值是 64 位字，与机器 `int64` 位型相同，但项目中 **没有 C 源文件**。

---

## 5. 默认后端：aarch64-apple 寄存器分配

| 抽象 | 物理 | 备注 |
|------|------|------|
| `RES` `ARG0` | `x0` | Apple / AAPCS 第一参数与返回值 |
| `ARG1`…`ARG7` | `x1`–`x7` | |
| `HP` | `x19` | callee-saved |
| `HL` | `x20` | callee-saved |
| `SELF` | `x21` | callee-saved |
| `FP` | `x29` | Apple 要求有帧时使用标准帧指针 |
| `LR` | `x30` | |
| `SP` | `sp` | 调用点 16 字节对齐 |
| 临时 | `x9`–`x15` | caller-saved，emit 内部用 |

**禁止使用 `x18`**（Darwin 平台保留）。不要用 `x16`/`x17` 当长期临时（动态链接 trampoline）。

Darwin Mach-O：全局符号在汇编里带下划线：`_scheme_entry`、`_rt_print`、`_main`。Linux aarch64 **没有**这个前缀——这是后端差异，不是 IR 差异。

---

## 6. 后端接口（`emit_*`）

这是**自托管编译器**必须实现的逻辑接口。自托管之前，用检入的 `.s` 手写出与下列过程**相同的机器效果**；不要为此写 Python / Scheme-on-Chez 代码生成器。

自托管之后，`emit-*` 写在 Scheme 编译器里（例如 `compiler/` 下的后端模块）。名字保持英文。未用到的层可以先写 stub，收到对应 IR 时 `error`。

```scheme
;; 输出端口或内部 buffer 由实现自定；下列为逻辑接口。

(emit-program codes main-ir)
;; codes : list of (code lid formals fvs body)
;; 写出 .text、对齐、.globl _scheme_entry、序言/跋、main-ir

(emit-imm u64)                 ; mov x0, #imm 或 movz/movk 序列
(emit-prim name ir-args ctx)   ; 按 name 分派
(emit-if test then else ctx)
(emit-seq ir-list ctx)
(emit-let bindings body ctx)
(emit-ref id ctx)
(emit-assign id ir ctx)

(emit-label lid)
(emit-jmp lid)
(emit-jfalse lid)              ; x0 == BOOL_F 则跳
(emit-stack-alloc n-words)     ; 调整 sp，保持 16B 对齐
(emit-stack-save slot)         ; str x0, [fp, #off]
(emit-stack-load slot)

(emit-alloc nbytes)            ; 旧 HP → x0（裸指针），HP += align8(nbytes)
(emit-tag x-reg tag)           ; orr
(emit-untag x-reg tag)         ; sub 或 bic

(emit-call n-args)
(emit-tail-call n-args)
(emit-load-self)               ; mov x21, x0 在闭包入口
(emit-closure-ref i)           ; 第 i 个自由变量 → x0

(emit-rt-call name n-args)     ; bl _name，遵守 Darwin 整数约定；目标是汇编 runtime，不是 C
```

`ctx` 建议包含：

```
si    下一个可用栈槽（以 word 计，负向增长）
env   alist: id → (stack . slot) | (reg . r) | (free . index)
```

这是 Ghuloum 论文里的 `si`/`env`。换芯片时 **ctx 形状不变**，只换指令。

---

## 7. 运行时边界

**C 不在范围内。** 仓库与读者实现都不得为 runtime 引入 `.c` / `.h`。`clang`/`ld` 只汇编、只链接 `.s`/`.o`。

汇编 runtime 拥有：进程入口、堆内存（`mmap` 或文档写死的 `.bss`；默认 aarch64-apple 用 `mmap`）、打印、报错退出、（L43+）I/O、（L51+）GC、（L46）符号 intern 表（表在 runtime 汇编或后续 Scheme 里，不在 C）。

`_scheme_entry` 体（手写或自托管发出）拥有：求值、分配 bump（调用 `emit-alloc` 的机器效果，不直接 `mmap`）、调用 Scheme 过程。

Darwin 符号（汇编里带 `_` 前缀）：

```
_scheme_entry   ; 编译器生成：x0=heap_base, x1=heap_nbytes → x0=result
_rt_print       ; runtime：按当前层认识的类型打印，末尾换行，SYS_write
_rt_error       ; runtime：写 stderr，SYS_exit(1)
_main           ; runtime：mmap 堆，bl _scheme_entry，bl _rt_print，SYS_exit
```

标签常量（与 §2 相同）写在手写 `.s` 注释（早期层）或自托管编译器与 `runtime.s` 顶部注释，数值必须一致。没有 `scheme.h`。

`_main` 逻辑：

```
n = 64 * 1024 * 1024          ; 64MiB，足够做到 L55
heap = mmap(0, n, PROT_READ|PROT_WRITE, MAP_ANON|MAP_PRIVATE, -1, 0)
r = _scheme_entry(heap, n)    ; x0, x1
_rt_print(r)
SYS_exit(0)
```

**打印策略（分层）**：

- L00：把返回值当有符号整数打印（此时尚未打标签）。
- L01–L04：`_rt_print` 认识对应立即数。
- L13+：递归打印 pair（注意环，L15 之后若出现环可先不检测，L44 再处理）。
- L44：实现 `write`/`display` 的完整规则；`_rt_print` 改为走同一套 writer。

**`_scheme_entry` 体不要**直接做系统调用。syscall 只出现在 `runtime/*.s`。

---

## 8. 汇编、链接（摘要）

细节与 Apple / Linux 差异见 [backend/README.md](backend/README.md)。默认命令：

```sh
# 早期层：compiler/scheme_entry.s 是手写的。只汇编、只链接 .s。
clang -arch arm64 -c runtime/aarch64-apple/runtime.s -o runtime.o
clang -arch arm64 -c compiler/scheme_entry.s -o program.o
clang -arch arm64 runtime.o program.o -o program
./program
```

`_scheme_entry` 必须按 Darwin 整数约定保存它**弄脏的** callee-saved 寄存器。L00 可以只保存 `x29`/`x30`；L12 起还要保存 `x19`/`x20`（HP/HL），L26 起保存 `x21`（SELF）。

---

## 9. 如何新增一种芯片后端

1. 为新 triple 写一份纯汇编 `scheme_entry`（早期层）或自托管后一份 emit 模块，保持全部 `emit-*` 名字与 `ctx` 形状。不要用 Python 或其它 HLL 生成器起步。
2. 复制 `runtime/aarch64-apple/` 为 `runtime/<triple>/`。标签数值必须与 §2 **一致**（写在 `runtime.s` 注释与手写/自托管编译器里）。入口符号按该平台命名（Mach-O 下划线 vs ELF 无前缀）。仍是纯汇编，不要引入 C。
3. 改寄存器表、立即数加载序列、调用/栈对齐、标签语法（Mach-O vs ELF vs 指令选择）。
4. 测试驱动增加 `TARGET=x86_64-linux` 一类开关；**同一组** `tests/Lxx` 必须通过。
5. 不要为了新芯片改 IR 或层文档中的求值规则。若指令集做不到某抽象（例如缺寄存器），在 backend README 写清映射，而不是改前端。

验收：L00 的「固定返回」在新后端上先绿，再跑 L01… 直到当前进度。

---

## 10. 测试与驱动约定

- 每个测例一个输入表达式（文件内单个 Scheme 表达式，或 `tests/Lxx/NNN-name.scm`）。
- 期望：标准输出等于某字符串（含末尾换行），退出码 0；错误类测例期望非 0 且 stderr 含关键字。
- 命名：`NNN-short-english-slug.scm`，`NNN` 三位小数，与层文档「测例清单」编号一致。
- 回归：第 N 层必须跑通第 0…N 层全部测例（文档里写「上一层全部测例仍须通过」）。

驱动伪代码（L00 与早期层：没有 HLL `compile` 步骤）：

```sh
# $t.s 是检入的手写汇编（L00：compiler/scheme_entry.s）
clang -arch arm64 -c runtime/aarch64-apple/runtime.s -o rt.o
clang -arch arm64 -c compiler/scheme_entry.s -o "$t.o"
clang -arch arm64 rt.o "$t.o" -o "$t.bin"
"$t.bin" > "$t.out"
diff -u "$t.expected" "$t.out"
```

自托管之后可以把「Scheme 编译器写出 `$t.s`」插在汇编之前；该编译器必须是本仓库的 Scheme 子集，不是 Python / Chez / Guile。

---

## 11. 与 R4RS 的关系

本教程**逼近** R4RS，不是声称第 55 层结束即 100% 符合。L54–L55 给出缺口清单与第三方小程序验收。刻意延后或简化的包括：完整数值塔（L53 只强制 bignum 这一步）、完整卫生宏的边界情况、完整 I/O 端口模型、`eval` 的环境参数细节。每层「范围之外」会写死。
