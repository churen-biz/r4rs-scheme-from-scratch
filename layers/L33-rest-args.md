# L33 — rest 参数

## 目标

支持带点号的参数表：`(lambda (a b . r) …)` 与「全 rest」`(lambda r …)`。调用时固定位置的参数仍走 `x0–x7`（及栈上溢出槽），多出来的实参按从左到右 `cons` 成一张**真列表**放进 rest 绑定。`argc` 在 `x8`，用来知道该打包多少个。`(lambda (a . r) …)` 的 arity 检查是 **`argc >= 1`**，不是相等。

本层范围之外：`case-lambda`、`#!rest` 读者语法（源文本用点号即可）、关键字参数、`apply`（L34）。没有 rest 的 `lambda` 仍是 L25 的精确 arity（`argc == n`）。

## 原理

### 用户语法

```
formals ::= (id …)           ; 精确 n 个，L25
         |  (id1 … idk . rest-id)   ; k ≥ 1 个固定 + rest
         |  rest-id          ; k = 0，全部打进表
```

`(lambda (a b . r) body)`：最少 2 个实参；`a`、`b` 绑定前两个，`r` 绑定剩余列表。恰好 2 个实参时 `r` 为 `'()`。

`(lambda r body)`：任意个实参（含 0），`r` 是全体实参的列表。

点号不是一个 id。非法形式（编译期错）：`(lambda (a . 5) …)`、`(lambda (a . (b)) …)`、`(lambda ( . r) …)`（写成 `(lambda r …)`）、两个点号。

### 入口序言

对 `k` 个固定参数 + rest：

1. `cmp x8, #k`；`b.lt L_arity_err`（**小于**才失败；大于合法）。
2. 建帧、保存 `LR`/`FP`/`SELF`，与 L25 相同。
3. **打包 rest**：从下标 `k` 起到 `argc-1`，把每个实参 `cons` 到累加器上。必须从**右往左** cons，使得结果列表从左到右与调用顺序一致：
   - 累加器初值 `EMPTY_LIST`（`0x3F`）
   - `i = argc - 1 … k`：`acc = cons(arg[i], acc)`
4. 把 `acc` 写入 rest 的 home（寄存器或栈槽）。固定参数已在 `x0…` / 入参槽，不要再动。
5. 贴 `L_*_body`（L31 自身尾调用跳这里——见下文 rest 与尾调用的交互）。
6. 执行 body。

`(lambda r …)` 即 `k=0`：无「小于 k」失败；`argc=0` 时 rest 为 `'()`。

`cons` 走已有 `emit-alloc 16` + `PAIR_TAG`。打包会 bump `HP`，这是预期副作用。`argc` 很大时 rest 表很大，堆不够会在 L51 前表现为撞 `HL` 或静默越界——本层测例保持 rest 长度适度（≤ 32）。

### 按索引取第 i 个实参

调用约定（L25，本层不改）：

| 下标 i | 位置 |
|--------|------|
| 0–7 | `x0`–`x7` |
| ≥ 8 | 调用方放在栈上。相对 **本帧 FP** 的偏移由你在 L25 锁定的入参布局决定：推荐「溢出参数在保存 `x29,x30` 之前由调用方写入，位于更高地址」，入口用 `[fp, #16 + 8*(i-8)]` 一类公式。合同：同一套公式用于普通多参、rest 打包、L34 的 `apply`。 |

打包循环用 `x8` 当上限，不要假设 `argc ≤ 8`。循环本身可用汇编展开（测例短）或运行时辅助 `rt_pack_rest(argc, k, fp)` 返回列表。允许 runtime 汇编辅助；它必须遵守：用传入的 Scheme 参数寄存器 / 栈槽，走 `HP` 做 `cons`（把 `HP` 当全局或额外参数传入——推荐显式传 `x19`，runtime 侧不要自己在堆外分配）。

更干净的做法是纯汇编循环，避免 `bl` 破坏 `x19–x21`。若走 runtime 辅助：`bl` 前 `stp` 那些 callee-saved。

### 自身尾调用 + rest

L31 跳过整个序言不再合法：新一次自身调用的 `argc` 可以变（`(lambda (n . r) (f (fxsub1 n) extra …))`），rest 表必须按新的 `x8` 重打包。锁定：

- 自身尾调用跳到 **`L_*_rest`：arity 最小检查之后、rest 打包之前**（精确 arity 的过程仍跳 `L_*_body`，无打包）。
- 先把新实参搬到 `x0–x7`/出参栈并设 `x8`，再 `b L_*_rest`。
- 不要跳到入口（会再建帧），也不要跳过打包。

跨过程尾调用（L32）进的是目标**入口**，目标自己做 `argc >= k` 与打包，无需新标签。

### 空 rest 与一对

`(cons 1 '())` 仍是 pair。rest 为 `'()` 时 `(pair? r)` 为 `#f`，`(null? r)` 为 `#t`。不要把「无剩余」编码成 `#f`。

## 与上一层的差异

- `lambda` 形参 AST 从「id 列表」变成「固定列表 + 可选 rest id」。
- 入口 arity：精确 `==` 与最少 `>=` 两支。
- 第一次在序言里分配堆（rest 表）。此前序言只动栈与寄存器。
- 自身尾调用的目标标签对 rest 过程前移到打包前。
- IR 的 `(code lid formals fvs body)` 中 `formals` 允许最后一个元素是 `(rest id)` 或单独约定 `(formals (a b) r)`。锁定形状：

```
(code lid (a b (rest r)) (fv …) body)
(code lid ((rest r)) (fv …) body)
(code lid (a b) (fv …) body)          ; 无 rest，同 L25
```

后端看见 `(rest r)` 才发打包代码。

## 代码骨架

### 可移植：解析 formals

```scheme
(define (parse-formals fml)
  (let loop ((x fml) (fixed '()))
    (cond
      ((null? x) (cons (reverse fixed) #f))
      ((symbol? x) (cons (reverse fixed) x))
      ((and (pair? x) (symbol? (car x)))
       (loop (cdr x) (cons (car x) fixed)))
      (else (error "L33: bad formals" fml)))))
```

### aarch64-apple：rest 序言

```asm
L_f_code:
    cmp     x8, #1              ; k=1 的 (lambda (a . r) …)
    b.lt    L_arity_err
    stp     x29, x30, [sp, #-32]!
    mov     x29, sp
    str     x21, [sp, #16]
L_f_rest:                       ; 自身尾调用带 rest 跳这里
    mov     x10, #0x3F          ; acc = '()
    mov     x11, x8             ; i = argc
    ; while (i > k) { i--; acc = cons(arg[i], acc); }
L_pack_loop:
    cmp     x11, #1             ; k
    b.le    L_pack_done
    sub     x11, x11, #1
    ; load arg[x11] → x12   （见 emit-load-arg-index）
    ; cons x12, x10 → x10
    b       L_pack_loop
L_pack_done:
    mov     x1, x10             ; r 的 home，例：第二形参
L_f_body:
    ; …
```

`emit-load-arg-index`：`i` 在通用寄存器里。

```scheme
(define (emit-load-arg-index dst-reg idx-reg fp-reg)
  ;; if idx < 8:  查表 ldr dst, [sp, #tmp] 不方便；用分支或
  ;; adr + 跳进「mov dst, xN」表。简单实现：展开 0..7 的 cmp/b.eq，
  ;; else 从栈 [fp, #off(idx-8)] 加载。
  ...)
```

`cons` 片段（与 L13 相同，注意保存 `acc` 与 `i`）：

```asm
    ; car=x12, cdr=x10, 结果 → x10
    mov     x13, x19            ; raw = HP
    add     x19, x19, #16
    str     x12, [x13]
    str     x10, [x13, #8]
    orr     x10, x13, #1        ; PAIR_TAG
```

runtime 汇编辅助版（允许）：

```
; 算法伪代码：实现必须是 runtime 汇编，不是 C。
/* runtime.s
 * argv[0] 对应 Scheme x0 … 由汇编把 x0–x7 存进一块、再把溢出栈指针传入。
 * 返回带 PAIR_TAG 的列表。HP 通过指针传入以便 bump。
 */
ptr rt_pack_rest(i64 argc, i64 k, ptr *reg_args, ptr *stack_args, ptr *hp);
```

汇编在 `bl _rt_pack_rest` 前后保存 `x19–x21`、`x29`、`x30`，并把更新后的 `*hp` 写回 `x19`。

### 精确 arity 不受影响

```asm
    cmp     x8, #2
    b.ne    L_arity_err         ; 仍是 ne，不是 lt
```

## 测例清单

上一层全部测例仍须通过。

1. **全 rest，零实参**  
   `((lambda r r) )` → `()`

2. **全 rest，一个**  
   `((lambda r r) 1)` → `(1)`

3. **全 rest，三个**  
   `((lambda r r) 1 2 3)` → `(1 2 3)`

4. **一个固定 + rest，恰好一个**  
   `((lambda (a . r) (cons a r)) 7)` → `(7)`  
   即 `r='()`。

5. **一个固定 + rest，多个**  
   `((lambda (a . r) (cons a r)) 1 2 3)` → `(1 2 3)`

6. **两个固定 + rest**  
   `((lambda (a b . r) (cons a (cons b r))) 1 2 3 4)` → `(1 2 3 4)`

7. **两个固定，无剩余**  
   `((lambda (a b . r) r) 1 2)` → `()`

8. **rest 上做 `car`/`cdr`**  
   `((lambda (a . r) (car r)) 1 2 3)` → `2`

9. **arity 太少（运行时）**  
   `((lambda (a . r) a) )`  
   期望非 0，stderr 含 arity。`argc=0 < 1`。

10. **两个固定但只给一个（运行时）**  
    `((lambda (a b . r) a) 1)` → 非 0。

11. **精确 arity 仍拒绝多余**  
    `((lambda (a b) (fx+ a b)) 1 2 3)` → 非 0。证明 rest 没有把精确 `lambda` 改成 `>=`。

12. **精确零参数仍拒绝一个**  
    `((lambda () 1) 2)` → 非 0。

13. **`(lambda r …)` 接受很多**  
    `((lambda r (car (cdr (cdr r)))) 10 20 30 40)` → `30`

14. **rest + 闭包自由变量**  
    `(let ((k 9)) ((lambda (a . r) (fx+ k (car r))) 1 2))` → `11`

15. **letrec 递归走 rest 表**  
    `(letrec ((len (lambda (xs) (if (null? xs) 0 (fxadd1 (len (cdr xs))))))) ((lambda r (len r)) 1 2 3 4 5))` → `5`

16. **自身尾调用 + rest，argc 从 2 变成 1**  
    `(letrec ((f (lambda (n . r)
                   (if (fx= n 0)
                       (if (null? r) 0 (car r))
                       (f (fxsub1 n))))))
       (f 10000 7))` → `0`  
    第一次 `argc=2`，`r=(7)`；自身尾调用 `(f (fxsub1 n))` 的 `argc=1`，`r='()`。必须跳到打包前的标签重打包，且不得爆栈。本层没有 `(f x . xs)` 应用层 splicing，那是 L34 的 `apply`。

17. **测例 16 的结果分支**  
    `(letrec ((f (lambda (n . r)
                   (if (fx= n 0)
                       (if (null? r) 0 (car r))
                       (f (fxsub1 n))))))
       (f 0 7))` → `7`

18. **跨过程尾调用到 rest 过程**  
    `(letrec ((f (lambda (n) (g n 1 2 3)))
              (g (lambda (x . r) (fx+ x (car r)))))
       (f 10))` → `11`

19. **8 个寄存器参数 + rest 溢出**  
    `((lambda (a b c d e p q h . r) (cons h r)) 1 2 3 4 5 6 7 8 9 10)` → `(8 9 10)`  
    `9` 与 `10` 来自栈。形参不要用 `f`，以免与读者可能引入的库名混淆。

20. **恰好 8 个 + 空 rest**  
    `((lambda (a b c d e p q h . r) r) 1 2 3 4 5 6 7 8)` → `()`

21. **rest 列表是新分配的，`set-car!` 不影响调用方**  
    无调用方变量。改为：两次独立调用不相等指针——  
    `(eq? ((lambda r r) 1) ((lambda r r) 1))` → `#f`

22. **`null?` / `pair?` 对 rest**  
    `((lambda r (cons (null? r) (pair? r))))` → `(#t . #f)`  
    `((lambda r (cons (null? r) (pair? r))) 1)` → `(#f . #t)`

23. **嵌套 lambda rest**  
    `(((lambda (x) (lambda r (cons x r))) 1) 2 3)` → `(1 2 3)`

24. **编译期坏 formals**  
    `(lambda (a . 1) a)` → 编译期错。  
    `(lambda (a . (b)) a)` → 编译期错。

25. **L31 精确 arity 自身尾调用仍过**  
    `(letrec ((f (lambda (n a) (if (fx= n 0) a (f (fxsub1 n) (fx+ a n)))))) (f 10000 0))` → `50005000`

26. **L32 even/odd 仍过**  
    `(letrec ((even (lambda (n) (if (fx= n 0) #t (odd (fxsub1 n))))) (odd (lambda (n) (if (fx= n 0) #f (even (fxsub1 n)))))) (even 10000))` → `#t`

## 验收标准

- 测例 1–8、13–23、25–26 退出码 0，打印匹配（pair 打印与 L13 一致：真列表用 `(1 2 3)` 糖或 `(1 . (2 . (3 . ())))`，两层文档与 `rt_print` 保持同一选择；本层期望按 L13 已锁定的 `write` 风格）。
- 测例 9–12 运行时非 0；测例 24 编译期非 0。
- rest 表在堆上，标签 `PAIR_TAG`；空 rest 是 `EMPTY_LIST` 不是 `#f`。
- `(lambda (a b) …)` 的 arity 仍是 `==`，不是 `>=`。
- 带 rest 的自身尾调用不涨栈（测例 16），且 `argc` 变化后 rest 内容正确（测例 16 vs 17）。
- 打包用 `x8`，不写死「最多 8 个」。
- 序言与 `cons` 路径保持 `sp` 16 字节对齐；不用 `x18`。带 rest 的自身尾调用用 `b`/`br` 到打包标签，不是 `blr`。
- 上一层全部测例仍须通过。

## 常见坑

- **从左往右 cons**：`(lambda r r) 1 2 3` 得到 `(3 2 1)`。必须从最后的实参往前 cons。
- **空 rest 写成 `#f`**：R4RS 是 `'()`。`null?` 测例会红。
- **精确 `lambda` 误用 `b.lt`**：多余参数被吞进不存在的 rest。
- **自身尾调用仍跳 `L_body`**：rest 仍是上一轮的表，测例 16 返回 `7` 而不是 `0`，或使用陈旧的 pair。
- **`x8` 在打包循环里被改掉又当 argc 用**：先拷到 `x11`。
- **从栈取 `i≥8` 时用错相对 `sp`/`fp` 的偏移**：拆帧、对齐填充都会让公式差 8 字节。用 L25 同一宏。
- **runtime 汇编辅助 在堆外分配 rest**：对象必须在 Scheme 堆上，否则以后 GC 看不见，且 `HP` 会计数对不上。
- **打包时没保存 `SELF`**：`cons` 序列若借 `x21` 当临时，自由变量全坏。
- **`lambda r` 与 `(lambda (r) …)` 搞混**：后者精确一参，前者全 rest。
- **用 `x18` 当打包循环的 `i`**：Darwin 保留。索引用 `x11` 一类临时。

## 下一层预告

L34 实现 `apply`：把最后一个列表实参摊平进调用约定，并在 `apply` 处于尾位置时 `br` 进目标，不再为摊平本身留一帧。
