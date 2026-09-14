# L23 — `set!`、VOID，以及赋值转换（box）

## 目标

用户语法：

```scheme
(set! id Expr)
```

- `id` 必须已在 `env` 中（`let` / `let*` 绑定）。未绑定 → **编译期错误**。
- 求值 `Expr`，把新值写入该变量，**整个 `set!` 的值为 VOID**（打印 `#<void>`）。
- 之后在同一绑定的作用域里 `ref` 该名字，须看见新值。

本层实现堆对象 **box**：

```
BOX_TAG = 0b100
布局（去标签后）： [ val:word ]
```

内部原语（测例可调用，名字带 `%`，不是 R4RS）：`%box`、`%unbox`、`%set-box!`。

**赋值策略（锁定，二选一已选定）**：

> **对每一个在其作用域内成为 `set!` 目标的绑定，做赋值转换：绑定的是 box，而不是裸值。**  
> `ref` 该变量 → `%unbox`；`set!` → `%set-box!`（返回 VOID）。  
> 从未被 `set!` 的变量仍是栈上裸值，与 L18–L22 相同。

本层即使还没有 `lambda`，也做这一转换。多一次 `emit-alloc 8`，换 L26 捕获赋值变量时已经是「槽里是盒子指针，闭包拷这一格」——不必回头改 `set!`。

备选（**不要做**）：本层只 `str` 到栈槽，L26 再给「被赋值且被捕获」的变量加 box。那样 L23 稍快，L26 必须重写前端与所有 `set!` 测例路径。合同拒绝这条路。

本层范围之外：`(set-car! …)` 不是 `set!`（已是 L15）；`set!` 的 `id` 不是 `car`；顶层 `define` / 顶层赋值（以后）；对未装箱槽的用户级 `set!`；`box?` 用户谓词（可用 `%unbox` 测内部原语）。

## 原理

### 为何闭包之前就要 box

栈槽赋值对「当前帧、无逃逸」足够：

```asm
    ; 求值 Expr 到 x0
    str     x0, [x29, #off]
    mov     x0, #0x1F
```

一旦 L26 把变量关进闭包，闭包活得比分配它的帧久，帧上的槽会消失。若该变量还可 `set!`，逃逸的是**单元格**，不是某一时刻的快照。单元格就是 box：堆上一个带标签的字。

两种常见切法：

1. 仅当「被赋值 ∧ 被捕获」时装箱（精确，分析重）。
2. 凡被赋值就装箱，捕获不捕获都一样（多分配，分析轻）。

本教程锁 **2**。没有 `lambda` 时「被捕获」恒假，若选 1 则本层退化成纯栈写，L26 仍要上盒子。选 2 让盒子路径本层就可测。

### 赋值分析（带遮蔽）

在 `expand`（`let*` / `and` / `or` 已消失）之后、降 IR 时，对每个 `let` 绑定 `id` 问：`body` 里是否有以这个 `id` 为**目标**的 `set!`，且中间没有同名绑定把它挡住。

```
assigned?(id, e):
  (set! id E)                         → true（仍要递归看 E，但对本问已 true）
  (set! other E)                      → assigned?(id, E)
  (let ((id E1)) B)                   → assigned?(id, E1)   ;; 内层同名：body 里的 set! 不算外层
  (let ((y  E1) ...) B)  y≠id         → 任一 rhs 或 body 里 assigned?
  (begin …) / (if …) / (prim …)       → 任一子表达式
  其它叶                              → false
```

并行 `let` 多个绑定：每个 `id` 单独问 **body**（以及本组？）。同组 rhs **看不见**新名字，rhs 里的 `(set! id …)` 若 `id` 是本组正在绑的名字，则指向**外层**同名（或 unbound）。因此「本组 `x` 是否装箱」只看 body（加内层非遮蔽处），不看同组 rhs。

`let*` 已展开，分析器不必认识 `let*`。

```scheme
(let ((x 1)) (begin (set! x 2) x))           ; 外层 x 装箱
(let ((x 1)) (begin (let ((x 2)) (set! x 3)) x))
                                             ; 外层 x 未赋值；内层 x 装箱
(let ((x 1)) (let ((y (begin (set! x 2) 0))) y))
                                             ; 外层 x 被内层 rhs 赋值 → 装箱
```

分析必须在降 `let` 之前知道结果，因为 rhs 要包不包 `%box` 取决于 body（及嵌套）里有没有 `set!`。先扫描再降，或两遍。

### 转换后的 IR 形状

源：

```scheme
(let ((x 1))
  (begin
    (set! x 2)
    x))
```

IR（fixnum 已标签）：

```
(let ((x (prim %box (imm 4))))
  (seq
    (prim %set-box! (ref x) (imm 8))
    (prim %unbox (ref x))))
```

- 绑定槽里是 **box 指针**（`BOX_TAG`）。
- `(ref x)` 只 load 指针，从不把裸 1/2 放在这个槽里（该变量被赋值过）。
- 用户 `set!` **不**降成 IR `(assign x …)`。ARCHITECTURE 的 `(assign id Ir)` 与 `emit-assign` 仍要实现：语义为「把右值 `str` 进该 id 的栈槽并返回 VOID」，供未走转换的内部路径或调试。**本层前端对用户 `set!` 不发出 `assign`。** 测例不要混用两条路。

未赋值变量：

```scheme
(let ((x 1)) x)
```

仍是 `(let ((x (imm 4))) (ref x))`，无 `%box`。

### 内部原语

| 原语 | 含义 | 返回 |
|------|------|------|
| `(%box v)` | `emit-alloc 8`，把 `v` 写入该字，指针 OR `BOX_TAG` | box |
| `(%unbox b)` | 去标签，`ldr` 槽内值 | 原值 |
| `(%set-box! b v)` | 去标签，`str v`；**返回 VOID** | VOID |

`%box` 的操作数、`%set-box!` 的 `v` 任意本层值（含另一个 box）。`%set-box!` 与 `%unbox` 本层**不做**标签检查；错标签未定义。不要提供用户语法 `box?`。

`%box` / `%unbox` / `%set-box!` 走已有 `emit-prim` 与二元栈协议（先求 box，save，再求 v）。

### aarch64 序列

`%box`（`v` 已在 `x0`；`HP` 仍是 `x19`）：

```asm
    str     x0, [x29, #off]        ; 保存 v（若 alloc 会用 x0）
    ; emit-alloc 8：旧 HP → x0（裸指针），HP += 8（已 8 对齐）
    ldr     x9, [x29, #off]        ; v
    str     x9, [x0]
    orr     x0, x0, #4             ; BOX_TAG
```

若 `emit-alloc` 约定不破坏你保存 v 的槽，按 L12/L13 的 `cons` 同样模式：先把 payload 放栈再 alloc。不要让 `v` 只活在 `x0` 里穿过 `emit-alloc`。

`%unbox`：

```asm
    ; x0 = tagged box
    bic     x9, x0, #7             ; 或 sub x9, x0, #4
    ldr     x0, [x9]
```

`%set-box!`（`v` 在 `x0`，box 在槽 `si`）：

```asm
    ldr     x9, [x29, #off_box]
    bic     x9, x9, #7
    str     x0, [x9]
    mov     x0, #0x1F
```

去标签用 `bic …, #7` 与 `sub …, #4` 对合法 box 等价（低 3 位恰好 `100`）。与 pair 的 `sub #1` 同一风格即可。

### 求值顺序

`(set! x Expr)`：先完全求值 `Expr`（此时 `ref x` 仍是旧值，可能 `%unbox`），再 `%set-box!`。

```scheme
(let ((x 1))
  (begin
    (set! x (fxadd1 x))
    x))                              ; → 2
```

`(set! x x)` 是合法的无操作（仍返回 VOID）。

### 打印 box

若程序根表达式返回 box（例如 `(%box 1)`），`rt_print` 打 `#<box>`，**不要**自动 unbox 成 `1`（以免和 fixnum 测例混淆）。观察内容一律 `%unbox`。未知标签不要 silently 当 fixnum。

```
; 算法伪代码：实现必须是 runtime 汇编，不是 C。
; BOX_TAG 4

if ((x & 7) == BOX_TAG) { write("#<box>\n"); return; }
```

`runtime.s 标签注释` 增加 `BOX_TAG`。VOID 打印已在 L22。

### `emit-assign`（接口完整，用户路径不用）

```scheme
(define (emit-assign id ir ctx)
  (let ((loc (env-lookup id (ctx-env ctx))))
    (string-append
      (emit-ir ir ctx)
      (emit-stack-save (cdr loc))
      (emit-void))))
```

若误对**已装箱**变量发 `assign`，会把裸值覆写进本应是 box 指针的槽，随后 `%unbox` 会把 fixnum 当指针——测例崩。这是前端发错 IR 的 bug，不是再给 `emit-assign` 加 unbox 的理由。

### 仍禁止的语法

| 形式 | 处理 |
|------|------|
| `(set! x 1)` 无绑定 | 编译期 `unbound` |
| `(set! 1 2)` | 编译期错误（目标不是标识符） |
| `(set! (car p) 1)` | 编译期错误；用户应写 `set-car!` |
| 顶层 `(set! x 1)` | 与无绑定相同，本层无全局环境 |
| `(set!)` / `(set! x)` | arity 错误 |

`let` body 仍是单表达式：`(let ((x 1)) (set! x 2) x)` 非法；写成 `(let ((x 1)) (begin (set! x 2) x))`。

## 与上一层的差异

| 项 | L22 | L23 |
|----|-----|-----|
| 可变绑定 | 无 | `set!` + 赋值转换 |
| IR | `seq` / `let` / `ref` | 用户 `set!` → `%set-box!`；可有 `assign` 接口 |
| 堆标签 | pair/vector/string | 增加 `BOX_TAG` |
| 内部原语 | — | `%box` `%unbox` `%set-box!` |
| 未赋值 `let` | 裸槽 | 仍裸槽（不要无故全装箱） |

## 代码骨架

### 可移植：分析 + 降 IR

```scheme
(define BOX_TAG 4)

(define (any pred xs)
  (and (pair? xs)
       (or (pred (car xs)) (any pred (cdr xs)))))

(define (assigned-in? id expr)
  (cond
    ((and (pair? expr) (eq? (car expr) 'set!) (>= (length expr) 3))
     (or (eq? (cadr expr) id)
         (assigned-in? id (caddr expr))))
    ((and (pair? expr) (eq? (car expr) 'let))
     (let ((binds (cadr expr))
           (body (caddr expr)))
       (or (any (lambda (b) (assigned-in? id (cadr b))) binds)
           (if (memq id (map car binds))
               #f
               (assigned-in? id body)))))
    ((and (pair? expr) (eq? (car expr) 'begin))
     (any (lambda (e) (assigned-in? id e)) (cdr expr)))
    ((pair? expr)
     (any (lambda (e) (assigned-in? id e)) expr))
    (else #f)))

(define (boxed-in-env? id env)
  (cond
    ((null? env) (error "unbound variable" id))
    ((eq? (caar env) id) (eq? (cdar env) 'boxed))
    (else (boxed-in-env? id (cdr env)))))

(define (extend-env-flags ids box?s env)
  (if (null? ids)
      env
      (extend-env-flags
        (cdr ids) (cdr box?s)
        (cons (cons (car ids) (if (car box?s) 'boxed 'bare)) env))))

(define (expr->ir expr env)
  (cond
    ((and (pair? expr) (eq? (car expr) 'set!))
     (if (not (and (= (length expr) 3) (symbol? (cadr expr))))
         (error "L23: bad set!" expr)
         (begin
           (if (not (boxed-in-env? (cadr expr) env))
               (error "L23: set! of unboxed var (analysis missed)" (cadr expr)))
           `(prim %set-box! (ref ,(cadr expr)) ,(expr->ir (caddr expr) env)))))
    ((symbol? expr)
     (if (boxed-in-env? expr env)
         `(prim %unbox (ref ,expr))
         (begin (env-lookup-exists expr env) `(ref ,expr))))
    ((and (pair? expr) (eq? (car expr) 'let))
     (lower-let expr env))
    (else (expr->ir-core expr env))))

(define (lower-let expr env)
  (call-with-values
    (lambda () (parse-let expr))
    (lambda (binds body)
      (let* ((ids (map car binds))
             (box?s (map (lambda (id) (assigned-in? id body)) ids))
             (env2 (extend-env-flags ids box?s env))
             (ir-rhs*
              (map (lambda (b box?)
                     (let ((ir (expr->ir (cadr b) env)))  ; 并行：旧 env
                       (if box? `(prim %box ,ir) ir)))
                   binds box?s)))
        `(let ,(map list ids ir-rhs*)
           ,(expr->ir body env2))))))
```

前端 `env` 本层起要能区分 **boxed / 裸**：例如 `(id . boxed)` / `(id . bare)`。后端 `env` 仍是 `id → (stack . slot)`——槽里装的是值还是 box 指针，后端不需要知道；`%unbox` 是 prim。

并行 `let` 的 rhs 仍在旧 `env` 下降（L20）。若 rhs 里 `set!` 外层已装箱变量，`(ref …)` 会走 `%unbox`，正确。

### aarch64-apple：`emit-prim` 分派

```scheme
(define (emit-prim name args ctx)
  (case name
    ((%box)
     (let ((si (ctx-si ctx))
           (off (slot-offset (ctx-si ctx))))
       (string-append
         (emit-ir (car args) ctx)
         (ensure-frame-covers si)
         (emit-stack-save si)
         (emit-alloc 8)                 ; 裸指针在 x0
         "\tmov x10, x0\n"
         "\tldr x9, [x29, #" (number->string off) "]\n"
         "\tstr x9, [x10]\n"
         "\torr x0, x10, #4\n")))
    ((%unbox)
     (string-append
       (emit-ir (car args) ctx)
       "\tbic x9, x0, #7\n"
       "\tldr x0, [x9]\n"))
    ((%set-box!)
     (let ((si (ctx-si ctx))
           (off (slot-offset (ctx-si ctx))))
       (string-append
         (emit-ir (car args) ctx)
         (ensure-frame-covers si)
         (emit-stack-save si)
         (emit-ir (cadr args) (make-ctx (+ si 1) (ctx-env ctx)))
         "\tldr x9, [x29, #" (number->string off) "]\n"
         "\tbic x9, x9, #7\n"
         "\tstr x0, [x9]\n"
         (emit-void))))
    (else (emit-prim-L22 name args ctx))))
```

`%box` 与 `cons` 同一套路：payload 先入栈，alloc 后不要用会覆盖 `x0` 的 `emit-stack-load` 把裸指针丢掉。`%set-box!` 走 L07 二元 save 协议，最后 `emit-void`。

`emit-program` 跋继续 `mov sp, x29` 再恢复 FP 链。box 在堆上，不随 `sp` 收回而消失（本层程序结束即进程结束，无观察问题）。

## 测例清单

上一层全部测例仍须通过。

1. `(let ((x 1)) (begin (set! x 2) x))` → `2`
2. `(let ((x 1)) (set! x 2))` → `#<void>`
3. `(let ((x 1)) (begin (set! x (fxadd1 x)) x))` → `2`（rhs 见旧值）
4. `(let ((x 0)) (begin (set! x 1) (set! x (fx+ x x)) x))` → `2`（连续赋值可见）
5. `(let ((x 1)) (begin (let ((x 2)) (set! x 3)) x))` → `1`（内层 `set!` 不碰外层）
6. `(let ((x 1)) (let ((x 2)) (begin (set! x 3) x)))` → `3`
7. `(set! x 1)`：编译期 `unbound`
8. `(let ((x 1)) (set! y 2))`：编译期 `unbound`
9. `(%unbox (%box 42))` → `42`
10. `(%set-box! (%box 1) 2)` → `#<void>`
11. `(let ((b (%box 1))) (begin (%set-box! b 5) (%unbox b)))` → `5`
12. `(let ((x 1) (y 2)) (begin (set! x y) (set! y 0) (cons x y)))` → `(2 . 0)`
13. `(let ((x 1)) (begin (set! x 2) (let ((y x)) y)))` → `2`（赋值后经 `let` 仍可见）
14. `(let ((x 1)) (begin (set! x 2) (let ((x 3)) x)))` → `3`（遮蔽不受外层赋值影响）
15. `(let ((x 1)) (let ((y 0)) (begin (set! y x) (set! x 9) (fx+ x y))))` → `10`
16. `(%box 1)` → `#<box>`
17. `(set! 1 2)`：编译期错误
18. `(let ((x 1)) (begin (set! x (cons x x)) x))` → `(1 . 1)`
19. 未赋值变量不分配 box：`(let ((x 4)) (fx+ x x))` → `8`（行为同 L19；生成代码不应有 `%box` / `BOX_TAG` 的 `orr`，可用 `.s` 抽查）
20. `(let* ((x 1) (y 0)) (begin (set! y x) (set! x 5) (fx+ x y)))` → `6`

## 验收标准

- 测例 1、3–6、9、11–15、18、20 打印正确；2、10 为 `#<void>\n`；16 为 `#<box>\n`。
- 测例 7、8、17 编译期失败。
- 被 `set!` 的变量：对应 `let` 的 rhs 外有 `%box`；每次用户 `ref` 经 `%unbox`；`set!` 经 `%set-box!`。
- 从未 `set!` 的绑定不得无故装箱（测例 19）。
- 内层同名 `set!` 不改变外层（测例 5）。
- `BOX_TAG` 在编译器与 `runtime.s 标签注释` 均为 `4`；布局仅一字 payload。
- 用户 `set!` 的 IR 不含裸槽 `assign`（或你若发出了，必须仍先保证槽内是 box——与锁定冲突，故不要发）。
- L22 的 mutator VOID 与 `begin` 测例仍绿。

## 常见坑

- **只 `str` 到栈却声称做了赋值转换**：测例 1 会绿，L26 必翻车。本层用 `%unbox` / `%box` 测例 9–11、16 钉死盒子路径。
- **外层因内层同名 `set!` 被装箱甚至被改**：分析忘记遮蔽。测例 5。
- **`set!` 的 rhs 里 `ref x` 走了已经 store 的新值**：必须先算完 rhs。`(set! x (fxadd1 x))` 否则可能读垃圾或新值，测例 3 钉死。
- **装箱变量的 `ref` 忘记 unbox**：返回 `#<box>`，测例 1 会红。
- **全部变量都 `%box`**：未赋值测例仍可能绿，但浪费且掩盖分析 bug。测例 19 抽查。
- **`%set-box!` 返回 box 或 `v`**：打印不是 `#<void>`。与 L22 mutator 同一收尾。
- **`bic x9, x0, #4` 去标签**：`#4` 只清 bit 2；应清低 3 位或减 `BOX_TAG`。pair 用错掩码同样是经典坑。
- **把 `set-car!` 改成走 `set!`**：目标不是标识符。`set!` 与字段 mutator 分路径。

## 下一层预告

还没有用户过程：不能写 `lambda`，也不能调用除原语以外的东西。下一层要能编译无自由变量的 `lambda` 并调用它。
