# L35 — `values` 与 `call-with-values`

## 目标

实现 R4RS 的多值接口：`(values …)` 与 `(call-with-values producer consumer)`。单值路径不分配；零个或多个值走本层锁定的寄存器约定。消费者 arity 对不上时 **`rt_error`**，不默默丢弃或多补。

本层范围之外：`let-values` 派生语法、把多值存进数据结构的库过程、`call/cc` 捕获多值延续（L36 起 continuation 仍按单值 Unary 处理，直到以后需要再开层）。

## 原理

### 锁定的编码（覆盖 `_contract.md` 里尚未收窄的选项）

Callee-saved **`x22 = MV`**，含义是「当前这次返回交付了几个值」。

| 路径 | `x22` | `x0` | 堆 |
|------|-------|------|----|
| 普通表达式 / `(values x)` | `1` | **原始值**（不是单元素表） | 不分配 |
| `(values)` | `0` | `VOID`（`0x1F`） | 不分配 |
| `(values e1 e2 … en)` `n≥2` | `n` | **全体值的真列表** `(e1 … en)` | `cons` 出表 |
| `scheme_entry` 入口 | `1` | （尚未有返回值） | — |

这是合同里「更简单」的那条：多值一律进一张表，避免再占标签或再发明 values 块。`x7` 最高位不用。不要把个数放进 `x8`（`x8` 是 `argc`）。

`scheme_entry` 在保存 callee-saved 之后执行 `mov x22, #1`。序言从本层起还必须保存/恢复 `x22`（它是 callee-saved，callee 约定与系统可能弄脏；对 runtime 辅助的 `bl` 也依赖这一点）。Apple 上与 `x19–x21` 一起 `stp`，帧大小仍是 16 的倍数。

### `values`

用户语法：任意个操作数（含零）。从左到右求值。

- `n=1`：结果就是那个操作数，`x22=1`。等价于「没有 `values` 包一层」，但显式 `(values x)` 仍必须把 `x22` 写成 1（防止外层残留 `x22=3`）。
- `n=0`：`x0=VOID`，`x22=0`。
- `n≥2`：分配列表，`x0=list`，`x22=n`。

若 `values` 在尾位置：设好 `x0`/`x22` 后按尾返回（拆帧 `ret`，或属于某个 `lambda` 的尾，直接交还给调用方）。不要再包一次普通 `call`。

若 `values` 在**单值延续**里（作为 `fx+` 的操作数、`if` 的 test、`begin` 非最后一项之外——注意 `begin` 非最后一项的值被丢弃，见下）：

- 单值延续在「需要这个值」的点检查 `x22`。锁定：
  - **需要该结果的单值上下文**（原语操作数、`if` 的 test、`let` 右值、普通 `call` 的实参、非尾 `call` 的返回且调用方要用）：若 `x22 ≠ 1`，`rt_error("wrong number of values")`。
  - **丢弃该结果的上下文**（`begin` / `seq` 的非最后项）：不检查 `x22`，求完下一个表达式。求下一个之前建议 `mov x22, #1`，以免残留。
  - **顶层 `scheme_entry`**：打印看 `x0`（及 VOID），**不**因 `x22≠1` 报错。这样 `(values 1 2)` 作为程序可以直接测：打印那张表；`(values)` 打印 VOID；`(values 1)` 打印 `1`。

### `call-with-values`

```
(call-with-values producer consumer)
```

两个操作数，都是零参 / 任意 arity 的闭包。

1. 以 **argc=0** 调用 `producer`。这次调用的延续是**多值延续**：返回后**不要**执行「`x22≠1` 则报错」，也不要把 `x22` 重置为 1。
2. 读 `n = x22`，`x0` 为上表编码。
3. 把这些值当作实参去调用 `consumer`：
   - `n == 1`：以 `argc=1`、`x0` 仍是那个原始值，调用 `consumer`（普通单参调用，**不要**把 `x0` 再包成表）。
   - `n == 0`：以 `argc=0` 调用 `consumer`。`x0` 的 `VOID` **不是**实参。
   - `n ≥ 2`：`x0` 已是值表，走 L34 的 apply 机械把表摊进 `consumer`（无额外前缀）。
4. `consumer` 的 arity 由它自己的序言检查：对不上 → 已有的 `rt_error`。不要另写一套「忽略多余值」。R4RS 把错误的个数留给实现；本教程锁定为报错。
5. **`x22` 的恢复**：
   - `call-with-values` 在**非尾**位置：`consumer` 返回后，调用方处于单值上下文 → 若 `x22 ≠ 1` 则 `rt_error`，否则保持 `x22=1`。等价于一次普通非尾调用。
   - `call-with-values` 在**尾**位置：尾调 `consumer`，不再恢复。`consumer` 交付的 `x22`/`x0` 就是外层看到的。
   - 无论哪种，**不要**把 `x22` 恢复成 `producer` 留下的 `n`——那会让 `consumer` 的单值返回被外层误当成 `n` 个值。

嵌套：外层 `call-with-values` 的 producer 里还有内层。内层结束时必须按上面第 5 条把 `x22` 留给内层自己的 consumer 路径；外层 producer 最终用 `values` 或单值返回，外层再读 `x22`。只要「普通非尾调用会检查并清成单值、producer 调用不会」这条分界清晰，嵌套自然对。

### 普通过程返回

过程若没用 `values`，离开时 `x22` 应是 `1`。不要在**每个**序言里 `mov x22, #1`：那会在 `producer` 入口把外层还没读的 MV 清掉——不对，外层是在 producer **返回后**才读，入口清掉反而安全？不：producer 内部若先 `call-with-values` 再 `(values a b)`，入口清的是进 producer 时的残留，无害；但 producer 入口清 `x22` 也会让「忘记 `values`、直接返回一个值」得到 `x22=1`，这是好事。

锁定更窄、更好实现的一条：

- **每个 Scheme 过程入口**（`scheme_entry` 除外的用户 `code`）**不**改 `x22`。
- **每个非尾 `call` / 非尾 `apply` 返回之后**（且该调用不是 `call-with-values` 的 producer 调用）：若 `x22 ≠ 1` 则 `rt_error`，然后继续（此时 `x22` 已是 1）。
- **`values`** 按表设置 `x22`。
- **`producer` 调用**用单独的 `emit-mv-call`：调用后不检查 `x22`。

这样普通过程只要不碰 `x22`，入口时的 `1` 会一直留到返回（因为 `scheme_entry` 或上一次单值检查写过 1）。过程内部若调用了 `(values 1 2)` 且该 `values` 处于尾位置，调用方会看见 `x22=2`。

### VOID 打印

本层起 `rt_print` 识别 `0x1F`，输出 `#<void>\n`。不要把它当 fixnum `-8` 一类解码。

### IR

```
(values Ir ...)
(with-values Ir-producer Ir-consumer)
```

与 ARCHITECTURE §3 一致。`producer`/`consumer` 是表达式（通常是 `lambda` 或 `ref`），不是已保证的闭包——求值后检查标签。

## 与上一层的差异

- 新 IR：`values`、`with-values`。
- 新寄存器 `x22`；`scheme_entry` 保存集扩大。
- 非尾调用点增加 MV 检查。
- `apply` 机械被 `call-with-values` 在 `n≥2` 时复用。
- `rt_print` 认识 `VOID`。

## 代码骨架

### `scheme_entry` 序言（aarch64）

```asm
_scheme_entry:
    stp     x29, x30, [sp, #-48]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    mov     x19, x0
    add     x20, x19, x1
    mov     x22, #1             ; 单值约定
    ; … 编译体 …
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret
```

48 已是 16 的倍数。不要用 `x18`。

### `emit-values`

```scheme
(define (emit-values ir-args ctx)
  (let ((n (length ir-args)))
    (cond
      ((= n 0)
       (string-append
         (emit-imm VOID)
         "\tmov x22, #0\n"))
      ((= n 1)
       (string-append
         (emit-ir (car ir-args) ctx)
         "\tmov x22, #1\n"))
      (else
       (string-append
         (emit-list-of ir-args ctx)  ; x0 = (e1 … en)，左到右求值
         "\tmov x22, #" (number->string n) "\n")))))
```

### `emit-with-values`

```scheme
(define (emit-with-values prod cons ctx)
  (string-append
    (emit-ir prod ctx)          ; 闭包在 x0
    (emit-check-closure)
    "\tmov x21, x0\n"
    "\tmov x8, #0\n"
    "\tand x9, x0, #~7\n"
    "\tldr x9, [x9]\n"
    "\tblr x9\n"                ; producer；返回后不要查 x22
    ;; 现在 x22=n, x0=payload
    (emit-cwv-dispatch-consumer cons ctx)))

(define (emit-cwv-dispatch-consumer cons ctx)
  ;; 保存 payload 与 n，求值 consumer 闭包
  ;; n==1:  argc=1, x0=payload, call/tail-call consumer
  ;; n==0:  argc=0, call consumer
  ;; n>=2:  tail-apply/apply consumer payload
  ...)
```

尾位置的 `with-values`：对 consumer 走 `br`（及 `tail-apply`）。非尾：`blr` 之后 `cmp x22, #1; b.ne L_wrong_mv`。

### 非尾调用点

```scheme
(define (emit-mv-guard)
  (string-append
    "\tcmp x22, #1\n"
    "\tb.ne L_wrong_values\n"))
```

`L_wrong_values` 调 `_rt_error`。全程序一个标签即可。

## 测例清单

上一层全部测例仍须通过。

1. **单值 `values`**  
   `(values 42)` → `42`

2. **普通常量仍是单值**  
   `42` → `42`

3. **两值顶层**  
   `(values 1 2)` → `(1 2)`

4. **三值顶层**  
   `(values 1 2 3)` → `(1 2 3)`

5. **零值顶层**  
   `(values)` → `#<void>`

6. **`call-with-values` 单值**  
   `(call-with-values (lambda () 42) (lambda (x) (fxadd1 x)))` → `43`

7. **producer 用 `(values x)`**  
   `(call-with-values (lambda () (values 42)) (lambda (x) x))` → `42`

8. **两值 + 两参 consumer**  
   `(call-with-values (lambda () (values 10 32)) (lambda (a b) (fx+ a b)))` → `42`

9. **零值 + 零参 consumer**  
   `(call-with-values (lambda () (values)) (lambda () 7))` → `7`

10. **三值 + rest consumer**  
    `(call-with-values (lambda () (values 1 2 3)) (lambda r r))` → `(1 2 3)`

11. **两值 + 固定与 rest**  
    `(call-with-values (lambda () (values 1 2 3)) (lambda (a . r) (cons a r)))` → `(1 2 3)`

12. **consumer 参数过少（运行时）**  
    `(call-with-values (lambda () (values 1 2)) (lambda (x) x))` → 非 0。

13. **consumer 参数过多（运行时）**  
    `(call-with-values (lambda () (values 1)) (lambda (a b) a))` → 非 0。

14. **零值交给一参（运行时）**  
    `(call-with-values (lambda () (values)) (lambda (x) x))` → 非 0。

15. **单值上下文里的多值（运行时）**  
    `(fx+ (values 1 2) 3)` → 非 0。

16. **单值上下文里的零值（运行时）**  
    `(fxadd1 (values))` → 非 0。

17. **`if` 的 test 多值（运行时）**  
    `(if (values 1 2) 3 4)` → 非 0。

18. **`begin` 丢弃多值**  
    `(begin (values 1 2) 3)` → `3`

19. **`begin` 最后是多值（顶层）**  
    `(begin 1 (values 4 5))` → `(4 5)`

20. **非尾 `call-with-values` 的结果当单值**  
    `(fx+ 1 (call-with-values (lambda () (values 10 20)) (lambda (a b) a)))` → `11`

21. **尾位置 `call-with-values` 交付两值**  
    `(call-with-values (lambda () (values 1 2)) (lambda (a b) (values a b)))` → `(1 2)`

22. **producer 不是 `values` 而是普通调用**  
    `(call-with-values (lambda () (fx+ 1 2)) (lambda (x) x))` → `3`

23. **嵌套 `call-with-values`**  
    `(call-with-values
       (lambda ()
         (call-with-values (lambda () (values 1 2))
                           (lambda (a b) (values (fx+ a b) 10))))
       (lambda (s t) (fx+ s t)))` → `13`

24. **consumer 是闭包带自由变量**  
    `(let ((k 100))
       (call-with-values (lambda () (values 1 2))
                         (lambda (a b) (fx+ k (fx+ a b)))))` → `103`

25. **`values` 操作数有副作用顺序**  
    `(let ((b (cons 0 '())))
       (begin
         (values (begin (set-car! b 1) 10)
                 (begin (set-car! b (fx+ (car b) 1)) 20))
         (car b)))` → `2`

26. **producer / consumer 非闭包（运行时）**  
    `(call-with-values 1 (lambda r r))` → 非 0。  
    `(call-with-values (lambda () 1) 2)` → 非 0。

27. **编译期 arity**  
    `(call-with-values (lambda () 1))` → 编译期错。  
    `(values)` 合法，不要误伤。

28. **`apply` 与单值仍过**  
    `(apply (lambda (a b) (fx+ a b)) '(1 2))` → `3`

29. **consumer 用 `apply` 机械的长列表**  
    `(call-with-values (lambda () (values 1 2 3 4 5 6 7 8 9))
                       (lambda (a b c d e p q h i) i))` → `9`

30. **VOID 不等于 `'()` 或 `#f`**  
    `(call-with-values (lambda () (values)) (lambda () (null? '())))` → `#t`  
    另：`(eq? (begin (values) 0) 0)` 只证明 begin。顶层 `(values)` 打印 `#<void>`，不是 `()`。

## 验收标准

- 测例 1–11、18–25、28–30 退出码 0，输出匹配。`#<void>` 含尖括号，后面换行。
- 测例 12–17、26 运行时非 0；27 编译期非 0。
- `(values x)` 与 `x` 打印相同且不经过 pair 打印机。
- `scheme_entry` 保存并恢复 `x22`；入口置 `1`。
- 非尾 `fx+` 等处插入了 `x22` 检查；`begin` 非最后项没有误报。
- 上一层全部测例仍须通过。

## 常见坑

- **`(values x)` 仍 `cons` 成单元素表**：顶层打印 `(42)`，`call-with-values` 一参 consumer 收到一张表。`n=1` 必须是裸值。
- **`n=0` 把 `VOID` 当实参传给 consumer**：零参 consumer 反而 arity 错，一参 consumer 假绿。
- **过程入口盲目 `mov x22,#1` 发生在 producer 返回前被 consumer 入口清掉**：若你在 consumer 入口清 `x22`，dispatch 之前就要把 `n` 存进栈槽。推荐 dispatch 先读 `x22` 再求值 consumer。
- **非尾调用忘记 guard**：`(fx+ (values 1 2) 3)` 会把列表当 fixnum 加。
- **guard 误装在 producer 调用之后**：`call-with-values` 全部变「多值错误」。
- **`x8` 兼当 MV**：与 `argc` 冲突，apply 与多值互相踩。MV 只放 `x22`。
- **忘记保存 `x22`**：`rt_print` / 其它 runtime 辅助调用后 `x22` 垃圾，顶层 `(values 1 2)` 假绿或假红。
- **`call-with-values` 返回后把 `x22` 恢复成 producer 的 n**：测例 20 的 `fx+` 会报错或把列表当整数。
- **用 `x18` 暂存 n**。

## 下一层预告

L36 引入 `call/cc`，但只允许**向下逃逸**：把栈指针快照进一个闭包，用来放弃当前计算，不能在 `call/cc` 已经正常返回之后再调用该延续。
