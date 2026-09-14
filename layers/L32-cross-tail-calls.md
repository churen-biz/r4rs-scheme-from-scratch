# L32 — 跨过程 / 互递归尾调用

## 目标

尾位置调用**另一个**闭包时不再积累栈帧：把实参按调用约定摆好，装入目标代码指针与 `argc`，把**本帧**像返回那样拆掉（恢复 `FP`/`LR`、收回本帧 `SP`），然后 `br` 到目标，而不是 `ret` 或 `blr`。互递归 `letrec` 的 even/odd 在尾位置来回跳，栈深度保持常数。

本层范围之外：`apply`、rest 参数、多值、`call/cc`。自身尾调用（L31）必须继续走「不拆帧、跳 body 标签」的快路径，不要倒退成拆帧再进自己的入口。

## 原理

### 为什么自身跳转不够

`(even n)` 的尾位置调用的是 `odd`，不是 `even`。`odd` 可能有不同的 arity、不同的帧大小、不同的自由变量。不能 `b L_even_body`。必须进入 `odd` 的**入口**（含它自己的序言），但调用方 **even 的帧要先消失**，否则每次 even→odd→even 仍涨两帧。

### 跨过程尾调用算法（芯片无关）

当前帧正在执行过程 A，尾位置要调过程 B（一个闭包）：

1. **求值** B 的闭包与全部实参，写入不会被下一步拆帧毁掉的临时。优先 `x0–x7`（实参）、`x9`（代码指针）、`x10`（闭包指针暂存）、spill 槽若要用，必须放在「拆帧后仍然合法」的位置——最简单是**全部装进寄存器**（本层测例参数个数 ≤ 8）。超过 8 个的溢出参数：先写到**调用方帧下方的出参区**，再把 `SP` 调整到「只留下这些出参 + 对齐」，不要把它们写在即将弹出的槽里。
2. `x8 = argc`。
3. `x21 = SELF =` 目标闭包（带 `CLOSURE_TAG`）。
4. 去标签，`ldr x9, [raw]` 得到 B 的代码指针。
5. **拆 A 的帧**：把序言保存的 `x29`/`x30` 弹回（`LR` 变成 A 的调用方返回地址），`SP` 回到 A 被调用时的值。不要把 `HP`（`x19`）/`HL`（`x20`）弹成 A 入口时的旧值——堆是进程资源，B 必须看见 A 已经 bump 过的 `HP`。`SELF` 已在第 3 步写成 B，不要再从 A 的帧里 `ldr` 回 A 的闭包。
6. `br x9`。不是 `blr`（那会把 `LR` 写成尾调用点，A 的调用方就丢了），不是 `ret`（那会回到 A 的调用方而跳过 B）。

效果：A 的帧被 B 的序言即将创建的帧**替换**。对 A 的调用方来说，B 返回即 A 返回。这就是 R4RS 的尾调用。

### 与自身尾调用的分工

| | 自身（L31） | 跨过程（本层） |
|--|-------------|----------------|
| 目标 | 当前 `lid` 的 body 标签 | 另一个闭包的 **code 入口** |
| 帧 | 复用，不改 `SP` | 拆掉本帧，目标再建自己的 |
| `SELF` | 不变 | 换成目标闭包 |
| 指令 | `b L_body` | `br x9`（`x9` = 目标代码） |
| arity | 相同，可跳过检查 | 目标入口自己 `cmp x8` |

后端 `emit-tail-call`：若 `self-call?` 走 L31；否则走本层序列。L31 把非自身降级为 `call` 的临时政策在本层废止。

### even / odd

```scheme
(letrec ((even (lambda (n)
                 (if (fx= n 0) #t (odd (fxsub1 n)))))
         (odd  (lambda (n)
                 (if (fx= n 0) #f (even (fxsub1 n))))))
  (even 10000))
```

`odd` 在 `even` 的 `if` 假支尾位置，`even` 在 `odd` 的假支尾位置。识别「callee 是另一个 `letrec` 绑定」即可；不必是常量闭包——运行时从环境加载 `odd` 的闭包指针，然后走跨过程路径。即使 `even` 与 `odd` 帧布局碰巧相同，也**不要**偷跳对方的 body 标签（自由变量槽、arity 检查会对不齐）。一律入口 + `br`。

### aarch64 细节

- 拆帧后、`br` 之前，`sp` 必须 16 字节对齐（A 被调用时就是对齐的；A 序言若 `stp … #-32`，对称 `ldp … #32` 后回到对齐）。
- `br x9` 不改 `sp`、不写 `x30`。B 的序言 `stp x29, x30` 保存的是 **A 之调用方** 的 `LR`，B 的 `ret` 直接回到那里。
- 禁止 `x18`。`x16`/`x17` 不要夹着跨 `br` 当长期临时（目标序言不保存它们）。
- 参数 ≤ 8 个时全部在 `x0–x7`，拆帧安全。这是本层测例的主路径。

### 非尾调用不变

`(fx+ 1 (g x))` 仍是 `blr`。跨过程优化只作用于 IR `(tail-call …)`。

## 与上一层的差异

- `emit-tail-call` 对非 `self` 不再降级为 `emit-call`。
- 第一次在尾路径上**平衡**当前函数的 `stp`/`ldp`（拆帧）但不 `ret`。
- 互递归 `letrec`（L29）的尾调用栈深度变为常数；L29 测例里 n 很小所以当时看不出来。
- 自身尾调用算法不改。

## 代码骨架

### 可移植：`emit-tail-call` 分派

```scheme
(define (emit-tail-call rator args ctx)
  (if (self-call? rator ctx)
      (emit-self-tail rator args ctx)
      (emit-cross-tail rator args ctx)))
```

### aarch64-apple：跨过程

```scheme
(define (emit-cross-tail rator args ctx)
  ;; 1. 求值 rator →  spill closure 到栈槽 T_CLOS 或 x10
  ;; 2. 求值 args → 临时（寄存器/槽），不得覆盖 T_CLOS
  ;; 3. 装入 x0–x7；溢出见下
  ;; 4. 闭包 → x21，去标签 → x9 = code
  ;; 5. x8 = n
  ;; 6. 拆帧
  ;; 7. br x9
  (string-append
    (emit-ir rator ctx)
    (emit-stack-save (ctx-clos-slot ctx))
    (emit-args-into-temps args ctx)
    (emit-temps-to-arg-regs args ctx)
    (emit-stack-load (ctx-clos-slot ctx))
    "\tmov x21, x0\n"
    "\tand x9, x0, #~7\n"     ; bic 掉 CLOSURE_TAG=0b110；用 bic 更干净
    "\tldr x9, [x9]\n"
    "\tmov x8, #" (number->string (length args)) "\n"
    (emit-frame-teardown ctx)  ; ldp x29,x30; 不恢复 x19/x20；不恢复 x21
    "\tbr x9\n"))
```

`emit-frame-teardown` 必须与该 `code` 的序言对称：

```asm
    ; 序言曾：stp x29, x30, [sp, #-32]! ; str x21, [sp, #16]
    ; 拆帧：  （忽略 [sp,#16] 的旧 SELF）
    ldp     x29, x30, [sp], #32
```

若序言还保存了其它 callee-saved（除 `HP`/`HL`/`SELF` 外你不该在每帧保存它们），在此对称弹出。**`x19`/`x20` 保持当前值穿过 `br`。**

### 溢出参数（>8）

出参区位于拆帧后的 `sp` 下方。推荐顺序：先按非尾调用那样把溢出参数 `str` 到「本帧低地址预留的 outgoing 区」，再 `ldp` 拆掉序言保存的 `x29`/`x30` 时**不要**把 outgoing 区一起拆掉——即序言把「保存区」和「outgoing」分成两段，拆帧只弹保存区。本层测例可以只用 ≤8 个参数；若实现了 >8，必须在测例 20 证明不涨栈。

### 错误

目标不是闭包：沿用 L24/L25 的运行时检查（在 B 的入口或 `br` 前 `and` 标签）。arity 不符：B 入口 `cmp x8` 后 `rt_error`。这些检查在尾调用下仍然发生，因为我们进的是入口而不是 body。

## 测例清单

上一层全部测例仍须通过。

1. **even 0**  
   `(letrec ((even (lambda (n) (if (fx= n 0) #t (odd (fxsub1 n))))) (odd (lambda (n) (if (fx= n 0) #f (even (fxsub1 n)))))) (even 0))` → `#t`

2. **odd 1**  
   同上绑定，`(odd 1)` → `#t`

3. **even 2** → `#t`

4. **odd 2** → `#f`

5. **even 3** → `#f`

6. **合同：even 10000 不得爆栈**  
   `(even 10000)` → `#t`

7. **odd 10000** → `#f`

8. **even 10001** → `#f`

9. **更大 n**  
   `(even 1000001)` → `#f`，不得 SIGSEGV。

10. **三过程轮转尾调用**  
    `(letrec ((a (lambda (n) (if (fx= n 0) 0 (b (fxsub1 n))))) (b (lambda (n) (c n))) (c (lambda (n) (a n)))) (a 10000))` → `0`

11. **尾调用邻接过程（非 letrec 名，值是闭包）**  
    `(let ((g (lambda (x) (fxadd1 x)))) (letrec ((f (lambda (n) (if (fx= n 0) 0 (g n))))) (f 41)))` → `42`  
    `g` 不是 `f` 自己；必须走跨过程 `br`。

12. **被调用方多一个参数**  
    `(letrec ((f (lambda (n) (g n 1))) (g (lambda (a b) (fx+ a b)))) (f 41))` → `42`

13. **被调用方零参数**  
    `(letrec ((f (lambda (n) (if (fx= n 0) (g) (f (fxsub1 n))))) (g (lambda () 7))) (f 10000))` → `7`

14. **非尾的互递归仍正确（小 n）**  
    `(letrec ((even (lambda (n) (if (fx= n 0) #t (if (odd (fxsub1 n)) #t #f)))) (odd (lambda (n) (if (fx= n 0) #f (even (fxsub1 n)))))) (even 8))` → `#t`  
    `odd` 包在 `if` 的 test 里，对 `even` 而言不是尾；不得误优化。n 保持小。

15. **自身 + 跨过程混合**  
    `(letrec ((f (lambda (n a) (if (fx= n 0) (g a) (f (fxsub1 n) (fx+ a n))))) (g (lambda (x) (fxadd1 x)))) (f 10 0))` → `56`  
    `f` 自尾，最后一次跨过程尾调 `g`。

16. **自由变量跨尾调用**  
    `(let ((k 5)) (letrec ((f (lambda (n) (if (fx= n 0) k (g (fxsub1 n))))) (g (lambda (n) (f n)))) (f 10000)))` → `5`  
    `f` 捕获 `k`；每次进入 `f` 必须带着 `f` 的闭包当 `SELF`，不能沿用 `g` 的 `x21`。

17. **返回闭包再尾调**（L27）  
    `(let ((make (lambda (x) (lambda (n) (if (fx= n 0) x (g (fxsub1 n) x))))) (g (lambda (n x) ((make x) n)))) ((make 3) 10000))` → `3`

18. **`begin` 末尾跨过程**  
    `(letrec ((f (lambda (n) (begin 1 2 (g n)))) (g (lambda (n) (if (fx= n 0) 9 (f (fxsub1 n)))))) (f 10000))` → `9`

19. **`let` body 跨过程**  
    `(letrec ((f (lambda (n) (let ((m (fxsub1 n))) (g m)))) (g (lambda (n) (if (fx< n 0) 1 (f n))))) (f 10000))` → `1`

20. **参数表达式有调用（非尾）再尾调**  
    `(letrec ((add1 (lambda (x) (fxadd1 x))) (f (lambda (n) (if (fx= n 0) 0 (g (add1 n))))) (g (lambda (n) (f (fxsub1 (fxsub1 n)))))) (f 10))` → `0`  
    `(add1 n)` 不是尾；`(g …)` 是。

21. **内部 define 互递归**  
    `(let () (define (even n) (if (fx= n 0) #t (odd (fxsub1 n)))) (define (odd n) (if (fx= n 0) #f (even (fxsub1 n)))) (even 10000))` → `#t`

22. **尾调用前有 `set!`**  
    `(let ((c 0)) (letrec ((f (lambda (n) (begin (set! c (fxadd1 c)) (if (fx= n 0) c (g (fxsub1 n)))))) (g (lambda (n) (f n)))) (f 100)))` → `101`  
    盒子在堆上，尾调用不得把 `set!` 弄丢。

23. **arity 错误仍报错（运行时）**  
    `(letrec ((f (lambda (n) (g n))) (g (lambda (a b) a))) (f 1))`  
    期望非 0 退出，stderr 含 arity / argument 一类关键字。

24. **非闭包当目标（运行时）**  
    `(letrec ((f (lambda (n) (n 1)))) (f 5))`  
    期望非 0，stderr 含 type / closure / procedure 一类关键字。

25. **汇编抽查**  
    测例 6 的 `.s` 在 `even`→`odd` 边上是 `br` 不是 `blr`；`odd`→`even` 同。自身路径（若有）仍是 `b L_*_body`。

## 验收标准

- 测例 1–22 退出码 0，输出匹配。6、7、9、10、13、16、18、19、21 不得栈溢出。
- 测例 23–24 运行时失败（不是编译期），退出码非 0。
- L31 测例 5（自身一万次）仍然只跳 body、不拆帧。可用 grep：`fact`/`f` 自递归边没有成对的 `ldp x29, x30` 紧挨 `br`。
- 跨过程尾调用拆帧不恢复 `x19`/`x20`。
- `sp` 在 `br` 前 16 字节对齐；无 `x18`。
- 上一层全部测例仍须通过。

## 常见坑

- **拆帧时把 `HP` 弹回去**：A 里 `cons` 过再尾调 B，B 看见的堆指针倒退，新对象被覆盖。Scheme 帧不要保存 `x19`/`x20`；只在 `scheme_entry` 与 C 调用边界保存。
- **拆帧时恢复旧 `SELF` 再 `br`**：B 的自由变量全从 A 的闭包里读。先写 `x21` 再拆帧，拆帧不要 `ldr x21`。
- **`blr` 代替 `br`**：`LR` 指向拆帧后的下一条，而你已经把帧拆了，返回时 `sp` 错位。
- **先拆帧再从旧槽读实参**：实参还在 A 的帧里。必须先搬到寄存器。
- **跳到对方 body 标签**：跳过对方 arity 检查与 `SELF` 设置。even/odd 碰巧能过，带自由变量的测例 16 会挂。
- **把 test 位置的调用也做成尾**：测例 14 语义变「只跑一半」。
- **`br x9` 但 `x9` 仍是闭包而不是 code 指针**：立刻指进标签位。去 `CLOSURE_TAG` 再 `ldr`。
- **对齐**：拆帧立即数与序言不一致，导致 `sp` 差 8 字节，下一次 `stp` SIGBUS。

## 下一层预告

L33 要让 `lambda` 在固定参数后面接一个 rest 表：入口用 `x8` 里的 `argc` 把多出来的寄存器/栈参数 `cons` 成表。
