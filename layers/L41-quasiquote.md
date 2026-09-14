# L41 — quasiquote / unquote / unquote-splicing

## 目标

把反引号模板展开成已有的构造操作：`cons`、`quote`、以及本层新增的原语 **`%append`**。支持：

- `` `datum `` / `(quasiquote datum)`
- `,expr` / `(unquote expr)`：在 **深度 0** 求值插入
- `,@expr` / `(unquote-splicing expr)`：在 **列表或向量元素位置** 拼接
- **至少再套一层** 的嵌套 quasiquote（用深度计数器，不是特判两层）

本层范围之外：`syntax-rules` 里的 pattern 反引号；循环结构的模板（展开期不求值，不会自己长环）；把 `unquote` 做成运行时过程；多值插入。`append` 的 **用户可见** 库过程叫 L42；本层只提供展开用的 `%append`。完整数值塔、I/O、`eval` 仍不做。

## 原理

### 深度计数器

`quasiquote` / `unquote` / `unquote-splicing` 是 **配对的语法**，不是普通调用。嵌套时内层的逗号要「少剥一层」：

```
`(a ,(+ 1 2))           ; 深度 0 的 unquote → 把 3 插进表
``(a ,(+ 1 2))          ; 外层深度 0 碰到内层 quasiquote → 深度变 1
                        ; 深度 1 的 unquote 不得求值，要重建成
                        ; (quasiquote (a (unquote (+ 1 2))))
```

锁定算法：`qq(form, d)` 在「正在展开一层 quasiquote、当前嵌套深度为 `d`」时把 `form` 变成 **核心表达式**（不是又一层模板）。

进入：展开 `(quasiquote x)` 即求 `qq(x, 0)`。

| 当前 `form` | `d = 0` | `d > 0` |
|-------------|---------|---------|
| `(unquote e)` | 返回 `expand(e)`（求值） | 重建：`(cons 'unquote (cons (qq e, d-1) '()))` |
| `(unquote-splicing e)` | **错误**（见下，非元素位置） | 重建 `unquote-splicing` 同上，深度 `d-1` |
| `(quasiquote e)` | 不应在 `d=0` 作为「又一次语法进入」走错路：这是 **嵌套**，走 `d>0` 那一列 | 重建：`(cons 'quasiquote (cons (qq e, d+1) '()))` |
| 序对 `(a . b)` | 按列表规则（下节） | 同样按列表规则，对 car/cdr 递归时深度不变 |
| 向量 | 先当表展开再 `list->vector`，或逐槽 `vector` | 同左，深度规则不变 |
| 原子（fixnum、char、布尔、`()`、符号、字符串） | `(quote atom)` | `(quote atom)` |

`d = 0` 时若 `form` 是 `(quasiquote e)`，这就是嵌套反引号：**不要**再当「程序里的 quasiquote 语法」交给外层 `expand` 剥掉。必须提高深度并 **构造一份运行时列表**，其 `car` 是符号 `quasiquote`。

因此：嵌套展开需要 **运行时符号对象**（`SYMBOL_TAG`）。本层 runtime 放入最小 **`rt_intern(byte *, size_t)`**（线性表即可）。L43 的 reader、L46 的 `string->symbol` **必须复用同一张表**；禁止各做一份，否则后来 `eq?` 会假。本层 `quote` 符号与重建关键字都走 `rt_intern`。L40 曾拒绝 quote 符号，本层解禁。

前端对符号常量：

```
(quote foo)  ⇒  (prim %intern (imm-or-string-lit "foo"))
```

或编译期直接调用宿主侧包装的 intern，把返回的 tagged ptr 写成 `(imm …)` **不行**——符号是堆对象，地址每次运行不同。必须是运行时 intern 或静态数据区 + intern。推荐：`scheme_entry` 前由 runtime 不需要预填；第一次 `%intern` 分配 string + symbol 格。

### 列表位置 vs 非法 splicing

R4RS：`,@` 只能出现在 **列表或向量的元素位置**。下列编译期错误：

| 模板 | 原因 |
|------|------|
| `,x` 作为整个 `(quasiquote …)` 的 form 且是 `unquote-splicing` | 不是元素 |
| `` `@x `` 即 `(quasiquote (unquote-splicing x))` 作为 **整个** 模板 | 拼接结果不是「插入元素」，而是要变成多值/非序对上下文 |
| `` `(a . ,@x) `` | `,@` 在 cdr 的 **点对位置**，不是元素 |
| `` `#(,@x) `` 可以 | 向量元素位置，合法 |
| `` `(,@x) `` 合法 | 元素位置，展开为 `(%append x '())` 或就是对 `x` 的拷贝/共用 |

锁定 `` `(,@xs) `` → `(%append xs '())`（或 `xs` 若你证明 `xs` 已是 proper list 且调用方可共享；**不要共享**：splicing 应对第一参数做拷贝语义与 `append` 一致，见 `%append`）。空拼接 `` `(1 ,@'() 2) `` → `(1 2)`。

`` `(a ,@x b) `` → `(cons 'a (%append x (cons 'b '())))`。

多个 splicing 嵌 `%append`：`` `(,@a ,@b) `` → `(%append a (%append b '()))`。

### `%append` 原语

IR：`(prim %append Ir Ir)`，二元。语义与 R4RS 二元 `append` 相同：

- 第一参数必须是 **proper list**（含 `()`）；否则 **运行时** `rt_error("append")`。
- 拷贝第一表的所有序对，最后一格 cdr 指向第二参数（第二参数任意对象，不要求是表）。
- 不修改原表。
- 分配走 `emit-alloc` / 现有 `cons` 路径，**禁止 `malloc`**。

三种实现都合格，选一种写进注释：

1. **推荐**：后端 `emit-prim` 生成循环：先量长度，再从右往左 `cons`，或两次扫描；用 `HP` 分配。
2. `bl _rt_append`：runtime 汇编里调 runtime 导出的 `rt_alloc(n)`（内部读/写与 `x19` 同步的堆指针）。若 runtime 与 `x19` 各记一份 HP 且不同步，GC 之前就会静默翻车——必须在 `emit-rt-call` 前后 `str/ldr x19` 到约定全局。
3. 编译器注入一段 Scheme：

   ```scheme
   (define (%append a b)
     (if (null? a) b (cons (car a) (%append (cdr a) b))))
   ```

   此时展开式里写 **调用** `(%append A B)` 而不是 `(prim %append …)`。仍须保证每个用户程序都能看见这个绑定（与 L42 prelude 同一包装）。递归实现深度等于第一表长度，本层接受。

L42 的用户过程 `append` **包装** `%append`（n 元在 Scheme 里折成二元），不要再做第二份拷贝算法，除非你删掉 prim、只留 prelude。

`list` 若尚未作为库过程存在：展开器 **不要依赖** `(list …)`。深度 `d>0` 的重建用 `cons` 链：

```
(cons (quote unquote) (cons (qq e d-1) (quote ())))
```

符号 `unquote` / `quasiquote` / `unquote-splicing` 走 intern。

### 向量模板

L16 已有 vector。`` `#(a ,x) `` 先把内容当列表做 `qq-list`，再：

```
(prim vector-from-list Ir)   ; 若你有
;; 或
(list->vector <list-ir>)     ; L42 才给库；本层可用 make-vector + 循环
```

本层最小合格：向量模板展开为 `(prim %list->vector list-ir)`，后端用 `make-vector` + 逐槽 `vector-set!`，或注入一小段 Scheme。无向量模板的实现 **不合格**（R4RS 有 `#(…)` 的 quasiquote）。不含 splicing 的向量也可以展开成 `(vector <each>)` 若你已有 n 元 `vector` 原语；没有则走 list 再转换。

### `unquote` 出现在 quasiquote 之外

程序里顶层的 `(unquote e)` 或 `,e`（若 reader 尚未存在，驱动喂 s-expression）是 **编译期错误**。`expand` 在 `d` 未激活时看到 `car` 为 `unquote` / `unquote-splicing` 即 `error`。L43 之后 `'`,@` 读进来也是这两种形式，同一条规则。

### 与 `expand` 的衔接

`expand` 遇到 `(quasiquote x)` → 替换为 `qq(x,0)`，再对结果递归 `expand`（结果里是 `cons`/`%append`/`quote`/`if` 等，不应再有深度 0 的 `quasiquote`）。`quote` 节点不走进去。

**不要**把 `qq` 的输出里为重建而生成的 `(quote quasiquote)` 再当成语法。重建用的是 `cons` + intern 符号，不是 `quasiquote` 特殊形式。

## 与上一层的差异

- L40 的 `quote` 只服务 `case` 立即数；本层 `quote` 要能产符号（intern）和列表常量。
- 新增展开器 `qq` 与深度参数；新增 prim `%append`（或注入过程）以及 `%intern`。
- runtime 第一次有 intern 表（线性即可）。符号单元格布局与 ARCHITECTURE 一致：`[tagged-string]`，指针标签 `SYMBOL_TAG=0b101`。
- `rt_print` 对本层新出现的符号：可先打印符号的字符串名（无 `' ` 前缀），L44 再区分 `write`/`display`。未知标签仍按你现有 `#<ptr>` / hex。

## 代码骨架

### 可移植展开

```scheme
(define (qq-error msg . irritants)
  (apply error (cons (string-append "L41: " msg) irritants)))

(define (qq form d)
  (cond
    ((and (pair? form) (eq? (car form) 'unquote) (length=? form 2))
     (if (zero? d)
         (expand (cadr form))
         (qq-rebuild 'unquote (qq (cadr form) (- d 1)))))
    ((and (pair? form) (eq? (car form) 'unquote-splicing) (length=? form 2))
     (if (zero? d)
         (qq-error "unquote-splicing outside list/vector")
         (qq-rebuild 'unquote-splicing (qq (cadr form) (- d 1)))))
    ((and (pair? form) (eq? (car form) 'quasiquote) (length=? form 2))
     (qq-rebuild 'quasiquote (qq (cadr form) (+ d 1))))
    ((pair? form)
     (qq-pair form d))
    ((vector? form)
     (list '%list->vector (qq-pair (vector->list form) d)))
    (else (list 'quote form))))

(define (qq-rebuild tag inner-expr)
  ;; (cons '<tag> (cons inner '()))
  (list 'cons (list 'quote tag)
        (list 'cons inner-expr (list 'quote '()))))

;; 合法 splicing 永远是元素位置 ((unquote-splicing e) . rest)。
;; (a . (unquote-splicing x)) 的 car 是符号 unquote-splicing，走错误分支。
(define (qq-pair form d)
  (cond
    ((null? form) (list 'quote '()))
    ((not (pair? form)) (qq form d)) ; dotted atom tail
    ((and (zero? d)
          (pair? (car form))
          (eq? (caar form) 'unquote-splicing)
          (length=? (car form) 2))
     (list '%append (expand (cadar form)) (qq-pair (cdr form) d)))
    ((and (zero? d)
          (eq? (car form) 'unquote-splicing))
     (qq-error "splicing in non-list context" form))
    (else
     (list 'cons (qq (car form) d) (qq-pair (cdr form) d)))))
```

`d>0` 时不要把内层 `unquote-splicing` 当拼接执行，只当普通列表结构递归（`car` 为符号 `unquote-splicing` 的 **三元素列表** 已在 `qq` 开头被整表匹配）。整表匹配必须 **先于** `qq-pair`，否则 `(unquote e)` 会被当成普通两元素表 `cons` 起来。

### `%intern` / `%append` 的 IR

```scheme
((eq? (car expr) '%append)
 `(prim %append ,(expr->ir (cadr expr)) ,(expr->ir (caddr expr))))
((eq? (car expr) '%intern)
 `(prim %intern ,(expr->ir (cadr expr))))
((eq? (car expr) '%list->vector)
 `(prim %list->vector ,(expr->ir (cadr expr))))
```

`quote` 符号：

```scheme
(define (datum->ir d)
  (cond
    ((symbol? d) `(prim %intern (imm-string ,(symbol->string d))))
    ((pair? d)
     `(prim cons ,(datum->ir (car d)) ,(datum->ir (cdr d))))
    ;; 立即数、字符串、向量：沿用 L13–L17
    (else (literal->ir d))))
```

`imm-string` 不是 ARCHITECTURE 的 IR 节点。两种合格降法：编译期把宿主字符串做成 L17 的 string 分配图（`(prim make-string …)` + `string-set!`），或后端认识 `(prim %intern (imm …))` 配一张只读 NUL 结尾字节串（`adr` + 字节）。推荐前者，少一种 IR。

### aarch64-apple：`%append` 循环要点

```
; x0 = list a, x1 = b（先把 b 存栈）
; 若 a 是 ()，返回 b
; 否则：
;   可递归：与 Scheme 版同，注意栈
;   或：计数 n，从 a 拷贝 n 个 cons，最后一个 cdr = b
```

非 pair 且非 `()` 的「表中段」→ `emit-rt-call rt_error`。不要静默把点对当终止。

`%intern`：`emit-rt-call rt_intern`。runtime 侧：

```
; 算法伪代码：实现必须是 runtime 汇编，不是 C。
; INTERN_CAP 256
static struct { ptr sym; } intern_tab[INTERN_CAP];
static int intern_n;

ptr rt_intern(ptr str); /* Scheme string → symbol；线性 memcmp */
```

若你从汇编传入的是「NUL 结尾字节串指针 + 长度」而不是 Scheme string，本层可以暂时这样，但 L46 的 `string->symbol` 必须改成吃 tagged string，并 **走同一张表**。推荐本层 runtime 辅助约定就吃 tagged string。

`runtime.s` 注释 补 `SYMBOL_TAG 5`（若尚未定义）。`rt_print`：去标签，读出 string 槽，按 L17 的字节打印名字。

符号分配：`emit-alloc 8`，槽 0 = tagged string，OR `SYMBOL_TAG`。intern 命中则返回旧指针，**不要**新分配。

## 测例清单

上一层全部测例仍须通过。

1. `` `(1 2 3) `` → `(1 2 3)`
2. `` `1 `` → `1`
3. `` `() `` → `()`
4. `(let ((x 4)) `(1 ,x 3))` → `(1 4 3)`
5. `(let ((x 4)) `(,x))` → `(4)`
6. `(let ((xs '(2 3))) `(1 ,@xs 4))` → `(1 2 3 4)`
7. `(let ((xs '(2 3))) `(,@xs))` → `(2 3)`
8. `(let ((a '(1)) (b '(2))) `(,@a ,@b))` → `(1 2)`
9. `(let ((xs '())) `(1 ,@xs 2))` → `(1 2)`
10. 点对尾：`(let ((x 9)) `(1 . ,x))` → `(1 . 9)`
11. 嵌套 cons：`` `((1 2) (3)) `` → `((1 2) (3))`
12. 向量：`(let ((x 8)) `#(1 ,x 3))` → `#(1 8 3)`
13. 向量 splicing：`(let ((xs '(a b))) `#(1 ,@xs 2))` → `#(1 a b 2)`
14. 嵌套一层（深度计数）：`` `(a ,(+ 1 2)) `` 作为 **内层尚未求值** 的对象：

    ```scheme
    ``(a ,(+ 1 2))
    ```

    → `(quasiquote (a (unquote (+ 1 2))))`  
    打印（L13 pair + 本层符号名）：`(quasiquote (a (unquote (+ 1 2))))`  
    注意：`+` 是符号，本层 intern 后 `eq?` 同一名字。
15. 双重 unquote 在嵌套里求值一次：

    ```scheme
    ``(a ,,(+ 1 2))
    ```

    读入为 `(quasiquote (quasiquote (a (unquote (unquote (+ 1 2))))))`。外层 `d=0` 重建 `quasiquote`，内层 `d=1` 的双重 `unquote` 把深度降到 0 从而求值 `(+ 1 2)`。锁定打印：`(quasiquote (a (unquote 3)))`。
16. 模板里的 quote：`` `(quote ,(+ 1 1)) `` → `(quote 2)`
17. L40 回归用符号 case（本层起合法）：`(case 'b ((a) 1) ((b) 2) (else 3))` → `2`
18. `(unquote 1)` 不在 quasiquote 内：编译期错误。
19. `(unquote-splicing '(1))` 顶层：编译期错误。
20. `` `(1 . ,@xs) `` 或宿主读入的等价非法点对 splicing：编译期错误。
21. `%append` 运行时类型：把展开结果接到非列表第一参数——例如 `(let ((x 1)) `(,@x))` → **运行时** 错误（stderr 含 `append`）。
22. splicing 不修改原表：

    ```scheme
    (let ((xs (cons 1 (cons 2 '()))))
      (let ((ys `(0 ,@xs)))
        (begin (set-car! xs 9) ys)))
    ```

    → `(0 1 2)`（拷贝语义；若共享了 `xs` 的序对，`set-car!` 会把 `ys` 改成 `(0 9 2)`）
23. `` `,@(list 1 2) `` 作为整个模板：编译期错误（与测例 19 同类，确认 reader/驱动喂的是 `unquote-splicing` 包裹的 **整个** form）。

## 验收标准

- 测例 1–17、22 输出与上表一致（pair 打印沿用 L13：真表用空格，点对用 `.`；向量沿用 L16 的 `#(` … `)`）。
- 18–20、23 编译期失败；21 运行时失败。
- 嵌套测例 14–15 证明深度 +1 / −1，而不是「看见两个反引号就当一层」。
- `%append` 与以后 L42 `append` 对同一两表参数结果 `equal?`（L42 加回归）。intern 表与 L43/L46 共用——本层至少保证两次 `(quote foo)` 在同一程序里 `eq?` 为真：`(eq? 'foo 'foo)` → `#t`。
- 无 `malloc` 做表拷贝；HP 只经 `emit-alloc` 或同步后的 `rt_alloc`。

## 常见坑

- **展开后再走一遍 `expand` 把嵌套 `quasiquote` 剥光**：重建必须用 `cons`+符号，不能输出 `(quasiquote …)` 特殊形式。
- **先拆 pair 再认 `unquote`**：`(unquote e)` 会被做成 `(cons 'unquote (cons e '()))` 而 `e` 不再求值。
- **`,@` 用 `cons` 而不是 `%append`**：`` `(1 ,@'(2 3)) `` 会变成 `(1 (2 3))`。
- **splicing 共享序对**：测例 22。
- **深度 0 对 `(quasiquote e)` 再调用顶层 expand**：`` `(a) `` 会直接变成 `(a)`，测例 14 失败。
- **符号每次 `quote` 新分配**：`eq?` 失败，L46 无法补救除非当时就 intern。
- **C `rt_append` 自己在堆外分配 或用不更新的 HP**：对象落在堆外，以后 GC 必炸；本层测例也可能和 bump 断言冲突。
- **宿主 `` `(a . ,@x) `` 的 read 结果认错**：打印/展开前先在宿主里 `write` 一下读入的 s-expression，对照 R4RS 的 `unquote-splicing` 形状。

## 下一层预告

L42 要用 Scheme 自己写一套 **核心库**（`list`、`length`、`map`、用户可见的 `append`…），并规定 prelude 的装载顺序。
