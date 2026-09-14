# L42 — 核心库 `list` `length` `map` `append` …

## 目标

把一批 R4RS 常用过程做成 **库**：用本编译器编译的 Scheme（推荐）或等价手写 IR。用户程序在测例里看起来像在调用普通闭包，而不是前端硬编码的 prim——但已有的 prim（`not`、`boolean?`、`pair?`、`null?`、`car`/`cdr`、向量串、fixnum 算术）不必拆掉。

本层必须提供：

| 过程 | 最小合同 |
|------|----------|
| `list` | 任意个参数（含 0）；用 L33 rest：`(lambda xs xs)` |
| `length` | proper list → fixnum |
| `append` | n 元，0 元得 `()`，1 元得该参数，≥2 元折成 L41 的 `%append` |
| `reverse` | proper list → 新表 |
| `map` | **一元** `(map f list)` 与 **二元表** `(map f list1 list2)` |
| `for-each` | 同样一元与二元表；返回 `VOID` |
| `caar` `cadr` `cdar` `cddr` | 二层 `car`/`cdr` 组合，必须有 |
| `caaar` … `cdddr` | 三层组合，必须有（名字写到 `cdddr`） |
| `list-ref` | `(list-ref list k)`，`k` 为非负 fixnum |
| `assq` | `(assq obj alist)`，`eq?` 比 caar |
| `memq` | `(memq obj list)`，命中返回从该元素起的尾表，否则 `#f` |
| `number?` | **本层等于 `fixnum?`**（L53 前的别名） |
| `zero?` `positive?` `negative?` | 对 fixnum |
| `abs` | 即 `fxabs`：负数 `fxneg`，否则原值 |
| `min` `max` | **恰好两** 个 fixnum 参数 |
| `+` `-` `*` `=` `<` | 两参数，分别转发 `fx+` `fx-` `fx*` `fx=` `fx<`（合同 `_contract.md`） |

`not`、`boolean?`、`pair?`、`null?` 以及 L16/L17 的向量/字符串过程 **已经存在**：prelude 不要用同名 `define` 盖住 prim，除非你的前端只对「未绑定的调用」开 prim——本层锁定：**这些名字在操作符位置仍按 prim 编译**，prelude 不重定义。

本层范围之外：完整数值塔（无前缀 `+` 的可变 arity、bignum、有理数）；浮点；I/O 端口过程；`eval`；`apply` 已在 L34，不必重写；三列及以上 `map`/`for-each`；`assoc`/`member`（`equal?`）——尚未保证深比较库。`list-tail`、`append!` 不做。

## 原理

### 装载顺序（钉死）

```
runtime.c  （C：堆、打印、%append/%intern 若在 C）
    → 编译器把 prelude.scm 与用户程序 **编成一份** IR
    → emit 一份 program.s
    → 链接成一个可执行文件
```

没有模块系统。没有运行时 `load`（L45 才有）。本层 **每个** 用户程序都包一层 prelude。

推荐包装（prelude 过程互相递归用 `letrec`，L29 已有）：

```scheme
(letrec
  ((list (lambda xs xs))
   (length (lambda (xs) …))
   (append (lambda xss …))
   ;; … 其余绑定，右值里可以互相调用
   )
  USER-EXPR)
```

`USER-EXPR` 是原来的测例表达式。旧测例不引用这些名字，多一层 `letrec` 仍应返回同一值——回归靠这个。

另一种合格做法：prelude 编成独立的 `code` 标签，在 `scheme_entry` 里先跑一遍把闭包写进全局表。本层还没有 L45 的 `GLOBALS`，**不要**提前发明第三种环境。用 `letrec` 包装最省事。

文件：

```
compiler/prelude.scm     ; 仅库定义，不要顶层副作用
compiler/compile.scm     ; read prelude + wrap
```

`prelude.scm` 用本教程已有语法编写：`lambda`、`if`/`cond`、`let`、`begin`、`eq?`、`car`/`cdr`/`cons`、`null?`、`fx*` 比较、`%append`。不要在 prelude 里用 `define` 除非你按 L30 把它当内部 define 变换；顶层 `define` 留 L45。骨架用 `letrec` 绑定列表，与文件形式对应即可：编译器读入 `(begin (define …) …)` 再降成 `letrec` 也合格，但须在注释写死「仅编译器包装阶段，不是用户顶层 define」。

### 过程即闭包

库过程是 L26 闭包。`(map fxadd1 '(1 2))` 是普通 `call`。`fxadd1` 若仍是 prim，传给 `map` 会失败——**原语不是对象**。锁定：

- 作为操作符的 `(fxadd1 x)` 继续走 prim；
- 作为操作数的 `fxadd1` 必须是闭包。本层给 **每个需要当值传递的 prim** 包一层 eta：prelude 里 `(lambda (x) (fxadd1 x))` 仅用于测例需要的那些。不要自动把全部 prim 提升为闭包，除非你愿意维护一张表。测例用显式 `lambda` 或 prelude 提供的 `add1` **不强制**；测 `map` 时写 `(map (lambda (x) (fxadd1 x)) xs)`。

### 各过程语义

**`list`**：`(list)` → `()`；`(list 1 2 3)` → `(1 2 3)`。Rest 参数已经是表，函数体就是该表。

**`length`**：只接受 proper list。点对或环：**运行时错误**（可数到一个上限或 Floyd；本层最小是走到非 pair 且非 `()` 就 `rt_error`）。环可能导致无限递归——本层不强制检环（L44 才给打印检环）。测例只用 proper list。

**`append`**：

```
(append)           ⇒ ()
(append xs)        ⇒ xs   ; 不拷贝
(append xs ys)     ⇒ (%append xs ys)
(append xs ys zs)  ⇒ (%append xs (%append ys zs))
```

最后一参数可以不是表；前面的必须是 proper list（`%append` 已查）。n 元用 rest + 递归。

**`reverse`**：迭代累加器（`(cons (car xs) acc)`），一次线性、新序对。不要 `append` 每次加一个（平方）。

**`map` 一元**：

```scheme
(define (map1 f xs)
  (if (null? xs)
      '()
      (cons (f (car xs)) (map1 f (cdr xs)))))
```

**`map` 两表**：两表同时走，**以较短者为准停**（R4RS 要求各 list 长度相同，长度不同是错误）。本层锁定：长度不同 → **运行时错误**，不要静默截断。可用 `length` 先比，或走完发现一个先空另一个非空则报错。

```scheme
(define (map2 f xs ys)
  (cond
    ((and (null? xs) (null? ys)) '())
    ((or (null? xs) (null? ys)) (error "map length"))
    (else (cons (f (car xs) (car ys))
                (map2 f (cdr xs) (cdr ys))))))
```

对外 `map`：按参数个数分派。0 个 list 或 ≥3 个：**本层编译期不必查**（运行时 arity 走 L25/L33）。锁定用户可见 arity：`map` 用 rest，`(map f)` 无表 → 运行时错误；`(map f a b c)` → 运行时错误（范围之外的 3-list map 直接拒绝，不要悄悄只跑前两张表）。

**`for-each`**：同 `map` 的遍历与长度规则，但 `(begin (f …) (for-each …))`，最终 `VOID`。顺序从左到右，必须执行副作用。

**`cxr`**：纯组合。`cdddr` = `(cdr (cdr (cdr x)))`。错误与 `car`/`cdr` 对非 pair 的规则相同（L14）。

**`list-ref`**：`(list-ref xs 0)` = `(car xs)`。`k` 负或跑出表外 → 运行时错误。不要依赖 `fxsub1` 绕过 0。

**`assq`**：空表 → `#f`。每个元素须是 pair（`caar`），否则运行时错误。用 `eq?` 不是 `eqv?`（对立即数二者相同；对符号 L46 后必须是指针相等）。

**`memq`**：命中返回 **原表的尾**（共享），不是拷贝。

**算术别名**：两参数。`(min 2 9)` → `2`。不是 fixnum → 与 `fx<` 相同的类型错误路径（若 L08 未查类型，本层也不新加，测例只喂 fixnum）。`abs` 对 `most-negative-fixnum` 溢出：与 `fxneg` 相同，本层不额外规定。

**`number?`**：`(lambda (x) (fixnum? x))` 或前端把 `(number? e)` 改写成 `(fixnum? e)`。两种都行；测例对 `#t`、`()`、pair 为 `#f`，对 fixnum 为 `#t`。

### 手写 IR 选项

若 prelude 暂时不好编译（例如 `letrec` 绑一堆 lambda 触发你实现里的 bug），允许把每个库过程手写成 `(code …)` + `close`。必须与 Scheme 版语义相同，且一旦 prelude 通路修好就删掉双份。文档注释写「正在用 hand IR」。合格标准是测例，不是源是否漂亮。

## 与上一层的差异

- 第一次有 **用户级过程库**，不是新语法。
- 每个程序多一层 `letrec`（或等价）包装；`scheme_entry` 的主 IR 变成「先关包再跑用户表达式」。
- `append` 对用户可见；L41 模板展开仍可直接 `%append`。
- `+` 等无 `fx` 前缀的名字出现，但 **只有两参数、只吃 fixnum**。旧测例继续写 `fx+`，不要改 L07 测例文件。
- intern/符号打印沿用 L41；本层不改标签。

## 代码骨架

### `compiler/prelude.scm`（装进 `letrec` 或顶层 `define` 的绑定）

```scheme
;; 以下作为 letrec 绑定的右值来读。名字在左栏。

list (lambda xs xs)

length
(lambda (xs)
  (letrec ((loop (lambda (ys n)
                   (cond
                     ((null? ys) n)
                     ((pair? ys) (loop (cdr ys) (fxadd1 n)))
                     (else (%error "length"))))))
    (loop xs 0)))

append
(lambda xss
  (cond
    ((null? xss) '())
    ((null? (cdr xss)) (car xss))
    (else (%append (car xss) (apply append (cdr xss))))))

reverse
(lambda (xs)
  (letrec ((loop (lambda (in acc)
                   (if (null? in)
                       acc
                       (loop (cdr in) (cons (car in) acc))))))
    (loop xs '())))

map
(lambda (f . lists)
  (cond
    ((null? lists) (%error "map"))
    ((null? (cdr lists)) (map1 f (car lists)))
    ((null? (cddr lists)) (map2 f (car lists) (cadr lists)))
    (else (%error "map"))))

for-each
(lambda (f . lists)
  (cond
    ((null? lists) (%error "for-each"))
    ((null? (cdr lists)) (for-each1 f (car lists)))
    ((null? (cddr lists)) (for-each2 f (car lists) (cadr lists)))
    (else (%error "for-each"))))
```

`map1`/`map2`/`for-each1`/`for-each2` 放在同一 `letrec` 里，或写成内部 `letrec`。`%error` 是对 `rt_error` 的薄 prim（若还没有：加 `(prim %error)` → `emit-c-call rt_error`；参数可忽略或传 string）。`apply` 来自 L34：`append` 的 n 元递归用得上。若不想在 prelude 用 `apply`，改写成显式递归吃 rest 表：

```scheme
(define (append-lists xss)
  (cond
    ((null? xss) '())
    ((null? (cdr xss)) (car xss))
    (else (%append (car xss) (append-lists (cdr xss))))))
```

`assq` / `memq` / `list-ref`：

```scheme
assq
(lambda (obj alist)
  (cond
    ((null? alist) #f)
    ((eq? (caar alist) obj) (car alist))
    (else (assq obj (cdr alist)))))

memq
(lambda (obj xs)
  (cond
    ((null? xs) #f)
    ((eq? (car xs) obj) xs)
    (else (memq obj (cdr xs)))))

list-ref
(lambda (xs k)
  (if (fx= k 0)
      (car xs)
      (list-ref (cdr xs) (fxsub1 k))))

zero?     (lambda (n) (fx= n 0))
positive? (lambda (n) (fx> n 0))
negative? (lambda (n) (fx< n 0))
abs       (lambda (n) (if (fx< n 0) (fxneg n) n))
min       (lambda (a b) (if (fx< a b) a b))
max       (lambda (a b) (if (fx< b a) a b))
number?   (lambda (x) (fixnum? x))
+         (lambda (a b) (fx+ a b))
-         (lambda (a b) (fx- a b))
*         (lambda (a b) (fx* a b))
=         (lambda (a b) (fx= a b))
<         (lambda (a b) (fx< a b))
```

```scheme
caar  (lambda (x) (car (car x)))
cadr  (lambda (x) (car (cdr x)))
cdar  (lambda (x) (cdr (car x)))
cddr  (lambda (x) (cdr (cdr x)))
caaar (lambda (x) (car (car (car x))))
caadr (lambda (x) (car (car (cdr x))))
cadar (lambda (x) (car (cdr (car x))))
caddr (lambda (x) (car (cdr (cdr x))))
cdaar (lambda (x) (cdr (car (car x))))
cdadr (lambda (x) (cdr (car (cdr x))))
cddar (lambda (x) (cdr (cdr (car x))))
cdddr (lambda (x) (cdr (cdr (cdr x))))
```

四层 `cxxxxr` 范围之外。

### 编译器包装

```scheme
(define (wrap-with-prelude user-expr)
  (list 'letrec prelude-bindings user-expr))

(define (compile-program expr)
  (emit-program (expr->ir (expand (wrap-with-prelude expr)))))
```

`prelude-bindings` 可以是宿主里的常量列表，或读 `prelude.scm` 再转换。读文件时 **本层仍可用宿主 `read`**（L43 才换自研 reader）。

### aarch64-apple

无新指令模式。若新增 `%error`：`bl _rt_error`。闭包数量变多：注意 `scheme_entry` 堆 64MiB 仍够。prelude 的 `letrec` 会分配一串闭包——`HP` 必须已在 L12 方式初始化，否则一跑 prelude 就写空指针。

## 测例清单

上一层全部测例仍须通过。

1. `(list)` → `()`
2. `(list 1 2 3)` → `(1 2 3)`
3. `(length '())` → `0`
4. `(length '(1 2 3))` → `3`
5. `(append)` → `()`
6. `(append '(1 2) '(3 4))` → `(1 2 3 4)`
7. `(append '(1) '(2) '(3))` → `(1 2 3)`
8. `(append '(1 2) 3)` → `(1 2 . 3)`（最后一参数非表）
9. `(reverse '())` → `()`
10. `(reverse '(1 2 3))` → `(3 2 1)`
11. `(map (lambda (x) (fxadd1 x)) '(1 2 3))` → `(2 3 4)`
12. `(map (lambda (x y) (fx+ x y)) '(1 2 3) '(10 20 30))` → `(11 22 33)`
13. `(let ((xs '(1 2))) (begin (for-each (lambda (x) (set-car! xs x)) '(9)) xs))` → `(9 2)`（`for-each` 执行了副作用；返回值被 `begin` 丢掉）
14. 更干净的 `for-each` 返回值：`(for-each (lambda (x) x) '(1 2))` → `#<void>`
15. `(caar '((1 . 2) . 3))` → `1`
16. `(cadr '(1 2 3))` → `2`
17. `(caddr '(1 2 3 4))` → `3`
18. `(cdddr '(1 2 3 4))` → `(4)`
19. `(list-ref '(a b c) 0)` → `a`（符号打印为 `a`）
20. `(list-ref '(a b c) 2)` → `c`
21. `(assq 2 '((1 . a) (2 . b) (3 . c)))` → `(2 . b)`
22. `(assq 9 '((1 . a)))` → `#f`
23. `(memq 2 '(1 2 3))` → `(2 3)`
24. `(memq 9 '(1 2 3))` → `#f`
25. `(number? 3)` → `#t`
26. `(number? #t)` → `#f`
27. `(zero? 0)` → `#t`
28. `(zero? 1)` → `#f`
29. `(positive? 3)` → `#t`
30. `(negative? (fxneg 2))` → `#t`
31. `(negative? 0)` → `#f`
32. `(abs (fxneg 5))` → `5`
33. `(abs 5)` → `5`
34. `(min 3 8)` → `3`
35. `(max 3 8)` → `8`
36. `(+ 2 3)` → `5`
37. `(* 2 3)` → `6`
38. `(= 4 4)` → `#t`
39. `(< 4 1)` → `#f`
40. `(map (lambda (x y) x) '(1) '(1 2))`：运行时错误。
41. `(list-ref '(1) 3)`：运行时错误。
42. `(let ((xs '(1 2))) (eq? (memq 1 xs) xs))` → `#t`

## 验收标准

- 测例 1–39、42 退出码 0，标准输出与期望字节级一致。
- 40、41 非零退出，stderr 含 `map` 或 `list-ref` 或通用 `error`。
- 旧层测例在包装 prelude 之后 **仍绿**（`letrec` 不改变无自由变量的立即数程序结果）。
- `append` 与 `` `(,@xs ,@ys) `` 对相同 proper list 得到 `equal?` 的结构（可用测例 6 对照 L41 测例 8）。
- 没有把 `map` 做成只支持一元却让两表测例假绿（例如忽略第二表）。
- `number?` 对字符、布尔、空表、pair 为 `#f`。

## 常见坑

- **prim 当值**：`(map fxadd1 xs)` 编译期「未知变量」或把 `fxadd1` 当调用。测例一律 `lambda` 包一层。
- **`append` 用 `apply` 而 L34 对「最后一参数不是表」处理错**：`append` 的 rest 已经是表，`(apply append (cdr xss))` 的最后一个元素才是下一份 list，不是 rest 本身。写成 `(apply append (cdr xss))` 当 `xss='((1) (2) (3))` 时等于 `(append '(2) '(3))`，正确。
- **`for-each` 返回最后一次 `f` 的值**：必须 `VOID`。
- **`map` 两表静默截短**：R4RS 不同长度是错误；测例 40。
- **`reverse` 用 `append`**：复杂度与栈都会痛，长表测例才暴露——本层至少用累加器。
- **prelude `define` 被当成用户顶层**：本层还没有全局环境，内部 define 必须变成 `letrec`。
- **包装 `letrec` 捕获了用户 `lambda` 的自由变量名字**：prelude 绑定名（`list`、`map`…）会影子用户同名绑定。R4RS 里这些是标准过程，影子是预期的。用户 `(let ((list 1)) list)` 仍应得到 `1`（内层 let），测一下防止你把 prelude 塞进动态作用域。
- **`min`/`max`/`+` 做成 rest 可变 arity**：合同是两参数，L53 再谈。多余参数走 arity 错误即可。

## 下一层预告

L43 要丢掉「测试驱动靠宿主 `read` 喂 s-expression」这条捷径，做出 **自己的 reader**：从端口读 datum。
