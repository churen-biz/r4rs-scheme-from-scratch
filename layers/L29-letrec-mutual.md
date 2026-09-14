# L29 — 互递归 `letrec`

## 目标

`letrec` 允许多组绑定，右值里的 `lambda` 可以互相引用。典型：

```
(letrec ((e (lambda (n) (if (fx= n 0) #t (o (fxsub1 n)))))
         (o (lambda (n) (if (fx= n 0) #f (e (fxsub1 n))))))
  (e 5))
```

打印 `#f`（5 是奇数）。策略仍是 L28 的 box 降级，只是 **先把所有盒子分配完，再从左到右求值各个 RHS 并 `set-box!`，最后 body**。

本层范围之外：内部 `define`、尾调用、R4RS「初始化完成前引用」的强制检测、`letrec*` 与 `letrec` 的差异测例（见原理）。rest / `apply` 仍无。

## 原理

### 为何必须先全部分配

若按普通 `let*` 一个一个来：

```
(let ((e (%box VOID)))
  (set-box! e (lambda (n) … (o …)))   ; 此时 o 还不存在
  ...)
```

`o` 未绑定。互递归要求在 **任何一个** RHS 被 `close` 时，所有名字对应的盒子已经在 env 里。

锁定顺序：

1. **并行分配**：`(let ((e (%box VOID)) (o (%box VOID))) …)` —— L20 的多绑定 `let`，右值都是 `(%box VOID)`，不依赖彼此。
2. **从左到右初始化**：`(%set-box! e e-rhs')` 然后 `(%set-box! o o-rhs')`。每个 RHS 里对 `e`/`o` 的引用已是 `(%unbox …)`。
3. **body**（同样改写引用）。

`close` e 的时候，`o` 的盒子已存在（内容仍可能是 VOID）。e 的 lambda 并不在创建时调用 o，只把 **o 的盒子** 存进 fv。对 e 自己：fv 存 e 的盒子。两个闭包都可以同时捕获 `{e-box, o-box}`。

### 自由变量集合

`e` 的 lambda 自由变量至少包含 `o`（若它调用 `o`），以及它调用自己时的 `e`。也可以把「只通过 unbox 的 letrec 绑定」都算进去。顺序仍按 **该 lambda 的 body 内首次引用**。

`e` 不一定捕获 `e`：若实现把自调用写成 unbox 当前盒子，需要捕获 e-box；这正是 L28 的做法。不要对 `e` 发「跳自己的标签、不经过闭包」的第二套 ABI。

`o` 同理捕获 `e`（以及自身，若有自调用）。

### 与 R4RS `letrec` / R6RS `letrec*`

R4RS：所有绑定的位置先存在，初始化表达式的求值顺序未指定，完成前引用该绑定是错误。R6RS `letrec*`：从左到右，先初始化完的名字可以在后面的 RHS 里立即使用。

本教程锁定 **先全部分配盒子，再从左到右 `set-box!`**。这对「RHS 都是 lambda」与 R4RS 一致（lambda 创建不执行 body）。它同时也让 `(letrec ((x 1) (y 2)) (fx+ x y))` 得到 `3`。不要添加依赖「第二个 RHS 立即 unbox 第一个」的必过测例（那是 `letrec*`），以免以后若改成「先全部求值 RHS、再一次性赋入」时测例反转。互递归测例的 RHS **全部是 lambda**。

非 lambda 的多绑定若 RHS 互不引用，可以工作，测例可包含 `(letrec ((x 1) (y 2)) (fx+ x y))`。

### 三函数互递归

`(f → g → h → f)` 同一算法：三个盒子，三次 close，三次 set-box!。证明实现不是「写死两个槽」。

### 调用与 SELF

`(e 5)` 在 body 里：`unbox e` 得闭包，`x8=1`，`blr`。e 的 body 调用 o：同样 unbox 自己的 fv（o 的盒子）再 call。每次进入不同代码标签，`x21` 换成当前闭包。返回 e 之后若还要再读 e 的 fv，靠序言保存的 SELF。即使/odd 在调用 o **之后** 没有本地 fv 可读（直接返回 o 的结果），仍须正确保存 `x21`，因为 o 返回后 C 与 scheme_entry 的约定不变，且更复杂的互递归会在调用后继续用 SELF。

arity：`e` 与 `o` 都是 1 个形参。`(e)` 仍运行时 `arity`。

## 与上一层的差异

- `letrec` 绑定从「一组」到「多组」；expand 必须先分配 **全部** 盒子。
- 两个以上闭包的 fv 交叉指向对方的 box。
- L28 单绑定测例仍过；不要把单绑定改成另一种布局。
- 若 L28 对两组绑定直接 `error`，本层删掉这个限制。

## 代码骨架

### 可移植 expand

L28 的 `expand-letrec` 已经按 `map` 处理列表，本层确认：

```scheme
(define (expand-letrec expr)
  (let ((bindings (cadr expr))
        (body (cddr expr)))
    (unless (and (list? bindings)
                 (every (lambda (b) (and (pair? b) (symbol? (car b))
                                         (pair? (cdr b)) (null? (cddr b))))
                        bindings))
      (error "L29: bad letrec binding"))
    (let ((ids (map car bindings)))
      (unless (unique? ids)
        (error "L29: duplicate letrec binder" ids))
      (when (null? body)
        (error "L29: letrec missing body"))
      (let* ((box-bindings
              (map (lambda (id) `(,id (%box (%void)))) ids))
             (inits
              (map (lambda (b)
                     `(%set-box! ,(car b) ,(rewrite-refs (cadr b) ids)))
                   bindings))
             (body* (rewrite-refs (if (null? (cdr body))
                                      (car body)
                                      `(begin ,@body))
                                  ids)))
        `(let ,box-bindings
           (begin ,@inits ,body*))))))
```

`let` 多绑定必须是 L20 语义：先求所有右值（这里每个都是 `(%box (%void))`，可分配多个盒子），再入栈。不要展开成嵌套 `let` 以致第二个 `%box` 的环境里已经有第一个 `e` 却没有 `o`——虽然本例右值不引用邻居，嵌套 `let` 对「全是 `%box (%void)`」也够用；**初始化** 那一段必须在 **两个名字都已绑定** 的环境里。最稳：并行 `let` 绑盒子，`begin` 里顺序 `set-box!`。`(%void)` 见 L28，不要插入 fixnum 31。

`rewrite-refs` 走进 lambda 时用 formals 遮蔽。`e` 的 body 里名字 `o` 仍在 ids 中且不是 e 的形参 → `(%unbox o)`。`o` 是外层 let 的盒子变量，对 e 的 lambda 而言是自由变量，L26 会把它放进闭包。

### 两个代码对象（示意）

```
(code Le (n) (o e) … call (unbox (ref o)) …)
(code Lo (n) (e o) … call (unbox (ref e)) …)
```

实际 fvs 顺序按首次引用：`e` 的 body 若先写 `(fx= n 0)` 再 `(o …)`，可能只有 `(o)`，自调用才出现 `e`。even 的典型 body 先 `if` 再调 `o`，**可以不捕获 e**。odd 捕获 `e`。不要在文档外另要求「每个函数都捕获所有绑定」——多捕获仍正确，少捕获必须仍能互调。

### 不必改 backend ABI

无新寄存器。`emit-close` 对每个 lambda 各分配一次，nfree 一般为 1 或 2。arity 字仍是 fixnum 1。

## 测例清单

上一层全部测例仍须通过。

1. `(letrec ((e (lambda (n) (if (fx= n 0) #t (o (fxsub1 n))))) (o (lambda (n) (if (fx= n 0) #f (e (fxsub1 n)))))) (e 5))` → `#f`
2. 同上 `(e 4)` → `#t`
3. 同上 `(o 1)` → `#t`（`o` 当作 odd?：n=1 转到 `(e 0)` 得 `#t`）
4. `(letrec ((e (lambda (n) (if (fx= n 0) #t (o (fxsub1 n))))) (o (lambda (n) (if (fx= n 0) #f (e (fxsub1 n)))))) (o 0))` → `#f`
5. `(letrec ((a (lambda () (b))) (b (lambda () 7))) (a))` → `7`（单向也走多绑定）
6. `(letrec ((f (lambda (n) (if (fx= n 0) 0 (g n)))) (g (lambda (n) (fxadd1 (f (fxsub1 n)))))) (f 3))` → `3`
7. `(letrec ((x 1) (y 2)) (fx+ x y))` → `3`
8. `(letrec ((p (lambda (n) (if (fx= n 0) 0 (q (fxsub1 n))))) (q (lambda (n) (if (fx= n 0) 1 (p (fxsub1 n)))))) (p 4))` → `0`
9. `(letrec ((f (lambda (n) (if (fx= n 0) 1 (g (fxsub1 n))))) (g (lambda (n) (if (fx= n 0) 2 (h (fxsub1 n))))) (h (lambda (n) (if (fx= n 0) 3 (f (fxsub1 n)))))) (f 5))` → `3`（`f(5)→g(4)→h(3)→f(2)→g(1)→h(0)`）
10. `(letrec ((e (lambda (n) (if (fx= n 0) #t (o (fxsub1 n))))) (o (lambda (n) (if (fx= n 0) #f (e (fxsub1 n)))))) (let ((f e)) (f 2)))` → `#t`（把其中一个闭包当值拿出再调）
11. `(let ((k 5)) (letrec ((e (lambda (n) (if (fx= n 0) k (o (fxsub1 n))))) (o (lambda (n) (if (fx= n 0) 0 (e (fxsub1 n)))))) (e 4)))` → `5`（互递归 + 捕获外层 `k`；4 为偶数走到 `e` 的 0）
12. `(letrec ((e (lambda (n) (if (fx= n 0) #t (o (fxsub1 n))))) (o (lambda (n) (if (fx= n 0) #f (e (fxsub1 n)))))) (e))`：运行时 `arity`
13. `(letrec ((e (lambda (n) n)) (e (lambda (n) n))) e)`：编译期错（重复名字）
14. `(letrec ((e (lambda (n) (if (fx= n 0) #t (o (fxsub1 n))))) (o (lambda (n) (if (fx= n 0) #f (e (fxsub1 n)))))) (begin (e 2) (o 3)))` → `#t`（`begin` 最后是 `(o 3)`，3 奇数，odd 为真）
15. `(letrec ((make (lambda (x) (lambda () x))) (f (lambda () (make 9)))) ((f)))` → `9`（多绑定但几乎不互调；返回闭包）
16. `(letrec ((e (lambda (n acc) (if (fx= n 0) acc (o (fxsub1 n) (fx+ acc 1))))) (o (lambda (n acc) (if (fx= n 0) acc (e (fxsub1 n) (fx+ acc 1)))))) (e 3 0))` → `3`（两参数互递归计数）

测例 1–4、10、12、14 共用同一对 `e`/`o`：`e` 是 even?（0 → `#t`），`o` 是 odd?（0 → `#f`）。

## 验收标准

- 测例 1–11、14–16 输出与上表一致（含 `#t`/`#f` 行）。
- 测例 12 非 0、stderr 含 `arity`；13 编译期失败。
- L28 单函数递归（含阶乘）仍绿。不得为了互递归改掉单绑定的盒子个数（单绑定仍一个盒子）。
- 两个闭包必须是 **两次** `emit-alloc` 闭包 + **两次** `emit-alloc` box（或等价：两个 box 对象、两个 closure 对象）。把 even/odd 合成一块代码、用寄存器里的函数号分派，视为作弊，测例 10 把 `e` 当值取出时会暴露。
- 无 `x18`；布局偏移不变；`x21` 协议不变。

## 常见坑

- **第二个盒子在第一个 RHS 之后才分配**：`e` 的 lambda 编译时 `o` 不在 env。必须并行 `let` 两个 `%box`。
- **两个 lambda 共享一份 fv 数组**：改 `o` 的盒子指针会写穿。各 `close` 各有对象。
- **`rewrite-refs` 改掉了形参 `n`**：只有 ids 里的 letrec 名字才改成 unbox。
- **even/odd 写反测例期望**：以「`e` 在 0 返回 `#t`」为准，那是 even?；不要和函数名 `o` 的英文 odd 弄拧却改错期望值。
- **只 close 一次、用 `set!` 改 code 指针**：违反布局（code 不是 Scheme 值语义的可变槽），也让测例 10 难以给 `f` 一个稳定闭包。
- **初始化写成先全部求 RHS 再 set-box，但求值环境里盒子尚未绑定**：`close` 无法捕获。分配与绑定盒子必须发生在任何 RHS 求值之前。
- **三函数只开了两个槽**：测例 9 红或未绑定。
- **互递归调用后未恢复 `x21`**：测例 11 在 base case 读捕获的 `k`，会暴露。

## 下一层预告

互递归已经能写，但还得把绑定全部列在 `letrec` 里。L30 要让过程体开头的 `define` 自动变成这些绑定。
