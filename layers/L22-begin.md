# L22 — `begin` 与 mutator 返回 VOID

## 目标

用户语法增加表达式 `begin`：

```scheme
(begin E1 E2 … En)    ; n ≥ 1
```

从左到右求值，**整个 `begin` 的值是 `En`**。前面的值丢弃（它们的副作用保留）。

`(begin)` 零个子表达式：**编译期错误**（本教程表达式 `begin` 需要 ≥1 个；R4RS 对「空 begin」在定义上下文另有说法，这里不引入定义上下文）。

单表达式 `(begin E)` 语义恒等 `E`。前端可以剥掉，也可以降成单元素 `(seq Ir)`；**推荐降成 `seq`**，后端对单元素就是 emit 那一项，少一个前端特例。

本层同时做一次**锁定的语义修正**：

> `set-car!`、`set-cdr!`、`vector-set!`、`string-set!` 若在 L15–L17 仍返回被修改的容器，本层改为返回 **VOID = `0x1F`**。`rt_print` 把 VOID 打成 `#<void>`（其后换行）。

迁移：依赖「`set-car!` 返回 pair」的旧测例，改为 `let` 绑住容器，用 `begin` 先 mutate 再给出容器。

IR：`(seq Ir ...)`。后端 `emit-seq`。

本层范围之外：`set!`（L23）、隐式 begin 作为 `let` 的多 body（`let` 仍恰好一个表达式，序列请显式写 `begin`）、空 `begin` 当 unspecified 却仍生成代码。

## 原理

### 为何现在才做 `begin`

没有变量时，「先 `set-car!` 再返回 pair」只能写成嵌套原语，而 mutator 若返回容器，碰巧能当值。有了 `let`，中间结果可以丢掉，但写法丑陋：

```scheme
(let ((p (cons 1 2)))
  (let ((ignored (set-car! p 9)))
    p))
```

`begin` 把「求值并丢弃」变成核心形式。本层又把 mutator 的返回值改成 VOID：没有 `begin`/`let` 时，单独一个 `(set-car! (cons 1 2) 3)` 打印 `#<void>`，不再假扮成改好的 pair。这逼测例把副作用和值写清楚，并与 R4RS「未指定返回值」对齐——本教程把未指定钉成 VOID。

### IR `seq`

```
(seq Ir1 Ir2 … Irn)     ; n ≥ 1
```

ARCHITECTURE 已列 `(seq Ir ...)`：只保留最后值。不要把 `begin` 做成 `prim`。不要用嵌套 `(let ((_ Ir1)) (seq …))` 代替——那会占槽、污染 `env`。

前端：

```
(begin e1 e2 … en)  →  (seq ir1 ir2 … irn)
```

嵌套 `begin` 可在前端展平：`(begin (begin a b) c)` → `(seq a b c)`。展平可选；不展平时后端嵌套 `emit-seq` 也正确。锁定任选其一，测例 不依赖是否展平。

空列表不要构造 `(seq)`。前端在看到 `(begin)` 时 `error`，关键字建议 `empty-begin`。

### `emit-seq`

芯片无关：按顺序 `emit-ir` 每一个；前 `n-1` 个的 `x0` 被覆盖即丢弃；最后一个留下。全程**同一** `ctx`（同一 `si` 与 `env`）。`seq` 不分配绑定。

前一个表达式若是 `let`，它内部会把 `si` 抬高再在 body 结束时逻辑上结束——但按 L18 锁定，**不收回 `sp`**，且 `emit-let` 返回后外层 `ctx` 仍是进入 `let` 前的 `si`/`env`。因此：

```scheme
(begin (let ((x 1)) x) (let ((y 2)) y))
```

两个 `let` 都从同一个外层 `si`（例如 0）起始，**复用 slot 0**。这是对的：第一个 `let` 的绑定已死。不要为 `seq` 的每一项把 `si` 单调加下去造成帧膨胀（可以，但不必要）。**锁定：`emit-seq` 每项传入相同的外层 `ctx`。**

aarch64 无特殊指令；不要在项与项之间 `mov x0, xzr`。VOID 只来自那些约定返回 VOID 的 prim / 字面。

### VOID = `0x1F`

与 ARCHITECTURE §2 立即数表一致：

```
VOID = 0x1F = 0b00011111
低 3 位 111（立即数族），不是 pair/vector/string/box。
```

`runtime.s 标签注释` 与编译器常量必须同值。`emit-imm` 已能装载 `0x1F`。

`rt_print`：

```
; 算法伪代码：实现必须是 runtime 汇编，不是 C。
; VOID 0x1F

void rt_print(ptr x) {
    /* … 已有 fixnum / bool / () / char / pair / vector / string … */
    if (x == VOID) { write("#<void>\n"); return; }
    ...
}
```

满字比较。不要只看低 8 位。打印形式恰好 `#<void>` 加换行，不是空行、不是 `#<unspecified>`。

### mutator 返回值迁移

| 原语 | L15–L17（若你返回了容器） | 本层起 |
|------|---------------------------|--------|
| `set-car!` | 被改的 pair | VOID |
| `set-cdr!` | 被改的 pair | VOID |
| `vector-set!` | 被改的 vector | VOID |
| `string-set!` | 被改的 string | VOID |

`emit-prim` 在做完 `str` 到对象字段之后：

```asm
    mov     x0, #0x1F
```

不要把容器指针留在 `x0`。类型错误（非 pair 上 `set-car!`）若 L15 已有运行时检查，保持；本层不新加。

**回归怎么改**（文档合同，实现者改自己的 `tests/L15` 等）：

旧：

```scheme
(set-car! (cons 1 2) 9)          ; 曾期望 (9 . 2)
```

新：

```scheme
(let ((p (cons 1 2)))
  (begin
    (set-car! p 9)
    p))                          ; → (9 . 2)
```

只测 VOID：

```scheme
(set-car! (cons 1 2) 9)          ; → #<void>
```

L20 用 `(let ((x (set-car! p 9)) (y (car p))) y)` 测左到右的，本层仍合法：`x` 绑的是 VOID，`y` 仍是 `9`。期望文件若曾断言 `x` 为 pair，改为只观察 `y`，或改成 `begin` 版。

`car` / `cdr` / `vector-ref` / `string-ref` / `cons` / `make-vector` / `make-string` **不**返回 VOID。

### `if` 与 `begin`

```scheme
(if #t (begin 1 2) 3)            ; → 2
```

`and`/`or` 已展开成 `if`，不要把 `begin` 再展开成 `if`。最后一项在值位置（L31 尾调用会再谈；本层只保证值是最后一项）。

### `let` body

仍是单表达式。要序列：

```scheme
(let ((x 1))
  (begin (fxadd1 x) x))          ; → 1 ，fxadd1 的值丢掉
```

不要在本层允许 `(let ((x 1)) (fxadd1 x) x)`。隐式 begin 会让「忘写 begin」的测例过掉，L23 的 `set!` 序列也分不清是语法糖还是 `seq`。

## 与上一层的差异

| 项 | L21 | L22 |
|----|-----|-----|
| 顺序求值 | 只能嵌套 `let` 丢中间名 | `(begin …)` / `(seq …)` |
| 空序列 | — | `(begin)` 编译期错 |
| mutator 返回值 | 可能是容器 | **一律 VOID** |
| `rt_print` | 无 VOID | `#<void>` |
| `let` body 个数 | 1 | 仍为 1（显式 `begin`） |

## 代码骨架

### 可移植：前端

```scheme
(define VOID #x1F)

(define (expr->ir expr env)
  (cond
    ((and (pair? expr) (eq? (car expr) 'begin))
     (if (null? (cdr expr))
         (error "empty-begin")
         `(seq ,@(map (lambda (e) (expr->ir e env)) (cdr expr)))))
    ((and (pair? expr) (eq? (car expr) 'let*))
     (expr->ir (let*-desugar expr) env))  ; 或已在 expand 做掉
    ...))
```

`emit-ir` 增加 `(seq . irs)` 分派。

### aarch64-apple：`emit-seq` 与 mutator 收尾

```scheme
(define (emit-seq ir-list ctx)
  (if (null? ir-list)
      (error "empty seq")
      (let loop ((xs ir-list) (acc ""))
        (if (null? (cdr xs))
            (string-append acc (emit-ir (car xs) ctx))
            (loop (cdr xs)
                  (string-append acc (emit-ir (car xs) ctx)))))))

;; 在 set-car! / set-cdr! / vector-set! / string-set! 的字段 store 之后：
(define (emit-void)
  "\tmov x0, #0x1F\n")
```

`runtime.s 标签注释`：

```
; 算法伪代码：实现必须是 runtime 汇编，不是 C。
; VOID 0x1F
```

与编译器 `VOID` 同为 `31`。

## 测例清单

上一层全部测例仍须通过。L15–L17 中以 mutator 为**整个程序**且期望打印容器的测例，按本节迁移改写后须绿。

1. `(begin 1)` → `1`
2. `(begin 1 2 3)` → `3`
3. `(begin #t #f)` → `#f`
4. `(begin)`：编译期 `empty-begin`
5. `(let ((x 1)) (begin (fxadd1 x) x))` → `1`（前值丢弃，绑定仍在）
6. `(let ((p (cons 1 2))) (begin (set-car! p 9) p))` → `(9 . 2)`
7. `(let ((p (cons 1 2))) (begin (set-cdr! p 9) p))` → `(1 . 9)`
8. `(set-car! (cons 1 2) 9)` → `#<void>`
9. `(let ((v (make-vector 1 0))) (begin (vector-set! v 0 7) (vector-ref v 0)))` → `7`
10. `(vector-set! (make-vector 1 0) 0 1)` → `#<void>`
11. `(let ((s (make-string 1 #\a))) (begin (string-set! s 0 #\b) (string-ref s 0)))` → 按 L04/L17 打印 `#\b`（或该层锁定的字符格式）
12. `(string-set! (make-string 1 #\a) 0 #\b)` → `#<void>`
13. `(begin (begin 1 2) 3)` → `3`
14. `(if #t (begin 1 2) 3)` → `2`
15. 左到右副作用：

    ```scheme
    (let ((p (cons 1 2)))
      (begin
        (set-car! p 8)
        (set-car! p (fxadd1 (car p)))
        p))
    ```

    → `(9 . 2)`
16. `(begin (let ((x 1)) x) 2)` → `2`
17. `(let ((x 1) (y 2)) (begin x y))` → `2`
18. L20 左到右在 VOID 下仍成立：

    ```scheme
    (let ((p (cons 1 2)))
      (let ((x (set-car! p 9))
            (y (car p)))
        y))
    ```

    → `9`

## 验收标准

- 测例 1–3、5–18 退出码 0，输出含末尾换行；VOID 测例恰好 `#<void>\n`。
- 测例 4 编译期失败，不得运行出 `#<void>` 或崩溃。
- 四个 mutator 作为程序根表达式时打印 `#<void>`，不得再打印 pair/vector/string。
- `let` 多 body 仍拒绝：`(let ((x 1)) (set-car! …) x)` 无 `begin` 则编译期错。
- `seq` 不扩展 `env`、不改变外层 `si`。
- `#f`（`0x2F`）与 VOID（`0x1F`）打印不同。

## 常见坑

- **空 `begin` 降成 `(imm VOID)`**：本层禁止。空 begin 是语法错，不是 unspecified 值。VOID 只从 mutator（及 L23 的 `set!`）来。
- **`emit-seq` 每项 `si += 高水位`**：合法但浪费；更糟的是若你把递增后的 `si` 当成「上一 let 还活着的槽」，第二个 `let` 会避开 slot 0——测例仍可能绿。锁定同一外层 `ctx`，让槽复用。
- **mutator 改 VOID 却忘了改旧期望**：回归一片红。本层允许改 L15–L17 测例文件的期望/源；不要改那些层的**语法范围**（不要把 `begin` 写进 L15 文档）。
- **打印 `void` / `#void` / 空行**：测例按 `#<void>`。
- **`mov w0, #0x1F` 后当指针用**：VOID 不是指针；下一指令若 `str` 进 `x0` 当 pair 会炸。mutator 先改堆再写 VOID。
- **把 `begin` 展开成嵌套 `let` 绑哑变量**：浪费槽，且哑名可能与用户变量冲突。用 `seq`。

## 下一层预告

绑定还是不可变的：没有办法让同一个 `let` 变量在 body 里换成新值。下一层是 `set!`，以及为以后闭包准备的 box。
