# L27 — 嵌套闭包与返回闭包

## 目标

闭包可以作为返回值离开创造它的那一帧，之后仍能调用。内层 `lambda` 捕获外层 **形参** 以及外层已经捕获的自由变量。外层 `ret` 之后，那些名字不得再指向已死的栈槽——L26 若把值（或 box）抄到堆上，本层只是把这件事测穿。

经典结果：`(((lambda (x) (lambda (y) (fx+ x y))) 3) 4)` 打印 `7`。

本层范围之外：`letrec`、内部 `define`、尾调用、把闭包当键做 `eq?` 的身份保证（两次 `lambda` 不是同一对象即可，不必另测）。不新增 ABI。

## 原理

### 为什么「嵌套」要单独一层

L26 的测例多半是：

```
(let ((x 10))
  ((lambda (y) (fx+ x y)) 5))
```

`let` 帧在调用期间还活着。把 `fp+slot` 存进闭包也会碰巧算对。本层强迫顺序变成：

1. 进入外层过程，形参 `x` 在外层栈上；
2. `close` 内层，把 `x` 的值写入内层堆对象的 `fv0`；
3. 外层 **返回** 内层闭包（`ldp x29,x30` 丢掉外层帧）；
4. 调用方再调用这个闭包。

第 4 步若 `fv0` 是「外层 `fp` 加偏移」，读到的是别人的帧或未映射内存。

### 内层的自由变量从哪来

```
(lambda (x)              ; 外层，formals=(x)，fvs=()
  (lambda (y)            ; 内层，formals=(y)，fvs=(x)
    (fx+ x y)))
```

编译内层时，当前 env 里 `x` 是外层形参的 `(stack . slot)`。`close` 的初始化 `(ref x)` 从 **外层栈** 读一次，写入内层堆。之后内层只认 `(free . 0)`。

更深：

```
(lambda (a)
  (lambda (b)
    (lambda (c)
      (fx+ a (fx+ b c)))))
```

最内层 `fvs = (a b)`（按首次引用：先 `a` 后 `b`）。创造最内层时，执行的是「中间那一层」：`b` 是它的形参（栈），`a` 是它的自由变量（`emit-closure-ref`）。中间层必须已经捕获了 `a`，否则最内层无法从中间层的 SELF 读到 `a`。

规则：若内层自由变量 `v` 不是本层形参，则本层也必须把 `v` 列入自己的 fvs（传递捕获）。不要做「内层 SELF 指向外层闭包」的静态链——对象布局没有链槽，L24 已锁死 `[code][arity][nfree][fv…]`。

### 赋值与返回

```
(let ((make (lambda (x)
              (lambda ()
                (begin (set! x (fxadd1 x)) x)))))
  (let ((f (make 0)))
    (begin (f) (f))))
```

`x` 是外层形参，被内层捕获且被 `set!`：外层入口就要把传入的 `x0` **先放进 box**，再 `close`（fv 存盒子）。外层返回后盒子仍在堆上，两次 `(f)` 看到同一可变单元。若只把 fixnum `0` 拷进内层，`set!` 改的是内层私有拷贝，第二次仍从 0 加起——或者更糟，写死栈。

### 证明「不是死栈」的测例结构

在第一次返回的闭包 **尚未调用** 之前，再跑一个同样会开帧的计算，把栈上那片空间盖掉，然后再调用第一个闭包：

```
(let ((f ((lambda (x) (lambda (y) (fx+ x y))) 3)))
  (let ((g ((lambda (a) (lambda (b) (fx+ a b))) 100)))
    (fx+ (f 4) (g 5))))
```

期望 `7 + 105 = 112`。若 `f` 的 `x` 留在栈上，创造 `g` 时那槽多半已被写成 `100`，`(f 4)` 会得到 `104` 一类错值。

调用约定、`x21` 协议、arity、三字头：全部沿用 L24–L26。本层前端多半不用新 IR 节点，只是允许 `close` 出现在非尾的值位置并把结果当普通值传递。

### 0 形参返回闭包

`((lambda (x) (lambda () x)) 3)` 的结果是 0 参闭包；再 `()` 调用得 `3`。argc 仍走 `x8`。不要因为「看起来像柯里化」就省略内层对象。

## 与上一层的差异

- 明确允许闭包从过程返回、再被调用；测例必须包含「外层已 `ret`」。
- 多层嵌套：内层 fvs 包含外层形参 **以及** 外层的 fvs。
- 不改布局、不改寄存器。若 L26 已经把值抄到堆上，本层主要是测例与传递捕获。
- `scheme_entry` / 每个过程仍保存 `x21`：返回的闭包在之后的调用里会覆盖 `x21`，调用方（可能是顶层）靠 callee-saved 协议恢复。

## 代码骨架

### 可移植：传递捕获

`free-vars` 在走进内层 `lambda` 时，必须把内层的自由变量里「不属于本层 formals」的名字并入本层 fvs：

```scheme
(define (free-vars expr bound env)
  ;; bound = 本 lambda 形参 ∪ 当前 let 绑定
  (cond
    ((and (pair? expr) (eq? (car expr) 'lambda))
     (let* ((formals (cadr expr))
            (body (normalize-body (cddr expr)))
            (inner (free-vars body formals env)))
       (filter (lambda (v) (not (memq v bound))) inner)))
    ((symbol? expr)
     (if (or (memq expr bound) (not (assq expr env)))
         '()
         (list expr)))
    ((and (pair? expr) (eq? (car expr) 'let))
     (let* ((b (car (cadr expr)))  ; 简化：按你的 let 形状展开
            ...)
       ...))
    ((pair? expr)
     (unique-append (free-vars (car expr) bound env)
                    (free-vars (cdr expr) bound env)))
    (else '())))
```

「第一次出现顺序」在 `unique-append` 里保持左到右。对 `(fx+ a (fx+ b c))`，最内层 fvs 为 `(a b)`（`c` 是形参）。

创造内层时的初始化 IR：对每个 fv 名字在 **当前** env 做 `expr->ir`。当前过程若已经把某名字标成 `(free . i)`，生成 `emit-closure-ref`，这是在把外层闭包里的值再抄一份到内层——**抄的是值/box 指针，不是外层闭包对象本身**（除非你故意捕获一个闭包值）。

### 形参装箱（返回后再 `set!`）

与 L23/L26 相同：**形参在自己的 body 里被 `set!` 就装箱**，不必再问「有没有被捕获」。捕获只是把已经在槽里的盒子指针抄进内层 fv。

```scheme
(define (compile-lambda formals body env add-code)
  (let* ((body-expr (normalize-body body))
         (boxed-formals (filter (lambda (p)
                                  (assigned? p body-expr))
                                formals)))
    ;; 序言：未装箱形参 str xN 到槽；装箱形参先 %box 再 str
    ...))
```

不要对外层从未 `set!` 的形参装箱：`(((lambda (x) (lambda (y) (fx+ x y))) 3) 4)` 只拷 fixnum `3` 即可。测例 7 的 `x` 在内层被 `set!`，外层形参必须是盒子，两次 `(f)` 才能从 0 加到 2。

### 调用返回的闭包

没有新的 `emit-call`。操作数在 `x0` 里就是 tagged 闭包，按 L25 装填实参、`mov x10, …`、`blr x9`。顶层 `(((lambda (x) (lambda (y) …)) 3) 4)` 是两次 `call` 嵌套：内层 `call` 的操作数 IR 是外层那次 `call`。

## 测例清单

上一层全部测例仍须通过。

1. `(((lambda (x) (lambda (y) (fx+ x y))) 3) 4)` → `7`
2. `(((lambda (x) (lambda () x)) 3))` → `3`
3. `((((lambda (a) (lambda (b) (lambda (c) (fx+ a (fx+ b c))))) 1) 2) 3)` → `6`
4. `(let ((f ((lambda (x) (lambda (y) (fx+ x y))) 3))) (f 4))` → `7`
5. `(let ((f ((lambda (x) (lambda (y) (fx+ x y))) 3))) (let ((g ((lambda (a) (lambda (b) (fx+ a b))) 100))) (fx+ (f 4) (g 5))))` → `112`（栈复用后仍正确）
6. `(let ((make (lambda (x) (lambda (y) (fx+ x y))))) (let ((f (make 10))) (f 1)))` → `11`
7. `(let ((make (lambda (x) (lambda () (begin (set! x (fxadd1 x)) x))))) (let ((f (make 0))) (begin (f) (f))))` → `2`
8. `(let ((make (lambda (x) (lambda () (begin (set! x (fxadd1 x)) x))))) (let ((f (make 0))) (let ((g (make 10))) (begin (f) (g) (f)))))` → `2`（两个计数器隔离：最后一次是 `f`）
9. `(let ((make (lambda (x) (lambda () (begin (set! x (fxadd1 x)) x))))) (let ((f (make 0))) (let ((g (make 10))) (begin (f) (g) (g)))))` → `12`（最后一次是 `g`）
10. `(let ((h ((lambda (x) ((lambda (y) (lambda () (fx+ x y))) 4)) 3))) (h))` → `7`（两层形参都捕获）
11. `(let ((n 1)) (let ((f ((lambda (x) (lambda (y) (fx+ n (fx+ x y)))) 2))) (f 3)))` → `6`（内层同时有外层 let 的 fv 与外层 lambda 的形参）
12. `(((lambda (x y) (lambda (z) (fx+ z (fx+ x y)))) 1 2) 3)` → `6`（多形参外层）
13. `(let ((f ((lambda () (lambda (x) x))))) (f 9))` → `9`（返回无 fv 的内层；对照「有捕获」）
14. `(let ((f ((lambda (x) (lambda (a b) (fx+ x (fx+ a b)))) 10))) (f 1 2))` → `13`（内层多参 + 捕获）
15. `((lambda (p) ((lambda () (car p)))) (cons 8 9))` → `8`（捕获 pair，外层是顶层调用不是 let）
16. `(let ((f ((lambda (x) (lambda (y) (fx+ x y))) 1))) (f))`：运行时错误，stderr 含 `arity`（内层要 1 个实参）。

## 验收标准

- 测例 1–15 输出正确。测例 16 非 0 且 stderr 含 `arity`。
- 测例 5 是硬条件：实现不得依赖「外层帧还在」。若只过 1 不过 5，视为本层未完成。
- 测例 7–9：返回后的 `set!` 作用在 heap box 上；两个 `make` 互不改写。
- 三层嵌套（测例 3、10）的最内层对象 `nfree` 为 2，中间层 `nfree` 为 1。可用调试断言，不强制驱动读内存。
- L24–L26 全部测例仍绿。无 `x18`，`blr x9`，`x21` 由 callee 保存。

## 常见坑

- **静态链**：闭包里存外层 SELF。外层返回后 SELF 指向的对象虽可能还在（若外层闭包被别人拿着），但外层 **形参** 在栈上，链也救不了形参。必须在 `close` 当时把形参值/box 抄进 fv。
- **中间层没捕获 `a`，最内层却列出 `a`**：创造最内层时 env 里没有 `a`，会编译期「未绑定」或读错槽。传递捕获。
- **测例 1 假绿、测例 5 红**：典型死栈。用测例 5 当验收门槛。
- **两个 `make` 共享一个 box**：形参装箱发生在每次进入外层，应是新盒子。测例 8/9 区分这一点。
- **返回闭包后调用方不把结果当闭包**：`emit-call` 对操作数再次走标签检查。
- **内层 `close` 时用错 SELF**：若在求 fv 前误把 `x21` 改成内层未完成对象，`emit-closure-ref` 读垃圾。先按外层 SELF 读齐 fv，再 `emit-alloc` 内层。
- **深嵌套每层都 `blr` 却不恢复 `x21`**：最内层创建代码跑在中间层，中间层之后还可能再 ref 自己的 fv。callee-saved 协议不能在本层「优化掉」。

## 下一层预告

现在过程还不能在自己的 body 里按名字调用自己。L28 要用 `letrec` 做出单函数递归。
