# L47 — 非卫生 `define-macro`（可选垫脚石）

## 目标

加入 **`define-macro`**（defmacro 风格）：在 **编译期、自托管 Scheme 编译器** 上跑转换器，得到新的 s-expression，再交给已有的 `expand`/`compile`。这不是 R4RS 宏（R4RS 是 `syntax-rules`），而是一层故意不卫生的垫脚石，用来：

- 让你看清「宏 = 编译期函数，吃源形式，吐源形式」；
- 可选地把 L40 的 `cond`/`case` 改写成宏（核心形式仍只有 `if`/`let`/`begin`）；
- 用一个 **let 捕获** 测例证明它是错的——L49 卫生将修这个问题。

锁定：转换器是 **自托管编译器里的过程**（本教程 Scheme 子集，不是 Chez / Python）。对 `(define-macro (name . formals) body …)` 在编译器里 `eval`（或手工 `apply` 构造的 `lambda`）得到 `proc`，存进编译器的宏表。展开 `(name arg …)` 时执行 `(apply proc (cdr form))`——即 **参数是源形式的 `cdr`**，返回新形式，然后 **再 expand**。

本层范围之外：卫生、`syntax-rules`、`syntax-case`、相、标识符对象、宏在目标机上运行、运行时 `eval`、把转换器编译进用户程序。R4RS 没有 `define-macro`；本层结束后用户代码若依赖它，L48 起应以 `syntax-rules` 重写，`define-macro` 可保留给编译器自己。

## 原理

### 为何在自托管编译器上跑

目标机用户程序还没有完整 `eval`。转换器若跑在用户程序里，你得先把宏展开器编译进去并在编译期解释它——循环依赖。自托管编译器已经能 `lambda`、`cons`、quasiquote。锁定在编译器里执行。不要为此引入 Chez / Python。

代价：宏 body 是 **编译器所用的 Scheme 子集**，不是任意外部实现。纪律：宏只把列表拆开再拼起来，不要打开文件。测例只使用 `cons`/`car`/`cdr`/`list`/`if` 与 quasiquote。

### 语法

顶层（与 `define` 相同的 splicing 位置）：

```scheme
(define-macro (name p1 p2 . rest)
  body1
  body2)    ; 最后一个表达式的值是「新形式」
```

等价于编译器里：

```scheme
(define name
  (lambda (p1 p2 . rest)
    body1
    body2))
```

然后 `(name-macro (cdr use-form))`。

也允许：

```scheme
(define-macro (when test . body)
  `(if ,test (begin ,@body) #f))
```

`(when (fx> x 0) (fxadd1 x))` → 转换器收到 `test=(fx> x 0)`，`body=((fxadd1 x))`，返回 `(if (fx> x 0) (begin (fxadd1 x)) #f)`。

无参数：`(define-macro (nil) '())` 然后 `(nil)` 的 `cdr` 为 `()`，`apply` 零个参数。

非法：表达式位置的 `define-macro`（编译期错误）；`(define-macro name proc)` 第二参数已是过程对象——本层 **不支持** 这种两参数形式（过程对象不能出现在源文件里）。一律用 `(define-macro (name . formals) . body)`。

宏表：

```scheme
(define *macros* '()) ; alist: name -> compiler procedure

(define (lookup-macro name)
  (let ((p (assq name *macros*)))
    (and p (cdr p))))
```

`define-macro` 覆盖同名宏。若名字同时是 prim，锁定：**宏优先**（否则无法用宏影子测试）。prelude 的全局过程仍是运行时绑定；expand 在认宏之后才认 prim 调用。

### expand 规则

```
expand(form):
  if pair and car is symbol and lookup-macro(car):
       new := apply(proc, cdr(form))   ; 编译器调用
       return expand(new)              ; 再展开，支持宏返回宏调用
  else: 按 L40–L45 的特殊形式与递归
```

防止无限展开：可选深度上限（例如 256），超限编译期错误。测例不要写无递归基的宏。

`quote` 内不展开。`quasiquote` 按 L41，不要把模板里的 `(when …)` 当宏——那是数据。`define-macro` 自己的 body 是编译器代码：**不要**用目标机 expand 走一遍 body（`eval` 前也不要目标机 `qq`，除非你故意用目标展开器预处理；锁定：body 原样交给编译器 `eval`）。

编译器 `eval` 的环境：本教程 Scheme 子集。把 `body` 包成：

```scheme
(eval `(lambda ,formals ,@body) (scheme-report-environment 5))
```

若还不想依赖完整 `eval`：手写一个 **只含 lambda/if/cons/car/cdr/quote/quasiquote** 的迷你解释器。不要用 Chez / Guile / Racket / Python 当前端。

### 为什么不卫生（给 L49 看的反例）

```scheme
(define-macro (or2 a b)
  `(let ((t ,a))
     (if t t ,b)))

(let ((t 1))
  (or2 #f t))
```

展开：

```scheme
(let ((t 1))
  (let ((t #f))
    (if t t t)))
```

内层 `t` 把外层 `t` 影子掉，结果是 `#f`，不是 `1`。插入的绑定 **捕获** 了用户代码里的同名变量。卫生宏会把插入的 `t` 改成看不见的标识符。本层 **锁定测例期望为 `#f`**：系统必须表现出捕获，而不是「碰巧 gensym 了」。因此 **`define-macro` 展开插入的名字就是源里写的那些符号**，不要在这一层偷偷 `gensym` 把测例变绿——那是 L48/L49 的工作。

对比 L40 编译器自己展开 `cond` 时用的 `gentemp`：那是编译器实现细节，用户不写那些名字。用户宏没有 gensym 就必然捕获。

### 可选：用宏实现 `cond`

不强制删除 L40 的手写展开。若改写：

```scheme
(define-macro (cond . clauses)
  (if (null? clauses)
      '(%void)
      (let ((cl (car clauses)) (rest (cdr clauses)))
        (if (eq? (car cl) 'else)
            (cons 'begin (cdr cl))
            ; … 与 L40 相同，插入的 let 临时名若叫 t 则用户可捕获
            ))))
```

一旦改成宏，L40 的「临时名不得撞用户 `t`」测例可能变红——那是非卫生的代价。锁定：

- **默认**：L40 手写 expand **保留**；`define-macro` 是额外能力。
- **若** 你把 `cond` 改成宏：须用编译器 `gensym` 当临时名，才能继续通过 L40 回归；这 **不是** 卫生（用户代码里的标识符仍不带相），只是编译器宏作者自己避开撞名。在注释里写清。捕获测例仍用 `or2` 这种 **用户宏**，不要 gensym。

### 与 `load` / 顶层顺序

`define-macro` 必须在使用之前于 **expand 期** 登记。文件顺序：

```scheme
(define-macro (when test . body) `(if ,test (begin ,@body) #f))
(when #t 1)
```

合法。反过来先 `when` 再 `define-macro` → 编译期「未知宏/当全局调用」：`when` 会被当成运行时全局，通常 unbound。锁定：**宏必须先定义再使用**（同一文件从左到右 expand）。`load` 的文件里的 `define-macro` 在 splicing 点立即生效，后续 form 可见。

宏不进入 `x24`。运行时没有 `when` 过程，除非你另 `define`。

## 与上一层的差异

- 编译器多一张宏表；顶层多一种 form。
- 展开循环：宏 → 新形式 → 再 expand。
- 第一次允许用户「生成代码的代码」；故意不卫生。
- 目标机 runtime、IR、标签、`x24` 不变。

## 代码骨架

```scheme
(define *macros* '())

(define (install-macro name proc)
  (set! *macros* (cons (cons name proc) *macros*)))

(define (eval-transformer formals body)
  (eval (cons 'lambda (cons formals body))
        (scheme-report-environment 5)))

(define (expand-toplevel-form f)
  (cond
    ((and (pair? f) (eq? (car f) 'define-macro))
     (let ((spec (cadr f)) (body (cddr f)))
       (install-macro (car spec)
                      (eval-transformer (cdr spec) body))
       '(%void))) ; 顶层 define-macro 结果 VOID，可从序列里丢掉
    (else (expand-expr f))))

(define (expand-expr expr)
  (cond
    ((and (pair? expr)
          (symbol? (car expr))
          (lookup-macro (car expr)))
     (expand-expr (apply (lookup-macro (car expr)) (cdr expr))))
    ((and (pair? expr) (eq? (car expr) 'quote)) expr)
    ((and (pair? expr) (eq? (car expr) 'if))
     (list 'if (expand-expr (cadr expr))
           (expand-expr (caddr expr))
           (expand-expr (cadddr expr))))
    ; let / begin / lambda / quasiquote / call：递归 expand-expr
    ((pair? expr) (map expand-expr expr))
    (else expr)))
```

`apply` 宏过程时 **不要** 先 `expand` 参数：宏收到的是 **未展开的源**（传统 Lisp 宏）。返回后再 expand。这样 `` `(if ,test …) `` 里的 `test` 仍是用户写的那个表达式树。

特殊形式优先还是宏优先：若用户 `(define-macro (if …) …)` 会毁掉语言。锁定：**核心形式 `if` `lambda` `let` `begin` `quote` `set!` `define` 不可被宏覆盖**。先看核心，再看宏，再看调用。`cond`/`case`/`and`/`or` 若仍是前端展开而不是宏，也视为核心派生，宏不能覆盖它们——除非你已把它们改成宏并允许覆盖。锁定列表写进 `core-form?`。

## 测例清单

上一层全部测例仍须通过。

1. 恒等宏：

    ```scheme
    (define-macro (id x) x)
    (id 3)
    ```

    → `3`
2. `when`：

    ```scheme
    (define-macro (when test . body)
      `(if ,test (begin ,@body) #f))
    (when #t 1 2)
    ```

    → `2`
3. `when` 为假：`(when #f 1)` 接在同一宏定义后 → `#f`（上面 `when` 的 else 是 `#f` 不是 VOID）
4. 宏返回的形式再展开：

    ```scheme
    (define-macro (id x) x)
    (define-macro (twice x) `(id ,x))
    (twice 9)
    ```

    → `9`
5. 算术：

    ```scheme
    (define-macro (sq x) `(fx* ,x ,x))
    (sq 4)
    ```

    → `16`（注意：`x` 求值两次；本层接受）
6. 捕获（非卫生，期望「错」的答案）：

    ```scheme
    (define-macro (or2 a b)
      `(let ((t ,a))
         (if t t ,b)))
    (let ((t 1))
      (or2 #f t))
    ```

    → `#f`  
    （卫生的 `or` 应变为 `1`。L49 用本例对照。）
7. 无捕获时 `or2` 仍可用：

    ```scheme
    (define-macro (or2 a b)
      `(let ((t ,a))
         (if t t ,b)))
    (or2 #f 3)
    ```

    → `3`
8. `load` 文件里的宏：`008-mac.scm` 含 `when` 的 `define-macro`，主文件 load 后 `(when #t 6)` → `6`
9. 顶层顺序错误：`(when #t 1) (define-macro (when test . body) test)` → 编译期或运行时失败。锁定 **编译期错误** 若 `when` 不是全局过程；若被当成 `%global-ref` 则运行时 unbound。本号期望：**非 0 退出**，stderr 含 `when` 或 `unbound` 或 `macro`。不要静默当 `#<void>`。
10. 表达式位置 `(+ 1 (define-macro (m) 1))`：编译期错误。
11. 核心 `if` 不被宏覆盖：

    ```scheme
    (define-macro (if a b c) 0)
    (if #t 1 2)
    ```

    → `1`（仍是核心 `if`）
12. `quote` 不展开宏：

    ```scheme
    (define-macro (when test . body) 0)
    (quote (when #t 1))
    ```

    → `(when #t 1)`
13. 递归宏有基：

    ```scheme
    (define-macro (nand a b)
      `(not (if ,a ,b #f)))
    (nand #t #t)
    ```

    → `#f`
14. 宏与全局 define 同文件：

    ```scheme
    (define-macro (call1 f) `(,f 1))
    (define (inc x) (fxadd1 x))
    (call1 inc)
    ```

    → `2`
15. `(define-macro (m x))` 无 body：编译期错误。
16. 无限展开防护（可选但本层要求上限）：

    ```scheme
    (define-macro (loop) '(loop))
    (loop)
    ```

    → 编译期错误（深度上限），不要让编译器卡死。

## 验收标准

- 测例 1–8、11–14 退出码 0，输出匹配；其中 **6 必须是 `#f`**，不得 gensym 成 `#t`/`1`。
- 9、10、15、16 失败路径如上述。
- 上一层（含 `load`、intern、`write`）全部仍绿。
- 目标机生成代码里没有「宏转换器闭包」——转换只发生在自托管编译器里。反汇编 / 读 IR：`when` 测例应只剩 `if`/`begin`。
- 文档或注释用测例 6 的展开树说明捕获；不要写「以后再解释」。

## 常见坑

- **先 expand 参数再交给宏**：`(sq (fxadd1 3))` 若先展开参数还好；若宏要看「用户写了什么形式」就丢信息。本层锁定不预展开。
- **宏返回字符串或 fixnum 当代码**：`(define-macro (m) 3)` 然后 `(m)` 合法（返回表达式 `3`）。返回编译器内部过程对象则 `expr->ir` 崩溃——编译期错误即可。
- **用目标机 `eval` 跑宏**：没有这条原语。
- **偷偷 gensym 让测例 6 变 `1`**：破坏本层教学目标。
- **`define-macro` 写进 `x24`**：运行时 `(when …)` 会去调全局，宏已展开则不应留下 `when` 调用。若忘记再 expand，IR 里会出现对 `when` 的 `call`。
- **编译器 quasiquote 与目标 L41 混淆**：宏 body 在编译器 `eval`，用的是本教程（或展开器）的 `` ` ``，不经过用户程序的 `qq`。这是对的。
- **覆盖 `if`**：测例 11；先匹配核心形式。
- **不要用 Python `eval` 当宏展开器**：本仓库禁止 Python。宏只在自托管编译器里跑。

## 下一层预告

L48 开始做 R4RS 真正的宏系统：**`syntax-rules`**——用模式匹配生成代码，而不再把源形式交给随便一个编译器过程。
