# L54 — R4RS 库缺口清单与强制填料

## 目标

本层主要是一张 **对照表**：R4RS 的必要语法与标准过程，每一项标成「已有层号 / 本层补 / 明确不做」。不声称补完后 100% 符合（那是 L55 的布尔清单）。强制在本层用 prelude / 少量 runtime **补上**这些，并写测例：

- **named let**
- **`do`**
- **`delay` / `force`**
- **`substring` `string-append` `string->list` `list->string`**
- **`quotient` `remainder` `modulo`**（fixnum 与 bignum）
- **`char-ci=?` 等 char-ci 族：可选**（做了就写测例；不做则表里标「明确不做」）

I/O：不要因为有 `load` 和 `current-input-port` 就在表里勾「完整端口」。没有的 `open-output-file` / `transcript-on` 标「明确不做」或「近似」。

本层范围之外：新 IR 节点（填料展开成已有核心形式）、新堆标签、浮点、`eval` 的环境参数、完整文件端口。

## 原理

### 怎么读这张表

三列含义：

| 标记 | 含义 |
|------|------|
| 已有 Lxx | 该层测例已覆盖用户可见语义；本层不必再实现 |
| 本层补 | 你必须在本层 prelude 或 C 里写出，并过本层对应测例 |
| 明确不做 | 教程结束也不强制；L55 报告缺口时照抄 |

「近似」：有一部分行为，但缺参数或缺错误检查。表中写清缺什么。

R4RS 没有 `syntax-rules`（那是 R5RS）。本教程 L48–L50 是额外能力，表中单独一行「非 R4RS」。

### 语法（R4RS §4）

| 形式 | 状态 |
|------|------|
| `lambda` | 已有 L24–L33 |
| `if` | 已有 L10 |
| `quote` | 已有 L41 前应已有 quote；字面量与 `quote` 在 L13/L41/L43 |
| `set!` | 已有 L23 |
| `begin` | 已有 L22 |
| `cond` | 已有 L40，L50 用 syntax-rules 覆盖；**无 `=>`**（L50 明确不做） |
| `case` | 已有 L40（手写展开即可） |
| `and` `or` | 已有 L11，L50 覆盖 |
| `let` | 已有 L19–L20 |
| `let*` | 已有 L21 |
| `letrec` | 已有 L28–L29 |
| **named let** | **本层补** |
| **`do`** | **本层补** |
| **`delay`** | **本层补**（与 `force` 成对） |
| `quasiquote` | 已有 L41 |
| `define` 内部 | 已有 L30 |
| `define` 顶层 | 已有过程层起 |
| `=>` 在 cond | 明确不做 |
| `let-syntax` | 明确不做 |

### 6.1 布尔

| 过程 | 状态 |
|------|------|
| `not` `boolean?` | 已有 L05–L06 |

### 6.2 等价

| 过程 | 状态 |
|------|------|
| `eq?` `eqv?` | 已有 L09，堆对象后指针相等；bignum **不要**用 `eq?` 比数值（用 `=`） |
| `equal?` | L42 未强制 `member`/`assoc` 时可能没有。L55 测例 2b 用 `equal?`：**本层补** 递归 `equal?`（pair 比 car/cdr，vector 逐元，string 逐字符，数字用 `=`，其余 `eq?`） |

### 6.3 对与表

| 过程 | 状态 |
|------|------|
| `pair?` `cons` `car` `cdr` `set-car!` `set-cdr!` | 已有 L13–L15 |
| `caar`…`cddddr` | 已有 L42（到 `cdddr`/`cddddr` 以 L42 表为准） |
| `null?` `list?` `list` `length` `append` `reverse` | `null?` L05；`list`/`length`/`append`/`reverse` 已有 L42。`list?` 缺则 **明确不做**（L42 未强制） |
| `list-tail` `list-ref` | `list-ref` 已有 L42；`list-tail` 明确不做 |
| `memq` `memv` `member` `assq` `assv` `assoc` | `memq` `assq` 已有 L42；`memv`/`member`/`assv`/`assoc` 明确不做 |

### 6.4 符号

| 过程 | 状态 |
|------|------|
| `symbol?` `symbol->string` `string->symbol` | 已有 L46 |

### 6.5 数

| 过程 | 状态 |
|------|------|
| `number?` `integer?` | 已有 L53（两者同义） |
| `complex?` `real?` `rational?` | 明确不做（或若你把它们做成 `number?` 别名，标近似：无复数） |
| `exact?` | **本层补**：fixnum 与 bignum → `#t`；其它 → `#f` |
| `inexact?` | **本层补**：恒 `#f`（无 inexact） |
| `=` `<` `>` `<=` `>=` | `=` `<` 已有 L53（可变 arity 的 `=`/`<` 以 L53 为准）；`>` `<=` `>=` **本层补** prelude |
| `zero?` `positive?` `negative?` | 已有 L42（fixnum）；对 bignum **本层补** 转发到 `<`/`=`/`>` |
| `odd?` `even?` | **本层补**（`remainder`/`modulo` 之后） |
| `max` `min` | 已有 L42 恰好两参数；可变 arity 明确不做 |
| `+` `*` `-` | 已有 L53 |
| `/` | 明确不做（L53） |
| `abs` | 已有 L42（fixnum）；bignum **本层补** |
| **`quotient` `remainder` `modulo`** | **本层补**（C，支持 bignum） |
| `gcd` `lcm` | 明确不做（可用 Euclidean 做；不做则表已写清） |
| `numerator` `denominator` | 明确不做 |
| `floor` `ceiling` `truncate` `round` | 明确不做（无非整数） |
| `rationalize` 超越函数 `expt` `sqrt` | 明确不做 |
| `exact->inexact` `inexact->exact` | 明确不做 |
| `number->string` `string->number` | 近似：L44/`write` 可打数字；完整 radix 明确不做。**本层不强制** |

### 6.6 字符

| 过程 | 状态 |
|------|------|
| `char?` `char=?` `char<?` 及 `>` `<=` `>=` | `char?` L04/L05；比较 **本层补** 或 L42。锁定 **本层补 `char=?` `char<?`** |
| `char-ci=?` 及 ci 不等式 | **可选**。做则测例 14；不做写明确不做 |
| `char-alphabetic?` `char-numeric?` `char-whitespace?` `char-upper-case?` `char-lower-case?` | 明确不做 |
| `char->integer` `integer->char` | 已有 L06 的 `char->fixnum`/`fixnum->char` 或 R4RS 名。若只有 `fx` 名：**本层补别名** |
| `char-upcase` `char-downcase` | 明确不做（除非做了 char-ci 需要它们；ci 可用 `| 0x20` 仅 ASCII） |

### 6.7 字符串

| 过程 | 状态 |
|------|------|
| `string?` `make-string` `string-length` `string-ref` `string-set!` | 已有 L17 |
| `string`（字符序列造串） | L42 或 **本层补** |
| `string=?` 及序比较 | L42 或 **本层补 `string=?`** |
| `string-ci=?` 等 | 随 char-ci 可选 |
| **`substring` `string-append` `string->list` `list->string`** | **本层补** |
| `string-copy` `string-fill!` | 明确不做（`string-copy` 可用 substring 全长近似；不强制） |

### 6.8 向量

| 过程 | 状态 |
|------|------|
| `vector?` `make-vector` `vector-ref` `vector-set!` `vector-length` | 已有 L16；L53 收紧 `vector?` |
| `vector` `vector->list` `list->vector` `vector-fill!` | L42 或本层不强制；缺则明确不做 |

### 6.9 控制

| 过程 | 状态 |
|------|------|
| `procedure?` | 已有 L24 后 |
| `apply` | 已有 L34 |
| `map` `for-each` | 已有 L42（一元与二元表；`for-each` 返回 void） |
| **`force`** | **本层补**（配 `delay`） |
| `call-with-current-continuation` | 已有 L37（别名 `call/cc`） |

### 6.10 I/O

| 过程 | 状态 |
|------|------|
| `call-with-input-file` `call-with-output-file` | 明确不做 |
| `input-port?` `output-port?` | 明确不做 |
| `current-input-port` `current-output-port` | 近似：L43/L44 可能有「当前端口」全局；无则明确不做。锁定：**不强制完整端口对象** |
| `with-input-from-file` `with-output-to-file` | 明确不做 |
| `open-input-file` `open-output-file` `close-*-port` | 明确不做（`load` 内部开文件不算用户 API） |
| `read` | 已有 L43（读当前输入或 `load`） |
| `read-char` `peek-char` `char-ready?` | 明确不做 |
| `eof-object?` | 已有 L43 |
| `write` `display` `newline` | 已有 L44 |
| `write-char` | 明确不做 |
| `load` | 已有 L45 |
| `transcript-on` `transcript-off` | **明确不做**（R4RS 特有、极少实现） |
| `eval` | **明确不做**（R4RS 无标准 `eval`；R5RS 才有）。测例禁止声称支持 |

### 其它本教程有而 R4RS 无

| 项 | 状态 |
|------|------|
| `syntax-rules` / `define-syntax` | 额外；L48–L50 |
| `define-macro` | 额外；L47 |
| `values` `call-with-values` | R5RS；已有 L35，保留 |
| `%gc` | 测试原语，非 R4RS |
| bignum | R4RS 要求精确整数任意范围的「意图」；我们用 L53 逼近 |

### 强制填料语义

### named let

```
(let <name> ((id init) ...) body ...)
 ≡ ((letrec ((<name> (lambda (id ...) body ...)))
      <name>)
    init ...)
```

展开后走已有 `letrec`+调用。`name` 在 body 可见，在 `init` 不可见。

### `do`

R4RS：

```
(do ((var init step) ...)
    (test expr ...)
    command ...)
```

`step` 缺省为 `var`。语义展开成 named let 或 `letrec` 循环：先绑 `init`，若 `test` 真则 `begin expr ...`（无 expr 则未指定，锁定 **void**），否则 `begin command ...` 再以 `step`  recurs。

### `delay` / `force`

```
(delay exp) → promise 对象
(force p)   → 求值一次，缓存
```

promise 用 **box 里放 thunk 或已缓存值**。表示锁定：

```
promise = box of (cons 'lazy  thunk) | (cons 'done value)
```

`delay` 是宏：`(delay e)` → `(%box (cons 'lazy (lambda () e)))`。`force` 是过程：若 `'lazy` 则调用 thunk，`set-car!`/`set-cdr!` 成 `'done` 与值（注意 thunk 里再 `force` 自己：先把状态改成 in-progress 或允许 R4RS 未指定；锁定 **先写入 `'done` 占位再调用** 会死循环时油尽——更简单：调用前保持 lazy，结束后写入；自 force 未指定，测例不写。）

`promise?` 非 R4RS，不提供。

### 字符串填料

均对可变 string，索引 fixnum，越界运行时错误。

- `substring s start end`：新串，含 `start` 不含 `end`。
- `string-append` 可变 arity，零个 → `""`。
- `string->list` / `list->string`：字符表。

可用 Scheme 循环 + `string-ref`/`string-set!`，不必新 C。

### `quotient` `remainder` `modulo`

对整数（fixnum 或 bignum）。C 实现，与 R4RS：

- `quotient` 向 0 截断。
- `remainder` 满足 `n = q*d + r` 且 `r` 与 `n` 同号（或 0）。
- `modulo` 的 `r` 与 `d` 同号（或 0）。

除零：运行时错误。非整数：错误。

bignum 除法：长除 32-bit digits；结果 `normalize`。

## 与上一层的差异

- 无新标签、无新 GC 种类（promise 用已有 box+pair+closure）。
- prelude 显著变长；`do`/`named let`/`delay` 是宏（syntax-rules 或手写展开，二者合格）。
- 表中「明确不做」的过程若用户代码调用 → 编译期 unknown 或运行时 error，不要静默成 `#f`。

## 代码骨架

### named let 与 do（展开器或 syntax-rules）

```scheme
(define-syntax let
  (syntax-rules ()
    ((let ((n v) ...) e0 e1 ...)
     ((lambda (n ...) e0 e1 ...) v ...))
    ((let tag ((n v) ...) e0 e1 ...)
     ((letrec ((tag (lambda (n ...) e0 e1 ...)))
        tag)
      v ...))))
```

注意：这会覆盖核心 `let`。expand 必须先认 syntax-rules `let`，其模板里的 `lambda`/`letrec` 解析到 **核心绑定**（L48 def-env），否则无穷展开。若怕覆盖，手写：看第二项是标识符则走 named 分支，否则走 L20。

```scheme
(define-syntax do
  (syntax-rules ()
    ((do ((var init step ...) ...)
         (test expr ...)
         command ...)
     (letrec
         ((loop (lambda (var ...)
                  (if test
                      (begin expr ...)
                      (begin command ...
                             (loop (do-step var step ...) ...))))))
       (loop init ...)))))
```

`do-step`：`step` 空则用 `var`。syntax-rules 里用两规则：

```scheme
(define-syntax do
  (syntax-rules ()
    ((do ((var init) ...) (test expr ...) command ...)
     (do ((var init var) ...) (test expr ...) command ...))
    ((do ((var init step) ...) (test expr ...) command ...)
     (letrec ((loop (lambda (var ...)
                      (if test
                          (begin #f expr ...)
                          (begin command ... (loop step ...))))))
       (loop init ...)))))
```

无 `expr` 时 `begin` 只有 `#f` 占位不好；改成核心 void。骨架：`(if test (begin (if #f #f) expr ...) …)` 仍丑。锁定：无 `expr` 则 then 枝为 `(%void)` 或已有 void 立即数。

### delay / force

```scheme
(define-syntax delay
  (syntax-rules ()
    ((delay e)
     (%box (cons 'lazy (lambda () e))))))

(define (force p)
  (let ((c (%unbox p)))
    (if (eq? (car c) 'done)
        (cdr c)
        (let ((v ((cdr c))))
          (%set-box! p (cons 'done v))
          v))))
```

### 字符串

```scheme
(define (substring s start end)
  (let ((n (- end start)))
    (let ((out (make-string n #\nul)))
      (letrec ((lp (lambda (i)
                     (if (= i n)
                         out
                         (begin
                           (string-set! out i (string-ref s (+ start i)))
                           (lp (+ i 1)))))))
        (lp 0)))))

(define (string-append . ss)
  (list->string (apply append (map string->list ss))))

(define (string->list s)
  (let ((n (string-length s)))
    (letrec ((lp (lambda (i)
                   (if (= i n) '()
                       (cons (string-ref s i) (lp (+ i 1)))))))
      (lp 0))))

(define (list->string cs)
  (let ((n (length cs)))
    (let ((s (make-string n #\nul)))
      (letrec ((lp (lambda (i xs)
                     (if (null? xs) s
                         (begin (string-set! s i (car xs))
                                (lp (+ i 1) (cdr xs)))))))
        (lp 0 cs)))))
```

空 `append`/`map` 依赖 L42。`string-append` 零参数：`ss` 空，`map` 空表，`append` 无参——L42 的 `append` 零参数应是 `'()`，`list->string` 得 `""`。若 `append` 不许零参，则：

```scheme
(define (string-append . ss)
  (if (null? ss) (make-string 0 #\nul)
      (list->string (apply append (map string->list ss)))))
```

### 整除（C）

```c
void num_divmod(ptr n, ptr d, int mode, ptr *q, ptr *r);
/* mode 0 : towards-zero quotient + remainder
   mode 1 : modulo (r 与 d 同号) */

ptr rt_quotient(ptr n, ptr d);
ptr rt_remainder(ptr n, ptr d);
ptr rt_modulo(ptr n, ptr d);
```

fixnum 快路径用 C `%`/`/` 注意 **向 0**（C99 已向 0）。负数 `modulo` 不要直接用 C `%`。bignum 先实现绝对值除法再调符号。

### exact?

```scheme
(define (exact? x) (integer? x))
(define (inexact? x) #f)
```

`inexact?` 对非数：R4RS 域错误。锁定：非数 → 运行时 error，与 `exact?` 相同。

```scheme
(define (exact? x)
  (if (integer? x) #t (rt_error "exact?")))
```

更松：非数 `#f`。锁定 **非数 error**，测例只对整数与 `#t`。

```scheme
(define (> a b) (< b a))
(define (<= a b) (not (> a b)))
(define (>= a b) (not (< a b)))
(define (even? n) (zero? (remainder n 2)))
(define (odd? n) (not (even? n)))

(define (equal? a b)
  (cond
    ((eq? a b) #t)
    ((and (number? a) (number? b)) (= a b))
    ((and (pair? a) (pair? b))
     (and (equal? (car a) (car b)) (equal? (cdr a) (cdr b))))
    ((and (string? a) (string? b))
     (let ((n (string-length a)))
       (and (= n (string-length b))
            (letrec ((lp (lambda (i)
                           (or (= i n)
                               (and (char=? (string-ref a i) (string-ref b i))
                                    (lp (+ i 1)))))))
              (lp 0)))))
    ((and (vector? a) (vector? b))
     (let ((n (vector-length a)))
       (and (= n (vector-length b))
            (letrec ((lp (lambda (i)
                           (or (= i n)
                               (and (equal? (vector-ref a i) (vector-ref b i))
                                    (lp (+ i 1)))))))
              (lp 0)))))
    (else #f)))
```

## 测例清单

上一层全部测例仍须通过。

1. **named let 阶乘/求和**  
   ```scheme
   (let loop ((i 5) (s 0))
     (if (= i 0) s (loop (- i 1) (+ s i))))
   ```  
   → `15`

2. **named let 的 init 看不见名字**  
   ```scheme
   (let ((n 3))
     (let n ((i n))
       i))
   ```  
   → `3`（外层 `n`，不是绑定自己）

3. **do 求和**  
   ```scheme
   (do ((i 0 (+ i 1))
        (s 0 (+ s i)))
       ((= i 5) s))
   ```  
   → `10`（0+1+2+3+4）

4. **do 无 body 无 expr**  
   ```scheme
   (do ((i 0 (+ i 1)))
       ((= i 3)))
   ```  
   → `#<void>`

5. **delay 不立即求值**  
   ```scheme
   (begin
     (define x 0)
     (define p (delay (begin (set! x 1) 9)))
     x)
   ```  
   → `0`

6. **force 一次**  
   ```scheme
   (begin
     (define x 0)
     (define p (delay (begin (set! x (+ x 1)) 7)))
     (list (force p) (force p) x))
   ```  
   → `(7 7 1)`

7. **substring**  
   `(substring "abcd" 1 3)` → `"bc"`（`display` 无引号则 `bc`；锁定 **`write`/`rt_print` 对 string 与 L17/L44 一致**，若打印带引号则 `"bc"`。）

8. **string-append**  
   `(string-append "a" "b" "c")` → `"abc"`；`(string-append)` → `""`

9. **string↔list**  
   `(list->string (string->list "hi"))` → `"hi"`

10. **quotient remainder modulo**  
    ```scheme
    (list (quotient 10 3)
          (remainder 10 3)
          (modulo 10 3)
          (quotient -10 3)
          (remainder -10 3)
          (modulo -10 3))
    ```  
    → `(3 1 1 -3 -1 2)`  
    （`-10 = (-3)*3 + (-1)` remainder；modulo 要 `r` 与除数 3 同号 → `2`，因 `-10 = (-4)*3 + 2`。）

11. **bignum quotient**  
    `(quotient (+ 2305843009213693951 5) 2)` → `1152921504606846978`

12. **exact? inexact?**  
    `(list (exact? 3) (inexact? 3) (exact? (+ 2305843009213693951 1)))` → `(#t #f #t)`

13. **char=?**  
    `(list (char=? #\a #\a) (char=? #\a #\b) (char<? #\a #\b))` → `(#t #f #t)`

14. **char-ci 可选**  
    若实现：`(char-ci=? #\A #\a)` → `#t`。不实现则无此文件，表中已标明确不做。

15. **equal?**（L55 deriv 测例依赖）  
    ```scheme
    (list (equal? '(a (b) 3) (list 'a (list 'b) 3))
          (equal? '(1) '(2))
          (equal? "ab" (list->string '(#\a #\b))))
    ```  
    → `(#t #f #t)`

16. **> <= >= odd? even?**  
    `(list (> 4 1) (<= 2 2) (>= 2 3) (odd? 3) (even? 4))` → `(#t #t #f #t #t)`

17. **除零** `(quotient 1 0)` → **运行时错误**。`017-err-div-zero.scm`

18. **transcript 不存在** `(transcript-on "t")` → **编译期或运行时错误**。`018-err-transcript.scm`

19. **eval 不存在** `(eval '(+ 1 2))` → **编译期或运行时错误**。`019-err-eval.scm`

20. **substring 越界** `(substring "a" 0 2)` → **运行时错误**。`020-err-substring.scm`

## 验收标准

- 表中每一行都有三列之一，无空白、无「以后再说」。
- 测例 1–13、15–16 退出码 0；14 依选择；17–20 非 0。
- 未把 `open-input-file`、`transcript-on`、`eval`、`/`、浮点标成已有。
- named let / do / delay 的展开不新增 IR 操作码。
- `quotient` 等对 L53 bignum 有效（测例 11）。

## 常见坑

- **named let 用手写 `let` 模式却把 `tag` 当第一个绑定**：`(let foo ((x 1)) …)` 被看成绑定名叫 `foo` 的单变量。要先看第二个元素是不是**标识符**。
- **do 的 step 用了旧 var**：step 表达式在新一轮调用前求值，应看到本轮 var；展开成 `(loop step …)` 在 command 之后，正确。
- **delay 用非记忆化**：测例 6 的 `x` 变成 `2`。
- **C `%` 当 modulo**：负数测例 10 最后一项会是 `-1` 而不是 `2`。
- **string-append 依赖循环 `append` 的可变 arity 却只实现了二元**：用 `apply`。
- **声称 I/O 完成**：L55 会按本表打脸；缺的就写明确不做。

## 下一层预告

L55 用一张布尔符合性表加上三个可运行的小程序验收整份教程，并说明如何记录仍开放的缺口。
