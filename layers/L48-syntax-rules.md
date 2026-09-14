# L48 — `syntax-rules` 基础

## 目标

在 expand 阶段接入 **R5RS 风格**的 `(define-syntax name (syntax-rules (lits) (pat tmpl) ...))`。本层能：按**列表结构**匹配模式、把 `lits` 里的标识符当字面量（典型：`else`、`unquote`、`...` 本身以外你列出的名字）、把模式变量绑到输入子树、把模板里的模式变量换成绑定，并处理**一层**省略号 `...`。

卫生：本层就必须给**模板引入的标识符**打标（Kohlbecker 颜色 / Dybvig marks，二选一写死）。禁止「整棵树 `eq?` 符号替换」那种完全未卫生实现——哪怕更狠的测例要到 L49。L47 的 `define-macro` **整条路径保留**，不要拆掉；两套宏表并存，`define-syntax` 优先。

本层范围之外：fender（`syntax-rules` 守卫表达式）、vector 模式、`syntax-case`、标识符宏、**递归宏**（同一关键字在模板里再展开自己，见 L50）、嵌套省略号 `(a (b ...) ...)`（L50）。本层只允许**顶层** `define-syntax`（局部 `let-syntax` / 内部 `define-syntax` 明确不做，L49 再锁一次）。

## 原理

### 它在管道里的位置

```
源文本 → reader → expand → ir-lower → emit
                     ↑
              本层改这里
```

`define-syntax` **不是**运行时原语，也不是 IR 节点。遇到它时 expander 把 `name` 登记到**语法环境**，该顶层形式本身展开成空/`void`（不生成代码）。之后 `(name …)` 在 expand 里被模式匹配替换成核心形式（`if`/`begin`/`let`/`set!`/`lambda`/`quote`/调用……），再交给已有的 `expr->ir`。

L40 的 `cond`/`case`、L11 的 `and`/`or` 可以仍是手写展开器。本层不强制删它们；用户新写的 `define-syntax` 走匹配器。L47 表：`(define-macro (name . formals) body)` 在宿主上得到 `proc`，展开时 `(apply proc (cdr use-form))`，**不打标**。查找顺序锁定（与 L47 一致，并插入 syntax-rules）：

1. 不可覆盖的核心形式：`if` `lambda` `quote` `set!` `begin` `define` `define-syntax` `define-macro`（与 L47：不可被宏改写 `if`）
2. 语法环境里有 `define-syntax` → `syntax-rules`
3. 否则 L47 宏表有 `define-macro` → 未卫生展开
4. 否则 L11/L40 派生展开器（`and`/`or`/`cond`/`case`）
5. 否则当调用

L50/L54 若用 `define-syntax` 覆盖 `and`/`or`/`cond`/`let`，走第 2 步，不再走第 4 步。不可覆盖列表**不含**这些派生名。

### 语法形状

```
(define-syntax <name>
  (syntax-rules (<literal> ...)
    (<pattern> <template>)
    ...))
```

- `<name>` 与每个 `<pattern>` 的**头标识符**通常相同；匹配时**不把头当模式变量**（R5RS：模式的 car 被忽略，只用于「这是哪个宏」的文档）。实现：匹配从 pattern 的 `cdr` 对输入的 `cdr` 开始，或先确认输入 car 与宏名 `free-identifier=?` 再比尾巴。
- `<literal>` 是标识符列表，可空。`_` 永远是通配，不绑定，也不必写入 lits。
- 同一 `syntax-rules` 里多条 `(pat tmpl)` **从上到下**，先完全匹配者胜；无一匹配则 **expand 期报错**（不要生成代码去 runtime 炸）。
- 模板里出现的、既不是模式变量也不是 `...` 的标识符，叫**引入标识符**。

### 一层省略号

本层 `...` 只修饰**紧挨着的前一个**模式子项或模板子项，且不嵌套：

```
模式 (when test body ...)     ; test 一个，body 零个或多个
模板 (if test (begin body ...) #f)
```

绑定：`body` 的值是**语法对象列表**（可能空）。模板里 `body ...` 把该列表展开成并列子形式。禁止：`(a (b ...) ...)`、`((a ...) (b ...))` 里两个省略号对齐以外的「嵌套重复」（后者若两列等长，有人会做；本层**不要**做，留给 L50）。

`...` 本身若出现在 lits 里，则输入中的标识符 `...` 按字面量比，不再当省略符。本层测例不依赖这个角落，但匹配器要认得：不在省略位置的 `...` 当普通标识符会失败得难看——发现 pattern 里 `...` 不在「前一项的后缀」就编译期错。

### 匹配（芯片无关）

输入与模式都是**语法对象**（见下），不是裸 symbol 树。对一份 `(pattern input env-of-literals)`：

| 模式 | 输入 | 动作 |
|------|------|------|
| `_` | 任意 | 成功，不绑定 |
| 标识符 ∈ lits | 标识符且 `free-identifier=?` 于该 literal | 成功 |
| 其它标识符 | 任意子树 | 绑定该模式变量 → 该子树；同一变量在一条模式里出现两次则两处 `bound-identifier=?`（本层可禁「重复模式变量」，遇重复直接 error，更简单） |
| `(p1 … pn)` | 真列表且长度相同 | 逐项匹配 |
| `(p1 … pk rest ...)` 其中 `...` 修饰 `rest` | 列表长度 ≥ k，前 k 项对 `p1…pk`，其余每项对 `rest` | `rest` 绑定为列表 |
| 非对、非标识：常量 | `equal?` 的 datum（数字、`#t`/`#f`、`()`、字符、字符串） | 成功 |
| 其它 | | 失败，试下一条规则 |

**不要**在本层匹配点对 `#(…)`、不当列表的原子当列表打开。

`free-identifier=?`（本层可用简化版）：两个标识符名字相同，且「解析到同一绑定」——对尚未被 `let`/`lambda` 绑的顶层名，即两边都未绑定。实现见「标记」。字面量 `else` 因此**不会**变成模式变量；只有真正的 `else` 关键字对得上（顶层未绑定的 `else`）。用户写 `(foo bar)` 不会因为模式是 `(cond (else e))` 而把 `bar` 当成 `else`。

### 标记：本层最小卫生（必须做）

完全未卫生的替换会把模板里的 `if`、`let`、`t` 与用户的同名变量撞车。本层锁定 **Dybvig 式 marks 的子集**：每个标识符是 `(name, mark*)`，不是裸 symbol。

```
syntax-id  ::= #(stx-id <symbol> <marks>)
marks      ::= 整数的列表（外层在 car）
syntax     ::= syntax-id | 常量 | (syntax . syntax)
```

- 读入/未宏展开的程序：所有标识符 `marks = ()`。
- **一次宏应用**生成新鲜 `m = fresh-mark()`。
- 模板里**引入**的标识符：`marks` 为 `(m)` 接到宏定义处的 marks 上（定义在顶层则为 `(m)`）。
- 模板里**模式变量**换入的子树：原样保留 use-site 的 marks，**不要**再打 `m`（否则用户传入的 `x` 会变成另一个标识符，`set!` 对不上）。
- 比较：
  - `bound-identifier=?`：名字相同 **且** marks 集合相同（用于 `lambda`/`let` 绑定时「这个 x 是不是那个 x」）。
  - `free-identifier=?`：把标识符拿到各自该出现的语法环境里 lookup；同一 binding 对象则真；都 miss 则退回「名字相同」（顶层）。

Kohlbecker 颜色是合法替代：引入名改成 `if#42` 这种不会与用户 `if` 碰撞的 symbol，并在核心环境登记 `if#42` → 核心 `if`。效果与 marks 相同。**须在实现注释写死你选 marks 还是颜色**；测例不依赖内部表示。

展开 `let`/`lambda` 时，绑定的名字用 `bound-identifier=?` 去对 body 里的引用。核心 `if` 在初始语法环境里是一个 binding 对象；宏引入的 `if`（带定义侧 marks）lookup 到它；用户 `(let ((if #f)) …)` 里的 `if` 是另一 binding。这就是「引入的 `if` 不被用户遮蔽」的机制。

L47 路径：输入当裸 s-expression，输出也是裸树，随后再 `datum->syntax` 成 **空 marks** 的语法对象（或直接当 datum 塞回 expand）。不要给 `define-macro` 的引入名打宏标，以保持 L47 测例语义。

### 代入模板

```
subst(tmpl, env, mark):
  tmpl 是模式变量 → lookup env（若该变量是「… 绑定」则必须出现在 tmpl ... 上下文，否则 error）
  tmpl 是 (t ...) 且 t 含省略绑定 → 按列表长度 map subst 再 append
  tmpl 是标识符且非模式变量 → 引入：add-mark(tmpl, mark)，lookup 定义环境
  tmpl 是 pair → cons 两边
  tmpl 是常量 → 原样
```

省略号与非省略混用：`(list x y ... z)` 要求 `y` 是重复绑定，`x`/`z` 是单值。长度由 `y` 的列表决定。

### 与核心形式的交接

expand 在「不再是宏应用」之后看到的 `if`/`let`/… 必须是**解析过的核心绑定**，不能再拿用户当前环境的 `if` 去比。做法：初始 `core-env` 把 `if`、`lambda`、`quote`、`set!`、`begin`、`let` 等绑到 expander 内部标签（如 `'core-if`）。引入的 `if` 经 def-env 解析到 `'core-if`。`expr->ir` 只认这些核心标签或你已经 `syntax->datum` 并保证不会被遮蔽的内部名。

不要把展开结果里的引入名 `syntax->datum` 成裸 `if` 再走一遍「按 symbol 分派的 expr->ir」——那会在 `(let ((if #f)) (when #t 1))` 上把 `when` 展开出的 `if` 重新解析成局部变量。**要么** IR 降层吃核心标签，**要么**在 expand 彻底变成无标识符歧义的内部 AST。骨架采用核心标签。

### 本层够用的宏（非递归）

```scheme
(define-syntax when
  (syntax-rules ()
    ((when test body ...)
     (if test (begin body ...) #f))))

(define-syntax unless
  (syntax-rules ()
    ((unless test body ...)
     (if test #f (begin body ...)))))

(define-syntax my-or2
  (syntax-rules ()
    ((my-or2 a b)
     (let ((t a)) (if t t b)))))
```

`when`/`unless` 测一层 `...`。`my-or2` **不是**递归宏，用来逼出引入的 `let`/`if`/`t` 的标记。完整 `or`/`and`/`cond` 的自调用留 L50。

## 与上一层的差异

- L47：`define-macro` + 运行期/展开期过程，捕获用户绑定。本层增加第二张表与匹配器。
- 标识符从「就是 symbol」变成**带 marks 的语法对象**（至少在 expand 内部；IR 的 `<id>` 仍是卫生化后的不透明字符串，与 ARCHITECTURE 一致）。
- 第一次在教程里区分 `free-identifier=?` / `bound-identifier=?`。
- 不新增 IR 节点、不改标签、不改 `emit-*`、不改 runtime。

## 代码骨架

### 语法对象与标记

```scheme
(define *mark-n* 0)
(define (fresh-mark)
  (set! *mark-n* (+ *mark-n* 1))
  *mark-n*)

(define (make-id name marks) (vector 'stx-id name marks))
(define (identifier? x)
  (and (vector? x) (= (vector-length x) 3) (eq? (vector-ref x 0) 'stx-id)))
(define (id-name id) (vector-ref id 1))
(define (id-marks id) (vector-ref id 2))

(define (add-mark id m)
  (make-id (id-name id) (cons m (id-marks id))))

(define (bound-identifier=? a b)
  (and (identifier? a) (identifier? b)
       (eq? (id-name a) (id-name b))
       (equal? (id-marks a) (id-marks b))))

;; def-env / use-env : alist of (id . binding-cell)
(define (free-identifier=? a b env-a env-b)
  (let ((ba (lookup-id a env-a))
        (bb (lookup-id b env-b)))
    (cond
      ((and ba bb) (eq? ba bb))
      ((and (not ba) (not bb)) (eq? (id-name a) (id-name b)))
      (else #f))))

(define (datum->syntax ctx x)
  ;; ctx 的 marks 涂到 x 里每个标识符上（本层顶层 ctx 可用空 marks）
  (cond
    ((symbol? x) (make-id x (if (identifier? ctx) (id-marks ctx) '())))
    ((pair? x) (cons (datum->syntax ctx (car x)) (datum->syntax ctx (cdr x))))
    (else x)))

(define (syntax->datum x)
  (cond
    ((identifier? x) (id-name x))
    ((pair? x) (cons (syntax->datum (car x)) (syntax->datum (cdr x))))
    (else x)))
```

`lookup-id` 用 `bound-identifier=?` 扫当前环境链。绑定细胞（`box` 或 pair）从 `let`/`lambda`/`define-syntax` 创建，指针相等表示同一绑定。

### 登记与展开

```scheme
(define *syntax-env* '())   ; 顶层 define-syntax
(define *macro-env* '())    ; L47 define-macro，勿删

(define (define-syntax-form name transformer)
  ;; transformer = (syntax-rules lits rules def-env)
  (set! *syntax-env*
        (cons (cons name transformer) *syntax-env*)))

(define (expand expr env)
  (cond
    ((identifier? expr)
     (let ((b (lookup-id expr env)))
       (if b (binding-use b) expr)))
    ((not (pair? expr)) expr)
    (else
     (let ((head (car expr)))
       (cond
         ((and (identifier? head) (lookup-syntax head env))
          => (lambda (tf)
               (let* ((m (fresh-mark))
                      (out (apply-syntax-rules tf expr env m)))
                 (expand out env))))
         ((and (identifier? head) (eq? (id-name head) 'define-syntax)
               (lookup-core 'define-syntax env))
          (register-define-syntax expr env)
          (core-void))
         ((and (identifier? head) (lookup-define-macro head))
          => (lambda (proc)
               ;; L47：apply proc 于 (cdr use-form) 的 datum，不是整棵 expr
               (let ((out (apply proc (cdr (syntax->datum expr)))))
                 (expand (datum->syntax head out) env))))
         ((and (identifier? head) (lookup-core-form head env))
          => (lambda (core) (expand-core core expr env)))
         (else (map-expand-call expr env)))))))
```

### 匹配与代入（一层 `...`）

```scheme
(define (apply-syntax-rules tf input use-env mark)
  (let ((lits (tf-lits tf))
        (rules (tf-rules tf))
        (def-env (tf-def-env tf)))
    (let loop ((rs rules))
      (if (null? rs)
          (error "L48: no syntax-rules match" (syntax->datum input))
          (let ((pv (try-match (caar rs) input lits use-env def-env)))
            (if pv
                (subst (cadar rs) pv mark def-env)
                (loop (cdr rs))))))))

(define (try-match pat in lits uenv denv)
  ;; 返回 alist 或 #f
  ;; 头标识符：跳过 pat 与 in 的 car（或要求 free-identifier=? 于宏名）
  (match-form (cdr pat) (cdr in) lits uenv denv '()))

(define (ellipsis? x)
  (and (identifier? x) (eq? (id-name x) '...)))

(define (literal-id? id lits denv)
  (and (identifier? id)
       (ormap (lambda (lit) (free-identifier=? id lit denv denv)) lits)))

;; match-form / subst：按「原理」表实现。
;; 遇到 (p rest-pat) 且 (ellipsis? (car rest-pat))：
;;   把 in 剩余每个元素对 p 做 match，cons 到模式变量的列表绑定。
```

`register-define-syntax` 必须 **关闭定义处 `env`** 进 transformer，否则引入的 `if` 会跑到 use-site 去 lookup。

### 不要改的后端

无新 `emit-*`。卫生化后的 `let` 绑定名仍是 IR `<id>` 字符串（可把 marks 编进名字，如 `t.m12`，后端当不透明）。

## 测例清单

上一层全部测例仍须通过（含 L47 `define-macro`）。

1. **when 真**  
   ```scheme
   (begin
     (define-syntax when
       (syntax-rules ()
         ((when test body ...)
          (if test (begin body ...) #f))))
     (when #t 1))
   ```  
   → `1`

2. **when 假**  
   同上宏，`(when #f 1)` → `#f`（骨架把假枝写成 `#f`；不要输出未定义就当成功）。

3. **when 多 body**  
   `(when #t (fxadd1 0) 7)` → `7`

4. **when 零个 body**  
   `(when #t)` 展开成 `(if #t (begin) #f)`。L22 空 `begin` 是编译期错：本测例期望 **expand/编译期错误**。slug：`004-err-when-empty-body.scm`。

5. **unless**  
   `(unless #f 3)` → `3`；`(unless #t 3)` → `#f`

6. **一层省略号拼 list**  
   ```scheme
   (define-syntax wrap-list
     (syntax-rules ()
       ((wrap-list e ...) (list e ...))))
   (wrap-list 1 2 3)
   ```  
   → `(1 2 3)`（需 L42 `list`）

7. **字面量 else：顶层匹配**  
   ```scheme
   (define-syntax if-else
     (syntax-rules (else)
       ((if-else (else e)) e)
       ((if-else (t e)) (if t e #f))))
   (if-else (else 9))
   ```  
   → `9`

8. **字面量 else：非 else 标识符不走第一规则**  
   `(if-else (foo 9))` 在 `foo` 未绑定当变量会编译期错；写成 `(if-else (#t 8))` → `8`。证明 `else` 不是「任意标识符」模式变量。

9. **引入 if 不被用户绑定遮蔽**  
   ```scheme
   (define-syntax kif
     (syntax-rules ()
       ((kif t a b) (if t a b))))
   (let ((if #f)) (kif #t 1 2))
   ```  
   → `1`（若得到编译/运行错误或 `2`，引入名没有 marks）

10. **引入临时变量不捕获**  
    ```scheme
    (define-syntax my-or2
      (syntax-rules ()
        ((my-or2 a b) (let ((t a)) (if t t b)))))
    (let ((t 0)) (my-or2 #f t))
    ```  
    → `0`（用户的 `t`，不是宏里那个临时槽）

11. **模式变量保持 use-site**  
    `(let ((t 5)) (my-or2 t 9))` → `5`

12. **多规则顺序**  
    ```scheme
    (define-syntax pick
      (syntax-rules ()
        ((pick a) a)
        ((pick a b) b)))
    (pick 1)
    ```  
    → `1`；另测 `(pick 1 2)` → `2`

13. **无一匹配**  
    `(pick 1 2 3)` → **expand 期错误**。`013-err-no-rule.scm`

14. **L47 仍可用**  
    若 L47 测例有 `(define-macro …)`，本层回归已覆盖。另加：同一程序先 `define-macro` 再 `define-syntax` 同名，后者优先。期望以 syntax-rules 语义为准。

15. **非顶层 define-syntax**  
    `(lambda () (define-syntax x (syntax-rules () ((x) 1))) (x))` → **本层编译期错误**（范围之外）。`015-err-local-define-syntax.scm`

16. **vector 模式拒绝**  
    `(syntax-rules () ((m #(a)) a))` 作为 define-syntax → **编译期错误**。`016-err-vector-pattern.scm`

## 验收标准

- 测例 1–3、5–12、14 退出码 0，stdout 与期望字节级一致。
- 测例 4、13、15、16 非 0，stderr 含 `syntax` 或 `define-syntax` 或 `match` 一类关键字。
- 生成代码仍无「宏匹配」指令；宏在 expand 消失。
- 存在 `fresh-mark`/`add-mark`（或 Kohlbecker 着色函数），且测例 9–10 依赖它们，而不是碰巧没撞名。
- `define-macro` 路径未删除。
- 无新堆标签、无 GC、无对 `emit-alloc` 的改动。

## 常见坑

- **展开后再按裸 `if` 符号降 IR**：测例 9 会把引入的 `if` 解析成局部变量。必须核心绑定或内部 AST。
- **给模式变量结果也 `add-mark`**：测例 11 的 `t` 与 `let` 绑定对不上，`my-or2` 变成「引用未绑定的 t.m」。
- **`...` 当普通标识符写入 lits 却仍当省略符**：匹配器先识别「模式中位于后缀的省略记号」，再谈 lits。
- **递归展开没有油限**：本层虽不做递归宏，`expand` 对宏输出必须再 `expand`；若忘了，`(when #t 1)` 可能把 `if` 当调用。设 `expand` 深度上限（如 1024）防止以后 L50 写炸。
- **把 `define-syntax` 编进 IR**：运行时没有这个原语，会在 `emit-prim` 里 unknown。
- **匹配 improper list 时用 `length`**：`(a b . c)` 本层可不支持；若输入不是真列表，本层当匹配失败。不要 `error` 成 runtime。
- **L47 与 L48 抢同一个 `expand` 入口却共用一张表**：未卫生测例会突然变绿或全红。两张表，查找顺序写死。

## 下一层预告

L49 不扩大匹配能力，而是把 marks / 引入 vs 使用 / `set!` / `let` 遮蔽写成必须过的测例，并补上本层算法里会漏的洞。
