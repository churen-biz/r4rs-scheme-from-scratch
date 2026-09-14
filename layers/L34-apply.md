# L34 — `apply`

## 目标

实现 `(apply proc a1 … list)`：除最后一个实参外按普通求值，最后一个必须是**真列表**（以 `'()` 结尾、无环），把它摊平进 L25 的调用约定，再调用 `proc`。若整个 `apply` 处于尾位置，这次调用必须是尾调用（`br`，不积累 `apply` 自己的帧）。允许运行时辅助 `rt_apply`（纯汇编循环）。

本层范围之外：把 `fx+` 等**内联原语**做成可 `apply` 的闭包（测例只用 `lambda` / `letrec` 过程）；`values` 多值；对无穷表或带环表做比「报错」更聪明的事。

## 原理

### 语法与求值

```
(apply proc arg1 arg2 … argN list)
```

`N ≥ 0`。最少两个操作数：`proc` 与 `list`。`(apply)`、`(apply proc)` 编译期 arity 错。

求值顺序：从左到右求 `proc`、`arg1`…`argN`、`list`。然后：

1. `proc` 必须是闭包（`CLOSURE_TAG`），否则 `rt_error`。
2. `list` 必须是真列表：反复 `cdr` 直到 `'()`。若遇到非 pair 且非 `'()`（点对），或步数超过一个实现上限而怀疑环——合同：**环与点对一律 `rt_error`**。环检测：龟兔或「步数 > 当前堆对象数」；简单实现可用龟兔（Floyd），不要静默死循环。
3. 逻辑实参序列 = `(arg1 … argN)` 再接 `list` 的元素。空表接上等于没有额外参数。
4. 按调用约定装入 `x0–x7`、溢出栈、`x8=argc`、`x21=proc`，进 `proc`。

`(apply f 1 2 '(3 4))` 等价于 `(f 1 2 3 4)`。`(apply f '())` 等价于 `(f)`。`(apply f '(1 2) '(3))` 不是把两张表都摊开：只有**最后一个**参数被摊平，结果是 `(f (1 2) 3)`。

### 尾位置

`(apply proc … list)` 若在尾位置（L31 的 `tail?`），摊平后必须走 L32 的跨过程尾调用：拆掉当前帧（或复用后 `br`），**不得** `blr` 进 `proc` 再 `ret` 回 `apply` 的残帧。否则 `(letrec ((f (lambda xs (if (null? xs) 0 (apply f (cdr xs)))))) (apply f (make-long-list)))` 会涨栈。

非尾位置的 `apply`：摊平后 `blr`，返回值在 `x0`，然后继续当前表达式。

IR 锁定两种：

```
(apply      Ir-proc Ir-arg … Ir-list)       ; 非尾
(tail-apply Ir-proc Ir-arg … Ir-list)       ; 尾
```

或复用 `(call`/`tail-call)` 之前由前端把列表展开——**不行**：列表是运行时值。必须留到运行时摊平。

### `rt_apply`

允许。推荐职责切分：

```
; 算法伪代码：实现必须是 runtime 汇编，不是 C。
/* 检查 list 为真列表，把元素写入 out[0..]，返回元素个数。
 * 失败则 rt_error，不返回。out 由调用方提供（栈上缓冲或堆）。
 * 不要在这里调用 Scheme 过程。
 */
i64 rt_list_to_args(ptr list, ptr *out, i64 cap);
```

汇编：把 `arg1…argN` 与 `out[0…]` 拼成最终 argc，装寄存器，再 `br`/`blr`。

另一种： noreturn 的汇编循环写在 runtime 的 `.s` 里，符号 `_rt_apply_tail` / `_rt_apply_call`。两种都合格。**不要**用一个会再 `blr` 回 Scheme 的「普通函数」去「调用」Scheme 过程——额外帧会破坏尾调用，且辅助代码必须遵守 Scheme 的 `SELF`/`HP` 约定。锁定：runtime 最多负责「表 → 数组 + 检查」；**跳进闭包的 `br`/`blr` 由生成代码或 runtime 里明确的 asm 跳转发出**。

容量：`cap` 太小则 `rt_error("apply: too many arguments")`。本层测例 argc ≤ 32。缓冲可以是 `scheme_entry` 旁的静态数组，或在当前 `SP` 下再减一块对齐空间。

### 与 rest 的配合

`(apply (lambda (a . r) (cons a r)) '(1 2 3))`：`proc` 入口看见 `argc=3`，按 L33 打包 `r=(2 3)`。`apply` 不自己做 rest；它只负责调用约定。

`(apply (lambda r r) 1 '(2 3))` → `(1 2 3)`。

### 固定前缀

`(apply f a b lst)` 的 `a`、`b` 不是列表，原样作为前两个逻辑参数。若 `a` 碰巧是 pair，也不摊开。

## 与上一层的差异

- 新核心形式 / 原语 `apply`（用户语法）。前端识别 `(apply …)`，不要当普通调用（普通调用不会摊平最后一项）。
- 运行时第一次按动态 `argc` 填 `x0–x7`（之前 argc 在编译期已知）。
- 尾位置 `apply` 必须接上 L32 的 `br` 路径。
- rest 过程可被 `apply` 打进任意合法 `argc`。

## 代码骨架

### 可移植前端

```scheme
(define (expr->ir expr env tail?)
  (cond
    ((and (pair? expr) (eq? (car expr) 'apply))
     (if (< (length (cdr expr)) 2)
         (error "L34: apply expects proc and list")
         (let ((irs (map (lambda (e) (expr->ir e env #f)) (cdr expr))))
           (if tail?
               `(tail-apply ,@irs)
               `(apply ,@irs)))))
    ;; …
    ))
```

`apply` 不是 Scheme 绑定名的普通调用：它是核心形式。若以后 L42 要让 `apply` 作为一等过程，再包一层闭包；本层测例用核心形式即可。

### aarch64-apple：非尾 `apply`

```asm
    ; x21 = proc（已检查闭包）, x9 = 前缀已装入的个数
    ; x0… 可能暂存了前缀；先 spill 到栈缓冲 ARGS
    ; x10 = list
    mov     x0, x10
    adrp    x1, _apply_buf@PAGE
    add     x1, x1, _apply_buf@PAGEOFF
    mov     x2, #32
    bl      _rt_list_to_args     ; 返回 n_list in x0；Darwin 整数约定 保存 x19–x28
    ; argc = n_prefix + n_list
    ; 从缓冲 + 前缀装填 x0–x7，溢出写入 [sp, #…]
    mov     x8, argc
    and     x9, x21, #~7
    ldr     x9, [x9]
    blr     x9
```

### aarch64-apple：尾 `apply`

与上相同直到装填完毕，然后：

```asm
    ; teardown 当前帧（同 L32），HP/HL 保持
    br      x9                  ; 不是 blr
```

注意：`bl _rt_list_to_args` 发生在拆帧**之前**。返回后 `x19` 仍是 HP（callee-saved）。然后装填、拆帧、`br`。

### `rt_list_to_args`

```
; 算法伪代码：实现必须是 runtime 汇编，不是 C。
i64 rt_list_to_args(ptr list, ptr *out, i64 cap) {
    i64 n = 0;
    ptr slow = list, fast = list;
    while (list != EMPTY_LIST) {
        if ((list & 7) != PAIR_TAG) rt_error("apply: improper list");
        if (n >= cap) rt_error("apply: too many arguments");
        out[n++] = *(ptr *)(list - PAIR_TAG);          /* car */
        list = *(ptr *)(list - PAIR_TAG + 8);          /* cdr */
        /* Floyd：fast 走两步 */
        if (fast != EMPTY_LIST && (fast & 7) == PAIR_TAG) {
            fast = *(ptr *)(fast - PAIR_TAG + 8);
            if (fast != EMPTY_LIST && (fast & 7) == PAIR_TAG)
                fast = *(ptr *)(fast - PAIR_TAG + 8);
            slow = *(ptr *)(slow - PAIR_TAG + 8);
            if (fast == slow) rt_error("apply: circular list");
        }
    }
    return n;
}
```

空表：`n=0`，合法。

## 测例清单

上一层全部测例仍须通过。

1. **摊平空表，零前缀**  
   `(apply (lambda () 42) '())` → `42`

2. **摊平单元素**  
   `(apply (lambda (x) (fxadd1 x)) '(41))` → `42`

3. **摊平两元素**  
   `(apply (lambda (a b) (fx+ a b)) '(10 32))` → `42`

4. **前缀 + 表**  
   `(apply (lambda (a b c) (fx+ a (fx+ b c))) 1 2 '(3))` → `6`

5. **前缀多个 + 空表**  
   `(apply (lambda (a b) (fx+ a b)) 10 32 '())` → `42`

6. **只有表，rest 过程**  
   `(apply (lambda r r) '(1 2 3))` → `(1 2 3)`

7. **前缀进入 rest**  
   `(apply (lambda r r) 1 2 '(3 4))` → `(1 2 3 4)`

8. **固定 + rest**  
   `(apply (lambda (a . r) (cons a r)) '(1 2 3))` → `(1 2 3)`

9. **最后一个才摊平**  
   `(apply (lambda (a b) (cons a b)) '(1 2) '(3))` → `((1 2) . 3)`  
   若 `b` 是 `3`，`cons` 得 `((1 2) . 3)`。`(3)` 摊成单个 `3`。

10. **`apply` 的 proc 是表达式**  
    `(apply (let ((f (lambda (x) (fx* x 2)))) f) '(21))` → `42`

11. **嵌套 `apply`**  
    `(apply apply (list (lambda (a b) (fx+ a b)) '(20 22)))`  
    需要 `list`。本层若无 `list` 库：  
    `(apply apply (cons (lambda (a b) (fx+ a b)) (cons '(20 22) '())))` → `42`

12. **尾位置 `apply` 深递归不得爆栈**  
    `(letrec ((f (lambda xs
                   (if (null? xs) 0
                       (if (null? (cdr xs)) (car xs)
                           (apply f (cons (fx+ (car xs) (car (cdr xs)))
                                          (cdr (cdr xs)))))))))
       (apply f '(1 2 3 4 5)))` → `15`

13. **合同：长列表尾 `apply` 不涨栈**  
    `(letrec ((lp (lambda (n)
                    (if (fx= n 0) 1
                        (apply lp (cons (fxsub1 n) '()))))))
       (lp 10000))` → `1`  
    `(apply lp (cons …))` 在 `lp` 的尾位置。

14. **非尾 `apply` 值参与运算**  
    `(fx+ 1 (apply (lambda (x) x) '(41)))` → `42`

15. **arity 不足（运行时）**  
    `(apply (lambda (a b) a) '(1))` → 非 0。

16. **arity 过多给精确 lambda（运行时）**  
    `(apply (lambda (a) a) '(1 2))` → 非 0。

17. **点对不是真列表（运行时）**  
    `(apply (lambda r r) (cons 1 2))` → 非 0，stderr 含 improper / list。

18. **最后一参是 fixnum（运行时）**  
    `(apply (lambda r r) 1)` → 非 0。

19. **最后一参 `#f`（运行时）**  
    `(apply (lambda r r) #f)` → 非 0。不要把 `#f` 当空表。

20. **环（运行时）**  
    `(let ((p (cons 1 '()))) (begin (set-cdr! p p) (apply (lambda r r) p)))` → 非 0，不得死循环。

21. **`proc` 不是闭包（运行时）**  
    `(apply 1 '(2))` → 非 0。

22. **编译期操作数太少**  
    `(apply (lambda () 1))` → 编译期错。

23. **闭包自由变量经 `apply`**  
    `(let ((k 10)) (apply (lambda (x) (fx+ x k)) '(32)))` → `42`

24. **`apply` 到 even（跨过程约定仍在）**  
    `(letrec ((even (lambda (n) (if (fx= n 0) #t (odd (fxsub1 n)))))
              (odd (lambda (n) (if (fx= n 0) #f (even (fxsub1 n))))))
       (apply even '(10000)))` → `#t`

25. **8 个寄存器 + 表溢出**  
    `(apply (lambda (a b c d e p q h i) i)
            1 2 3 4 5 6 7 '(8 9))` → `9`

26. **空 rest 经 `apply`**  
    `(apply (lambda (a . r) r) '(1))` → `()`

27. **L33 直呼 rest 仍过**  
    `((lambda r r) 1 2)` → `(1 2)`

28. **`begin` 中非尾 `apply` 再返回**  
    `(begin (apply (lambda (x) x) '(1)) 2)` → `2`

## 验收标准

- 测例 1–14、23–28 退出码 0，输出匹配。
- 测例 13、24 不得栈溢出。
- 测例 15–21 运行时非 0；测例 22 编译期非 0。环测例 20 必须在有限时间内结束。
- 尾位置 `apply` 的生成代码在进目标前使用 `br` 而非 `blr`（测例 13 的 `.s` 可抽查）。
- `rt_apply` / `rt_list_to_args` 若存在，不 `malloc` Scheme 对象；堆分配仍走 `HP`。
- 尾 `apply` 进目标用 `br`，非尾用 `blr`；`sp` 16 字节对齐；无 `x18`。
- 上一层全部测例仍须通过。

## 常见坑

- **runtime 汇编里直接调 Scheme 闭包**：破坏 `HP`/`SELF`，且尾调用无法成立。摊平用循环，汇编再 `br`。
- **不检查真列表**：点对让打包循环把 cdr 当指针，崩在 `cons` 之外。
- **`#f` 或 `'()` 搞混**：最后一参必须是表；`'()` 合法，`#f` 不是。
- **把所有实参都摊平**：`(apply f '(1) '(2))` 会错成 `(f 1 2)`。
- **非尾 `apply` 用了 `br`**：拆掉当前帧后 `fx+` 一类后续代码的局部槽全没了。`tail?` 为假时 `blr`。
- **装填 `x0–x7` 时覆盖还没读完的 list 指针**：先把 list 与前缀 spill。
- **`argc` 忘了加前缀长度**：`(apply f 1 '(2))` 只把表装进去。
- **环没有检测**：测例 20 挂死驱动。
- **对齐**：为参数缓冲 `sub sp` 后必须仍是 16 字节倍数，再 `blr`/`br`。
- **用 `x18` 暂存 list 指针**。

## 下一层预告

L35 要让过程能一次交付多个值：`values` 与 `call-with-values`，并用 callee-saved 的 `x22` 记住值的个数。
