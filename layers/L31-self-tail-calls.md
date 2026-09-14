# L31 — 自身尾调用

## 目标

让**同一 `lambda` 在尾位置调用自己**时不新开栈帧：覆盖本帧参数槽，跳到序言之后的循环标签，栈深度保持常数。没有这条优化，`(letrec ((f (lambda (n a) … (f (fxsub1 n) …)))) (f 10000 0))` 会为每一层递归压一帧；一万帧足以撑死默认栈。

本层只做**自身**尾调用（self tail）。互递归、调用另一个闭包的尾位置调用仍按 L24 的 `blr` 处理，会涨栈——那是 L32 的范围。

本层范围之外：跨过程尾调用、`apply` 的尾调用、`values` 的多值返回、continuation。`and`/`or` 仍按 L11 展开成 `if`，不要在后端为它们单独做尾调用指令。

## 原理

### 尾位置（芯片无关）

R4RS 的「尾上下文」落到本教程的核心形式上，就是下面这些节点。前端在降 IR 时带一个布尔 `tail?`；只有 `tail?` 为真时才发出 `(tail-call …)`，否则发出 `(call …)`。

| 语法 | 尾位置 |
|------|--------|
| `lambda` 的 body | 是 |
| `if` 的 consequent / alternative | 当整个 `if` 在尾位置时，两支都是 |
| `if` 的 test | 否 |
| `begin` 的最后一项 | 当整个 `begin` 在尾位置时是 |
| `begin` 的前面各项 | 否 |
| `and` / `or` 展开后的最后一项 | 是（L11 展开时必须保持尾；零操作数的 `and`/`or` 已是立即数，无调用） |
| `let` / `let*` / `letrec` 的 body | 当整个绑定形式在尾位置时是 |
| `let` 右值、`set!` 右值、调用的实参、原语操作数 | 否 |

`internal define`（L30）已经变成 `letrec`，所以只要 `letrec` 的 body 规则对了，内部定义函数的尾调用自然被看见。

检测必须在核心形式上进行，不要在展开前的表面语法上猜。`(if e (f x) (f y))` 两支都是尾；`(fx+ 1 (f x))` 里的 `(f x)` 不是。

### 自身尾调用

当前正在编译的 `code` 块为 `lid`，且 `(tail-call rator arg …)` 的 `rator` 就是这个过程自己——典型来源是 `letrec` 绑定的那个名字，或 `lambda` 经 `letrec` 起的别名。判定锁定：

- `rator` 是 `(ref id)`，且 `id` 就是本 `code` 对应的 `letrec` 名；或
- `rator` 的 IR 经已知别名仍指向本 `lid`。

不要靠「运行时比较闭包指针是否相等」来决定发不发 `br`：那会把每次递归变成间接跳，且无法跳过序言。自身识别是**编译期**的事。

命中之后，后端**禁止**走普通调用路径（`blr`、新帧、改 `LR`）。正确序列：

1. 按从左到右求值全部实参，结果写入**临时**（`x9–x15` 或当前帧 spill 槽）。任何实参表达式都可能读取旧的参数绑定，因此不得边求值边覆盖 `x0–x7` / 栈上的入参槽。
2. 把临时搬进本过程的参数寄存器 / 参数栈槽（覆盖旧实参）。
3. 把 `x8` 写成 `argc`（自身调用 arity 与入口相同，本层固定参数；写了也无妨，为 L33 铺路）。
4. `b L_<lid>_body`（或 `br` 到该标签地址）。标签贴在**序言之后**：arity 检查、`stp` 建帧、`mov x29, sp`、保存 `SELF` 全部做完，才进入 body。
5. `SELF`（`x21`）保持不变。不要重新 `ldr` 闭包、不要重新 bump 堆。

栈指针在循环里不变。一万次递归与一次调用占用同一帧。

### 为何必须跳过序言

若尾调用跳到过程**入口**（含 `stp x29, x30, [sp, #-N]!`），每次都会再压一帧，尾调用名存实亡。`LR` 也会被反复覆盖，最终 `ret` 回不到真正的调用方。

序言只在「从外面 `blr` 进来」时跑一次；自身尾调用是过程内部的 `goto`。

### aarch64 约定（本层起钉死）

- **非尾调用**：去标签闭包，`ldr x9, [raw]`，`blr x9`。`blr` 把返回地址写入 `x30`。调用点 `sp` 16 字节对齐。
- **自身尾调用**：`b` 到 body 标签，或 `br x9`（`x9` 里是标签地址）。**不要** `blr`。
- **禁止使用 `x18`**。临时用 `x9–x15`。不要用 `x16`/`x17` 长期活着。
- `argc` 仍在 `x8`（L25）。

可移植 IR 不变：

```
(call      Ir Ir ...)
(tail-call Ir Ir ...)
```

后端 `emit-tail-call` 本层只对「callee 是当前 `lid`」发出跳转；其它 `tail-call` **降级为 `call`**（正确但涨栈）。不要为此编译期报错，否则 L32 之前无法跑「尾位置写了别的函数」的程序。

### 与 `letrec` 的关系

L28 的单函数 `letrec` 是本层的主战场。绑定名在 body 里以 `ref` 出现，编译 `code` 时环境知道「这个 `ref` 就是我」。若你的 `letrec` 把闭包放进盒子再 `unbox` 调用，自身识别要透过这个盒子：要么前端在降 IR 时把自调用直接标成 `(tail-call (self) …)`，要么后端看见 `(prim unbox (ref f))` 且 `f` 是当前绑定。推荐前端显式标 `self`，少让后端猜。

## 与上一层的差异

- 第一次发出 `(tail-call …)` IR；此前所有调用都是 `(call …)`。
- 前端必须做尾位置分析。L30 的内部 `define` 变换后的 `letrec` body 要标尾。
- 后端第一次在 Scheme 过程里使用 `b`/`br` 而不是 `blr`。
- 非自身的尾位置调用语义不变（仍涨栈），只是 IR 形状可能已经是 `tail-call`。
- 栈帧布局不变；自身尾调用**复用**已有帧，不改 `FP`/`SP`。

## 代码骨架

### 可移植：尾位置降 IR

```scheme
(define (expr->ir expr env tail?)
  (cond
    ((if-form? expr)
     `(if ,(expr->ir (if-test expr) env #f)
          ,(expr->ir (if-then expr) env tail?)
          ,(expr->ir (if-else expr) env tail?)))
    ((begin-form? expr)
     (let* ((xs (begin-body expr))
            (head (drop-right xs 1))
            (last (last xs)))
       `(seq ,@(map (lambda (e) (expr->ir e env #f)) head)
             ,(expr->ir last env tail?))))
    ((let-form? expr)
     `(let ,(map (lambda (b)
                   (list (car b) (expr->ir (cadr b) env #f)))
                 (let-bindings expr))
        ,(expr->ir (let-body expr) env tail?)))
    ((app-form? expr)
     (let* ((op (car expr))
            (args (cdr expr))
            (ir-op (expr->ir op env #f))
            (ir-args (map (lambda (a) (expr->ir a env #f)) args)))
       (if tail?
           `(tail-call ,ir-op ,@ir-args)
           `(call ,ir-op ,@ir-args))))
    ;; lambda / letrec / ref / prim / imm … 同前层
    (else (error "L31: bad expr" expr))))

;; lambda 的 body 以 tail?=true 进入
(define (lambda->code lid formals fvs body env)
  `(code ,lid ,formals ,fvs ,(expr->ir body env #t)))
```

`and`/`or` 在进 `expr->ir` 之前展开成 `if`，展开必须把「最后一个操作数」放进 `if` 的尾支。

### 可移植：标记自身

```scheme
;; 编译某个 code 时：
(define (rewrite-self-tail ir lid self-id)
  (if (and (pair? ir) (eq? (car ir) 'tail-call)
           (self-rator? (cadr ir) self-id))
      `(tail-call (self ,lid) ,@(cddr ir))
      ir))  ; 递归走过 if/seq/let
```

### aarch64-apple：过程形状

```asm
    .p2align 2
L_f_code:
    cmp     x8, #2              ; arity（例：两参数）
    b.ne    L_arity_err
    stp     x29, x30, [sp, #-32]!
    mov     x29, sp
    str     x21, [sp, #16]      ; 保存入站 SELF；HP 不在每帧保存
    ; 溢出参数、局部槽按需再减 sp，保持 16 字节对齐
L_f_body:                       ; ← 自身尾调用跳到这里
    ; … body，结果在 x0 …
    ldr     x21, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret
```

自身尾调用（两参数，实参已求值到 `x9`、`x10`）：

```asm
    mov     x0, x9
    mov     x1, x10
    mov     x8, #2
    b       L_f_body            ; 不是 blr，不是 L_f_code
```

### aarch64-apple：`emit-tail-call`

```scheme
(define (emit-tail-call n-args rator ctx)
  (if (self-call? rator ctx)
      (string-append
        (emit-args-into-temps n-args ctx)
        (emit-temps-to-arg-home n-args ctx)
        "\tmov x8, #" (number->string n-args) "\n"
        "\tb L_" (ctx-lid ctx) "_body\n")
      (emit-call n-args)))  ; L32 之前降级
```

求值实参时若临时不够，spill 到**当前帧里不属于入参 home 的槽**。搬回 home 的顺序：先全部写入临时，再统一 `mov`/`str`，避免 `(f (fxsub1 n) n)` 把 `n` 提前毁掉。

`emit-call` 仍是：求值闭包到寄存器，去 `CLOSURE_TAG`，`ldr x9, [raw]`，设 `x8`，对齐 `sp`，`blr x9`。

## 测例清单

上一层全部测例仍须通过。

1. **小递归基线**  
   `(letrec ((f (lambda (n a) (if (fx= n 0) a (f (fxsub1 n) (fx+ a n)))))) (f 0 0))` → `0`

2. **一步**  
   同上，`(f 1 0)` → `1`

3. **三角形数**  
   `(f 5 0)` → `15`（`1+2+3+4+5`）

4. **`(f 10 0)`** → `55`

5. **合同测例：一万次不得爆栈**  
   `(letrec ((f (lambda (n a) (if (fx= n 0) a (f (fxsub1 n) (fx+ a n)))))) (f 10000 0))`  
   → `50005000`  
   一万个未优化帧在本教程的帧尺寸下会耗尽默认栈或至少明显涨栈；本层必须活着并给出正确和。

6. **更大的 n（防「栈碰巧很大」假绿）**  
   `(f 100000 0)` → `5000050000`（若宿主/`rt_print` 的 fixnum 范围装得下；`100000*100001/2 = 5000050000`，小于 `2^61`）。不得 SIGSEGV。

7. **尾递归阶乘**  
   `(letrec ((fact (lambda (n a) (if (fx= n 0) a (fact (fxsub1 n) (fx* a n)))))) (fact 5 1))` → `120`

8. **`(fact 10 1)`** → `3628800`

9. **零参数自身尾调用**  
   `(letrec ((f (lambda () 42))) (f))` → `42`  
   （无递归，但 `lambda` body 是尾位置的立即数，证明分析没有把 body 误标成非尾。）

10. **单参数倒数到零**  
    `(letrec ((f (lambda (n) (if (fx= n 0) 0 (f (fxsub1 n)))))) (f 10000))` → `0`

11. **`if` 两支都是自身尾调用**  
    `(letrec ((f (lambda (n a) (if (fx< n 0) (f (fxneg n) a) (if (fx= n 0) a (f (fxsub1 n) (fx+ a 1))))))) (f -3 0))` → `3`

12. **`begin` 最后一项是尾调用**  
    `(letrec ((f (lambda (n a) (begin (fxadd1 n) (if (fx= n 0) a (f (fxsub1 n) (fx+ a n))))))) (f 4 0))` → `10`  
    第一个 `fxadd1` 的值被丢弃。

13. **`let` body 是尾调用**  
    `(letrec ((f (lambda (n) (let ((m (fxsub1 n))) (if (fx< n 1) 0 (f m)))))) (f 10000))` → `0`

14. **`let*` body 是尾调用**  
    `(letrec ((f (lambda (n a) (let* ((n1 (fxsub1 n)) (a1 (fx+ a n))) (if (fx= n 0) a (f n1 a1)))))) (f 5 0))` → `15`

15. **`and` 最后一项保持尾**（依赖 L11 展开）  
    `(letrec ((f (lambda (n) (and (fx>= n 0) (if (fx= n 0) #t (f (fxsub1 n))))))) (f 10000))` → `#t`

16. **`or` 最后一项保持尾**  
    `(letrec ((f (lambda (n) (or (fx= n 0) (f (fxsub1 n)))))) (f 10000))` → `#t`

17. **非尾递归仍然正确（允许涨栈，n 保持较小）**  
    `(letrec ((f (lambda (n) (if (fx= n 0) 0 (fx+ n (f (fxsub1 n))))))) (f 10))` → `55`  
    `(f n)` 是 `fx+` 的操作数，**不得**被标成 `tail-call`。

18. **实参含旧参数，覆盖顺序**  
    `(letrec ((f (lambda (a b) (if (fx= a 0) b (f (fxsub1 a) (fx+ a b)))))) (f 5 0))` → `15`  
    第二个实参读取尚未覆盖的 `a`。

19. **闭包自由变量 + 自身尾调用**（L26）  
    `(let ((k 2)) (letrec ((f (lambda (n a) (if (fx= n 0) a (f (fxsub1 n) (fx+ a k)))))) (f 10 0)))` → `20`  
    `SELF` 在循环中不得丢失；`k` 每次从闭包槽加载。

20. **嵌套 `if` + `begin`**  
    `(letrec ((f (lambda (n s) (if (fx= n 0) (begin s) (if (fx= n 1) (f 0 (fx+ s 1)) (f (fxsub1 n) (fx+ s n))))))) (f 6 0))` → `21`

21. **内部 `define` 形状（L30）**  
    `(let () (define (f n a) (if (fx= n 0) a (f (fxsub1 n) (fx+ a n)))) (f 10000 0))` → `50005000`

22. **多参数（≥3）自身尾调用**  
    `(letrec ((f (lambda (a b c) (if (fx= a 0) (fx+ b c) (f (fxsub1 a) (fxadd1 b) c))))) (f 10000 0 7))` → `10007`

23. **尾位置 `letrec` 的 body 是调用**  
    `(letrec ((g (lambda (x) x))) (letrec ((f (lambda (n) (if (fx= n 0) 1 (f (fxsub1 n)))))) (f 100)))` → `1`

24. **非自身调用仍可用**  
    `(letrec ((id (lambda (x) x)) (f (lambda (n) (id n)))) (f 3))` → `3`  
    `(id n)` 即使在 `f` 的尾位置，本层可以 `blr`。结果必须对。

25. **汇编抽查（可手跑，建议进驱动 grep）**  
    测例 5 生成的 `.s` 在 `L_*_body` 循环路径上含 `b ` 或 `br `，**不得**在该自递归边上出现 `blr`。本测例不看 stdout，看汇编文本。

## 验收标准

- 测例 1–24 退出码 0，stdout 与期望逐字节相符（含末尾换行）。
- 测例 5、6、10、15、16、21 不得因栈溢出被杀（SIGSEGV / SIGALTSTACK）。实现若只在 n=10 时用 `br`、n=10000 时仍 `blr`，不合格。
- 测例 17 生成代码里对内层 `(f …)` 必须是 `blr`（或等价的非尾调用），证明尾位置分析没有把所有自调用都当成尾。
- 自身尾调用路径不改变 `SP`（循环体内无匹配的 `stp`/`add sp`）。序言的 `stp` 只执行一次。
- 调用点与过程入口仍 16 字节对齐；生成代码不含 `x18`。
- 上一层全部测例仍须通过。

## 常见坑

- **跳到函数入口而不是 body 标签**：每次 `stp` 一次，一万次照样爆栈。看起来「用了 `br`」却毫无意义。
- **边求值边覆盖参数寄存器**：`(f (fxsub1 n) n)` 若先把 `fxsub1 n` 写入 `x0`，第二个 `n` 已经是减一后的值。必须全进临时再搬。
- **`blr` 当尾调用**：`blr` 写 `x30`。即使你不建新帧，返回地址也被毁掉，最终 `ret` 跳进野地。
- **把非尾的自调用优化掉**：`(fx+ n (f (fxsub1 n)))` 必须涨栈，否则语义变成迭代加法，测例 17 的值可能碰巧对、更大的 n 或有副作用时会错。
- **`and`/`or` 展开把最后一项包进非尾上下文**：例如先算进临时再 `if`，最后一项就不再是尾，测例 15/16 会爆栈。
- **忘记自由变量**：循环里 `SELF` 被某个 prim 调用的 C ABI 毁掉。对 C 的 `bl` 前要按约定保存 `x19–x21`；自身纯 Scheme 循环不应碰 `x21`。
- **帧未 16 字节对齐**：`stp` 的立即数必须是 16 的倍数。Apple 上偶发 SIGBUS。
- **用 `x18` 当临时**：Darwin 保留，表现为偶发损坏，极难查。

## 下一层预告

L32 要把「尾位置调用**另一个**闭包」也做成不涨栈：拆掉本帧、`br` 进目标代码。互递归的 even/odd 将第一次可以深到一万层。
