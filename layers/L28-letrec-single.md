# L28 — 单函数 `letrec`

## 目标

支持 `(letrec ((f (lambda … f …))) body)`：`f` 在自己的定义里可见，从而写出递归。本层 **没有尾调用**，每次递归都新开帧、栈增长；测例深度保持很小（例如阶乘 5、倒数 10）。不要靠无限递归或「深到爆栈」来验收。

做完本层：

```
(letrec ((f (lambda (n)
              (if (fx= n 0) 1 (fx* n (f (fxsub1 n)))))))
  (f 5))
```

打印 `120`。

本层范围之外：互递归（L29）、内部 `define`（L30）、尾调用消除（L31）、`letrec` 初始化完成前引用的检测（R4RS 说是错误；测例不依赖未定义行为）。不改闭包布局与调用约定。

## 原理

### 循环引用

普通 `let` 是先求右值、再绑定。`(let ((f (lambda () (f)))) …)` 里内层 `f` 不是正在绑定的那个名字（未绑定或外层同名）。`letrec` 要让右值里的 `lambda` **捕获正在定义的 f**。

这是环形数据：闭包的 fv 指向「f 的值」，而 f 的值就是这个闭包。

### 锁定策略：box（推荐且本教程必做）

L23 已有 `%box` / `%unbox` / `%set-box!`，L26 已用 box 处理「捕获 + 赋值」。`letrec` 降成 **先分配盒子，再填，再跑 body**：

```
(letrec ((f rhs)) body)
⇒
(let ((f (%box (%void))))     ; (%void) → 立即数 0x1F，不是 fixnum 31
  (begin
    (%set-box! f rhs')          ; rhs' 里对 f 的引用改成 (%unbox f)
    body'))                     ; body 同样改写
```

对函数：

```
rhs  = (lambda (n) … (f (fxsub1 n)) …)
rhs' = (lambda (n) … ((%unbox f) (fxsub1 n)) …)
```

时间线：

1. 分配 box，槽里是 `VOID`；
2. `close` 内层 lambda，fv 存 **box 指针**（盒子已经在堆上，内容此时仍是 VOID，但 lambda **尚未调用**，不会 unbox）；
3. `set-box!` 把闭包写进盒子；
4. body 里 `(unbox f)` 得到闭包再 `call`。

递归调用走的是「unbox 得到同一闭包」再 `blr`，不是跳编译期标签。对象是循环的：box → closure → box。

`set! f` 在 letrec 绑定上：改写成 `%set-box!`。本层测例以递归函数为主，不强制测对 `f` 再赋值。

### 另一种实现（允许理解，测例不依赖）

先 `emit-alloc` 闭包壳，把 `code`/`arity`/`nfree` 填好，fv0 先写 `VOID`，再把 **自己的 tagged 指针** 写进 fv0（自环闭包）。body 里 `f` 就是这个闭包，不必 unbox。缺点：与 L26 的「赋值变量用 box」分叉，互递归（L29）要同时填两个壳，容易写错。**骨架与验收按 box 路径写。** 若你做自环闭包，必须仍通过全部测例，且不要改堆布局字段含义。

### 初始化顺序（单绑定）

1. 分配全部盒子（本层只有一个）；
2. 求值唯一 RHS（允许 `close` 捕获盒子）；
3. `set-box!`；
4. 求值 body。

`(letrec ((x 1)) x)` 合法：RHS 是立即数，不引用 `x`，结果 `1`。`(letrec ((x (fx+ x 1))) x)` 会 unbox 到 `VOID` 再 `fx+`，行为未定义；**不要写这样的测例**，也不必在本层做「未初始化引用」检测。

`(letrec () 42)` 降成 `42`（或 `begin` 包一层）。空绑定合法。

### 递归与栈

`(f (fxsub1 n))` 不在尾位置（外面还有 `fx*`），即使以后有 L31 也消除不了这一层。本层不要把 `bl` 改成 `b`。深度 5 的阶乘帧很少，测例必须通过。无限循环不作为测例。

调用仍走 L25：`x8` argc，arity 检查，`x21` callee-saved。递归进入同一 `L_code_*` 时，每次序言都保存 **当时** 的 `x21`；同一闭包每次 `mov x21, x10` 装的是同一 tagged 指针。SELF 不变也可以，但协议不能省——若以后 body 在递归调用 **之后** 还要 `emit-closure-ref`，必须恢复。

阶乘的 `f` 经 box 捕获，body 里每次调用都 unbox。可以在降 IR 时把「已知是自己」仍走普通 `call`；不要偷偷改成无闭包的 `bl L_code`。

### 语法

```
(letrec ((id E)) E)
```

本层骨架按 **恰好一组绑定** 写清楚；零组绑定也要能过。多组绑定若顺手用同一算法（先全部分配盒子）可以工作，但互递归测例留在 L29——本层测例不要两个函数互相调用。

`id` 重复：编译期错。RHS / body 为空：编译期错（`letrec` 需要 body 表达式）。多个 body 表达式：隐式 `begin`。

## 与上一层的差异

- 新核心形式 `letrec`（或前端降成 `let` + `%box` + `%set-box!`，后端可以不认识 `letrec`）。
- 新增内部 0 元原语 `%void`，只用来把盒子初始化成 VOID 立即数 `0x1F`（不是 fixnum 31）。
- 闭包的 fv 第一次指向「随后才会被 set-box! 的盒子」，形成递归。
- 不改 `[code][arity][nfree][fv…]`，不改 `x8`/`x10`/`x21`。
- L27 返回闭包测例仍须通过：`letrec` 不得破坏普通 `lambda`。

## 代码骨架

### 可移植降级（锁定）

```scheme
(define (expand-letrec expr)
  ;; (letrec ((f e)) b1 b2 ...)
  (let ((bindings (cadr expr))
        (body (cddr expr)))
    (when (not (unique? (map car bindings)))
      (error "L28: duplicate letrec binder"))
    (when (null? body)
      (error "L28: letrec missing body"))
    (let* ((ids (map car bindings))
           (rhss (map cadr bindings))
           (box-bindings
            ;; 不要写成 (%box 31)：31 会被打成 fixnum。(%void) → (imm #x1F)
            (map (lambda (id) `(,id (%box (%void)))) ids))
           (inits
            (map (lambda (id rhs)
                   `(%set-box! ,id ,(rewrite-refs rhs ids)))
                 ids rhss))
           (body* (rewrite-refs (if (null? (cdr body))
                                    (car body)
                                    `(begin ,@body))
                                ids)))
      `(let ,box-bindings
         (begin ,@inits ,body*)))))

(define (rewrite-refs expr ids)
  ;; 把作为引用出现的 id 改成 (%unbox id)
  ;; 把 (set! id e) 改成 (%set-box! id e')
  ;; 走进 (lambda formals …) 时：formals 遮蔽 ids
  ...)
```

`rewrite-refs` 不要改 `lambda` 的形参列表本身，也不要把 `(%unbox f)` 再包一层。操作数位置的 `f`（`(f n)` 的操作数）变成 `(%unbox f)`，然后仍是 `call`。

`(%void)` 是内部 0 元原语：`expr->ir` 生成 `(imm #x1F)`（或 `(prim %void)` 由后端 `emit-imm`）。运行时不要打印这个尚未 `set-box!` 的盒子；测例在初始化之后才 unbox。L22 不允许空 `begin` 当 VOID 用。

### 不必新的 emit

`%box` / `%unbox` / `%set-box!` / `let` / `begin` / `lambda` / `call` 全部已存在。本层若 IR 里仍留 `(letrec …)`，后端就要实现它——更简单的是 **expand 阶段消灭 letrec**，`expr->ir` 看不到它。

### 阶乘 IR 形状（示意）

```
(let ((f (prim %box (imm VOID))))
  (seq
    (prim %set-box! (ref f)
          (close Lfact (ref f)))     ; fv0 = box
    (call (prim %unbox (ref f)) (imm ,(ash 5 2)))))

(code Lfact (n) (f)
  (if (prim fx= (ref n) (imm 0))
      (imm 4)
      (prim fx*
            (ref n)
            (call (prim %unbox (ref f))
                  (prim fxsub1 (ref n))))))
```

`f` 在 `Lfact` 里是 `(free . 0)`，值是 box；每次递归 `unbox` 再 call。

## 测例清单

上一层全部测例仍须通过。

1. `(letrec ((f (lambda (n) (if (fx= n 0) 1 (fx* n (f (fxsub1 n))))))) (f 5))` → `120`
2. `(letrec ((f (lambda (n) (if (fx= n 0) 0 (fx+ n (f (fxsub1 n))))))) (f 4))` → `10`
3. `(letrec ((f (lambda (n) (if (fx= n 0) #t (f (fxsub1 n)))))) (f 3))` → `#t`
4. `(letrec ((f (lambda (x) (if (fx= x 0) 0 (fxadd1 (f (fxsub1 x))))))) (f 6))` → `6`
5. `(letrec ((k (lambda () 42))) (k))` → `42`（RHS 不引用自己，仍走 letrec）
6. `(letrec ((x 1)) x)` → `1`（非 lambda RHS）
7. `(letrec () 42)` → `42`
8. `(letrec ((f (lambda (n acc) (if (fx= n 0) acc (f (fxsub1 n) (fx+ acc n)))))) (f 4 0))` → `10`（两参数递归；**尚未**尾调用消除，只要求结果对）
9. `(let ((a 10)) (letrec ((f (lambda (n) (if (fx= n 0) a (f (fxsub1 n)))))) (f 3)))` → `10`（递归过程还捕获外层 `a`）
10. `(letrec ((f (lambda (n) (if (fx= n 0) (lambda () 7) (f (fxsub1 n)))))) ((f 2)))` → `7`（递归返回闭包再调用）
11. `(letrec ((f (lambda (x) x))) (f 3))` → `3`
12. `(letrec ((f (lambda (n) (if (fx<= n 1) n (fx+ (f (fxsub1 n)) (f (fx- n 2))))))) (f 6))` → `8`（树递归 Fibonacci，栈更深但有限）
13. `(letrec ((f (lambda (n) (if (fx= n 0) 1 (fx+ 1 (f (fxsub1 n))))))) (begin (f 2) (f 3)))` → `4`（`begin` 取后者；两次入口仍走同一闭包）
14. `(letrec ((f 1) (f 2)) f)`：编译期错（重复绑定）。两组 **不同** 名字的互递归留到 L29，本层测例不包含。
15. `(letrec ((f (lambda (x) (fx+ x 1)))) (f))`：运行时错误，stderr 含 `arity`。
16. `(letrec ((f (lambda (n) (if (fx= n 0) 1 (fx+ (f (fxsub1 n)) (f (fxsub1 n))))))) (f 4))` → `16`（每次两路递归，结果是 2 的 n 次方）

## 验收标准

- 测例 1–13、16 输出正确；15 非 0 且 stderr 含 `arity`；14 编译期失败。
- 阶乘 / 求和不得写成展开成常数的前端优化来假绿；生成代码必须有 `blr` 递归（可用 `objdump`/`otool -tv` 看对同一 `L_code_*` 的多次调用路径）。不强制自动化反汇编，但实现者需要自己看一眼。
- 递归深度 5–6 不得爆栈；不要为了本层去加大 C 线程栈。
- L24–L27 全绿。`VOID` 不得从成功测例里打印出来。
- 闭包头偏移不变；`x18` 仍禁用。

## 常见坑

- **用 `let` 而不是 box**：RHS 的 lambda 看不到 `f`，未绑定或捕获了外层。测例 1 编译失败或调用了别的东西。
- **先 close 再分配 box**：fv 没有合法盒子可存。必须先 `%box`。
- **body 里直接 `(ref f)` 当闭包**：`f` 的栈槽里是 box，不是闭包。忘记 `unbox` 会 `not a procedure`。
- **`(%box 31)` 当初始 VOID**：整数 31 走 fixnum 编码（`31<<2`），不是 `0x1F`。用 `(%void)` 或 IR `(imm #x1F)`。
- **自尾调用优化抢跑**：测例 8 即使看起来像尾递归，本层仍应涨栈。提前 `br` 且没把 arity/`x21` 处理对，会在 L31 之前引入难测的错。本层禁止尾调用消除。
- **递归调用后丢失 SELF**：`(lambda (n) (begin (f (fxsub1 n)) x))` 若 `x` 是 fv，依赖 `x21` 恢复。阶乘在调用后只用返回值，可能掩盖这个 bug。测例 9 在 base case 读外层 `a`（fv），每次递归返回路径都要 SELF 正确。
- **`letrec` 绑两个名字却只分配一个盒子**：留给 L29；本层若误接受两组绑定，用同一 box 会把第二个 RHS 覆盖第一个。

## 下一层预告

一个函数可以调自己了，但两个函数还不能互相调用。L29 要把 `even?` / `odd?` 这种互递归写进同一个 `letrec`。
