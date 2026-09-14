# L14 — `car` / `cdr`

## 目标

一元原语 `car` / `cdr`：操作数必须是 pair，否则运行时 `rt_error`。去标签后 `car` 加载字 0，`cdr` 加载字 8。结果已是带标签的 Scheme 值，不必再编码。

本层范围之外：`set-car!` / `set-cdr!`、`list-ref`、对非 pair 返回 `#f`（那不是 R4RS）、变量。嵌套 `(car (car …))`、`(car (cons (cons …) …))` 必须工作。

## 原理

### 求值

```
(car E)  → 求值 E 到 x0 → 检查 pair → raw = x0 - PAIR_TAG → ldr x0, [raw]
(cdr E)  → 同上，ldr x0, [raw, #8]
```

加载的是完整 64 位字。fixnum、布尔、嵌套 pair、空表都只是那个字里的位型。

### 类型检查（运行时，不是编译期）

`(car 1)`、`(car ())`、`(car #t)`、`(car #\A)` 都是合法程序、非法操作数。空表 **不是** pair：R4RS 对 `(car '())` 是错误，不是返回未定义值。本层锁定为调用 `rt_error`，stderr 含 `type` 或 `pair`，退出码非 0。

检查与 `pair?` 同一掩码：

```
(x & 7) == PAIR_TAG
```

失败路径 `bl _rt_err_type`（或带消息的 `_rt_error`）。成功后再去标签。不要先 `sub #1` 再检查：fixnum `0` 减 1 变成看起来像 tagged pair 的东西，接着就会对 `0xFFFFFFFFFFFFFFFF` 做 `ldr`。

去标签两种都合格：

```asm
    sub     x0, x0, #1          ; PAIR_TAG
    ; 或
    bic     x0, x0, #7          ; 清低 3 位；已证明是 pair 时等价
```

`bic` 更通用（L16 的 vector 去标签也是清 3 位），本层用哪个都行，须与后面层一致更好。锁定建议：**类型检查用具体 tag 比较，去标签用 `bic x0, x0, #7`**。

### IR

```
(prim car Ir)
(prim cdr Ir)
```

Arity ≠ 1：编译期错。未知 `car` 以外的名字仍编译期错。

### 不必改打印

L13 的 `rt_print` 已经能走指针打印整棵树。本层只是让 Scheme 代码也能取出子节点。C 打印不要改成调用 Scheme `car`——那会递归进尚未存在的闭包约定。

### 与 `%hp-fixnum`

`(car (cons 1 2))` 分配 16 字节，返回 `1`，不释放。没有 GC。测例不断言 HP。

## 与上一层的差异

- 新原语 `car` `cdr`。
- 第一次对用户值做**运行时类型错误**（L12 的 bump 非法尺寸也是运行时错，但那是测试原语）。`cons` 本身仍不检查操作数类型：任何值都可以是 car/cdr。
- 第一次从堆 **load**。L13 只 store。
- 打印逻辑不变。

## 代码骨架

### 可移植前端

```scheme
;; 在 expr->ir 的 cond 里
((and (pair? expr) (eq? (car expr) 'car) (length=? expr 2))
 `(prim car ,(expr->ir (cadr expr))))
((and (pair? expr) (eq? (car expr) 'cdr) (length=? expr 2))
 `(prim cdr ,(expr->ir (cadr expr))))
```

### aarch64-apple

```scheme
(define (emit-assert-pair)
  (string-append
    "\tand x9, x0, #7\n"
    "\tcmp x9, #" (number->string PAIR_TAG) "\n"
    "\tb.ne _rt_err_type\n"))

(define (emit-untag-heap)
  "\tbic x0, x0, #7\n")

(define (emit-prim-car)
  (string-append
    (emit-assert-pair)
    (emit-untag-heap)
    "\tldr x0, [x0]\n"))

(define (emit-prim-cdr)
  (string-append
    (emit-assert-pair)
    (emit-untag-heap)
    "\tldr x0, [x0, #8]\n"))
```

`emit-prim` 先 `emit-ir` 唯一操作数，再接上面。`_rt_err_type` 在 C：

```c
void rt_err_type(void) { rt_error("type error"); }
```

`b.ne _rt_err_type` 若链接器不接受条件跳进外部符号，改成本地 `.Lerr_type: bl _rt_err_type`。

`ldr x0, [x0, #8]` 的偏移 8 是字节。不要写成 `#1`（那会当成 1 字节偏移，且未对齐）。

## 测例清单

上一层全部测例仍须通过。

1. `(car (cons 1 2))` → `1`
2. `(cdr (cons 1 2))` → `2`
3. `(car (cons (cons 1 2) 3))` → `(1 . 2)`
4. `(cdr (cons 1 (cons 2 ())))` → `(2)`
5. `(car (car (cons (cons 1 2) 3)))` → `1`
6. `(cdr (cdr (cons 1 (cons 2 3))))` → `3`
7. `(car (cons 1 ()))` → `1`；`(cdr (cons 1 ()))` → `()`
8. `(fx+ (car (cons 3 4)) (cdr (cons 10 20)))` → `23`
9. `(pair? (cdr (cons 1 (cons 2 ()))))` → `#t`
10. `(car 1)`：运行时类型错误，stderr 含 `type` 或 `pair`
11. `(cdr ())`：运行时类型错误（空表不是 pair）
12. `(car #t)`：运行时类型错误
13. `(car #\A)`：运行时类型错误
14. `(car (cons 1 2) (cons 3 4))` / `(car)` / `(cdr)`：编译期 arity 错误
15. `(car (cdr (cons 1 (cons 2 3))))` → `2`

## 验收标准

- 测例 1–9、15 输出与上表一致（含 list 糖）。
- 测例 10–13 退出码非 0，且**不**把 fixnum / 空表 / 布尔里的位碰巧当成指针解引用后打印一个值。
- `car`/`cdr` 使用 64 位 `ldr`，偏移 0 与 8。
- 不使用 `x18`。
- `(car (cons 1 2))` 仍只分配一个 pair（16 字节）；`car` 本身不 bump。

## 常见坑

- **先去标签再检查**：`0` 或空表会被当成指针。必须先比低 3 位。
- **`(car '())` 返回未指定值还不报错**：合同是 `rt_error`。R4RS 说错误，本教程不「容错」。
- **`ldr w0, [x0]`**：丢掉高 32 位，负 fixnum 与堆指针都会坏。
- **偏移用 `#1` 或 `#2`**：那是把标签宽度当成了字节偏移。槽是字，+0 / +8。
- **检查写成 `(x & 3) == 1`**：`& 3` 只能区分 fixnum，string/vector/立即数会漏网或误伤。必须 `& 7`。
- **类型错误走编译期**：`(car 1)` 的 `1` 是合法表达式；错在运行时标签。前端看不到「这个子树不是 pair」（子树可以是任意 `cons` 调用）。
- **`cdr` 忘了 `#8`**：两个原语编成同一段代码，测例 2 会印 `1`。

## 下一层预告

L15 要能改写这两个槽：`set-car!` / `set-cdr!`。没有变量时如何观察 mutation，是那一层要锁死的合同。
