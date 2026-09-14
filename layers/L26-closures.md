# L26 — 带自由变量的真闭包

## 目标

`lambda` **可以引用外层绑定**。前端算出自由变量列表；`close` 在三字头之后多分配 `nfree` 个字，把当前环境里这些变量的 **值** 存进去。被调过程用 `SELF`（`x21`）按偏移取自由变量。

做完本层：`(let ((x 10)) ((lambda (y) (fx+ x y)) 5))` 打印 `15`。被 `set!` 且被捕获的变量走 L23 已经提供的 **box**（`%box` / `%unbox` / `%set-box!`），闭包里存的是盒子指针，不是过期栈槽。

本层范围之外：返回闭包后再在外层帧死亡的情况下调用（L27 专门测）、`letrec`、内部 `define`、尾调用、rest。无自由变量的 L24/L25 路径必须保持：`nfree=0` 仍 `emit-alloc 24`。

## 原理

### 自由变量

一个名字在 `lambda` 的 body 里被引用（含 `set!` 目标），且不是本 lambda 的形参、也不是 body 里更内层 `let`/`let*` 绑定的，它就是自由的。它必须在编译该 lambda 时的 `env` 里（否则 L18 未绑定错误）。

**列表顺序锁定**：按 body 里 **第一次出现** 的顺序去重。`close` 的初始化 IR 与 `emit-closure-ref` 的下标共用这张表。不要按字母排序另搞一套，除非你前端、后端、测例注释全部改成同一顺序——本教程不那么做。

```
(let ((x 10) (z 1))
  (lambda (y) (fx+ x y)))    ; fvs = (x)    z 未引用，不捕获
```

嵌套 lambda 的自由变量 **扁平抄一份** 到自己的闭包里，不把外层闭包当「静态链指针」追。本层先测「当前帧还活着时调用」；L27 再证明抄到堆上是必要的。

### IR

```
(code lid (y) (x) (prim fx+ (ref x) (ref y)))
(close lid (ref x))          ; 每个 fv 一个已在当前 env 可求值的 Ir
```

`(ref x)` 在 `close` 的初始化位置按 **当前过程的 env** 求值：可能是栈槽，也可能已经是外层的 `(free . index)`（本层若尚未返回闭包，外层仍在栈上）。`emit-close` 依次求值这些 IR，`str` 到 `fv0…`。

环境增加一种位置：

```
env : alist id → (stack . slot) | (free . index)
```

编译 lambda body 时：形参 → `stack`；每个 fv → `(free . 0..nfree-1)`。body 里的 `let` 仍分配新栈槽，并遮蔽同名 fv。

### 堆布局与 `emit-closure-ref`

沿用 L24 三字头：

```
+0   code
+8   arity     fixnum
+16  nfree     fixnum（本层可以 > 0）
+24  fv0       带标签 Scheme 值
+32  fv1
…
对象字节数 = 24 + 8 * nfree
标签 CLOSURE_TAG = 6
```

`SELF`（`x21`）保存 **tagged** 闭包。取第 `i` 个自由变量（ARCHITECTURE 的 `emit-closure-ref`）：

```
    sub  x9, x21, #6              ; untag
    ldr  x0, [x9, #(24 + 8*i)]
```

不要对 `x21` 原地去标签（否则第二次 ref 会再减 6）。临时只用 `x9`–`x15`。

`nfree` 字必须写成真实个数的 fixnum，便于以后调试和 GC 扫 fv 区间 `[24, 24+8*nfree)`。`code` 与 `arity` 不是 Scheme 指针。

### 赋值转换（捕获 + `set!`）

L23 已经锁定：凡被 `set!` 的 **let 绑定** 在绑定处就是 box，`ref` / `set!` 走 `%unbox` / `%set-box!`。本层不要改回「未捕获则写栈槽」——L23 测例依赖盒子路径。

本层补上 **lambda 形参** 的同一分析：body（含嵌套）里该形参是 `set!` 目标 → 序言 `%box` 再入槽。

捕获时看当前 env 里那一格 **已经是什么**：

| 变量 | 闭包 fv 里存什么 |
|------|------------------|
| 从未 `set!` | **值的拷贝**（fixnum、pair 指针、另一闭包……） |
| 已被 L23/形参分析装箱 | **盒子指针**（再拷一份指针，不拷槽里的旧 fixnum） |

分析范围是该绑定的整个作用域，不是「只看 lambda 内部有没有 set!」。反例：

```
(let ((x 10))
  (let ((f (lambda (y) (fx+ x y))))
    (begin (set! x 20) (f 5))))    ; 必须是 25，不是 15
```

L23 已把外层 `x` 变成 box。`close` 必须 `str` 那个 box 指针。若误 `unbox` 后再存 `10`，测例失败。

不要在后端「对栈槽取地址放进闭包」——那是死栈指针，L27 会爆。fv 槽里的盒子不必再包一层。

### 创建闭包时的寄存器

`emit-close` 的算法：

1. 先求值所有 fv IR，结果依次压进当前帧临时槽（每个 fv 求值都会打脏 `x0`，也可能 `blr`）。
2. `emit-alloc (24 + 8*nfree)` → 裸指针。
3. 填 `code`（`adr` / `adrp`+`add`，Darwin 局部标签）、fixnum arity、fixnum nfree。
4. 从临时槽 `ldr` 每个 fv，`str` 到 `+24+8*i`。
5. `orr` 上 `CLOSURE_TAG`，结果在 `x0`。

嵌套调用之后 `x21` 已由 callee 恢复，所以在某个过程体里 `close` 时，若某个 fv 来自 `(free . j)`，`emit-closure-ref` 仍然有效。这依赖 L24 锁定的 **callee 保存 `x21`**。不要在 `emit-close` 里另存一份 SELF，除非你实现错把 `x21` 当 caller-saved 用了。

### 调用协议不变

L24/L25：`x10` 闭包，`x9` 代码，`x8` argc，`blr x9`；callee 保存 `x21` 后 `mov x21, x10`。本层过程体第一次真正 **读取** `x21`。若某过程在两次 `emit-closure-ref` 之间做了 Scheme 调用，序言/跋协议必须把原来的 SELF 还回来，否则第二次 ref 读到被调方的闭包。

## 与上一层的差异

- `close` 带 fv 初始化；`nfree > 0` 时对象大于 24 字节。
- `env` 出现 `(free . index)`；`emit-ref` 分派到 `emit-closure-ref`。
- 前端必须做捕获分析；把 L23 的赋值转换扩到 lambda 形参。捕获已装箱变量时 fv 存盒子指针，不要先 unbox。
- 布局偏移 **不变**。L25 的多参与 arity 检查全部保留。

## 代码骨架

### 可移植：自由变量与装箱

```scheme
(define (free-vars expr formals env)
  (let ((seen '()))
    (define (add! x)
      (when (and (not (memq x formals))
                 (assq x env)
                 (not (memq x seen)))
        (set! seen (append seen (list x)))))
    (walk expr add!)     ; walk 进入内层 lambda 时，把它的 formals 并入「已绑定」
    seen))

(define (assigned-vars expr)
  ;; 返回 body 树里所有 set! 的目标名字（含嵌套 lambda）
  ...)

(define (should-box? id binding-body lambdas)
  (and (memq id (assigned-vars binding-body))
       (any (lambda (lam) (memq id (lambda-fvs lam))) lambdas)))
```

`walk` 进入 `(lambda (a b) e)` 时，递归 `free-vars e (append (a b) 当前已绑定)`，把内层的自由变量向上传递（若它们不是本层 formals）。

L23 对「被赋值的 let」已经降成 `%box`。本层 `close` 看到的 `(ref x)` 若 `x` 已装箱，求值结果就是盒子指针，直接存 fv。不要再 `%unbox` 一次再存。

未赋值的捕获不要额外 box：测例「捕获常量 10」与「捕获可变 x」行为必须不同。

形参赋值转换示例：

```scheme
;; 源：
;; (lambda (x) (begin (set! x (fxadd1 x)) x))
;; 序言后相当于槽上是 (%box 传入值)，body 为
(begin
  (%set-box! x (fxadd1 (%unbox x)))
  (%unbox x))
```

### IR 构造

```scheme
(define (compile-lambda formals body env add-code)
  (let* ((body-expr (normalize-body body))
         (fvs (free-vars body-expr formals env))
         (lid (gen-label "L_code_"))
         (body-env (append
                     (map (lambda (id i) (cons id `(free . ,i))) fvs (iota (length fvs)))
                     (bind-formals formals env)))
         (body-ir (expr->ir body-expr body-env add-code)))
    (add-code `(code ,lid ,formals ,fvs ,body-ir))
    `(close ,lid ,@(map (lambda (v) (expr->ir v env add-code)) fvs))))
```

注意：`close` 的 fv 初始化用 **外层** `env` 去 `expr->ir`，不是 `body-env`。对名字 `x`，外层可能是 `(stack . slot)`。

`bind-formals` 不要覆盖 fv 条目：形参与自由变量不应同名（同名则该名字不是自由的）。把 formals 放在 alist **前面**，让 `assq` 先碰到形参也可以，但此时 `x` 根本不该出现在 fvs 里。

### aarch64-apple：`emit-close` / `emit-closure-ref`

```scheme
(define (emit-closure-ref i)
  (string-append
    "\tsub x9, x21, #6\n"
    "\tldr x0, [x9, #" (number->string (+ 24 (* 8 i))) "]\n"))

(define (emit-close lid fv-irs ctx)
  (let* ((n (length fv-irs))
         (arity (label-arity lid))
         (nbytes (+ 24 (* 8 n)))
         (slots (map (lambda (_) (ctx-push-slot ctx)) fv-irs)))
    (string-append
      (emit-save-each fv-irs slots ctx)
      (emit-alloc nbytes)
      "\tmov x10, x0\n"
      (emit-load-label lid)
      "\tstr x9, [x10]\n"
      (emit-imm-to 'x9 (ash arity 2))
      "\tstr x9, [x10, #8]\n"
      (emit-imm-to 'x9 (ash n 2))
      "\tstr x9, [x10, #16]\n"
      (emit-store-fvs slots)
      "\torr x0, x10, #6\n")))

(define (emit-store-fvs slots)
  (let loop ((ss slots) (i 0) (acc ""))
    (if (null? ss)
        acc
        (loop (cdr ss) (+ i 1)
              (string-append acc
                (emit-stack-load (car ss))
                "\tstr x0, [x10, #" (number->string (+ 24 (* 8 i))) "]\n")))))
```

`emit-alloc` 打脏 `x0`，所以先把 fv 值放进栈槽。填字段时用 `x10` 钉住裸指针；`x0` 可当 fv 加载暂存。不要用 `x18`。不要把裸指针打标签后再 `str` 到 `+0`（code 槽是 raw）。

### `emit-ref`

```scheme
(define (emit-ref id ctx)
  (let ((loc (assq id (ctx-env ctx))))
    (cond
      ((not loc) (error "unbound" id))
      ((eq? (cadr loc) 'stack) (emit-stack-load (cddr loc)))
      ((eq? (cadr loc) 'free)  (emit-closure-ref (cddr loc)))
      (else (error "bad loc" loc)))))
```

`set!` 对 `free` 位置：本层若赋值转换正确，**不应该**还有对 `(free . i)` 的 `assign`——那条路径应已变成对 box 的 `%set-box!`，而 box 指针本身是只读拷贝在 fv 槽里。若你偷懒对 fv 槽 `str` 新值：那只改了这一份闭包的拷贝，其它捕获同一变量的闭包看不到；测例「两个 lambda 共享 x」会失败。锁定：对装箱变量禁止直接写 fv 槽。

## 测例清单

上一层全部测例仍须通过。

1. `(let ((x 10)) ((lambda (y) (fx+ x y)) 5))` → `15`
2. `(let ((x 10)) (let ((f (lambda (y) (fx+ x y)))) (f 5)))` → `15`
3. `(let ((a 1) (b 2)) ((lambda () (fx+ a b))))` → `3`（两个 fv，顺序 a 然后 b）
4. `(let ((x 1)) ((lambda () x)))` → `1`（0 形参，1 个 fv）
5. `(let ((x 10)) (let ((f (lambda (y) (fx+ x y)))) (begin (set! x 20) (f 5))))` → `25`
6. `(let ((x 1)) (let ((f (lambda () (begin (set! x (fxadd1 x)) x)))) (begin (f) (f))))` → `3`
7. `(let ((x 0)) (let ((inc (lambda () (set! x (fxadd1 x)))) (get (lambda () x))) (begin (inc) (inc) (get))))` → `2`（两闭包共享同一 box）
8. `(let ((x 4)) ((lambda (x) x) 9))` → `9`（形参遮蔽，不捕获外层）
9. `(let ((x 4)) ((lambda (y) (let ((x 1)) x)) 0))` → `1`（内部 let 遮蔽 fv）
10. `(let ((f (lambda (x) (lambda (y) y)))) ((f 1) 2))` → `2`（内层不捕获；为 L27 对照）
11. `(let ((x #t)) ((lambda () (if x 1 2))))` → `1`
12. `(let ((p (cons 1 2))) ((lambda () (car p))))` → `1`（捕获堆对象）
13. `(let ((x 1) (y 2) (z 3)) ((lambda () (fx+ z x))))` → `4`（只捕获用到的；中间 y 不进 nfree）
14. `((lambda (x) (let ((f (lambda (y) (fx+ x y)))) (f 4))) 3)` → `7`（捕获的是外层 **形参**）
15. `(let ((x 5)) (let ((f (lambda () x))) (f)))` → `5`
16. `(let ((n 2)) ((lambda (a b) (fx+ n (fx+ a b))) 3 4))` → `9`（多参 + 一个 fv）
17. `(let ((x 10) (g (lambda (z) z))) ((lambda (y) (fx+ x (g y))) 5))` → `15`（调用 `g` 之后仍要从 SELF 读 `x`，检验 callee 恢复 `x21`）

## 验收标准

- 测例 1–17 输出正确。
- 测例 5–7 失败几乎总是「按值捕获了可变变量」或「两个 lambda 各有一份 fixnum 拷贝」。必须共享 box。
- `nfree` 字等于真正写入的 fv 个数；未引用的外层绑定不得出现在对象里（可用调试打印或测例 13 的逻辑来约束：多捕获一般仍能算出 4，但不许漏捕获）。
- `emit-closure-ref` 使用偏移 `24+8*i`，SELF 保持 tagged。
- L24/L25 测例仍过；无 fv 的闭包仍是 24 字节。
- 无 `x18`；调用后仍能 `emit-closure-ref`（依赖 callee 恢复 `x21`）。

## 常见坑

- **fv 存栈地址**（`add x0, fp, #slot`）：本层外层帧还在，测例 1 可能假绿；L27 必炸。存 **值** 或 **box 指针**。
- **对 `x21` 做完 `sub` 写回 `x21`**：第二次 closure-ref 偏移全错。
- **先 `emit-alloc` 再求值 fv**：fv 求值若再分配（例如 `cons`）没问题，但若 fv 求值是 `call` 且你把裸指针留在 `x0`，指针丢了。先求 fv，再 alloc，再用 `x10` 钉住。
- **`close` 用 body-env 求 fv**：会从尚未存在的栈槽或从「自己的 free」读，而不是从外层。
- **捕获前先 unbox 再存 fv**：测例 5 得到 `15` 而不是 `25`。L23 的盒子必须原样进闭包。
- **两个闭包各 `%box` 一次**：测例 7 要求同一个 `let` 绑定只 box 一次（L23 已在绑定处做完），两个 `close` 存同一指针。
- **把 nfree 写成原始整数**：与 arity 字一样，堆上是 fixnum。偏移 16 的字对 `5` 个 fv 应是 `20`。
- **callee 未保存 `x21`**：`(lambda () (fx+ x (g)))` 若 `g` 是调用、`x` 在调用之后才 ref，会读错闭包。回到 L24 协议。

## 下一层预告

现在闭包几乎总是在「造出它的那一帧还在栈上」时被调用。L27 要处理闭包被 **返回** 之后、外层帧已经消失，再调用仍然正确。
