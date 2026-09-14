# L21 — `let*`：前端展开成嵌套 `let`

## 目标

增加派生形式 `let*`。语义是 **从左到右、边绑定边可见**：

```scheme
(let* ((a A) (b B)) C)
  ≡  (let ((a A)) (let ((b B)) C))
```

**锁定：只在前端展开，后端零新节点。** 不要在 `emit-let` 里按「每求完一个 rhs 就 extend env 再求下一个」实现用户 `let*`——那会让并行 `let` 与 `let*` 挤在同一段循环里，下一层很难查错。`emit-let` 保持 L20 的并行算法；嵌套的多个 `(let ((id …)) …)` 节点自然得到顺序语义。

本层范围之外：`begin`、`set!`、命名 `let`（`(let name (bindings) body)`，那是递归，L28 以后）、多表达式 body。用户 `let` 仍然并行，行为与 L20 完全相同。

## 原理

### 展开规则（锁死）

在 `and`/`or` 之后、`expr->ir` 之前（或作为 `expr->ir` 的第一件事）展开。已展开的树里不应再出现 `let*`。

```
(let* () Body)                 =>  Body
(let* ((id Expr)) Body)        =>  (let ((id Expr)) Body)
(let* ((id1 E1) (id2 E2) . rest) Body)
  =>  (let ((id1 E1)) (let* ((id2 E2) . rest) Body))
```

第三式递归到第一、二式。等价的非递归写法：从右往左包一层层单绑定 `let`。

展开后的 `let` 全部是 L19/L20 已有的单绑定（或多绑定但每层一项）。后端只看见 `let`/`ref`/`prim`/`if`/…。

### 为何必须先展开再做绑定检查

```scheme
(let* ((x 1) (y x)) y)
```

若未展开就按并行 `let` 检查，`y` 的 rhs 里的 `x` 会被判 unbound。展开后：

```scheme
(let ((x 1)) (let ((y x)) y))
```

内层 rhs 的 `x` 合法。赋值分析（L23）也必须在 `let*` 消失之后做，否则会把「对刚绑名字的 `set!`」算到错误的绑定上。

`and`/`or` 的展开（L11）同样应在本层之前或同一 `expand` 里、且在 `let*` 之外层或内层都再递归：

```scheme
(define (expand expr)
  (cond
    ((and (pair? expr) (eq? (car expr) 'let*))
     (expand (let*-desugar expr)))
    ((and (pair? expr) (eq? (car expr) 'let))
     (let ((binds (cadr expr))
           (body (caddr expr)))
       `(let ,(map (lambda (b) (list (car b) (expand (cadr b)))) binds)
          ,(expand body))))
    ((and (pair? expr) (memq (car expr) '(and or)))
     (expand (and-or-desugar expr)))   ; L11
    ((pair? expr)
     (cons (expand (car expr)) (expand (cdr expr))))
    (else expr)))
```

对 `let` 要递归展开 rhs 与 body：内层可以再写 `let*`。不要 `cons` 整棵 list 时把绑定表的 `(` 结构破坏到连 `id` 也被 `expand` 当表达式——`id` 是符号，走 `else`。绑定对 `(id E)` 只 expand `E`。

### 同名重复：`let*` 合法，并行 `let` 不合法

```scheme
(let* ((x 1) (x (fxadd1 x))) x)    ; → 2，展开为两层 let，内层遮蔽
(let  ((x 1) (x 2)) x)             ; 仍是 L20 的 duplicate 错误
```

不要在 `let*` 上套用「同一绑定表禁止重复名字」。展开后根本没有同一张表里的两个 `x`。

### 空与单项

`(let* () 42)` → `42`，IR 不必包 `let`。

`(let* ((x 1)) x)` 与 `(let ((x 1)) x)` 同一 IR 形状。

### 与并行对照（教学用，写进测例）

| 表达式 | 本层结果 |
|--------|----------|
| `(let* ((x 1) (y x)) y)` | `1` |
| `(let  ((x 1) (y x)) y)` | 无外层 `x`：编译期 `unbound` |
| `(let ((x 1)) (let* ((x 2) (y x)) y))` | `2` |
| `(let ((x 1)) (let  ((x 2) (y x)) y))` | `1` |

### 后端

`emit-let`、`emit-ref`、栈槽公式、对齐：**一字不改**。若你发现必须改后端才能让 `let*` 过，说明展开错了，或 L19 嵌套坏了。

## 与上一层的差异

| 项 | L20 | L21 |
|----|-----|-----|
| 用户 `let*` | 无 | 有，展开为嵌套 `let` |
| 后端 IR | `(let (多绑定并行) …)` | 不变；`let*` 不出现在 IR |
| 同名多绑定 | `let` 拒绝 | `let*` 允许（变成遮蔽） |
| `(let* ((x 1) (y x)) y)` | — | `1` |

## 代码骨架

### 可移植：`let*-desugar`

```scheme
(define (let*-desugar expr)
  ;; expr = (let* bindings body) ，body 单表达式
  (if (not (and (= (length expr) 3) (list? (cadr expr))))
      (error "L21: bad let*" expr)
      (let ((bindings (cadr expr))
            (body (caddr expr)))
        (let loop ((bs bindings))
          (cond
            ((null? bs) body)
            ((and (pair? (car bs))
                  (symbol? (caar bs))
                  (pair? (cdar bs))
                  (null? (cddar bs)))
             `(let (,(car bs)) ,(loop (cdr bs))))
            (else (error "L21: bad let* binding" (car bs)))))))
```

`expand` 在 `compile-program` 里于 `expr->ir` 之前调用。测例与错误信息：展开后的非法 `let` 仍走 L20 的报错；非法 `let*` 绑定在 desugar 时就能 `error`。

### 不要写的后端

```scheme
;; 错误：不要把用户 let* 做成「循环里 env 累积后再 emit 下一个 rhs」
;; 除非那条路径只处理内部 IR 且从不服务用户 let。本层锁定不存在这条路径。
```

若 IR 打印/调试：对 `(let* ((a 1) (b 2)) (fx+ a b))` 应看到两个单绑定 `let`，而不是一个两绑定 `let`。

## 测例清单

上一层全部测例仍须通过。

1. `(let* ((x 1) (y x)) y)` → `1`
2. `(let* ((x 1) (y (fxadd1 x)) (z (fx+ x y))) z)` → `3`
3. `(let* ((x 1) (x (fxadd1 x))) x)` → `2`（同名顺序遮蔽）
4. `(let ((x 1) (y x)) y)`：仍编译期 `unbound`（并行未改）
5. `(let* ((x 1)) x)` → `1`
6. `(let* () 42)` → `42`
7. `(let* ((x 1) (y 2)) (fx+ x y))` → `3`
8. `(let ((x 10)) (let* ((x 1) (y x)) (fx+ x y)))` → `2`
9. `(let ((x 1)) (let* ((x 2) (y x)) y))` → `2`（对照并行测例的 `1`）
10. `(let* ((p (cons 1 2)) (q (car p))) q)` → `1`
11. `(let* ((x 1) (y (let* ((x (fxadd1 x))) x))) (fx+ x y))` → `3`
12. `(let* ((x y)) x)`：编译期 `unbound`
13. `(let* ((x 1) (y 2) (z 3)) (fx+ (fx+ x y) z))` → `6`
14. `(let* (x 1) x)`：编译期错误（绑定形状）
15. 展开等价手写嵌套：`(let* ((a 1) (b 2)) (fx+ a b))` 与 `(let ((a 1)) (let ((b 2)) (fx+ a b)))` 输出同为 `3`
16. L20 交换回归：`(let ((a 1) (b 2)) (let ((a b) (b a)) (cons a b)))` 仍为 `(2 . 1)`，**不要**变成 `(2 . 2)`

## 验收标准

- 测例 1–3、5–11、13、15 打印正确。
- 测例 4、16 证明没有把用户 `let` 改成顺序绑定。
- 测例 12、14 编译期失败。
- 后端 `emit-*` 集合与 L20 相同；IR 谓词不需要 `let*?`。
- 对测例 1 生成的汇编应与手写嵌套单绑定 `let` 同类（两个 `str`、内层 rhs 的 `ldr` 来自外层槽）。

## 常见坑

- **只展开一层**：`(let* ((a A) (b B) (c C)) D)` 若变成 `(let ((a A)) (let* ((b B) (c C)) D))` 后不再递归 `expand`，后端会看见 `let*` 当未知形式。`expand` 必须对 desugar 结果再 `expand`。
- **把绑定表当表达式 `map expand`**：`(x 1)` 的 `x` 没事（符号），但若有人写成 `(expand 整个 bindings)` 可能把 `let` 绑成奇怪列表。按绑定对处理。
- **在后端用累积 env 实现 `let*` 且用户 `let` 走同一循环**：测例 4、16 会红。两条路径必须分开——而本层要求 `let*` 根本没有后端路径。
- **`(let* () E)` 做成未定义的空 `seq`**：直接变成 `E`。
- **多 body**：`(let* ((x 1)) x x)` 与 `let` 一样拒绝，直到显式 `begin`。

## 下一层预告

还不能写「先做完副作用，再给出另一个值」：你只能把中间结果绑进不用的 `let` 变量。下一层用 `begin` 做顺序求值，并让 mutator 返回 VOID。
