# L55 — 符合性清单与小程序验收

## 目标

教程最后一层：**不再加新语言机制**。交付三件事：

1. 一张 **布尔符合性表**（读者对自己的系统勾是/否）。
2. **三个指定小程序**必须跑通；源码写在本层测例清单里，不是「自选等价物」。
3. 如何记录仍开放的缺口，以及教程结束后的下一步（换芯片，不是 L56）。

测例回归改为：**L00–L54 全部测例仍须通过**，外加本层三个小程序（及下面的清单自检程序）。

本层范围之外：实现 `x86_64-linux` 后端、补 L54 已标「明确不做」的过程、R5RS/R6RS 模块与相位移、浮点、`eval`。

## 原理

### 符合性表（布尔）

对每一行，实现者在自己的 `CONFORMANCE.md`（读者仓库，非本教程必交文件）写 `yes`/`no`。本层验收：表中标「必须 yes」的项，若 no 则本层不合格；标「允许 no」的项在缺口报告里留档即可。

| 项 | 必须 yes | 判定标准 |
|----|----------|----------|
| reader | 是 | L43：能从文件读 datum；测例与 `load` 依赖它 |
| writer | 是 | L44：`write`/`display`/`rt_print` 对 pair、立即数、string、symbol、bignum 可打印 |
| 核心语法 | 是 | `lambda` `if` `quote` `set!` `begin` `let` `let*` `letrec` `define` |
| 派生语法 | 是 | `cond`（无 `=>`）`case` `and` `or` `quasiquote`；L54 的 named let、`do`、`delay` |
| 宏子集 | 是 | 顶层 `define-syntax`+`syntax-rules`：一层与嵌套 `...`、递归宏、L49 卫生测例。无 `syntax-case`、无 `let-syntax` |
| GC | 是 | L51 mark-compact + L52 根（栈、box、cont、wind）；`%gc` 后活对象仍对 |
| `call/cc` | 是 | L37 多次 invoke + L39 `dynamic-wind` + L52 GC |
| `values` | 是 | L35 `values`/`call-with-values` |
| `apply` | 是 | L34 |
| bignum | 是 | L53 `+ - * = <` 溢出提升、打印十进制、无浮点 |
| 库填料 | 是 | L54 强制项：substring 族、整除、delay/force、named let、do |
| 完整 I/O 端口 | 否 | L54 已明确不做 `open-*-file`/`transcript-*` |
| `eval` | 否 | 明确不做 |
| `/` 与有理数 | 否 | 明确不做 |
| flonum | 否 | 明确不做 |
| `cond =>` | 否 | 明确不做 |
| R4RS 100% | 否 | 本教程从不声称 |

「核心语法 yes」意味着这些形式的 **Lxx 测例仍绿**，不是另写一份规范。

### 三个小程序在测什么

1. **递归 fib + tak**：整数递归、`if`/`cond`、`+`/`-`/`<`、栈深度。fib 小、tak 稍深，验证未爆栈到离谱程度（不必 TCO 化 tak；TCO 已在 L31/L32 测过）。
2. **符号微分**：表处理、`eq?`、`cond`、`list`/`cadr`、quote。逼近「能跑非玩具程序」而不是再写一个编译器。
3. **多文件 list 脚本**：`load`、`map`、`append`、顶层 `define`。证明不是单文件 REPL 玩具。

### 如何报告剩余缺口

在读者仓库根目录维护 `GAPS.md`（本教程只规定格式，不在本仓库创建该文件）：

```markdown
# Gaps vs R4RS
- [ ] eval
- [ ] / and rationals
- [ ] flonum / inexact
- [ ] cond =>
- [ ] open-input-file / open-output-file / transcript-on
- [ ] gcd lcm
- [ ] char-ci=?   ; 若 L54 未做
- [ ] let-syntax / local define-syntax
把 L54 表里每一条「明确不做」抄过来，一条一行。
已补上的把 [ ] 改 [x] 并写层号或提交哈希。
```

不要删 L54 表去假装没有缺口。L55 合格 **不要求** GAPS 为空。

### 教程结束后做什么

无 L56。两条路，可并行：

1. 按 [`backend/README.md`](../backend/README.md) 的 **x86_64-linux 清单** 加后端：System V AMD64 寄存器、ELF 无下划线、同一组 `tests/Lxx`。先让 L00–L05 绿再往上。
2. 从 `GAPS.md` 挑 L54 开放项（I/O、`gcd`、`=>`…）当课后练习。

换芯片时 **禁止改 IR 与层文档求值规则**（ARCHITECTURE §9）。

## 与上一层的差异

- 无新 prim、无新展开器、无新 GC 行为。
- 增加三个多文件/稍长程序作为验收，不是新语义。
- 回归范围写成 L00–L54 全集。

## 代码骨架

本层无强制新代码。可选：驱动加 `tests/L55/` 并把 HEAP 默认 64MiB。小程序 3 需要两个源文件，驱动应支持「主文件 `load` 相对路径」。

若 `load` 只认绝对路径，测例 3 的主文件用驱动写入的绝对路径；文档锁定：**主文件与 `lib.scm` 同目录，`load "lib.scm"` 相对当前工作目录或相对主文件目录**。实现选一种，在驱动里 `cd` 到该测例目录再跑。

自检程序（可选，测例 4）：把符合性表里「必须 yes」的入口各调用一次，返回 `'ok`。

```scheme
(begin
  (define (touch)
    (list (boolean? #t)
          (pair? (cons 1 2))
          (procedure? (lambda (x) x))
          (exact? (+ 2305843009213693951 1))
          (apply + '(1 2 3))))
  (if (memq #f (touch)) 'fail 'ok))
```

→ `ok`

## 测例清单

全层回归 L00–L54 加上下列程序。不再写「上一层全部测例仍须通过」的缩略句：范围就是 **L00 起全部已有测例 + 本层**。

### 1. `001-fib-tak.scm` — 递归 fib 与 tak

```scheme
(begin
  (define (fib n)
    (if (< n 2)
        n
        (+ (fib (- n 1)) (fib (- n 2)))))
  (define (tak x y z)
    (if (not (< y x))
        z
        (tak (tak (- x 1) y z)
             (tak (- y 1) z x)
             (tak (- z 1) x y))))
  (list (fib 10) (tak 9 6 3) (fib 0) (tak 3 2 1)))
```

期望：`(55 6 0 2)`

`tak` 对照：`tak(3,2,1)=2`（`tak(tak(2,2,1), tak(1,1,3), tak(0,3,2))` → `tak(1,3,2)=2`）；`tak(9,6,3)=6`。不要改成更小参数来「优化」；`fib 10` 必须是 55。驱动可加长超时。

### 2. `002-deriv.scm` — 符号微分（子集）

```scheme
(begin
  (define (atom? x)
    (not (pair? x)))
  (define (deriv exp var)
    (cond
      ((number? exp) 0)
      ((symbol? exp)
       (if (eq? exp var) 1 0))
      ((eq? (car exp) '+)
       (list '+
             (deriv (cadr exp) var)
             (deriv (caddr exp) var)))
      ((eq? (car exp) '*)
       (list '+
             (list '* (cadr exp) (deriv (caddr exp) var))
             (list '* (deriv (cadr exp) var) (caddr exp))))
      ((eq? (car exp) '-)
       (list '-
             (deriv (cadr exp) var)
             (deriv (caddr exp) var)))
      (else (list 'unsupported exp))))
  (list (deriv 3 'x)
        (deriv 'x 'x)
        (deriv 'y 'x)
        (deriv '(+ x 3) 'x)
        (deriv '(* x y) 'x)
        (deriv '(* (* x y) (+ x 3)) 'x)))
```

期望（`write` 风格空格与 L44 一致；下列为 canonical）：

```
(0 1 0 (+ 1 0) (+ (* x 0) (* 1 y)) (+ (* (* x y) (+ 1 0)) (* (+ (* x 0) (* 1 y)) (+ x 3))))
```

若 `write` 对数字与符号的间隔不同，以你的 L44 空格规则生成 `.expected`，但 **cons 结构必须 `equal?` 于上面这棵树**。可用测例 2b 只返回最后一个 `deriv` 并用手写 `equal?` 对期望树：

```scheme
(equal?
  (deriv '(* (* x y) (+ x 3)) 'x)
  '(+ (* (* x y) (+ 1 0))
      (* (+ (* x 0) (* 1 y)) (+ x 3))))
```

→ `#t`  
**2b 为必过**（`002-deriv.scm` 用 2b 这版，避免打印格式争论）。完整 `list` 版可作为 `002b-deriv-print.scm` 对照打印，不强制。

### 3. `003-list-script/` — `load` + `map` + `append`

文件 `003-list-script/lib.scm`：

```scheme
(define (double x) (* x 2))
(define (sum-list xs)
  (if (null? xs) 0 (+ (car xs) (sum-list (cdr xs)))))
```

文件 `003-list-script/main.scm`（驱动编译/运行的入口）：

```scheme
(begin
  (load "lib.scm")
  (define nums '(1 2 3 4))
  (define a (map double nums))
  (define b (append a '(10)))
  (cons (sum-list b) b))
```

期望：`(30 2 4 6 8 10)`  
（`sum-list` 对 `(2 4 6 8 10)` 为 30。）

驱动须在该目录下运行，使 `load "lib.scm"` 成功。`lib.scm` 不得再 `load` 主文件。

### 4. `004-conformance-touch.scm` — 必做项冒烟

```scheme
(begin
  (define (k-ok)
    (call/cc (lambda (k) (k 1))))
  (define (v-ok)
    (call-with-values (lambda () (values 2 3))
                      (lambda (a b) (+ a b))))
  (define p (delay 9))
  (list (k-ok)
        (v-ok)
        (apply * '(2 3 4))
        (force p)
        (exact? (+ 2305843009213693951 1))
        (let rec ((n 3) (a 1))
          (if (= n 0) a (rec (- n 1) (* a n))))))
```

期望：`(1 5 24 9 #t 6)`  
（named let 阶乘 3! = 6。）

### 5. `005-gc-during-fib.scm` — 小程序与 GC 同时

```scheme
(begin
  (define (fib n)
    (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))
  (let ((a (fib 8)))
    (%gc)
    (cons a (fib 6))))
```

期望：`(21 . 8)`

### 6. 缺口报告格式自检（人工）

不进驱动。实现者打开 `GAPS.md`：L54 每一条「明确不做」都有一行。本号在验收标准里用清单勾选，不自动 diff。

## 验收标准

- L00–L54 回归全绿。
- 测例 1、2b、3、4、5 退出码 0，输出与期望一致。
- 符合性表「必须 yes」的行，不能被测例 4/5 和回归打假。
- 未实现 `eval`、`transcript-on`、`/`、浮点（L54 错误测例仍红）。
- 仓库没有声称「R4RS 完全符合」。
- 读者若要换芯片：只新增 `backend/x86_64-linux.scm` 与 `runtime/x86_64-linux/`，测例文件一字不改。

## 常见坑

- **tak 写成 `< x y` 搞反**：终止条件是 `not (< y x)`（即 `y >= x` 返 `z`）。写错则测例 1 对不上 `6` 和 `2`。
- **deriv 用 `fx+` 当符号 `+`**：quote 里的 `'+` 是符号，不是过程。
- **`load` 工作目录不对**：测例 3 找不到 `lib.scm`。驱动 `cd`。
- **`list` 打印无空格或有点对**：`.expected` 必须跟 L44；测例 2 用 `equal?` 就是为躲这个。
- **fib 用可变 `set!` 循环却测了「递归」**：允许用命名 let 迭代 fib，但本层源码锁定为真递归两行 `fib`；不要改测例来「优化」。
- **小堆默认跑 L55**：tak 与 fib 会分配大量闭包帧（若闭包化）或只用栈；64MiB 足够。不要用 `SCHEME_HEAP_BYTES=4096` 跑本层。
- **把本层当成可以改标签的许可**：不行。

## 下一层预告

无 L56。教程结束。下一步：按 `backend/README.md` 的 x86_64-linux 清单换芯片，或补 L54 仍开放项（I/O、`gcd`、`cond =>`、局部 syntax、有理数等）。IR、标签与 `tests/L00`–`tests/L55` 保持不动。
