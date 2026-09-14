# L06 — 一元原语 `not` `fxadd1` `fxsub1` `fxneg` `char->fixnum` `fixnum->char`

## 目标

在 L05 的谓词之外，增加六个**一元**原语。程序仍是无变量的表达式树：先求值唯一操作数到 `x0`，再就地改写 `x0`。本层第一次对 **已打标签的 fixnum** 做加减，并第一次在字符与 fixnum 之间搬 payload。

本层结束后，语言形状是：

```
P ::= literal
    | (fixnum? P) | (boolean? P) | (null? P) | (char? P)
    | (not P)
    | (fxadd1 P) | (fxsub1 P) | (fxneg P)
    | (char->fixnum P) | (fixnum->char P)
literal ::= fixnum | #t | #f | () | char
```

嵌套必须能工作，例如 `(fxadd1 (fxadd1 0))`、`(not (not #f))`、`(fixnum->char (char->fixnum #\A))`。

本层范围之外：二元算术（L07）、`if`（L10）、变量、运行时类型检查、溢出检测、泛型 `+`/`-`、`integer->char` 作为 R4RS 名字（本层用户语法是 `fixnum->char` / `char->fixnum`）。对非 fixnum 做 `fxadd1`、对非字符做 `char->fixnum` 的行为**不定义**——不要为此写「正确输出」测例，也不要在本层插入 `rt_error`。

## 原理

### 求值规则（芯片无关）

每个一元原语：

1. 递归求值唯一操作数，结果在约定返回寄存器（aarch64 上是 `x0`）。
2. 用该寄存器里的 **64 位已标签字** 做一次位运算或一次加减。
3. 新值仍放回同一寄存器。不分配栈槽，不调用 C。

IR：

```
(prim not           Ir)
(prim fxadd1        Ir)
(prim fxsub1        Ir)
(prim fxneg         Ir)
(prim char->fixnum  Ir)
(prim fixnum->char  Ir)
```

前端把 `(fxadd1 e)` 降成 `(prim fxadd1 (expr->ir e))`，与 L05 谓词同一条通道。未知原语、arity ≠ 1：编译期 `error`。

### `not`：Scheme 的假值，不是「取反所有位」

R4RS：只有 `#f` 为假。因此：

```
(not #f)  → #t
(not x)   → #f    ; 对任意 x ≠ #f，包括 0、()、#t、字符、非零 fixnum
```

`#f` 的编码是 `BOOL_F=0x2F`，`#t` 是 `BOOL_T=0x6F`。实现是 **满字比较**，不是 `eor` 掉 bit 6：

```
if x == 0x2F then 0x6F else 0x2F
```

错误实现 `x xor 0x40` 会让 `(not #t)` 碰巧对，但 `(not 0)` 会得到 `0x40`，既不是 `#f` 也不是 `#t`。`not` 与 L10 的 `if` 共用同一条假值规则：现在用谓词测例钉死它。

### `fxadd1` / `fxsub1`：加的是「1 的标签」，不是 1

fixnum 编码 `tagged = n << FX_SHIFT`，`FX_SHIFT=2`，所以字面量 `1` 的标签值是 `4`。

```
tagged(n+1) = (n+1)<<2 = (n<<2) + 4 = tagged(n) + tagged(1)
tagged(n-1) = tagged(n) - 4
```

因此：

- `fxadd1`：对 **已标签** 的字加 `4`（`add x0, x0, #4`）
- `fxsub1`：对已标签的字减 `4`

若写成 `add x0, x0, #1`，`(fxadd1 0)` 的低 2 位会变成 `01`，不再是 fixnum，`rt_print` 会走「未知值」或把垃圾当指针。这是本层最高频的 bug。

合同命名带 `fx` 前缀，直到 L53 才考虑无前缀的 R4RS `+`。不要把用户语法做成 `(add1 x)`。

### `fxneg`：对已标签字做二补码取负

```
tagged(-n) = (-n)<<2 = -(n<<2) = -tagged(n)     ; 二补码，忽略溢出
```

`0` 的标签值仍是 `0`，所以「用零减 x」与「取负 x」是同一条指令：

```
neg x0, x0          ; 等价于 sub x0, xzr, x0
```

**不要**先 `asr #2` 再取负再 `lsl #2`：那会丢掉低位，且多两拍；直接对标签值取负即可。

本层范围之外：最负 fixnum（`-2^61`）取负溢出；不检测，二补码环绕。

### `char->fixnum` / `fixnum->char`：移位差是 6，不是 8

合同（ARCHITECTURE §2）：

```
CHAR_TAG   = 0x0F
CHAR_SHIFT = 8          ; 码点在 bit[15:8]
FX_SHIFT   = 2
```

字符 `c` 的字：`(code << 8) | 0x0F`。fixnum `code` 的字：`code << 2`。两者 payload 相差 `8-2=6` 位：

```
char → fixnum :  asr x0, x0, #6
fixnum → char :  lsl x0, x0, #6 ; orr x0, x0, #0x0F
```

为何 `asr #6` 不会把 `CHAR_TAG` 残渣带进 fixnum：`0x0F` 只占 bit[7:0]，右移 6 后这些位进入 bit[1:0]，而 `0x0F` 的 bit[7:6] 是 `00`，于是结果低 2 位仍是 `00`（合法 fixnum 标签）。高位在合法字符里为 0，`asr` 与 `lsr` 本层等价；请用 `asr` 与 fixnum 算术右移习惯一致。

反向：fixnum 左移 6 得到 `code << 8`，OR 上 `0x0F` 即字符。不要 `orr` 完再移位，也不要把 `CHAR_TAG` 加到未移位的 fixnum 上。

本层范围之外：码点是否落在 0–255、是否为 R4RS 规定的字符集合。实现按 8 位移位；`rt_print` 仍用 L04 规则。非法码点不强制 `rt_error`。

### 嵌套与寄存器

一元原语覆盖 `x0`，所以嵌套只是递归 `emit-ir`：内层先跑完，外层接着改 `x0`。仍 **不必** 用栈。`ctx` 从 L05 骨架起就往下传，本层可以继续无视 `si`/`env`，但不要把它们从接口里删掉——L07 立刻要用。

临时寄存器只用 `x9`–`x15`。**禁止 `x18`**（Darwin 保留）。`not` 的 `#t`/`#f` 立即数可直接 `mov` 进 `x0`/`x10`，不必 `emit-imm` 四条 `movk`（`0x2F`/`0x6F` 很小）。

### 打印

不改 `rt_print`。结果仍是 L01–L04 已认识的立即数：fixnum 十进制、`#t`/`#f`、`()`、字符。

## 与上一层的差异

| 项 | L05 | L06 |
|----|-----|-----|
| 原语 | 四个谓词，结果必为布尔 | 谓词 + 六个一元；结果可以是布尔、fixnum 或 char |
| 算术 | 无 | 对**已标签**字 `±4` 与取负 |
| 移位 | 无（谓词只用 `and`/`cmp`） | 字符 ↔ fixnum 移 6 位 |
| 栈 | 无 | 仍无（嵌套一元仍覆盖 `x0`） |
| `rt_print` / 标签常量 | 不变 | 不变 |

## 代码骨架

### 可移植：前端

在 L05 的 `expr->ir` 上增加六条 arity=1 的分支。先匹配原语，再匹配字面量（否则 `(not #f)` 会被当成非法 pair）。

```scheme
(define FX_ONE 4)              ; tagged 1；fxadd1 加的就是它
(define CHAR_SHIFT_DIFF 6)     ; CHAR_SHIFT - FX_SHIFT；后端用，前端不必算标签

(define (unary-prim? name)
  (memq name '(not fxadd1 fxsub1 fxneg char->fixnum fixnum->char
               fixnum? boolean? null? char?)))

(define (expr->ir expr)
  (cond
    ((and (pair? expr) (unary-prim? (car expr)))
     (unless (length=? expr 2)
       (error "L06: unary arity" expr))
     `(prim ,(car expr) ,(expr->ir (cadr expr))))
    ((null? expr) `(imm ,EMPTY_LIST))
    ((eq? expr #t) `(imm ,BOOL_T))
    ((eq? expr #f) `(imm ,BOOL_F))
    ((char? expr)
     `(imm ,(logior CHAR_TAG (ash (char->integer expr) CHAR_SHIFT))))
    ((fixnum-range? expr) `(imm ,(* expr 4)))
    (else (error "L06: bad expr" expr))))
```

`length=?` 自己写：`(and (pair? (cdr expr)) (null? (cddr expr)))`。不要用 `length` 走完整表再比（以后 improper list 会疼）。未知符号 `(foo 1)` 仍进 `else`，编译期错。

### 可移植：`emit-prim` 分派

```scheme
(define (emit-prim name args ctx)
  (string-append
    (emit-ir (car args) ctx)     ; 操作数 → x0
    (case name
      ((fixnum?)        (emit-mask-eq 3 0))
      ((char?)          (emit-mask-eq 255 CHAR_TAG))
      ((null?)          (emit-cmp-eq EMPTY_LIST))
      ((boolean?)       (emit-boolean-pred))
      ((not)            (emit-not))
      ((fxadd1)         (emit-fxadd1))
      ((fxsub1)         (emit-fxsub1))
      ((fxneg)          (emit-fxneg))
      ((char->fixnum)   (emit-char->fixnum))
      ((fixnum->char)   (emit-fixnum->char))
      (else (error "unknown prim" name)))))
```

上面 `case` 里的 `emit-*` 在换芯片时替换；IR 与分派表可移植。

### aarch64-apple：各原语

```scheme
;; not：只有满字等于 BOOL_F 才变 #t
(define (emit-not)
  (string-append
    "\tcmp x0, #0x2F\n"
    "\tmov x0, #0x2F\n"      ; 默认 #f
    "\tmov x10, #0x6F\n"     ; #t
    "\tcsel x0, x10, x0, eq\n"))

(define (emit-fxadd1)
  "\tadd x0, x0, #4\n")

(define (emit-fxsub1)
  "\tsub x0, x0, #4\n")

(define (emit-fxneg)
  "\tneg x0, x0\n")          ; sub x0, xzr, x0

(define (emit-char->fixnum)
  "\tasr x0, x0, #6\n")

(define (emit-fixnum->char)
  (string-append
    "\tlsl x0, x0, #6\n"
    "\torr x0, x0, #0x0F\n"))
```

`cmp x0, #0x2F` 的立即数 47 落在 aarch64 算术立即数可编码范围。不要把 `BOOL_F` 先装进内存。

`neg` 是 aarch64 别名，Apple `as`/`clang -c` 接受。若你偏爱不透明别名，写 `sub x0, xzr, x0`，语义相同。

### 本层不要做的事

- 不要为 `fxadd1` 发 `add w0, w0, #4`（32 位）：负数 fixnum 高 32 位会丢。全程 `x0`。
- 不要在 `fxneg` 前 `and x0, x0, #~3` 去标签。
- 不要调用 C。本层纯整数/位运算。

## 测例清单

上一层全部测例仍须通过。

1. `(fxadd1 0)` → `1`
2. `(fxadd1 -1)` → `0`
3. `(fxsub1 0)` → `-1`
4. `(fxsub1 1)` → `0`
5. `(fxneg 0)` → `0`
6. `(fxneg 1)` → `-1`
7. `(fxneg -42)` → `42`
8. `(not #f)` → `#t`
9. `(not #t)` → `#f`
10. `(not 0)` → `#f`（fixnum 零不是假）
11. `(not ())` → `#f`
12. `(not #\A)` → `#f`
13. `(not (not #f))` → `#f`；`(not (not #t))` → `#t`（嵌套）
14. `(fxadd1 (fxadd1 1))` → `3`；`(fxsub1 (fxadd1 -1))` → `-1`
15. `(char->fixnum #\A)` → `65`；`(fixnum->char 65)` → `#\A`
16. `(fixnum->char (char->fixnum #\nul))` → `#\nul`（往返）
17. `(not (fixnum? #\A))` → `#t`（谓词结果再喂给 `not`）
18. `(fxadd1)` / `(fxadd1 1 2)` / `(not)`：编译期 arity 错误。`(foo 1)`：编译期未知原语。

测例 13–17 必须进驱动，不能只测单层原语：嵌套是本层合同。

## 验收标准

- 测例 1–17 的标准输出与上表一致（末尾一个换行，无空格）。`#t`/`#f` 三字符；字符打印遵守 L04。
- 生成代码对 `fxadd1` 出现 `add …, #4`（或把 4 装进临时再 `add`），**不得**对标签值 `add #1`。
- `not` 的路径上有与 `0x2F` 的比较；不得靠 `eor #0x40` 充当 `not`。
- 一元原语不 `str`/`ldr` 栈，不 `bl` C。
- 未知原语与错误 arity 在编译期失败，不产出能打印「碰巧结果」的可执行文件。

## 常见坑

- **`fxadd1` 加 1**：标签被破坏。用手算核对：输入 `0` 的机器字是 `0`，加 4 得 `4`，`rt_print` 右移 2 才是 `1`。
- **`not` 写成 xor bit 6**：`#t`/`#f` 互换看起来对，`(not 0)` 会炸打印或打出未知值。
- **把 `0` 或 `()` 当假**：那是 C / Lisp-1.5，不是 Scheme。本层 `(not 0)` 必须 `#f`。
- **`char->fixnum` 右移 8**：得到的是 `code >> 6` 量级的垃圾，`(char->fixnum #\A)` 不会是 `65`。差值是 `CHAR_SHIFT - FX_SHIFT = 6`。
- **`fixnum->char` 忘了 `orr CHAR_TAG`**：低 8 位为 0，`char?` 为假，打印也不走字符分支。
- **`fxneg` 去标签再取负**：多余且容易用成逻辑右移，把负 fixnum 变成巨大正数。
- **只用 `w0`**：`fxneg` 的负数字高 32 位全 1，32 位操作会截断。
- **临时用了 `x18`**：Darwin 上静默损坏，极难查。临时只用 `x9`–`x15`。

## 下一层预告

L07 引入二元 `fx+` `fx-` `fx*`：第一次要把左操作数存进栈，再求值右操作数。
