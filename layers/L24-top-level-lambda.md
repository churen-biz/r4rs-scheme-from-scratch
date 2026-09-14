# L24 — 顶层 `lambda` 与调用（无自由变量）

## 目标

程序第一次出现 **过程**：`(lambda (x) body)` 或 `(lambda () body)`，以及把过程当操作数的调用 `(e0)` / `(e0 e1)`。`lambda` **没有自由变量**；创建时在堆上分配闭包对象，调用时按约定跳进代码标签。

做完本层：`((lambda (x) x) 3)` 打印 `3`；`(lambda (x) x)` 作为程序的值打印 `#<procedure>`。`let` 绑定一个无捕获的 `lambda` 再调用，也必须能工作。

本层范围之外：两个及以上形参、arity 检查、`rest`、自由变量 / 真闭包、尾调用、`procedure?` 原语、顶层 `define`。遇到自由变量：**编译期报错**（留到 L26）。形参个数不是 0 或 1：**编译期报错**（留到 L25）。

## 原理

### 语言形状

在 L23 的表达式上增加：

```
E ::= … | (lambda () E+) | (lambda (id) E+) | (E) | (E E)
```

`E+` 表示一个或多个表达式，隐式 `begin`（沿用 L22）。空 body（`(lambda (x))`）编译期错。`(lambda x …)`、`(lambda (x . y) …)` 本层编译期错（rest 是 L33）。

求值：`lambda` 的结果是一个 **闭包值**（带 `CLOSURE_TAG` 的堆指针）。调用先求值操作数得到闭包，再求值实参（若有），然后跳到闭包里的代码。代码跑完，结果在 `RES`（`x0`）。

### 闭包堆布局（本层锁定）

ARCHITECTURE §2 把闭包写成 `[code][nfree][fv…]`。**从本层起偏离并钉死三字头**，以免 L25 再改偏移、把 L24 测例写崩：

```
去标签后的裸指针：
  +0   code    裸代码地址（raw pointer，不是 Scheme 值）
  +8   arity   fixnum，形参个数（0 或 1，已 << FX_SHIFT）
  +16  nfree   fixnum，自由变量个数（本层恒为 0）
  +24  fv0     第一个自由变量（本层不出现）
  …
指针标签：CLOSURE_TAG = 0b110 = 6
```

本层 `nfree = 0`，因此 `emit-alloc 24`（不是 16）。**即使还没有 arity 检查，也必须写出 arity 字**，这样 L25 只加比较，不改布局。

`code` 槽是机器地址，GC（L51）不得把它当带标签指针追。本层无 GC，只需不要对它 `rt_print` 解引用成 Scheme 对象。

### 调用约定（Scheme → Scheme）

| 角色 | 位置 | 本层 |
|------|------|------|
| 第 1 实参 / 返回值 | `x0` | 1 个形参时，进入过程时 `x0` 是那个实参；0 个形参时 **`x0` 不是实参**，body 结束时才把结果写入 `x0` |
| 参数个数 `argc` | `x8` | **未打标签的整数**（0 或 1），不是 fixnum。Apple 的 C ABI 里 `x8` 是间接结果寄存器；**C 调用不用它传 argc**，Scheme 内部调用可以用 |
| 当前闭包 `SELF` | `x21` | callee-saved。本层过程体还不读自由变量，但仍要建立协议，L26 才不会改 ABI |
| 被调代码指针 | `x9` | `ldr` 之后 `blr x9`。**禁止 `blr x18`**（Darwin 保留）。不要用 `x16`/`x17` 长期暂存 |
| 传入的闭包（tagged） | `x10` | `blr` **当时** `x10` 必须是本次要进入的那个闭包 |

实参从左到右求值。本层最多一个实参，求值操作数后把它压栈，再求值实参到 `x0`，再把闭包装回 `x10`。

### `x21` / SELF：callee-saved 协议（锁定）

每个 Scheme 过程都会把 `x21` 改成「自己的闭包」。若调用方在 `blr` **之前** `mov x21, 新闭包`，callee 序言保存的就是新闭包，调用方自己的 SELF 丢失——嵌套调用后无法再 `emit-closure-ref`。

因此锁定：

1. **调用方不额外保存 `x21`，也不在 `blr` 前覆盖 `x21`。** 把 tagged 闭包放进 `x10`，把代码指针放进 `x9`，`mov x8, #argc`，然后 `blr x9`。
2. **每个 Scheme 过程的序言保存 `x21`，跋恢复。** 保存之后立刻 `mov x21, x10`。这是 callee-saved 协议：嵌套调用回来后，当前过程的 SELF 还在。
3. **`scheme_entry` 保存 `x19`、`x20`、`x21`**（C 的 callee-saved）。`x19`=`HP`，`x20`=`HL` 沿用 L12；`x21` 本层开始会被 Scheme 过程弄脏。顶层表达式不是闭包，进入 `scheme_entry` 后把 `x21` 清零即可。

**不要**在 Scheme 过程的跋里恢复 `x19`/`x20`：它们是进程级堆指针，恢复等于把 bump 分配滚回去。

### IR

ARCHITECTURE 的过程节点本层全部启用：

```
(code <lid> (formals ...) (fvs ...) Ir)
(close <lid> Ir ...)     ; 本层 Ir… 为空，因为 nfree=0
(call Ir Ir ...)         ; 第一项是闭包
```

`(lambda (x) x)` 降为：登记一块 `(code L0 (x) () (ref x))`，在出现位置生成 `(close L0)`。

`((lambda (x) x) 3)` → `(call (close L0) (imm 12))`（3 的 fixnum 编码）。

前端维护一个 `codes` 列表；`emit-program` 先写 `_scheme_entry`（main IR），再写出所有 `code` 块。**禁止**为「直接调用」另做一套不经过闭包的 ABI——优化成跳标签是范围之外。所谓「直接调用」是指操作数为 `lambda` 表达式，例如 `((lambda (x) x) 3)`，仍然 `close` + `call`。

### 创建闭包

1. `emit-alloc 24` → 裸指针在 `x0`。
2. 把代码标签地址写入 `[x0]`。aarch64-apple：同一 `.text` 内用 `adr x9, L_code_0`（程序很小，±1MB 足够）；或 Darwin 的 `adrp x9, L_code_0@PAGE` / `add x9, x9, L_code_0@PAGEOFF`。标签本身是汇编局部标签，**不要**加 C 的 `_` 前缀（那是 `_scheme_entry`、`_rt_error` 用的）。
3. `[x0, #8]` ← arity 的 fixnum（0 → `0`，1 → `4`）。
4. `[x0, #16]` ← nfree 的 fixnum `0`。
5. `orr x0, x0, #CLOSURE_TAG`。

### 发出调用 `(e0 e1)`

```
求值 e0            ; tagged 闭包在 x0
str  x0, [fp, #tmp]
求值 e1            ; 实参在 x0
ldr  x10, [fp, #tmp]
; 可选：检查 (x10 & 7) == 6，否则 bl _rt_error
sub  x9, x10, #CLOSURE_TAG
ldr  x9, [x9]      ; code
mov  x8, #1        ; 原始 argc，不是 fixnum
blr  x9            ; 结果回到 x0
```

0 个实参的 `(e0)`：不求值 `e1`，`mov x8, #0`，`x0` 不作为实参传递（可保持未定义，callee 不得读它）。

临时寄存器只用 `x9`–`x15`。把代码地址装进 `x9` 再 `blr x9`，不要 `blr` 其它保留寄存器。

### 被调过程：序言、绑定、跋

```
L_code_0:
    stp  x29, x30, [sp, #-FRAMESIZE]!   ; FRAMESIZE 16 对齐，至少 32
    mov  x29, sp
    str  x21, [sp, #16]                 ; 保存调用方 SELF
    mov  x21, x10                       ; SELF := 本闭包（tagged）
    ; 本层可不 cmp x8（arity 检查 L25 强制）
    str  x0, [fp, #SLOT]                ; 1 个形参：把 x0 写入栈槽，env 记 (stack . slot)
    ; 0 个形参：不要把 x0 当成绑定
    … body …                            ; 结果在 x0
    ldr  x21, [sp, #16]
    ldp  x29, x30, [sp], #FRAMESIZE
    ret
```

`FRAMESIZE = align16(24 + 8 * nlocals)`：`fp/lr` 16 字节 + `x21` 与填充 8+8 + 局部槽。调用点 `sp` 必须 16 字节对齐。

形参可以 `set!`。L23 已锁定：**凡被 `set!` 的绑定都做赋值转换（槽里是 box）**。把同一规则扩到形参：若 body 里该形参是 `set!` 目标，序言里对 `x0` 做 `%box` 再写入槽；之后 `ref` / `set!` 走 `%unbox` / `%set-box!`。从未赋值的形参仍是裸值。`(lambda (x) (begin (set! x 3) x))` 合法，结果 `3`。本层没有捕获，盒子活在当前帧的槽里就够。

### 非过程调用

操作数低 3 位不是 `CLOSURE_TAG`：运行时 `rt_error`，stderr 含 `procedure` 或 `closure`。不要默默 `blr` 垃圾地址。

### 打印

`rt_print` 增加：

```c
if ((x & 7) == CLOSURE_TAG) { printf("#<procedure>\n"); return; }
```

R4RS 不规定过程的 `write` 文本；本教程锁定 `#<procedure>`。

### 自由变量检查

编译 `lambda` 时计算 body 相对 **本 lambda 形参** 的自由变量。还要扣掉 body 内部 `let`/`let*` 绑定的名字。若集合非空 → `error`「L24: free variable」。`(let ((x 1)) (lambda (y) y))` 合法（没有捕获）。`(let ((x 1)) (lambda (y) x))` 本层非法。

## 与上一层的差异

- 第一次出现堆对象标签 `CLOSURE_TAG`，第一次发出 `blr`。
- IR 增加 `code` / `close` / `call`；`emit-program` 输出多块代码。
- `scheme_entry` 必须保存 `x21`（以及既有的 `x19`/`x20`）。
- 环境 `env` 增加形参栈槽；本层还没有 `(free . index)`。
- `rt_print` 认识闭包。
- 闭包头是 **三字** `[code][arity][nfree]`，与 ARCHITECTURE 两字头不同；以本层为准，后续过程层不得改偏移。

## 代码骨架

### 可移植前端

```scheme
(define CLOSURE_TAG 6)
(define VOID #x1F)

(define (compile-program expr)
  (let ((codes '()))
    (define (add-code c) (set! codes (append codes (list c))))
    (let ((main (expr->ir expr '() add-code)))
      (emit-program codes main))))

;; env: alist id -> (stack . slot)
(define (expr->ir expr env add-code)
  (cond
    ((and (pair? expr) (eq? (car expr) 'lambda))
     (compile-lambda (cadr expr) (cddr expr) env add-code))
    ((and (pair? expr) (not (special-form? (car expr))))
     `(call ,@(map (lambda (e) (expr->ir e env add-code)) expr)))
    ;; let / if / begin / set! / prim / ref / imm ：沿用 L23
    (else (expr->ir-core expr env add-code))))

(define (compile-lambda formals body env add-code)
  (unless (or (null? formals)
              (and (pair? formals) (null? (cdr formals)) (symbol? (car formals))))
    (error "L24: only 0 or 1 formal" formals))
  (when (null? body) (error "L24: empty lambda body"))
  (let* ((fvs (free-vars (if (null? (cdr body)) (car body) `(begin ,@body))
                         formals env)))
    (unless (null? fvs)
      (error "L24: lambda has free variables" fvs))
    (let* ((lid (gen-label "L_code_"))
           (body-env (bind-formals formals env))
           (body-ir (expr->ir (if (null? (cdr body)) (car body) `(begin ,@body))
                              body-env add-code)))
      (add-code `(code ,lid ,formals () ,body-ir))
      `(close ,lid))))
```

`free-vars` 走语法树：`ref` 到不在 formals、而在外层 `env` 里的名字则计入；未绑定仍按 L18 编译期错。`gen-label` 生成 `L_code_0`、`L_code_1`… 不要生成裸 `L0`（部分汇编器把数字局部标签当另类语法）。

### aarch64-apple：`scheme_entry`

```scheme
(define (emit-program codes main-ir)
  (string-append
    "\t.text\n"
    "\t.globl _scheme_entry\n"
    "\t.p2align 2\n"
    "_scheme_entry:\n"
    "\tstp x29, x30, [sp, #-48]!\n"
    "\tmov x29, sp\n"
    "\tstp x19, x20, [sp, #16]\n"
    "\tstr x21, [sp, #32]\n"
    "\tmov x19, x0\n"
    "\tadd x20, x19, x1\n"
    "\tmov x21, xzr\n"
    (emit-ir main-ir (make-ctx))
    "\tldr x21, [sp, #32]\n"
    "\tldp x19, x20, [sp, #16]\n"
    "\tldp x29, x30, [sp], #48\n"
    "\tret\n"
    (apply string-append (map emit-code-object codes))))
```

帧 48 字节：16（fp/lr）+ 16（x19/x20）+ 16（x21 + 填充）。不要用 `x18`。

### `emit-close`（nfree=0）

```scheme
(define (emit-close lid fv-irs ctx)
  (unless (null? fv-irs) (error "L24: unexpected fvs" fv-irs))
  (let ((arity (label-arity lid)))
    (string-append
      (emit-alloc 24)
      "\tmov x10, x0\n"
      (emit-load-label lid)          ; adr x9, LID
      "\tstr x9, [x10]\n"
      (emit-imm-to 'x9 (ash arity 2))
      "\tstr x9, [x10, #8]\n"
      "\tstr xzr, [x10, #16]\n"      ; nfree fixnum 0
      "\torr x0, x10, #6\n")))

(define (emit-load-label lid)
  ;; Darwin 局部标签：无下划线。adr 与 adrp/add 二选一。
  (string-append "\tadr x9, " lid "\n"))
  ;; 备选：
  ;; (string-append "\tadrp x9, " lid "@PAGE\n"
  ;;                "\tadd x9, x9, " lid "@PAGEOFF\n")
```

### `emit-call`

```scheme
(define (emit-call operator-ir arg-irs ctx)
  (let* ((tmp (ctx-push-slot ctx)))
    (string-append
      (emit-ir operator-ir ctx)
      (emit-stack-save tmp)
      (emit-args-left-to-right arg-irs ctx)
      (emit-stack-load tmp)          ; 闭包 → x0
      "\tmov x10, x0\n"
      "\tand x9, x10, #7\n"
      "\tcmp x9, #6\n"
      "\tb.ne L_err_not_proc\n"
      "\tsub x9, x10, #6\n"
      "\tldr x9, [x9]\n"
      "\tmov x8, #" (number->string (length arg-irs)) "\n"
      "\tblr x9\n"))))
```

`L_err_not_proc` 是汇编里一块 `adrp/add` 装 C 字符串再 `bl _rt_error` 的共享 stub，放在 `emit-program` 末尾。消息例如 `not a procedure`。

### `emit-code-object`

```scheme
(define (emit-code-object c)
  (let* ((lid (cadr c))
         (formals (caddr c))
         (body (car (cddddr c)))
         (nslots (+ 1 (count-locals body)))  ; 至少给一个形参槽
         (framesize (align16 (+ 32 (* 8 nslots)))))
    (string-append
      "\t.p2align 2\n"
      lid ":\n"
      "\tstp x29, x30, [sp, #-" (number->string framesize) "]!\n"
      "\tmov x29, sp\n"
      "\tstr x21, [sp, #16]\n"
      "\tmov x21, x10\n"
      (if (null? formals)
          ""
          "\tstr x0, [fp, #24]\n")
      (emit-ir body (code-ctx formals framesize))
      "\tldr x21, [sp, #16]\n"
      "\tldp x29, x30, [sp], #" (number->string framesize) "\n"
      "\tret\n")))
```

1 个形参时 env 把该 id 映射到 `[fp, #24]`（或你统一的 slot 编号）。0 个形参不要读 `x0`。

### runtime 打印

```c
#define CLOSURE_TAG 6

void rt_print(ptr x) {
    if ((x & 7) == CLOSURE_TAG) { printf("#<procedure>\n"); return; }
    /* 其余沿用 L23 */
}
```

`scheme.h` 增加 `#define CLOSURE_TAG 6`，与编译器常量相同。

## 测例清单

上一层全部测例仍须通过。

1. `((lambda (x) x) 3)` → `3`
2. `((lambda (x) (fxadd1 x)) 41)` → `42`
3. `((lambda () 7))` → `7`
4. `((lambda () #t))` → `#t`
5. `((lambda (x) (fx+ x x)) 5)` → `10`
6. `(lambda (x) x)` → `#<procedure>`
7. `(let ((f (lambda (x) x))) (f 9))` → `9`
8. `(let ((f (lambda () 42))) (f))` → `42`
9. `((lambda (x) ((lambda (y) y) x)) 4)` → `4`（内层不捕获，合法）
10. `(((lambda () (lambda (x) x))) 8)` → `8`（返回无自由变量的闭包再调用）
11. `((lambda (x) (if x 1 2)) #f)` → `2`
12. `((lambda (x) (begin (set! x 3) x)) 1)` → `3`（形参被 `set!`，走 L23 的 box，不是捕获）
13. `(let ((x 1)) (lambda (y) y))` → `#<procedure>`
14. `(3 4)`：运行时错误，stderr 含 `procedure` 或 `closure`，退出码非 0。
15. `(let ((x 1)) (lambda (y) x))`：编译期错（自由变量）。
16. `(lambda (a b) a)`：编译期错（两个形参，等 L25）。
17. `(lambda x x)`：编译期错（rest）。
18. `((lambda (x) (cons x ())) 1)` → `(1)`（若 L13 打印如此；空表是 `()`）。

## 验收标准

- 测例 1–13、18 退出码 0，标准输出恰好一行（含换行），与上表一致。
- 测例 14 非 0 退出；15–17 在编译期失败，不得生成能链接的错程序。
- 生成代码对 Scheme 调用使用 `blr x9`，全文无 `x18`。
- 闭包对象 24 字节：偏移 0/8/16 分别为 code、fixnum arity、fixnum 0。
- `scheme_entry` 保存并恢复 `x19`、`x20`、`x21`。每个 `L_code_*` 序言保存 `x21`、跋恢复。
- Darwin 代码标签无多余 `_` 前缀；C 符号仍是 `_scheme_entry`、`_rt_error`。
- 本层不要求 arity 不匹配时报错；也不许靠「跳过堆、直接 `bl` 标签」让测例 1 碰巧通过——必须能返回 `#<procedure>`（测例 6）。

## 常见坑

- **`blr` 前把新闭包写入 `x21`**：callee 保存的是自己，调用方 SELF 丢了。闭包走 `x10`。
- **`emit-alloc 16`**：那是两字头。本层三字头，24 字节，nfree 在 **偏移 16**。
- **arity 字存原始整数 1 而不是 fixnum `4`**：以后若有人当 Scheme 值读会当 fixnum `0` 或垃圾。锁定存 fixnum。`x8` 则是原始 argc，两边不要混。
- **Darwin 标签写成 `_L_code_0` 还去 `adrp _L_code_0@PAGE`**：C 符号才要下划线。局部标签 `L_code_0`。
- **0 形参过程把 `x0` 当参数**：caller 可能留下任意值，body 若误读会红。
- **Scheme 跋 `ldp x19, x20`**：HP 回滚，后续 `cons` 覆盖旧对象。只在 `scheme_entry` 恢复它们。
- **`sp` 少对齐 8 字节**：`FRAMESIZE` 必须是 16 的倍数；`stp … #-24` 非法。
- **对闭包 `car`/`rt_print` 当 pair**：低 3 位是 `110` 不是 `001`。打印必须走 `CLOSURE_TAG` 分支。
- **内层 lambda 引用外层形参却没报错**：本层应编译期拒绝，否则 L26 测例无法区分「你已经捕获了」和「你读了死栈」。

## 下一层预告

现在过程只能有 0 或 1 个形参，传错个数也可以不报错。L25 要让 `(lambda (a b c) …)` 工作，并在个数不对时变成一次明确的运行时错误。
