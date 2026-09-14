# L49 — 卫生与遮蔽测例

## 目标

本层是 **测例层 + 补洞层**：不增加新的模式形状，不开放局部 `define-syntax`。把 L48 的标记算法写清楚到「引入 vs 使用」级别，用经典遮蔽程序逼出错误实现。锁死：

- **仅顶层** `define-syntax`（与 L48 相同；`let-syntax` / `letrec-syntax` / 内部 `define-syntax` 仍为范围之外）。
- 字面量用 `free-identifier=?`，不是 `symbol=?`。
- 模板引入名带 mark（或 Kohlbecker 色）；模式变量代入**保持 use-site 标识符**。
- 用户对**自己的**变量 `set!` 仍有效；对宏**引入**的名字 `set!` 不得改到用户同名变量上。

L47 未卫生宏继续存在，本层至少一条测例证明两条路径语义不同。

本层范围之外：局部语法绑定、`syntax-case`、`identifier-syntax`、相位移、fender、递归宏与嵌套 `...`（L50）。

## 原理

### 为何 L48 还会漏

只打「引入名改名」而不维护 **binding cell** 时，常见假绿：

- 宏从不引入 `if`/`let`，测例 9 没写到。
- 临时变量叫 `t`，用户变量叫 `x`，测例 10 没撞上。
- `cond` 仍是 L40 手写展开器，按 `eq?` 比 `else`，卫生字面量根本没跑到。

本层规定：下列算法必须能在纸上对每个测例走一遍，并与实现一致。

### 标识符的两套相等

```
bound-identifier=?  名字相同 ∧ marks 相同
free-identifier=?   lookup(a, env-a) 与 lookup(b, env-b) 是同一 binding-cell
                    ∨ (两边都 miss ∧ 名字相同)
```

用途分开，不要混：

| 场合 | 用哪一个 |
|------|----------|
| `let`/`lambda` 的形参对 body 里的引用 | `bound-identifier=?` |
| `syntax-rules` **字面量**（`else` 等） | `free-identifier=?`（一边 env 是定义处，一边是 use-site） |
| 判断「这是不是核心 `if`」 | 对核心 env 做 `free-identifier=?` 或 lookup 到 `'core-if` |

字面量比较时：**literal 标识符来自宏定义处**（def-env），**输入里的候选来自 use-site**（use-env）。这是 L48 骨架里 `try-match` 必须把两个 env 都传进去的原因。

### 引入 vs 使用（代入规则）

一次成功的规则应用产生新鲜 mark `m`。对模板每个叶：

1. **使用（use）**：叶是模式变量 → 放入匹配到的语法对象，marks 不变，也不换成 def-env 的同名绑定。
2. **引入（intro）**：叶是其它标识符 → `add-mark` 后在 **def-env** lookup。命中则产出指向该 binding 的引用（核心 `if`、用户在定义宏之前的 `define` 等）。miss 则这是宏私有名字（如 `t`）：保持带 `m` 的新标识符，随后 `let` 会为它建**新** binding-cell。

「使用」保证 `(my-or2 t 9)` 里的 `t` 仍是用户的 `t`。「引入」保证模板里的 `if`/`t` 不是用户的。

### `set!` 与引入名

`set!` 的左操作数按 `bound-identifier=?` 找当前绑定。因此：

```scheme
(define-syntax inc!
  (syntax-rules ()
    ((inc! x) (set! x (fxadd1 x)))))
```

这里 `x` 是模式变量（使用），`set!`/`fxadd1` 是引入。`(let ((x 0)) (inc! x) x)` 必须改到用户的 `x`。

```scheme
(define-syntax touch-secret
  (syntax-rules ()
    ((touch-secret) (set! secret 1))))
```

`secret` 是引入。`(let ((secret 0)) (touch-secret) secret)` 不得变成 1：引入的 `secret` 与用户的 `secret` marks 不同，应 **expand 期未绑定** 或绑到一个宏私有、用户看不见的槽。本层锁定：**expand 期错误**（未绑定标识符），不要默默建顶层全局。

### `let` 包在宏调用外面

展开在环境里发生。`(let ((if #f)) (kif #t 1 2))` 的顺序：

1. 进入 `let`，body 的 use-env 含 `if → cell₁`。
2. 展开 `(kif #t 1 2)`：匹配、代入得到带 def-env 标记的 `(if #t 1 2)`。
3. 展开该 `if`：头标识符 lookup **不在** `cell₁`（marks 不同），而在 core-env → `'core-if`。

若第 3 步用 `id-name` 当键去 use-env 里找，就会命中 `cell₁`，测例失败。

### 经典：字面量 `else`

R5RS：输入子形式匹配字面量 L iff 它是标识符且 `free-identifier=?`。因此：

```scheme
(cond (else 1))
```

顶层 `else` 与宏定义处的 `else` 都未绑（或都绑到同一关键字），匹配 else 规则，结果 `1`。

```scheme
(let ((else #f)) (cond (else 1)))
```

use-site 的 `else` lookup 到 `let` 的 cell；def-site 的 literal `else` 不是该 cell → **不是** else 子句。该子句按普通 `(test result)` 展开成对 `#f` 的测试，无后续子句则 R4RS 未指定。本教程锁定打印 **`#<void>`**（`VOID=0x1F`，与 L40/L44/L45 一致）。

「仍能工作」指：expander **不崩溃**、不把 `else` 当模式变量（否则任意标识符都会走「else 规则」返回 1）、也不因局部绑定而把 `cond` 整棵树判为非法。它与 L47「只比名字、局部 `else` 仍当关键字得到 1」**相反**——这是本层要拉开的差距。

本层测例里的 `cond` **必须是 syntax-rules 版**（prelude 覆盖 L40 手写器，或用另一名字 `sr-cond` 并在测例中只用它）。若仍走 L40 的 `eq? 'else`，本层字面量测例无意义。

推荐 prelude（非递归、两规则即可；完整多子句 `cond` 可留 L50）：

```scheme
(define-syntax cond
  (syntax-rules (else)
    ((cond (else e)) e)
    ((cond (test e)) (if test e #f))))
```

### subst 标记（Dybvig wrap 的最小子集）

完整系统在 `let` 绑定时给 body 加 **subst wrap**：`id ↦ fresh`。本层若已用 binding-cell + `bound-identifier=?`，不必再做第二套 wrap。若你选「纯 marks + subst 列表」实现，锁定这套操作：

```
wrap ::= (mark m) | (subst id binding)
apply-mark(stx, m):  每个 id 的 mark 列表 cons m；若已含 m 则抵消（anti-mark，宏调用边界用）
apply-subst(stx, id, b):  bound-identifier=? 于 id 的叶子改成指向 b
```

宏调用边界常见写法：对**输入**先加 anti-mark（与即将打在输出上的 `m` 成对），使模式变量带回去的用户标识符在「加 m」后抵消，保持 use-site marks。若你 L48 已经「模式变量不 add-mark」，则**不要**再加 anti-mark，否则会双重抵消。本层补洞时只选一种边界，写进注释：

- 策略 A（L48 骨架）：代入跳过 add-mark；无 anti-mark。
- 策略 B：输出整棵 `add-mark m`，输入先 `add-mark m` 再 `add-mark m`（两次即 anti）。不要混用。

### 局部 syntax：明确不做

`(let () (define-syntax …) …)`、`(let-syntax ((n tf)) body)` 本层 **编译期错误**。不要「顺便做了」却无测例；LOCK 就是不做。

## 与上一层的差异

- 匹配能力与 IR/runtime 不变。
- 必须能把 `cond`（或 `sr-cond`）写成 syntax-rules 且字面量行为符合上一节。
- 算法文档补上 `set!`、void 打印、anti-mark 策略二选一。
- 测例数量与对抗性是交付物；代码改动应只是修 L48 的洞。

## 代码骨架

本层骨架是 **标记与查找**，不是新匹配器。对照你的 L48 实现逐项打勾。

```scheme
;; --- marks ------------------------------------------------
(define (marks-equal? a b) (equal? a b))  ; 列表；不要当集合乱序除非你排序后比较

(define (add-mark-stx stx m)
  (cond
    ((identifier? stx) (add-mark stx m))
    ((pair? stx) (cons (add-mark-stx (car stx) m)
                       (add-mark-stx (cdr stx) m)))
    (else stx)))

;; 策略 B 才需要：同一 mark 出现两次则剥掉（anti-mark）
(define (add-mark id m)
  (let ((ms (id-marks id)))
    (if (and (pair? ms) (equal? (car ms) m))
        (make-id (id-name id) (cdr ms))
        (make-id (id-name id) (cons m ms)))))

;; --- bindings --------------------------------------------
;; binding-cell 是 pair 或 vector，eq? 表示同一绑定
(define (make-cell kind value) (cons kind value))

(define (extend-env ids cells env)
  ;; ids 与 cells 等长；body 查找用 bound-identifier=?
  (append (map cons ids cells) env))

(define (lookup-id id env)
  (let loop ((e env))
    (cond
      ((null? e) #f)
      ((bound-identifier=? id (caar e)) (cdar e))
      (else (loop (cdr e))))))

(define (free-identifier=? a b env-a env-b)
  (let ((ca (lookup-id a env-a))
        (cb (lookup-id b env-b)))
    (cond
      ((and ca cb) (eq? ca cb))
      ((and (not ca) (not cb)) (eq? (id-name a) (id-name b)))
      (else #f))))

;; --- set! -------------------------------------------------
(define (expand-set! stx env)
  ;; (set! id rhs) ；id 必须是 identifier
  (let ((id (cadr stx))
        (rhs (expand (caddr stx) env)))
    (let ((cell (lookup-id id env)))
      (if (not cell)
          (error "L49: unbound in set!" (syntax->datum id))
          `(core-set! ,cell ,rhs)))))

;; --- literals in match ------------------------------------
(define (match-literal lit-id input-stx def-env use-env)
  (and (identifier? input-stx)
       (free-identifier=? lit-id input-stx def-env use-env)))
```

核心 `if` 的 cell 在 `*core-env*` 里，宏的 `def-env` 是定义瞬间的 `env`（含 core + 已有顶层）。不要把 `def-env` 存成「当时所有 symbol 名的列表」而丢掉 cell 指针。

void 打印（若尚未有）：

```
; 算法伪代码：实现必须是 runtime 汇编，不是 C。
case VOID: /* 0x1F */
    write("#<void>\n");
    break;
```

## 测例清单

上一层全部测例仍须通过。

下列 `cond` 均指 syntax-rules 版（prelude 或测例文件内 `define-syntax`）。`sr-cond` 若你未覆盖 `cond`，把下面 `cond` 换成 `sr-cond`，期望不变。

1. **顶层 else 字面量**  
   `(cond (else 1))` → `1`

2. **局部 else 不是关键字**  
   `(let ((else #f)) (cond (else 1)))` → `#<void>`  
   （void 的打印字符串与你的 runtime 一致，本层 `.expected` 锁死。）

3. **局部 else 不破坏其它子句**  
   `(let ((else #f)) (cond (#t 1) (else 2)))`  
   若你的 prelude `cond` 只有单子句规则，改用：  
   `(let ((else #f)) (if-else (#t 1)))` 其中 `if-else` 为 L48 双规则宏 → `1`

4. **else 不是模式变量**  
   ```scheme
   (define-syntax only-else
     (syntax-rules (else)
       ((only-else (else e)) e)))
   (only-else (#t 1))
   ```  
   → **expand 期错误**（`#t` 不是 else）。`004-err-else-not-catchall.scm`

5. **引入 if vs 用户 if**  
   ```scheme
   (define-syntax kif
     (syntax-rules ()
       ((kif t a b) (if t a b))))
   (let ((if #f)) (kif #t 10 20))
   ```  
   → `10`

6. **用户 if 仍可当变量用**  
   `(let ((if 3)) if)` → `3`（回归：核心 if 未被你改成不可绑定的 symbol）

7. **引入 t 不遮蔽用户 t**  
   ```scheme
   (define-syntax my-or2
     (syntax-rules ()
       ((my-or2 a b) (let ((t a)) (if t t b)))))
   (let ((t 7)) (my-or2 #f t))
   ```  
   → `7`

8. **引入 t 不改用户 t（set!）**  
   ```scheme
   (let ((t 1))
     (my-or2 #f 2)
     t)
   ```  
   → `1`

9. **模式变量上的 set!**  
   ```scheme
   (define-syntax inc!
     (syntax-rules ()
       ((inc! x) (set! x (fxadd1 x)))))
   (let ((x 4)) (inc! x) x)
   ```  
   → `5`

10. **引入名上的 set! 不得打到用户变量**  
    ```scheme
    (define-syntax touch-secret
      (syntax-rules ()
        ((touch-secret) (set! secret 1))))
    (let ((secret 0)) (touch-secret) secret)
    ```  
    → **expand 期错误**（引入的 `secret` 未绑定）。`010-err-set-introduced.scm`

11. **let 包住宏调用：多一层**  
    `(let ((if #f)) (let ((x #t)) (kif x 1 2)))` → `1`

12. **字面量 unquote 名字**  
    ```scheme
    (define-syntax qlit
      (syntax-rules (unquote)
        ((qlit (unquote e)) e)
        ((qlit x) (quote x))))
    (qlit (unquote 3))
    ```  
    → `3`  
    另：`(let ((unquote 9)) (qlit (unquote 3)))` 因 `unquote` 已绑定，不匹配第一规则；若第二规则 `(qlit x)` 把整个 `(unquote 3)` quote 掉，结果取决于你是否对输入 car 再展开——本层锁定 **expand 期错误**（第二规则的 `x` 匹配整个 list 并 `quote`，会得到 `(unquote 3)` 打印；为减少歧义：**删第二规则**，本测例只保留「绑定了 unquote 则第一规则失败」→ `012-err-unquote-shadowed.scm`）。

    清晰版测例 12：仅一条规则 `(qlit (unquote e))`；顶层 `(qlit (unquote 3))` → `3`；`(let ((unquote #t)) (qlit (unquote 3)))` → expand 错误。

13. **L47 vs L48 同形不同义**  
    核心 `if` 按符号匹配，所以「引入 `if`」在未卫生路径上仍是特殊形式。真正拉开差距的是**引入的临时变量名**（L47 测例 6 同类）：  
    ```scheme
    (begin
      (define-macro (um-or a b) `(let ((t ,a)) (if t t ,b)))
      (let ((t 7)) (um-or #f t)))
    ```  
    → `#f`（内层 `let ((t #f))` 捕获用户的 `t`；不要 gensym）。  
    对照测例 7 的 `my-or2` → `7`。本号必须走 `define-macro` 表，证明 L47 路径仍未打标。

14. **宏展开后的 if 仍短路**  
    `(kif #t 1 (car '()))` 不得求值假枝。→ `1`（依赖已有 `if` 语义）

15. **重复 define-syntax 覆盖**  
    两次顶层 `define-syntax foo`，后者生效。先定义为恒等，再定义为 `(foo x) (fxadd1 x)`，`(foo 1)` → `2`

16. **局部 define-syntax 仍拒绝**  
    同 L48 测例 15，回归。`016-err-local-define-syntax.scm`

17. **begin 里夹 define-syntax**  
    顶层 `(begin (define-syntax w (syntax-rules () ((w x) x))) (w 6))` → `6`  
    （顶层 begin 里的 define-syntax 算顶层，必须允许。）

## 验收标准

- 测例 1、3、5–9、11、13–15、17 退出码 0，输出锁死。
- 测例 2 的 void 打印与项目其它 void 一致。
- 测例 4、10、12 的阴影分支、16 非 0。测例 13 退出码 0，输出 `#f`（未卫生捕获）。
- 实现注释写明策略 A 或 B（anti-mark），且 `free-identifier=?` 用于字面量。
- 没有实现 `let-syntax`。没有改 GC、标签、IR 形状。
- 用 `symbol=?` 让测例 2 打出 `1` 的实现 **不合格**（那是 L47 行为）。

## 常见坑

- **字面量用 `eq?` 比名字**：测例 2 会得到 `1`，看起来「else 仍工作」，其实没做卫生。
- **`lookup` 只用 symbol 当 alist 键**：测例 5 失败。键必须是 identifier（名+marks）或先 `bound-identifier=?`。
- **`set!` 按名字搜最近的 `secret`**：测例 10 假绿成打印 `0` 或错改成 `1`。引入失败必须是未绑定。
- **prelude `cond` 仍是 L40**：测例 1–4 测不到 syntax-rules。
- **void 打印成空字符串**：驱动 `diff` 与「无输出」难分；用 `#<void>\n`。
- **策略 A/B 混用**：用户标识符 marks 被剥光或叠两层，`let` 形参对不上 body。
- **测例 13 得到 `7`**：说明 `define-macro` 被你误加上 marks/gensym；L47 路径必须保持未卫生捕获。

## 下一层预告

L50 允许模板再展开**同一个**宏（递归 `and`/`or`/`cond`），以及嵌套省略号 `(a (b ...) ...)`。
