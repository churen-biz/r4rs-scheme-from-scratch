# L50 — 递归宏与更丰富模式

## 目标

在 L48/L49 的 `syntax-rules` 上只加两块能力：

1. **递归宏**：模板里可以再次出现正在定义的关键字，`expand` 循环直到核心形式。用它写出 R4RS 的 `and`/`or` 以及多子句 `cond`。
2. **嵌套省略号**：模式/模板形状 `(a (b ...) ...)`，即「外层重复的每一项里还有一层重复」。

卫生规则、顶层 `define-syntax`、一层 `...` 的旧测例全部保持。L47 路径不动。

本层范围之外：`syntax-case`、`identifier-syntax`、R6RS/R7RS **相位移**（`begin-for-syntax`、transformer 在另一期运行）、fender、vector 模式、`let-syntax`。不要在本层做模块系统。

## 原理

### 递归从哪来

`syntax-rules` 本身没有「函数调用」，递归是 **expand 的不动点**：

```
(or e1 e2 e3)
 → (let ((t e1)) (if t t (or e2 e3)))     ; 模板里的 or 仍是宏
 → (let ((t e1)) (if t t
     (let ((t e2)) (if t t (or e3)))))
 → …
```

要求：

- 登记 `define-syntax` 发生在任何调用之前（顶层顺序：先定义再使用）。互递归两个宏：本层允许 **同一 `begin` 里连续两条 `define-syntax`，然后才展开后面的表达式**。不要边解析边展开而丢掉尚未登记的名字。
- 每次宏应用仍 `fresh-mark()`。递归每一层引入的 `t` 必须是**不同** binding，否则 `(or e1 e2)` 内层 `let ((t e2))` 会和外层 `t` 撞车——卫生在递归下比 L49 更硬。
- 必须有终止规则：`(or)` → `#f`，`(or e)` → `e`。缺终止会直到 expand 深度上限报错。
- 油限：锁定 **expand 宏应用次数 > 4096 则 error**，避免 `(define-syntax loop (syntax-rules () ((loop) (loop))))` 卡死编译器。

`and`/`or` 在 L11 已是手写展开器。本层用 syntax-rules **覆盖**它们，语义必须与 L11 合同一致：`and` 零参数 → `#t`；`or` 零参数 → `#f`；最后一个操作数在**尾位置**（展开时不要包进非尾 `let` 的 body 之外——`or` 的最后一个 `e` 出现在内层 `if` 的 else 枝，那是尾；中间项经 `let` 不是尾，这是 R4RS 允许的）。

推荐定义（与 R5RS 相同结构）：

```scheme
(define-syntax or
  (syntax-rules ()
    ((or) #f)
    ((or e) e)
    ((or e1 e2 ...)
     (let ((t e1)) (if t t (or e2 ...))))))

(define-syntax and
  (syntax-rules ()
    ((and) #t)
    ((and e) e)
    ((and e1 e2 ...)
     (if e1 (and e2 ...) #f))))

(define-syntax cond
  (syntax-rules (else)
    ((cond (else e0 e1 ...)) (begin e0 e1 ...))
    ((cond (test) (clause ...)) (or test (cond clause ...)))
    ((cond (test e0 e1 ...) (clause ...))
     (if test (begin e0 e1 ...) (cond clause ...)))))
```

`cond` 的 `=>` 接收器本层 **范围之外**（R4RS 有 `=>`；不做。写成规则会误匹配，明确不要加）。`case` 可留 L40 手写，或本层用嵌套 `...` 写；若写，必须用字面量 `else`，测例见下。

### 嵌套省略号

一层：`(f a ...)` 把 `a` 绑成列表。  
两层：`(f (a ...) ...)` 把 `a` 绑成**列表的列表**。

```
输入  (m (1 2) (3) () (4 5 6))
模式  (m (a ...) ...)
绑定  a ↦ ((1 2) (3) () (4 5 6))
模板  (list (list a ...) ...)
结果  ((1 2) (3) () (4 5 6))
```

匹配：外层 `...` 把输入的每个元素拿去对 `(a ...)` 做「一层省略匹配」，得到内层列表，再 `cons` 到外层。

代入：模板里省略号层数必须与该模式变量的「省略深度」一致。`a` 深度 2，则必须出现在两个 `...` 之下。深度不够 → expand 期错误（「ellipsis mismatch」）。深度更深（三个 `...`）本层可 error，不必支持三层；测例只用两层。

对齐：同一模板片段里两个深度 1 的变量 `(list x y ...)` 要求 `x` 与 `y` 重复长度相同；不同则 error。深度 2 同样：外层长度相同，对应内层各自展开。本层测例避免「不等长 zip」，但匹配器要检测并报错，不能静默截短。

实现数据结构：模式变量的值不是「语法对象或 list」二选一，而是带深度的树：

```
pv-val ::= stx | (list pv-val ...)
```

深度 0：`stx`；深度 1：`stx` 的 list；深度 2：list 的 list。`match` 在进入一层 `...` 时对应该变量 `cons` 一层 list。

### 递归 + 省略号在同一规则

`(or e1 e2 ...)` 的模板 `(or e2 ...)`：`e2` 深度 1，模板一层 `...`，合法。展开后再匹配 `or` 的更短输入。不要在匹配器里「特判递归」，它只是普通宏应用。

### 卫生在递归下的一个坑

```scheme
(let ((t 0) (if #f))
  (or #f t))
```

每层 `or` 引入自己的 `t` 与 `if`。最终必须得到用户的 `t` 即 `0`。若递归展开忘记 `fresh-mark`，内层 `let ((t e2))` 会与外层或用户 `t` `bound-identifier=?`。

### 顶层收集再展开

为了互递归与「先定义后用」：

```
顶层形式流
  → 把连续的 define / define-syntax / begin 里的定义先登记
  → 再 expand 表达式与 define 的右值
```

本层最小做法：**两遍**——第一遍只登记所有顶层 `define-syntax`（右值必须是 `syntax-rules`，不求值），第二遍从左到右 expand 其余。`define` 的过程体在第二遍展开，才能看到后面才出现的宏——R4RS 顶层是顺序的，后出现的宏不应作用于前面的 `define` 体。锁定 **顺序语义**：

- 第一遍：扫描并登记 `define-syntax`（整个顶层文件）。
- 第二遍：从左到右 expand。因此文件**后面**的 `define-syntax` 仍会影响**前面**表达式——这与严格 R4RS「遇到才定义」不完全一样。

更严的做法：单遍，只有已经经过的 `define-syntax` 可见。测例全部把宏写在使用之前，两种都绿。**锁定单遍顺序可见性**（更简单、与「遇到 define-syntax 立刻登记」一致）。互递归：把两个 `define-syntax` 写在任何使用之前即可。不要做第一遍全文件扫描，以免与 `load`（L45）的顺序语义打架。

## 与上一层的差异

- 匹配器认识「`...` 套 `...`」；模式变量值变成嵌套列表。
- `expand` 必须在宏输出上循环；油限 4096。
- prelude 可用 syntax-rules 覆盖 `and`/`or`/`cond`；L11/L40 手写器可删可留，但用户可见语义以本层规则为准。
- 仍无新 IR、无新标签、无 runtime 变化。

## 代码骨架

### 嵌套 `...` 匹配

```scheme
(define (match-form pat in lits uenv denv env)
  (cond
    ((and (pair? pat) (pair? (cdr pat)) (ellipsis? (cadr pat)))
     (match-ellipsis (car pat) (cddr pat) in lits uenv denv env))
    ((and (pair? pat) (pair? in))
     (let ((env1 (match-form (car pat) (car in) lits uenv denv env)))
       (and env1 (match-form (cdr pat) (cdr in) lits uenv denv env1))))
    ;; identifier / literal / constant / () 同 L48
    (else …)))

(define (match-ellipsis p-elt p-rest in lits uenv denv env)
  ;; 贪心：最长前缀能让 p-rest 仍匹配。本层 p-rest 多为 ()，可先实现
  ;; 「p-rest 为空则 in 全部对 p-elt 重复」。
  (if (null? p-rest)
      (let loop ((xs in) (acc '()))
        (if (null? xs)
            (merge-ellipsis-env env (reverse acc))
            (let ((e1 (match-form p-elt (car xs) lits uenv denv '())))
              (and e1 (loop (cdr xs) (cons e1 acc))))))
      (error "L50: ellipsis not at end of pattern not required; implement or error")))

(define (merge-ellipsis-env env rows)
  ;; rows : list of alists from each repetition
  ;; 每个模式变量 v → (map (lookup v) rows) 接到 env
  …
  )
```

`p-elt` 自身可再含 `...`：`( (a ...) ...)` 里 `p-elt = (a ...)`，递归进入 `match-form` 即可得到深度 2。

### 代入深度

```scheme
(define (subst tmpl env mark def-env depth-ctx)
  ;; depth-ctx 进入一个 ... 则 +1
  (cond
    ((ellipsis-pair? tmpl)
     (subst-ellipsis (car tmpl) (cddr tmpl) env mark def-env depth-ctx))
    ((pv? tmpl env)
     (pv-ref tmpl env depth-ctx))
    ((identifier? tmpl)
     (intro-id tmpl mark def-env))
    ((pair? tmpl)
     (cons (subst (car tmpl) env mark def-env depth-ctx)
           (subst (cdr tmpl) env mark def-env depth-ctx)))
    (else tmpl)))

(define (pv-ref name env depth-ctx)
  (let ((v (lookup-pv name env)))
    (if (= (pv-depth v) depth-ctx)
        (pv-current v)          ; 当前重复层的元素
        (error "L50: ellipsis depth mismatch" name))))
```

`subst-ellipsis`：看模板片段里出现的 pv，取它们在当前层的列表长度 `n`（必须一致），对 `i=0..n-1` 把 env 投影到第 `i` 个元素再 `subst`。

### 油限

```scheme
(define *expand-fuel* 4096)

(define (expand expr env)
  (set! *expand-fuel* (- *expand-fuel* 1))
  (if (< *expand-fuel* 0)
      (error "L50: expand fuel exhausted")
      (expand-body expr env)))
```

每个**编译单元**（一个测例文件）开始时把 fuel 重置为 4096。不要用全局一次 4096 管整个测试套件。

## 测例清单

上一层全部测例仍须通过。

1. **or 零个** `(or)` → `#f`

2. **or 一个** `(or 3)` → `3`

3. **or 多值短路** `(or #f #f 8)` → `8`

4. **or 不求后面** `(or 1 (car '()))` → `1`

5. **and 零个** `(and)` → `#t`

6. **and 短路** `(and #t #f (car '()))` → `#f`

7. **and 全真** `(and 1 2 3)` → `3`

8. **递归卫生：用户 t 与 if**  
   ```scheme
   (let ((t 9) (if #f))
     (or #f #f t))
   ```  
   → `9`

9. **每层引入独立 t**  
   ```scheme
   (or (begin (set! a 1) #f)
       (begin (set! a 2) #f)
       a)
   ```  
   先 `(define a 0)`。→ `2`  
   证明内层 `let ((t …))` 没有把外层临时槽 `set!` 乱掉。`a` 是用户变量。

10. **cond 多子句 + else**  
    ```scheme
    (cond (#f 1) (#f 2) (else 3))
    ```  
    → `3`

11. **cond 局部 else 仍不是关键字**（L49 回归加强）  
    `(let ((else #f)) (cond (else 1)))` → `#<void>`  
    多子句版：`(let ((else #f)) (cond (#f 1) (else 2)))` → `#<void>`（第二子句是测试 `#f`）

12. **嵌套省略：恒等**  
    ```scheme
    (define-syntax nest
      (syntax-rules ()
        ((nest (a ...) ...)
         (list (list a ...) ...))))
    (nest (1 2) (3) () (4 5))
    ```  
    → `((1 2) (3) () (4 5))`

13. **嵌套省略：扁平一层**  
    ```scheme
    (define-syntax flat1
      (syntax-rules ()
        ((flat1 (a ...) ...)
         (list a ... ...))))
    ```  
    `a ... ...` 是两层省略写在同一列表里，R5RS 允许并表示拼接。若你的代入器支持，`(flat1 (1 2) (3))` → `(1 2 3)`。若实现选择 **不支持「同一列表连续两个 `...`」**，本测例改为编译期错误，并在实现注释写死；另提供测例 13b 用 `append`：  
    ```scheme
    (define-syntax flat1b
      (syntax-rules ()
        ((flat1b (a ...) ...)
         (append (list a ...) ...))))
    (flat1b (1 2) (3) (4))
    ```  
    → `(1 2 3 4)`  
    **锁定 13b 为必过**；13a 可选。驱动以 13b 为 `013-nested-append.scm`。

14. **深度不匹配**  
    ```scheme
    (define-syntax bad-depth
      (syntax-rules ()
        ((bad-depth (a ...) ...) (list a ...))))
    (bad-depth (1) (2 3))
    ```  
    → **expand 期错误**。`014-err-ellipsis-depth.scm`

15. **不等长 zip 报错**  
    ```scheme
    (define-syntax zip2
      (syntax-rules ()
        ((zip2 (a ...) (b ...)) (list (list a b) ...))))
    (zip2 (1 2) (3))
    ```  
    → **expand 期错误**。`015-err-ellipsis-length.scm`

16. **油限**  
    ```scheme
    (define-syntax forever
      (syntax-rules ()
        ((forever) (forever))))
    (forever)
    ```  
    → **expand 期错误**（fuel）。`016-err-expand-fuel.scm`

17. **互递归两个宏（使用前都已 define-syntax）**  
    ```scheme
    (define-syntax evenish
      (syntax-rules ()
        ((evenish) #t)
        ((evenish x y ...) (oddish y ...))))
    (define-syntax oddish
      (syntax-rules ()
        ((oddish) #f)
        ((oddish x y ...) (evenish y ...))))
    (evenish 1 2 3)
    ```  
    → `#f`（三个元素，偶名字宏遇到奇数个则落到 oddish 空规则……数一下：evenish 吃掉 1 把 rest 给 oddish；oddish 吃掉 2 给 evenish；evenish 吃掉 3 给 oddish；oddish 空 → `#f`。）  
    `(evenish 1 2)` → `#t`

18. **覆盖 L11：旧 and/or 测例语义不变**  
    回归已要求 L11 测例仍绿。本号再写 `(and (or #f 1) 2)` → `2`

19. **vector 模式仍拒绝**（范围之外回归）  
    同 L48 测例 16。

20. **=> 不做**  
    `(cond (#t => fxadd1))` → **expand 期错误**或按「test 为 `#t`、`=>` 当调用」乱展开。锁定：**expand 期错误**（无此规则）。`020-err-cond-arrow.scm`

## 验收标准

- 测例 1–13b、17、18 退出码 0。
- 测例 11 的 void 打印与 L49 一致。
- 测例 14–16、19、20 非 0。
- `(or e1 e2 e3)` 展开过程中至少两次进入 `or` 的 transformer（可用调试计数；验收不强制插桩，但测例 8–9 失败通常就是没递归或没 fresh-mark）。
- 未实现 `syntax-case`、相位移、`let-syntax`。
- L47 测例仍体现未卫生。

## 常见坑

- **递归宏用「展开一次就 `syntax->datum`」**：内层 `(or e2 ...)` 变成裸调用，再当过程 `or` 找 runtime 绑定——你没有函数 `or`。必须再 expand。
- **同一 mark 用于递归每一层**：测例 8、9 红。
- **嵌套 `...` 把内层列表 `append` 成一层再存**：深度丢失，测例 12 与 14 行为对调。
- **贪心省略号 + 后面还有模式**：`(a ... b)` 本层可不做；若半实现，测例外的用户代码会静默错匹配。未实现的模式形状 → 定义宏时或匹配失败时 error，不要当成功。
- **`cond` 的 `else` 写成模式变量**：L49 测例 4 回潮。
- **fuel 不按文件重置**：测试套件后半全部假红。
- **用 `and`/`or` 原语短路指令**：合同仍是展开成 `if`，后端不新增指令。

## 下一层预告

L51 第一次回收堆：bump 撞 `HL` 时停世界做标记-压缩，而不是无限涨 HP。
