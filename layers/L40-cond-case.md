# L40 — `cond` / `case` 展开

## 目标

在前端把派生形式 **`cond`** 与 **`case`** 展开成已有的核心形式：`if`、`begin`、`let`、`eqv?`。后端与运行时本层 **零改动**（若 `VOID` 尚未打印，只给 `rt_print` 加一条立即数分支，见下）。

本层锁定的语法：

- `cond`：普通子句 `(test e ...)`、单 `test` 子句、R4RS 的 `(test => proc)`、以及最后的 `(else e ...)`。
- `case`：对 **求值一次** 的 key 做 `eqv?` 匹配；子句 `((d1 d2 ...) e ...)` 与可选的 `(else e ...)`。

本层范围之外：把它做成可被用户扩展的宏系统（L47 才引入 `define-macro`，L48 才是 `syntax-rules`）；`case` 的 **符号** datum（需要堆上 intern 的 symbol 对象，L43/L46）；`cond`/`case` 当作运行时过程。完整数值塔、I/O、`eval` 仍不在本层。

## 原理

### 为何只动前端

L10 已有 `if`（只有 `#f` 为假），L22 已有 `begin`，L19–L20 已有 `let`，L09 已有 `eqv?`。`cond`/`case` 是语法糖：展开后的 IR 仍是 `(if …)`、`(seq …)`、`(let …)`、`(prim eqv? …)`。不新增 prim、不改调用约定、不改标签。

管道位置（ARCHITECTURE 的 expand 段）：

```
源 s-expression
  → expand          ; 本层：cond / case / 若缺则补 quote
  → expr->ir
  → emit
```

`expand` 必须在降 IR **之前** 递归走进每个子表达式（`if` 的三支、`let` 的右值与 body、`lambda` 的 body、`begin` 的每一句、过程调用的每一项）。只展开顶层一层会留下嵌套的 `cond`。

### `quote` 本层一并钉死

层列表里没有独立的 quote 层。`case` 子句里的 datum **不求值**，展开时要变成常量。本层起前端必须认识 `(quote d)`：

| `d` | 降法 |
|-----|------|
| fixnum / `#t` / `#f` / `()` / char | `(imm …)`，与字面量相同 |
| pair / vector / string | 按 L13+ 已有的常量图（`cons`/`prim` 或只读数据） |
| 符号 | 本层 **编译期错误**（还没有 `SYMBOL_TAG` 对象）。L43 intern 之后自动解禁，L46 加符号 `case` 回归 |

测例不覆盖符号分支，避免假绿。

### `cond` 展开（R4RS，含 `=>`）

约定：无子句或所有 test 为假且无 `else` 时，结果为 **unspecified**，编码 `VOID = 0x1F`。若 `rt_print` 还不认识它，本层加一行：打印 `#<void>`（与 L44 的未知值策略兼容，L44 再统一走 `write`）。

`else` 只允许作为 **最后** 一个子句；出现在中间或带 `=>` 都是编译期错误。`else` 不是被求值的标识符，而是语法关键字：展开时按 `eq?` 比较子句的 `car` 与符号 `else`。

多表达式子句包进 `begin`。单表达式不必硬包，但包了也对（`begin` 单句恒等，L22）。

用伪代码写死规则（对子句列表 `clauses` 从左到右）：

```
(cond)                          ⇒  VOID 的字面
(cond (else e1 e2 ...))         ⇒  (begin e1 e2 ...)
(cond (else))                   ⇒  编译期错误（else 至少一表达式；本教程锁定）
(cond (test => proc) . rest)    ⇒  (let ((t test))
                                     (if t (proc t) (cond . rest)))
(cond (test) . rest)            ⇒  (let ((t test))
                                     (if t t (cond . rest)))
(cond (test e1 e2 ...) . rest)  ⇒  (if test (begin e1 e2 ...) (cond . rest))
```

`t` 必须是 **expand 卫生化** 的新标识符（`tmp.cond.0` 这类），不得叫 `t` 等用户可能绑定的名字——否则会把用户的 `t` 影子吃掉。本层还没有宏卫生理论，但 **编译器自己生成的临时名** 必须不与源程序标识符冲突。实现：全局计数器或 `gensym`。

`=>` 子句形状必须恰好是 `(test => proc)` 三个元素：`=>` 是语法关键字，不是被求值的表达式。`(test =>)`、`(test => p extra)` 编译期错误。`proc` 仍要递归 `expand`。

单 `test` 子句与 `=>` 都必须用 `let` 绑一次：R4RS 要求 test **只求值一次**，且把该值交给 `proc` 或作为子句结果。不要展开成 `(if test test …)`，那会求值两次（副作用、`set!`、分配都会错）。

普通 `(test e ...)` 的 test **可以** 直接放进 `if`（只求值一次）。不要多余地 `let`，除非你想统一代码路径。

`=>` 的 `proc` 在运行时必须是单参过程；若不是，走 L24/L25 已有的调用错误（arity / 非闭包），本层不新增检查。

### `case` 展开

```
(case key
  ((d1 d2 ...) e1 e2 ...)
  ...
  (else e ...))
```

`key` 只求值一次，因此外层必须是 `let`：

```
(let ((k key))
  (cond
    ((or (eqv? k (quote d1)) (eqv? k (quote d2)) ...) (begin e1 e2 ...))
    ...
    (else (begin e ...))))
```

锁定细节：

1. `k` 同样是编译器临时名，不要叫 `key`/`t`。
2. 空 datum 列表 `(( ) e ...)`：该子句永远不匹配，合法；等价于跳过。R4RS 允许「各子句 datum 不必互异」，**先写的子句优先**。
3. 无 `else` 且全不匹配 → 与 `cond` 相同，得到 `VOID`。
4. datum 是 **外部表示对应的常量**，不是表达式：`(case x ((fx+ 1 2) 0))` 里的 `fx+` 不是调用，而是一个非法的 pair datum。本层：datum 必须是立即数（fixnum / bool / char / `()`）。pair/vector/string 作为 datum 可以按 `eqv?` 做（`eqv?` 对 pair 是指针相等，字面每次 `quote` 都是新对象，永远匹配不上）—— **本层禁止 pair/vector/string 当 case datum**（编译期错误），以免实现者以为在做 `equal?`。
5. `or` 零个操作数是 `#f`（L11）：空 datum 子句因此变成 `(or)` → `#f`。
6. 单个 datum 不必包 `or`：`((2) e)` → `(eqv? k (quote 2))`。
7. `(case key)` 无子句 → `VOID`。
8. `else` 规则与 `cond` 相同，必须最后。

`eqv?` 对立即数是位型相等（L09）。fixnum `2` 与 `2`、`#\a` 与 `#\a`、`#t` 与 `#t` 匹配；fixnum `0` 不匹配 `#f` 或 `()`。

### 展开后仍走旧 IR

```
(cond ((fx> x 0) => fxadd1) (else 0))
```

在 `x` 已绑定的环境里变成类似：

```
(let ((tmp.0 (fx> x 0)))
  (if tmp.0
      (fxadd1 tmp.0)
      0))
```

再降：

```
(let ((tmp.0 (prim fx> (ref x) (imm 0))))
  (if (ref tmp.0)
      (prim fxadd1 (ref tmp.0))
      (imm 0)))
```

`case` 同理，test 侧是一串 `(prim eqv? (ref k) (imm …))`。

**可移植**：换芯片时这一层文件不必改。

## 与上一层的差异

- L39 仍只有核心形式与 `dynamic-wind`；用户要写多路分支只能嵌 `if`。
- 本层增加 **纯展开**：`cond` / `case` /（若缺）`quote`。
- 第一次强制「编译器生成的临时绑定不得撞名」。
- 无新 IR 节点、无新标签、无新寄存器。
- `VOID` 成为用户可观察的结果（无匹配的 `cond`/`case`）。

## 代码骨架

### 可移植：`compiler/expand.scm`

```scheme
(define *tmp-n* 0)
(define (gentemp prefix)
  (set! *tmp-n* (+ *tmp-n* 1))
  (string->symbol
    (string-append prefix "." (number->string *tmp-n*))))

;; expand 产出核心形式 (%void)；expr->ir 把它认成 (imm #x1F)
(define (void-expr) '(%void))

(define (expand expr)
  (cond
    ((not (pair? expr)) expr)
    ((eq? (car expr) 'quote) expr) ; 常量不走进去
    ((eq? (car expr) 'cond) (expand (expand-cond (cdr expr))))
    ((eq? (car expr) 'case) (expand (expand-case (cdr expr))))
    ((eq? (car expr) 'lambda)
     (cons 'lambda (cons (cadr expr) (map expand (cddr expr)))))
    ((eq? (car expr) 'let)
     (list 'let
           (map (lambda (b) (list (car b) (expand (cadr b))))
                (cadr expr))
           (expand (caddr expr))))
    ((eq? (car expr) 'if)
     (list 'if (expand (cadr expr)) (expand (caddr expr))
           (expand (cadddr expr))))
    ((eq? (car expr) 'begin)
     (cons 'begin (map expand (cdr expr))))
    (else (map expand expr))))

(define (expand-cond clauses)
  (cond
    ((null? clauses) (void-expr))
    ((not (pair? (car clauses)))
     (error "L40: cond clause must be a list" (car clauses)))
    (else
     (let ((cl (car clauses)) (rest (cdr clauses)))
       (cond
         ((eq? (car cl) 'else)
          (if (not (null? rest))
              (error "L40: else not last")
              (if (null? (cdr cl))
                  (error "L40: empty else")
                  (cons 'begin (cdr cl)))))
         ((and (>= (length cl) 3) (eq? (cadr cl) '=>))
          (if (not (= (length cl) 3))
              (error "L40: bad => clause" cl)
              (let ((t (gentemp "c")))
                (list 'let (list (list t (car cl)))
                      (list 'if t
                            (list (caddr cl) t)
                            (cons 'cond rest))))))
         ((= (length cl) 1)
          (let ((t (gentemp "c")))
            (list 'let (list (list t (car cl)))
                  (list 'if t t (cons 'cond rest)))))
         (else
          (list 'if (car cl)
                (cons 'begin (cdr cl))
                (cons 'cond rest))))))))

(define (case-test k datums)
  (cond
    ((null? datums) #f)
    ((null? (cdr datums))
     (list 'eqv? k (list 'quote (car datums))))
    (else
     (cons 'or (map (lambda (d) (list 'eqv? k (list 'quote d))) datums)))))

(define (expand-case parts)
  (if (null? parts)
      (error "L40: case missing key")
      (let ((k (gentemp "k")))
        (list 'let (list (list k (car parts)))
              (cons 'cond (map (lambda (cl)
                                 (expand-case-clause k cl))
                               (cdr parts)))))))

(define (immediate-datum? d)
  (or (integer? d) (boolean? d) (char? d) (null? d)))

(define (expand-case-clause k cl)
  (cond
    ((eq? (car cl) 'else) cl)
    ((not (pair? (car cl)))
     (error "L40: case clause needs datum list" cl))
    (else
     (for-each (lambda (d)
                 (if (not (immediate-datum? d))
                     (error "L40: case datum must be immediate" d)))
               (car cl))
     (cons (case-test k (car cl)) (cdr cl)))))
```

`(%void)` 在 `expr->ir` 里映射为 `(imm #x1F)`。不要把某个编译器内部对象误当成 VOID。

`expand` 对 `cond` 的结果再 `expand` 一次，是为了让生成的 `let`/`if`/`or`/`begin` 继续被处理（`or` 走 L11 规则）。注意：不要对 `quote` 的内容递归，否则会把常量里的列表当代码展开。

### `expr->ir` 补丁

```scheme
((eq? expr '%void) `(imm ,VOID))
((and (pair? expr) (eq? (car expr) 'quote) (= (length expr) 2))
 (datum->ir (cadr expr)))
```

`datum->ir`：立即数走 `imm`；禁止符号（本层 `error`）；禁止 pair 当 `case` datum 已在 expand 拦过；`(quote (1 2))` 若你已有 list 常量通道则允许，本层测例不用。

### aarch64-apple

无新 `emit-*`。`VOID` 打印：

```
; 算法伪代码：实现必须是 runtime 汇编，不是 C。
if (x == VOID) { write("#<void>\n"); return; }
```

插在布尔 / 空表旁边。满字比较 `0x1F`。

## 测例清单

上一层全部测例仍须通过。

1. `(cond (#t 1) (else 2))` → `1`
2. `(cond (#f 1) (else 2))` → `2`
3. `(cond (#f 1) (#t 3) (else 4))` → `3`
4. `(cond (else 9))` → `9`
5. `(cond (#f 1) (#f 2))` → `#<void>`（无 else、全假）
6. `(cond)` → `#<void>`
7. 多表达式子句：`(cond (#t (fxadd1 1) (fxadd1 2)) (else 0))` → `3`（`begin` 取最后值）
8. 单 test 子句返回该值：`(cond (1) (else 0))` → `1`（`1` 为真）
9. 单 test 为假继续：`(cond (#f) (else 7))` → `7`
10. `=>`：`(cond ((fx+ 1 2) => fxadd1) (else 0))` → `4`
11. `=>` 为假走下一子句：`(cond (#f => fxadd1) (else 8))` → `8`
12. `=>` 的 test 只求值一次：

    ```scheme
    (let ((x 0))
      (cond ((begin (set! x (fxadd1 x)) x) => (lambda (v) (fx+ v x)))
            (else 0)))
    ```

    → `2`（若 test 求值两次，`x` 会变成 2，和 `v` 相加得更大）
13. 嵌套：`(cond (#t (cond (#f 1) (else 2))) (else 3))` → `2`
14. 只有 `#f` 为假：`(cond (0 1) (else 2))` → `1`；`(cond (() 3) (else 4))` → `3`
15. `(case 2 ((1) 10) ((2 3) 20) (else 30))` → `20`
16. `(case 9 ((1) 10) (else 30))` → `30`
17. `(case #\a ((#\b) 1) ((#\a) 2) (else 3))` → `2`
18. `(case #t ((#f) 1) ((#t) 2) (else 3))` → `2`
19. `(case '() ((#f) 1) ((()) 2) (else 3))` → `2`（空表不是 `#f`）
20. key 只求值一次：

    ```scheme
    (let ((x 0))
      (case (begin (set! x (fxadd1 x)) 2)
        ((1) x)
        ((2) x)
        (else 9)))
    ```

    → `1`
21. 无 else 不匹配：`(case 5 ((1 2) 0))` → `#<void>`
22. 先写的子句优先：`(case 1 ((1) 1) ((1) 2))` → `1`
23. 空 datum 列表：`(case 1 (() 2) (else 3))` → `3`
24. `(cond (#f 1) (else 2) (#t 3))`：编译期错误（`else` 不在最后）。
25. `(cond (1 => ))` 或 `(cond (1 => fxadd1 extra))`：编译期错误。
26. `(case 1 2)`（子句不是表）或 `(case 1 ((cons 1 2) 0))`：编译期错误（非法 datum）。
27. `(case 'foo ((foo) 1) (else 0))`：本层编译期错误（quote 符号）；不要改成「碰巧用编译器内部符号当立即数」。

## 验收标准

- 测例 1–23 由驱动自动绿；24–27 非零退出，stderr 含 `L40` 或 `cond`/`case`/`quote` 一类关键字，且是 **编译期** 失败（不要生成可执行文件再崩）。
- `expand` 之后的程序里不再出现作为语法的 `cond`/`case`（核心 `if`/`let`/`begin`/`or`/`eqv?`/`quote` 除外）。
- 生成代码不得为 `cond` 调用 runtime 辅助；`=>` 就是一次普通调用。
- 临时名与源程序标识符冲突的程序（用户绑定了 `t`/`k`）仍须得正确结果——用测例 12、20 的 `x` 不够，再手跑一次 `(let ((t 5)) (cond (#f => fxadd1) (else t)))` → `5`。
- 上一层 `dynamic-wind` / `call/cc` 测例仍绿：展开不得改变尾位置以外的求值次数（除 `cond`/`case` 自身文档规定的一次 key/test）。

## 常见坑

- **`(if test test else)` 展开单 test 子句**：`(cond ((begin (set! x (fxadd1 x)) #t)) …)` 会 `set!` 两次。
- **用户名字当临时名**：`(let ((t 1)) (cond (#t => (lambda (v) t))))` 若临时也叫 `t`，`=>` 的 `let` 会把 `1` 影子掉，过程看到的是 test 的 `#t`。
- **把 `else` 当普通标识符求值**：`(let ((else #f)) (cond (else 1)))` 在 R4RS 里 `else` 仍是关键字。本教程锁定同样：子句 `car` 是符号 `else` 就走 else 规则，不管环境里有没有绑定。不要展开成 `(if else 1 …)`。
- **`=>` 写成调用 `=>` 过程**：源程序里 `=>` 不是变量。
- **`case` 用 `eq?` 却拿 fixnum 当「未 intern」对象**：立即数上 `eq?` 与 `eqv?` 本实现相同；真正的坑是对 **heap 对象** 误用 `case` 当结构相等。本层直接禁止非立即数 datum。
- **对 `quote` 内部递归 expand**：`(quote (cond (#t 1)))` 必须仍是那份常量列表，不能变成 `1`。
- **忘记再 expand 一次**：生成的 `or`/`begin`/`let` 若原样丢给只认识核心形式的 `expr->ir` 会炸。要么 `expand` 生成已经是核心形式的树（`or` 当场再写成 `if`），要么对产出递归 `expand`。
- **空 `begin`**：`(cond (#t))` 是单 test 不是空 begin；`(cond (else))` 要编译期错，不要生成 L22 禁止的空 `begin`。

## 下一层预告

L41 要处理 **`quasiquote`**：把 `` ` ``、`,`、`,@` 展开成 `cons` / `list` / `append`，并正确处理嵌套反引号。
