# L45 — `load` 与多文件程序

## 目标

程序不再是「单个表达式」。本层加入：

1. **顶层形式序列**：一个源文件可含多个 datum，按顺序执行，最后一个表达式的值成为进程打印结果（若最后是 `define`，结果为 `VOID`）。
2. **`(load "path")`**：读入该文件全部 datum，当作在当前位置展开的顶层序列（隐式 `begin` / splicing）。支持嵌套 `load`。多文件。
3. **顶层 `define`**：`(define x e)` 与 `(define (f . args) body …)`。若全局已绑定则 `set!`，否则 **扩展** 全局环境。

本层范围之外：模块系统、`provide`/`require`、库相、按文件隔离的命名空间、运行时对 **计算出的路径** 做 `load`（那需要 `eval` 或把编译器链进运行时）。`(load expr)` 的 `expr` 必须是 **字符串字面量**（expand 期可见）。相对路径相对 **进程 cwd**（不是被 load 文件所在目录）；若你额外支持相对「当前文件」须在注释声明，测例只依赖 cwd。

## 原理

### 编译期 `load`（锁定）

没有 `eval`。`load` 不能等到运行时再解析任意 Scheme。前端在 **expand 顶层** 遇到 `(load "rel/path.scm")`：

```
forms = 用 L43 的读法读该文件全部 datum
        （自托管编译器：打开文件，循环 rt_read 或本教程 reader；
         注释、符号规则须与 L43 一致。不要用 Chez / Python 读文件。
         推荐：编译器用同一份 reader 算法。）
替换为 forms 的 splicing，然后对每个 form 再 expand（含嵌套 load）
```

检测循环 `load`：维护「正在 load 的路径栈」，realpath 后相同则 **编译期错误**。单纯嵌套非环合法：`a.scm` load `b.scm`，`b.scm` load `c.scm`。

路径：相对 cwd。绝对路径合法。找不到文件 → 编译期错误（不要生成会在运行时才失败的空程序）。

顶层 `begin`：**splicing**（R4RS 顶层 begin）。`(begin (define x 1) x)` 与先后两个顶层形式相同。表达式位置的 `begin` 仍是 L22 的 `seq`，**禁止**在 `lambda` 体内 `load`（编译期错误），以免语义变成「运行时读文件」。

### 全局环境 `GLOBALS`（`x24`）

ARCHITECTURE 的 callee-saved 里 `x19–x21` 已占用；L35 用 `x22` 作多值标志 `MV`。本层锁定：

| 抽象名 | 物理 | 含义 |
|--------|------|------|
| `GLOBALS` | `x24` | 指向全局绑定 alist 的 Scheme 值（tagged pair 链或 `()`） |

`scheme_entry` 序言：保存 `x24`（与其它 callee-saved 一起），初始化 `x24 = EMPTY_LIST`（`mov x24, #0x3F`）。跋里恢复。禁止用 `x18`。

alist 元素：`(cons symbol (cons value '()))` 即 `(sym . val)` 点对。查找：`assq`（`eq?` 符号）。

两种实现都合格：

1. **推荐：寄存器里的 Scheme alist**（如上）。L52 GC 根只要扫描 `x24`。
2. runtime 符号表（字符串 → ptr）。此时 `x24` 仍须保存一个能被 GC 看见的根（例如指向「所有全局值的 vector」）。不要只把值藏在 GC 扫不到的 堆外缓冲（禁止） 里。

本层文档骨架按 (1) 写。

### 顶层 `define`

```
(define x e)              ; e 任意表达式
(define (f a b) body …)   ; ≡ (define f (lambda (a b) body …))
(define (f a . rest) …)   ; rest 形参，L33
(define (f . rest) …)
```

内部 define（`lambda`/`let` body 开头）仍走 L30 → `letrec`，**不要**改成改全局。判别：只有 **顶层 expand**（含 load/`begin` splicing 之后）把 `define` 当全局；一旦进入 `lambda`，`define` 按 L30。

运行时语义（每个顶层 define 降成的 IR）：

```
tmp = eval(e)
if assq(name, GLOBALS):
    set-cdr!(that pair, tmp)
else:
    GLOBALS = cons(cons(name, tmp), GLOBALS)
结果 VOID
```

重复 `(define x …)` 覆盖，不报错（R4RS 顶层再 define 是允许的实现定义；本教程锁定为覆盖）。

查找顺序：局部 `env`（IR `ref`）→ 若无，则 **运行时** 全局 lookup。这改变了 L18「未绑定标识符编译期错」：

- **`lambda` 内自由变量若不是 prim、不是局部、不是已知 prelude 绑定**：本层起视为全局引用，生成 `(prim %global-ref intern("name"))`。运行时找不到 → `rt_error("unbound")`。
- 顶层表达式里的自由变量同样 `%global-ref`。
- 这样 `(define (f) (g)) (define (g) 1) (f)` 合法（互相向前引用），因为调用发生在两个 define 都执行之后。
- `(g)` 若出现在 `(define (g) …)` **之前** 且立刻执行 → 运行时 unbound。测例覆盖这两种。

prelude（L42）：继续 `letrec` 包装 **或** 改成在用户代码前插入一串顶层 `define`。本层推荐把 prelude 改成「先 load `prelude.scm`」：`prelude.scm` 全是 `define`，再接用户文件。旧的 `letrec` 包装仍合格，但全局 `define` 的用户过程必须进 `x24`，否则另一文件看不见。锁定：**prelude 用顶层 define + 编译器隐式 `(load "compiler/prelude.scm")`**，这样用户顶层 `(map …)` 走 `%global-ref`。若仍用 `letrec` 包整个程序，则用户 `define` 的名字在 `letrec` 之外——两种混用会丢绑定。选 prelude-as-defines，不要外层 `letrec` 再包一层挡住 `x24`。

### `%global-ref` / `%global-set!`

IR：

```
(prim %global-ref IrSym)
(prim %global-set! IrSym IrVal)   ; define 已有绑定
(prim %global-bind! IrSym IrVal)  ; 无则 cons 到 x24，有则 set-cdr!
```

可把 define 统一成 `%global-bind!`（upsert）。后端：

- 符号对象在 `x0`，alist 在 `x24`。
- 循环 `assq`；命中则 `car` 是 pair，`cdr` 是值。
- 未命中：`%global-ref` 报错；`%global-bind!` 做 `cons`。

也可用 Scheme 注入的闭包做 lookup，避免新 prim；但仍须在汇编里能读/写 `x24`。推荐 prim，路径短。

### 多文件驱动

驱动原来「每个测例一个表达式」改为「每个测例一个主文件，可含多 datum」。旧单表达式文件仍是合法顶层序列（长度为 1）。

```
tests/L45/001-two-defines.scm          ; 主文件
tests/L45/001-lib.scm                  ; 被 load
```

`load` 字符串写 `"tests/L45/001-lib.scm"` 或驱动先 `cd` 到测例目录。锁定期望：路径相对 **运行驱动时的 cwd**（通常是仓库根）。在测例条目里写死字符串。

### 嵌套与顺序

```
;; main
(load "a.scm")
(load "b.scm")
(foo)
```

先执行 `a.scm` 全部顶层，再 `b.scm`，再 `(foo)`。`a.scm` 里的 `load` 在继续 `a.scm` 的下一 form 之前完成。

## 与上一层的差异

- 源程序 = datum 列表，不是单 expr。
- 新增 `load`（expand 期）、顶层 `define`、寄存器 `GLOBALS`/`x24`。
- 未绑定标识符从「编译期错」改为「可能是全局，运行时再查」（lambda 内拼写错误会推迟到调用）。仍应对 **明显非法** 的 prim arity 保持编译期检查。
- `scheme_entry` 必须保存/恢复 `x24` 并初始化为 `()`。
- prelude 装载方式改为顶层 `define` 序列（见上）。

## 代码骨架

### 顶层 expand

```scheme
(define (expand-toplevel forms)
  (if (null? forms)
      '(%void)
      (cons 'begin (expand-toplevel-list forms))))

(define (expand-toplevel-list forms)
  (cond
    ((null? forms) '())
    (else
     (let ((f (car forms)) (rest (cdr forms)))
       (cond
         ((and (pair? f) (eq? (car f) 'begin))
          (append (expand-toplevel-list (cdr f))
                  (expand-toplevel-list rest)))
         ((and (pair? f) (eq? (car f) 'load))
          (if (and (= (length f) 2) (string? (cadr f)))
              (append (expand-toplevel-list (read-file-datums (cadr f)))
                      (expand-toplevel-list rest))
              (error "L45: load needs string literal")))
         ((and (pair? f) (eq? (car f) 'define))
          (cons (expand-define f) (expand-toplevel-list rest)))
         (else
          (cons (expand-expr f) (expand-toplevel-list rest))))))))

(define (expand-define form)
  ;; (define (name . args) . body) → bind name to lambda
  ;; (define name expr)
  (list '%global-bind!
        (list 'quote (define-name form))
        (expand-expr (define-rhs form))))
```

`read-file-datums`：打开文件，循环直到 `eof-object?`。

`expand-expr` 里看到 `load`/`define` → `error`（非顶层）。

变量引用：

```scheme
(define (expr->ir expr env)
  (cond
    ((symbol? expr)
     (let ((b (assq expr env)))
       (if b
           `(ref ,(cdr b))
           `(prim %global-ref ,(datum->ir expr)))))
    ...))
```

### aarch64-apple：`x24`

```asm
_scheme_entry:
    stp x29, x30, [sp, #-64]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    mov x19, x0
    add x20, x19, x1
    mov x24, #0x3F          ; GLOBALS = ()
    ; … emit body …
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #64
    ret
```

栈帧大小按你实际保存的寄存器对齐到 16。若 L35 已保存 `x22`，在同一序言里加 `x24`，不要拆成两种 `scheme_entry`。

`%global-ref` 循环（伪）：

```
    mov x9, x24          ; alist
loop:
    cmp x9, #0x3F
    b.eq unbound
    ; x9 is pair: car = binding pair (sym . val)
    ; 去标签，ldr car/cdr，eq? 符号
```

也允许 `bl _rt_assq` 但 alist 在 `x24`，C 又要同步。纯汇编或 Scheme 库 `assq` 调用都可以；若调 Scheme `assq`，须 prelude 已 bind。**define prelude 自己时不能调用尚未 bind 的 `assq`**——lookup 做成 runtime prim 更干净。

## 测例清单

上一层全部测例仍须通过。

1. 单文件两表达式：`1` 下一行 `2`（两个 datum）→ `2`
2. `(define x 3) x` → `3`
3. `(define x 1) (define x 2) x` → `2`（覆盖）
4. `(define (f) 7) (f)` → `7`
5. `(define (add1 n) (fxadd1 n)) (add1 10)` → `11`
6. 互相向前引用：

    ```scheme
    (define (even? n)
      (if (fx= n 0) #t (odd? (fxsub1 n))))
    (define (odd? n)
      (if (fx= n 0) #f (even? (fxsub1 n))))
    (even? 4)
    ```

    → `#t`
7. 使用在 define 之前：`(g) (define (g) 1)` → **运行时** unbound 错误。
8. `load`：主文件

    ```scheme
    (load "tests/L45/008-lib.scm")
    (foo)
    ```

    `008-lib.scm`：`(define (foo) 42)`  
    → `42`
9. 多文件顺序：`009-a.scm` `(define x 1)`，`009-b.scm` `(define x (fxadd1 x))`，主文件 `(load "tests/L45/009-a.scm") (load "tests/L45/009-b.scm") x` → `2`
10. 嵌套 load：`010-a.scm` 内 `(load "tests/L45/010-b.scm")`，`010-b.scm` `(define z 9)`，主文件 `(load "tests/L45/010-a.scm") z` → `9`
11. 顶层 `begin` splicing：`(begin (define a 1) (define b 2)) (fx+ a b)` → `3`
12. 最后是 define：`(define q 1)` → `#<void>`
13. 局部影子全局：`(define x 1) (let ((x 5)) x)` → `5`
14. 过程内读全局：`(define x 3) (define (f) x) (f)` → `3`
15. 过程内 `set!` 全局（`set!` 对全局走 `%global-bind!` 或 `%global-set!`；未绑定的 `set!` 运行时错）：

    ```scheme
    (define x 1)
    (define (f) (set! x (fxadd1 x)))
    (begin (f) x)
    ```

    → `2`
16. `(load 1)` 或 `(load)`：编译期错误。
17. `(load "tests/L45/no-such-file.scm")`：编译期错误。
18. 循环 load：`018-a.scm` load `018-b.scm`，`018-b.scm` load `018-a.scm`：编译期错误。
19. `lambda` 内 `(load "…")`：编译期错误。
20. `lambda` 内 `(define x 1)` 仍是 L30 内部 define，不是全局：

    ```scheme
    (define x 10)
    ((lambda () (define x 1) x))
    ```

    该表达式值 → `1`；若你再顶层写 `x` 应仍为 `10`。本测例程序用 `(begin ((lambda () (define x 1) x)) x)` → `10`（`begin` 最后值是全局 `x`）。  
    锁定本号期望：`10`。
21. prelude 仍可用：`(length '(1 2 3))` → `3`

路径字符串按你的驱动 cwd 调整，但文档与 `tests/L45/` 布局一致。

## 验收标准

- 测例 1–6、8–15、20–21 退出码 0，输出匹配。
- 7 运行时 unbound；16–19 编译期失败。
- 旧单表达式测例无需改写仍绿（长度为 1 的顶层序列）。
- `nm` 不必出现 `x24`；读生成的序言汇编，须保存 `x24` 并在入口置 `()`。
- 没有模块隔离：后 load 的 `define` 覆盖同名全局（测例 9）。
- `load` 不在运行时打开文件（字符串字面已在编译期展开）。用 `strace`/`dtruss` 非必须；源码路径上 `rt_read` 只用于用户 `(read)` 与 **自托管编译器** 打开 load 的文件。

## 常见坑

- **外层 `letrec` prelude 挡住 `x24`**：用户 `define` 写进全局，`map` 却是 letrec 绑定——或反过来用户看不见 prelude。统一用全局 define。
- **内部 define 误当全局**：测例 20。
- **向前引用在编译期查全局表**：编译期表是空的，`even?` 调 `odd?` 会被判 unbound。必须运行时 lookup。
- **`load` 用运行时 `open`**：路径不是字面时无法本层实现；字面却放到运行时会让「编译期循环检测」失效。
- **相对被 load 文件的路径**：嵌套 load 的字符串相对 cwd，不是相对 `010-a.scm` 所在目录。测例 10 的路径写成完整相对仓库根。
- **忘记保存 `x24`**：`scheme_entry` 必须按 callee-saved 保存它；否则 `_main` 返回路径栈烂（本进程可能仍能印结果）。养成与 `x19` 同样保存。
- **`set!` 未绑定全局当成局部槽**：无局部绑定时 `set!` 走全局 upsert 还是错误？R4RS `set!` 未绑定是错误。锁定：**未绑定 `set!` 运行时错**，与 `define` 扩展不同。测例 15 先 `define` 再 `set!`。
- **多 datum 驱动仍 `read` 一次**：只编译了第一个 define，测例 2 失败。

## 下一层预告

L46 要把符号从「reader 内部 stub」提升为完整的用户 API：`string->symbol`、`symbol->string`、`symbol?`，并钉死 intern 与 `eq?`。
