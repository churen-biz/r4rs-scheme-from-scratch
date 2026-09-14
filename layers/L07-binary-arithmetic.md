# L07 — 二元算术 `fx+` `fx-` `fx*`

## 目标

增加三个**恰好两个操作数**的 fixnum 算术原语：`fx+`、`fx-`、`fx*`。这是整部教程第一次使用 **Scheme 值栈槽**：左操作数求值完毕后必须腾出 `x0`，才能求值右操作数。

本层结束后，表达式树可以在任意深度混用 L05–L06 的一元原语与这三个二元原语。求值顺序 **从左到右**。

本层范围之外：泛型 / 可变 arity 的 R4RS `+` `-` `*`（L42 或 L53 才提供）；`fx/`、`fxremainder`、移位原语；溢出检测与 bignum；运行时类型检查（对非 fixnum 做 `fx+` 的位型结果不定义）；用户可见的局部变量（栈槽只给原语临时用，没有名字，要到 L18）。

## 原理

### 为何必须用栈

约定：任何表达式的结果都在 `x0`。二元原语有两个子表达式，不能同时占着 `x0`。Ghuloum 的办法：

1. 求值左操作数 → `x0`
2. `emit-stack-save`：把 `x0` 写进当前帧的下一个栈槽
3. 求值右操作数 → `x0`（此时左值安全地待在栈上）
4. 把栈上的左值载入临时寄存器，与 `x0` 做运算，结果写回 `x0`

右操作数内部若再有二元原语，必须使用 **更低的一个槽**，否则会覆盖尚未消费的左值。这就是 `si`（stack index）要递减着往下传的原因。

### `ctx`：`si` 与 `env`

ARCHITECTURE §6 的 `ctx` 本层开始真正工作：

```
si    下一个可用栈槽（以 word 计，负向增长）
env   alist：id → (stack . slot) | (reg . r) | (free . index)
```

本层 `env` 恒为 `()`（还没有绑定）。`si` 是相对帧指针 `x29` 的字节偏移，类型是负的 8 倍数。建议：

```
WORDSIZE = 8
初始 si  = -8          ; 第一个临时槽在 [fp, #-8]
保存一次后，传给右操作数的 si' = si - WORDSIZE
```

`env` 原样下传。不要把 `si` 做成「第几个槽」再临时乘 8——选一种单位写死：**字节偏移**，与 `str` 立即数一致。

### 帧布局（aarch64-apple）

L00 序言只做了：

```
stp x29, x30, [sp, #-16]!
mov x29, sp
```

此时 `fp`（`x29`）指向保存的旧 `x29`，`fp+8` 是 `x30`。局部槽必须在 **`fp` 下方**，所以要先把 `sp` 再往下调，否则 `str` 写到未分配区域。Darwin 有 128 字节红区，**不要依赖它**。

本层推荐固定帧（L19 再精确计算）：

```
stp x29, x30, [sp, #-16]!
mov x29, sp
sub sp,  sp,  #256          ; 32 个 word，16 字节对齐
; … 函数体，结果在 x0 …
mov sp,  x29                ; 丢掉局部区；不要 add 漏算
ldp x29, x30, [sp], #16
ret
```

`256` 够用：本层表达式嵌套深度对应的临时槽远小于 32。`str Xt, [Xn, #imm]` 的 9-bit 有符号未对齐形式范围为 `[-256, 255]`，偏移 `-8…-248` 都落在该窗口；不要本层就改用临时基址寄存器。

**可移植**：IR 不知道 256 或 `fp`。换芯片时仍是「`si` 指向下一个槽 + save/load」。x86-64 可能相对 `rsp` 而不是 `rbp`；那是后端的事。

### 标签下的算术（芯片无关）

fixnum 低 2 位恒 `00`，因此：

```
tagged(a) + tagged(b) = (a<<2)+(b<<2) = (a+b)<<2 = tagged(a+b)
tagged(a) - tagged(b) = tagged(a-b)
```

`fx+` / `fx-` **不必去标签**。这就是 L01 只占 2 位而不是 3 位的理由。

`fx*` 不行：`(a<<2)*(b<<2) = (a*b)<<4`，多移了 2 位。必须 **只去掉一个操作数的标签** 再乘：

```
(a<<2) * b = (a*b)<<2 = tagged(a*b)
```

实现：对其中一个操作数 `asr #2`，再 `mul`。不要两个都去标签（还得再 `lsl #2` 打回去），也不要两个都不去。

合同指定 aarch64 使用：

```
mul x0, x0, x9
```

即积写在 `x0`，两个源是 `x0` 与 `x9`。惯例：栈上取出左值到 `x9`，对 `x9` 做 `asr #2`，右值留在 `x0`（仍带标签），然后 `mul x0, x0, x9`。对右值去标签、左值保持带标签，同样正确；选一种写死，测例不区分。

本层范围之外：积超出 62 位有效精度。不检测，二补码环绕。`smulh` 不用。

### 求值顺序

严格左到右：先完整求值左操作数（含它内部的一切嵌套），保存，再求值右操作数。本层无副作用，顺序只影响栈槽占用；L23 有 `set!` 之后，左到右会变成可观测语义。现在就按这个顺序发代码，不要「先算右再算左」图省一个 `str`。

### IR

```
(prim fx+ Ir Ir)
(prim fx- Ir Ir)
(prim fx* Ir Ir)
```

前端 `(fx+ a b)` → `(prim fx+ (expr->ir a) (expr->ir b))`。arity 不是 2：编译期 `error`。没有 `(fx+ a b c)`，没有 `(fx+)`。

### 与一元原语共用分派

`emit-prim` 看 `name` 决定先 `emit` 几个参数。一元仍只 `emit` `car`；二元走 save/load。不要为二元另写一套 `expr->ir` 递归。

## 与上一层的差异

| 项 | L06 | L07 |
|----|-----|-----|
| 原语 arity | 全是 1 | 增加恰好 2 的 `fx+` `fx-` `fx*` |
| 栈 | 不用 | `emit-stack-save` / `emit-stack-load`；`si` 递减 |
| 序言 | 16 字节保存 `x29,x30` 即可 | 额外 `sub sp` 留出局部区；跋里 `mov sp, x29` |
| `ctx` | 可空传 | 必须携带 `si`；初始 `si=-8`，`env=()` |
| 指令 | `add #4` / `neg` / `csel` | `add`/`sub`/`mul` 两个寄存器；`asr #2` 仅用于 `fx*` |

## 代码骨架

### 可移植：前端

```scheme
(define (binary-arith? name)
  (memq name '(fx+ fx- fx*)))

(define (expr->ir expr)
  (cond
    ((and (pair? expr) (binary-arith? (car expr)))
     (unless (length=? expr 3)
       (error "L07: binary arity" expr))
     `(prim ,(car expr)
            ,(expr->ir (cadr expr))
            ,(expr->ir (caddr expr))))
    ((and (pair? expr) (unary-prim? (car expr)))
     (unless (length=? expr 2)
       (error "L07: unary arity" expr))
     `(prim ,(car expr) ,(expr->ir (cadr expr))))
    ;; … L01–L04 字面量 …
    (else (error "L07: bad expr" expr))))
```

`length=?` 对二元：正好三个顶层 pair 元素。`(fx+ 1 2 3)` 编译期错，不要静默丢掉 `3`。

### 可移植：`ctx` 与 `emit-prim`

```scheme
(define WORDSIZE 8)

(define (make-ctx si env) (cons si env))
(define (ctx-si ctx) (car ctx))
(define (ctx-env ctx) (cdr ctx))
(define (ctx-down ctx)
  (make-ctx (- (ctx-si ctx) WORDSIZE) (ctx-env ctx)))

(define (initial-ctx)
  (make-ctx -8 '()))

(define (emit-prim name args ctx)
  (cond
    ((memq name '(fx+ fx- fx*))
     (emit-binop name (car args) (cadr args) ctx))
    (else
     ;; L05–L06 一元：先 emit 唯一操作数
     (string-append
       (emit-ir (car args) ctx)
       (emit-unary-body name)))))

(define (emit-binop name left right ctx)
  (let ((si (ctx-si ctx)))
    (string-append
      (emit-ir left ctx)
      (emit-stack-save si)
      (emit-ir right (ctx-down ctx))
      (emit-binop-body name si))))
```

`emit-ir` 必须把 `ctx` 传到每一个子节点。`(imm n)` 忽略 `si`。

### aarch64-apple：栈与运算

```scheme
;; si 是负的 8 倍数，例如 -8、-16。写成十进制立即数即可。
(define (emit-stack-save si)
  (string-append "\tstr x0, [x29, #" (number->string si) "]\n"))

(define (emit-stack-load si dest-reg)
  (string-append "\tldr " dest-reg ", [x29, #" (number->string si) "]\n"))

(define (emit-binop-body name si)
  ;; 此刻：右值在 x0，左值在 [fp, #si]
  (string-append
    (emit-stack-load si "x9")
    (case name
      ((fx+) "\tadd x0, x9, x0\n")           ; 左 + 右
      ((fx-) "\tsub x0, x9, x0\n")           ; 左 - 右（不是右 - 左）
      ((fx*) (string-append
               "\tasr x9, x9, #2\n"          ; 去掉左值标签
               "\tmul x0, x0, x9\n"))        ; 带标签的右 × 去标签的左
      (else (error "binop" name)))))
```

`fx-` 的操作数顺序是合同：`(fx- 3 10)` → `-7`。写成 `sub x0, x0, x9` 会得到 `7`，测例会抓住。

`mul` 的 64×64→低 64 位就是 `mul`；不要用 `madd`，不要用 `umulh`。

### aarch64-apple：序言必须留局部区

把 L00 的 `emit-program` 跋改成先 `mov sp, x29`。若仍用 `ldp x29, x30, [sp], #16` 而 `sp` 还停在局部区底部，弹出的是栈上垃圾，返回地址毁掉，表现为「第一个二元测例就 SIGSEGV」。

本层仍不必保存 `x19`（`HP` 要到 L12）。不要提前改 `_scheme_entry` 的两参数约定。

Darwin 符号前缀 `_scheme_entry` 已在 L00 处理，本层不改。

## 测例清单

上一层全部测例仍须通过。

1. `(fx+ 1 2)` → `3`
2. `(fx+ -1 1)` → `0`
3. `(fx+ 0 0)` → `0`
4. `(fx- 3 10)` → `-7`
5. `(fx- 0 1)` → `-1`
6. `(fx- -5 -8)` → `3`
7. `(fx* 2 3)` → `6`
8. `(fx* -2 3)` → `-6`
9. `(fx* 0 99)` → `0`
10. `(fx* -4 -5)` → `20`
11. `(fx+ (fx+ 1 2) 3)` → `6`（嵌套在左）
12. `(fx+ 1 (fx+ 2 3))` → `6`（嵌套在右；必用 `si-8`，否则覆盖左值 `1`）
13. `(fx* (fx+ 1 2) (fx+ 3 4))` → `21`（两侧都是二元，栈槽不得撞车）
14. `(fxadd1 (fx+ 1 2))` → `4`；`(fx+ (fxadd1 1) (fxsub1 3))` → `4`
15. `(fx+ (fxneg 3) (fxneg -5))` → `2`
16. `(fx+)` / `(fx+ 1)` / `(fx+ 1 2 3)`：编译期 arity 错误。输入 `(+ 1 2)`：编译期未知原语（本层没有泛型 `+`）。

测例 11–13 是栈约定的验收核心，缺一不可。

## 验收标准

- 测例 1–15 输出与十进制字面量一致，含负号、无空格、一个末尾换行。
- 反汇编或读 `.s`：每个二元原语都能看到一次 `str x0, [x29, #…]` 与对应的 `ldr`。`(fx+ 1 (fx+ 2 3))` 的两个 `str` 立即数 **不同**。
- `fx*` 路径上恰好一次 `asr …, #2`（或等价 `sbfx`/`asr`），然后 `mul x0, x0, x9`（寄存器可对调，但积必须进 `x0`）。
- 生成代码无 `bl`，无对 `x18` 的引用。
- `(+ 1 2)` 不能碰巧算对：必须编译期拒绝，以免 L42 之前养成错误用户语法。

## 常见坑

- **右操作数仍用同一个 `si`**：`(fx+ 1 (fx+ 2 3))` 把 `1` 存到 `-8`，内层再把 `2` 存到 `-8`，最后变成 `(fx+ 2 3)` 或更糟。右操作数必须 `ctx-down`。
- **`fx-` 写成右减左**：`sub x0, x0, x9` 对 `(fx- 3 10)` 给出 `7`。左值在 `x9`，右值在 `x0`，`sub x0, x9, x0`。
- **`fx*` 两个都不去标签**：结果是真积的 4 倍（多了 `<<2`）。两个都去标签：结果是真积的 1/4，还丢了 fixnum 标签。
- **`fx*` 用 `lsr` 去标签**：负操作数会变成巨大无符号数。必须算术右移 `asr`。
- **忘了 `sub sp` 或跋里不恢复 `sp`**：第一个 `str` 或 `ret` 即崩。跋用 `mov sp, x29` 最不容易算错。
- **`add w0, w9, w0`**：高 32 位截断，负数与大整数失败。
- **提前实现 `+`**：测例与合同用 `fx+`。`+` 在 R4RS 里是任意 arity，现在做了以后要拆掉。
- **在 `x18` 或 `x16`/`x17` 里攒左值**：违反寄存器合同；左值进栈。

## 下一层预告

L08 用同一套「左值进栈、右值在 `x0`」的骨架做有符号比较，把结果写成 `#t`/`#f`。
