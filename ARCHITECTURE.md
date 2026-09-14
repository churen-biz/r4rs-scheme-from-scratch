# 架构

本文是全教程的**唯一设计合同**。各层文档默认遵守这里的标签、IR、调用约定与目录划分。若某层必须偏离，须在该层「原理」中显式声明，并说明何时回到本合同。

读者实现时：先读本文件，再按 `layers/` 顺序做。换芯片时只换 `backend/` 与 `runtime/` 中对应实现，不改 IR 与前端。

---

## 1. 系统切分

一条 Scheme 表达式从源文本到进程退出，经过四段**芯片无关**代码和两段**芯片相关**代码：

```
源文本
  → [reader]        芯片无关  L43 才必须；此前测试驱动可直接喂 s-expression
  → [expand]        芯片无关  宏、derived syntax → 核心形式
  → [ir-lower]      芯片无关  核心形式 → IR
  → [backend/emit]  芯片相关  IR → 汇编文本
  → [assemble/link] 芯片相关  汇编 + runtime → 可执行文件
  → [run]           运行时    入口进入 scheme_entry，打印结果
```

目录建议（读者仓库中逐步长出，本教程仓库本身以文档为主）：

```
compiler/
  compile.scm          ; 前端：expr → IR
  expand.scm           ; L11 / L30 / L40+ 逐步填
  ir.scm               ; IR 构造器与谓词
backend/
  aarch64-apple.scm    ; emit_* 默认后端
  x86_64-linux.scm     ; 以后加，本教程不实现
runtime/
  aarch64-apple/
    runtime.c          ; 打印、分配、入口胶水
    scheme.h           ; 与编译器共享的标签常量（注释副本）
  x86_64-linux/        ; 以后加
tests/
  driver.sh            ; 或 driver.scm：编译→汇编→链接→运行→比对
  L00/001-fixed-return.scm
  ...
```

**编译器宿主语言**：用能读写文件、处理 s-expression 的 Scheme（Chez / Guile / Racket 均可）。骨架用 R5RS 风格，避免依赖某一实现的扩展。若暂时没有宿主 Scheme，允许用 Python 3 写**同一套 IR 与 emit 接口**，但标识符与测例仍按本文。

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

1. `scheme_entry` 由 C 调用：参数 0 = 堆基址，参数 1 = 堆字节数（或上限指针）。汇编保存被调用者保存寄存器，把堆基址写入 `HP`，`HL = HP + size`，然后执行编译出来的顶层 IR，结果留在 `RES`，恢复寄存器，返回 C。
2. Scheme 过程调用：闭包在 `ARG0`（或先求值到 `RES` 再移），实参从左到右进 `ARG0…`，溢出的放栈。Arity 检查在 L25 引入。
3. 尾调用：不新开帧，把实参搬到当前帧的参数槽 / 参数寄存器，跳到目标代码。L31 先做自尾调用，L32 做跨过程。
4. 多返回值（L35）：单值仍只占 `RES`；多值用「第一个值 + 值个数 + 溢出栈/堆块」。具体编码在 L35 锁定。
5. C 运行时辅助函数（`rt_print`、`rt_error`、`gc_collect`）走平台 C ABI，由后端 `emit_c_call` 发出。Scheme 值与 C 的 `int64_t` 位型相同。

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

Darwin Mach-O：全局符号在汇编里带下划线：`_scheme_entry`、`_rt_print`。Linux aarch64 **没有**这个前缀——这是后端差异，不是 IR 差异。

---

## 6. 后端接口（`emit_*`）

`backend/aarch64-apple.scm`（或等价文件）至少实现下列过程。名字保持英文。未用到的层可以先写 stub，收到对应 IR 时 `error`。

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

(emit-c-call c-name n-args)    ; bl _c_name，遵守 C ABI
```

`ctx` 建议包含：

```
si    下一个可用栈槽（以 word 计，负向增长）
env   alist: id → (stack . slot) | (reg . r) | (free . index)
```

这是 Ghuloum 论文里的 `si`/`env`。换芯片时 **ctx 形状不变**，只换指令。

---

## 7. 运行时边界

C 运行时拥有：进程入口、堆内存、打印、报错退出、（L43+）I/O、（L51+）GC、（L46）符号 intern 表。

汇编/编译代码拥有：求值、分配 bump（调用 `emit-alloc`，不直接 `malloc`）、调用 Scheme 过程。

建议的 C 符号（Darwin 下编译器发出 `_` 前缀）：

```c
/* runtime/aarch64-apple/scheme.h 与 runtime.c */
#include <stdint.h>
typedef int64_t ptr;

#define FX_SHIFT 2
#define FX_TAG 0x00
#define PAIR_TAG 1
#define VECTOR_TAG 2
#define STRING_TAG 3
#define BOX_TAG 4
#define SYMBOL_TAG 5
#define CLOSURE_TAG 6
#define BOOL_F 0x2F
#define BOOL_T 0x6F
#define EMPTY_LIST 0x3F
#define CHAR_TAG 0x0F
#define VOID 0x1F
#define EOF_OBJ 0x5F

ptr scheme_entry(ptr *heap, uint64_t heap_nbytes); /* 汇编定义 */
void rt_print(ptr x);     /* 按当前层认识的类型打印，末尾换行 */
void rt_error(const char *msg); /* 打印到 stderr，exit(1) */
```

`main`：

```c
int main(void) {
    size_t n = 64 * 1024 * 1024; /* 64MiB 足够做到 L55；L12 可更小 */
    ptr *heap = aligned_alloc(8, n);
    ptr r = scheme_entry(heap, n);
    rt_print(r);
    return 0;
}
```

**打印策略（分层）**：

- L00：固定把返回值当无符号/有符号整数打印（此时尚未打标签，或约定返回 0）。
- L01–L04：`rt_print` 认识对应立即数。
- L13+：递归打印 pair（注意环，L15 之后若出现环可先不检测，L44 再处理）。
- L44：实现 `write`/`display` 的完整规则；`rt_print` 改为走 `write`。

编译器**不要**在汇编里直接 `svc` 做 I/O。

---

## 8. 汇编、链接（摘要）

细节与 Apple / Linux 差异见 [backend/README.md](backend/README.md)。默认命令：

```sh
# 编译器写出 program.s
clang -arch arm64 -c runtime/aarch64-apple/runtime.c -o runtime.o
clang -arch arm64 -c program.s -o program.o
clang -arch arm64 runtime.o program.o -o program
./program
```

`scheme_entry` 必须按 C ABI 保存它弄脏的 callee-saved 寄存器（至少 `x19–x21`、`x29`、`x30`）。

---

## 9. 如何新增一种芯片后端

1. 复制 `backend/aarch64-apple.scm` 为 `backend/<triple>.scm`，保持全部 `emit-*` 名字与 `ctx` 形状。
2. 复制 `runtime/aarch64-apple/` 为 `runtime/<triple>/`。`scheme.h` 标签必须**数值一致**。`runtime.c` 尽量共用；入口符号、`#ifdef` 处理 `_` 前缀。
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

驱动伪代码：

```sh
compile "$in" > "$t.s"
clang -arch arm64 -c runtime.c -o rt.o
clang -arch arm64 -c "$t.s" -o "$t.o"
clang -arch arm64 rt.o "$t.o" -o "$t.bin"
"$t.bin" > "$t.out"
diff -u "$t.expected" "$t.out"
```

---

## 11. 与 R4RS 的关系

本教程**逼近** R4RS，不是声称第 55 层结束即 100% 符合。L54–L55 给出缺口清单与第三方小程序验收。刻意延后或简化的包括：完整数值塔（L53 只强制 bignum 这一步）、完整卫生宏的边界情况、完整 I/O 端口模型、`eval` 的环境参数细节。每层「范围之外」会写死。
