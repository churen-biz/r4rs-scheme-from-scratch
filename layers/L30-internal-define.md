# L30 — 内部 `define` 变换为 `letrec`

## 目标

过程（以及 `let` / `let*` / `letrec`）的 **body 开头** 允许 R4RS 内部定义。前端扫描连续的 `define`，改写成 `letrec`，再走 L28/L29 的盒子降级。混合「先表达式后 `define`」是编译期错误。

做完本层：

```
((lambda (x)
   (define (sq n) (fx* n n))
   (sq x))
 4)
```

打印 `16`。两个内部函数互递归也必须工作（因为降成多绑定 `letrec`）。

本层范围之外：**顶层** `define` / `load`（L45）、`begin` 把内部 `define` splice 进 body（R4RS 允许这种 begin；本层不强制，遇到表达式 `begin` 包着的 `define` 不当内部定义）、卫生宏、`define-syntax`。不要把顶层程序当成「lambda body」来扫描。

## 原理

### R4RS body

`<body>` = 零个或多个定义，后跟一个或多个表达式。出现在：`lambda`、`let`、`let*`、`letrec`。内部定义的区域等于包一层 `letrec`：

```
(lambda ⟨formals⟩
  (define ⟨var1⟩ ⟨exp1⟩)
  …
  (define ⟨varn⟩ ⟨expn⟩)
  ⟨expr1⟩
  …
  ⟨exprm⟩)
≡
(lambda ⟨formals⟩
  (letrec ((⟨var1⟩ ⟨exp1⟩)
           …
           (⟨varn⟩ ⟨expn⟩))
    ⟨expr1⟩
    …
    ⟨exprm⟩))
```

`m ≥ 1`。若定义后面没有表达式：编译期错（`L30: body has no expression`）。

### 两种 `define` 形状

```
(define id E)
(define (id . formals) body …)
```

第二种在扫描时先降成 `(define id (lambda formals body …))`。`formals` 可以是：

- `(a b)` 普通列表；
- `()` 零参；
- 本层 **不** 接受 `(id . rest)` 或裸 `id`（rest 是 L33）。那种内部定义编译期错。

`(define)`、`(define 1 2)`、`(define (1) …)`：编译期错。

### 扫描算法（锁定）

对已展开其它 derived 之前的 body 形式列表 `forms`：

1. 从左收集连续的、`car` 为 `define` 的形式，得到 `defs`。
2. 剩余 `rest`。若 `rest` 为空 → 编译期错。
3. 若 `rest` 里 **任何** 形式还是 `define`（含嵌套在非 body 扫描位置之外的顶层遭遇）——更精确：剩余里出现以 `define` 开头的列表，即「命令之后又一个定义」→ 编译期错 `L30: define after expression`。不要执行到一半再报。
4. 把每个 define 转成 `letrec` 绑定；`rest` 作为 letrec body（多表达式隐式 `begin`）。
5. 若 `defs` 为空，body 不变（仍可隐式 `begin`）。

「`let` 的 body」同样扫描。不要只做 `lambda`：`(let () (define x 1) x)` 是合法 R4RS，本层要过。

**不扫描**：作为表达式求值的 `(begin (define …) …)`。本层 `begin` 仍是 L22 的表达式 `begin`，内部出现 `define` → 编译期错（`define` 不是表达式）。这与「不 splice」一致。

**顶层**：驱动喂给编译器的是 **一个表达式**。若整个程序是 `(define x 1)`，`define` 不是合法表达式 → 编译期错，消息含 `define` 与 `internal` 或 `L45`，表明这不是内部定义。不要静默当成全局赋值。

### 与 `letrec` 的关系

变换后的 `letrec` 就是 L29 的 `letrec`：可多绑定、可互递归。内部 `(define (e n) … (o …))` 与 `(define (o n) … (e …))` 必须与 L29 测例同等效力。

变换发生在 expand，早于 `free-vars`。内部函数捕获外层 lambda 形参：

```
(lambda (x)
  (define (add y) (fx+ x y))
  (add 3))
```

`add` 的自由变量含 `x`（形参，未赋值则按值抄进闭包）。不要把 `x` 误当成未绑定。

内部定义名字遮蔽外层：

```
(let ((x 1))
  (lambda ()
    (define x 2)
    x))
```

结果 `2`。`define` 不是 `set!`。

### `define` 不是第一类表达式

`(fx+ (define x 1) 2)` 编译期错。扫描只发生在 body 的 **前缀**，不是「程序里任意位置遇到 define 就当 letrec」。

### 实现顺序建议

1. `expand-internal-defines` 作用于每个 lambda/let/let*/letrec 的 body；
2. 得到的 `letrec` 再 `expand-letrec`（L29）；
3. `expr->ir`。

letrec 的 body 还要再扫一遍内部 define（R4RS 允许 letrec body 再定义）。锁定：对 **每一种** 含 body 的形式在 expand 时扫描；展开成 letrec 之后，其 body 若仍是用户写的表达式序列，已经在步骤 1 处理过。不要无限循环：扫描一次，define 前缀消失。

若用户写：

```
(lambda ()
  (define (f) (define (g) 1) (g))
  (f))
```

内层 `f` 的 lambda body 另有自己的 define，在编译那个 lambda 时扫描。外层只看到一个定义 `f`。

## 与上一层的差异

- 新的用户语法 `define`（仅内部）。前端多一遍 body 扫描。
- 不新增 IR、不改闭包布局、不改调用约定。
- L29 的显式 `letrec` 仍可用、仍须通过。
- 非法 `define` 位置从「未绑定原语」变成 **明确的编译期错**（不要生成对 `define` 的 `call`）。

## 代码骨架

### 可移植 expand

```scheme
(define (define-form? x)
  (and (pair? x) (eq? (car x) 'define)))

(define (define->binding form)
  (let ((rest (cdr form)))
    (cond
      ((and (pair? rest) (symbol? (car rest)) (pair? (cdr rest)) (null? (cddr rest)))
       (list (car rest) (cadr rest)))
      ((and (pair? rest) (pair? (car rest)) (symbol? (caar rest)))
       (let ((name (caar rest))
             (formals (cdar rest))
             (body (cdr rest)))
         (unless (and (list? formals) (every symbol? formals) (unique? formals))
           (error "L30: bad define formals" form))
         (when (null? body) (error "L30: empty define body" form))
         (list name `(lambda ,formals ,@body))))
      (else (error "L30: bad define" form)))))

(define (expand-body forms)
  (let loop ((fs forms) (defs '()))
    (if (and (pair? fs) (define-form? (car fs)))
        (loop (cdr fs) (append defs (list (define->binding (car fs)))))
        (begin
          (when (null? fs)
            (error "L30: body has no expression"))
          (when (any define-form? fs)
            (error "L30: define after expression"))
          (let ((body (if (null? (cdr fs)) (car fs) `(begin ,@fs))))
            (if (null? defs)
                body
                `(letrec ,defs ,body)))))))

(define (expand expr)
  (cond
    ((and (pair? expr) (eq? (car expr) 'lambda))
     `(lambda ,(cadr expr) ,(expand-body (map expand (cddr expr)))))
    ((and (pair? expr) (memq (car expr) '(let let* letrec)))
     ;; 先 expand 各 RHS 与 body 形式，再 expand-body
     ...)
    ((and (pair? expr) (eq? (car expr) 'define))
     (error "L30: define only at head of lambda/let/let*/letrec body"))
    ((pair? expr) (map expand expr))
    (else expr)))
```

注意：`expand-body` 收到的 forms 应已经对每个 form `expand` 过，这样嵌套 lambda 内部的 define 先被内层处理。**但** 若先 `map expand` 再扫 define，内层合法 define 已被变成 `letrec`，外层看到的不再是 `define`，这是对的。若某层错误地把内层未处理的 `define` 当表达式 `expand`，会打出「define only at head」——因此：对 lambda，不要对 **尚未分割的** body 整体 `map expand` 到 `define` 形式本身；要么 `expand-body` 先切前缀，再递归 expand 绑定右值与剩余表达式，要么 expand 遇到 define 时不报错、留给 expand-body。锁定更简单的一种：

**先按未 expand 的形状切前缀（只认 `car eq? define`），再对 RHS 与 rest 递归 `expand`。** 这样 `(define x (lambda () (define y 1) y))` 的内层 define 在 expand 那个 lambda 时处理。

```scheme
(define (expand-body forms)
  (let loop ((fs forms) (defs '()))
    (if (and (pair? fs) (define-form? (car fs)))
        (loop (cdr fs) (append defs (list (car fs))))
        (begin
          (when (null? fs) (error "L30: body has no expression"))
          (when (any define-form? fs)
            (error "L30: define after expression"))
          (let* ((bindings (map (lambda (d)
                                  (let ((b (define->binding d)))
                                    (list (car b) (expand (cadr b)))))
                                defs))
                 (rest (map expand fs))
                 (body (if (null? (cdr rest)) (car rest) `(begin ,@rest))))
            (if (null? bindings) body `(letrec ,bindings ,body)))))))
```

### 与 `letrec` 展开的衔接

`expand` 在处理 `(letrec …)` 时：对每个 RHS `expand`，对 body 走 `expand-body`（允许 letrec body 再内部定义），然后 `expand-letrec`。顺序：

```
源 → 切内部 define → letrec 核心 → box 降级 → IR
```

不要把 `define` 降成 `set!`（那是某些教学编译器的顶层做法，会让未先绑定的名字变成赋值，且互递归更糟）。

## 测例清单

上一层全部测例仍须通过。

1. `((lambda (x) (define (sq n) (fx* n n)) (sq x)) 4)` → `16`
2. `((lambda (x) (define sq (lambda (n) (fx* n n))) (sq x)) 5)` → `25`
3. `((lambda (x) (define a 1) (define b 2) (fx+ x (fx+ a b))) 3)` → `6`
4. `((lambda (n) (define (f k) (if (fx= k 0) 1 (fx* k (f (fxsub1 k))))) (f n)) 5)` → `120`（内部单递归）
5. `((lambda (n) (define (e k) (if (fx= k 0) #t (o (fxsub1 k)))) (define (o k) (if (fx= k 0) #f (e (fxsub1 k)))) (e n)) 5)` → `#f`（内部互递归）
6. `(let () (define x 3) x)` → `3`
7. `(let ((x 1)) ((lambda () (define x 2) x)))` → `2`（内部定义遮蔽）
8. `((lambda (x) (define (add y) (fx+ x y)) (add 3)) 10)` → `13`（捕获外层形参）
9. `((lambda () (define (f) 1) (define (g) (f)) (g)))` → `1`
10. `((lambda () (define x 1) (fx+ x 1) (define y 2)))`：编译期错，`define after expression`
11. `((lambda () (define x 1)))`：编译期错，body 没有表达式
12. `(define x 1)`：编译期错（顶层 / 非内部）
13. `((lambda () (fx+ (define x 1) 2)))`：编译期错
14. `(let () (define (f a b) (fx+ a b)) (f 2 3))` → `5`
15. `((lambda (x) (define (f) (define (g) x) (g)) (f)) 9)` → `9`（嵌套内部 define + 捕获最外层形参）
16. `((lambda () (define (f x) x) (f)))`：运行时 `arity`
17. `(let* ((a 1)) (define b (fx+ a 1)) b)` → `2`（`let*` body 扫描）
18. `((lambda () (define (p . q) q) (p 1)))`：编译期错（rest 形参）

## 验收标准

- 成功测例 1–9、14、15、17 输出正确。
- 测例 10–13、18 在 **编译期** 失败，不得链接运行；消息可区分「define after expression」与「顶层 define」与「bad define」。
- 测例 16 运行时 `arity`。
- 测例 5 与 L29 even/odd 同一语义，证明内部 define 没有走「只能单函数」的捷径。
- 顶层 `(define …)` 不得被当成「无外层 lambda 的内部定义」而意外成功。
- L24–L29 全绿。无新标签、无新寄存器；仍禁止 `x18`。

## 常见坑

- **`define` 当过程调用**：未识别的符号走 `call`，运行时 `not a procedure`。必须编译期识别。
- **只切 `lambda`、忘了 `let`**：测例 6 红。
- **先 `map expand` 再切前缀**：`expand` 见到 `define` 立刻报「只能出现在 head」，而此时还在收集前缀。按「先切后递归」锁定。
- **内部 define 降成 `set!` 未绑定变量**：没有盒子，互递归失败，也违反「define 引入绑定」。
- **`(define (sq n) …)` 没降成 `lambda`**：`letrec` 绑定右值不是过程，`(sq x)` 不是闭包。
- **begin splice**：`(lambda () (begin (define x 1)) x)` 本层允许失败。不要为了它破坏「define after expression」检测。范围之外写死即可，测例不要依赖 splice。
- **扫描吃掉非 define 的 `(define-foo …)`**：只认符号 `define`。
- **遮蔽失败**：内部 `define x` 仍引用外层 `x` 当同一栈槽，测例 7 会得到 `1`。必须是新的 letrec 绑定。
- **嵌套 define 只扫一层**：测例 15 的 `g` 看不到 `x` 或找不到 `g`。每个 lambda 自己 `expand-body`。

## 下一层预告

递归现在每次调用都涨栈。L31 要让 **同一过程、尾位置** 的调用变成跳转，而不再 `stp` 新帧。
