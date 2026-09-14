# L11 — `and` / `or`（前端展开为 `if`）

## 目标

加入派生形式 `and` 与 `or`。它们 **不是** 后端原语，也 **不是** 新的 IR 节点名字：前端把它们展开成已经会 emit 的 `if`（以及为了 `or` 的「只求值一次」而使用的 **IR `(let …)`**）。后端继续只认识 `imm` / `prim` / `if`，并在本层补上 `let` / `ref` 的 emit——即便 **用户语法的 `let` 要到 L19 才开放**。

零个操作数：`(and)` → `#t`，`(or)` → `#f`。一个操作数：该操作数本身。多个操作数：短路，最后一个操作数落在 **尾位置**。

本层范围之外：用户写 `(let ((x …)) …)`（编译期错误，与 L10 一样拒绝未知核心形式）；`cond`（L40）；后端为 `and`/`or` 手写专用跳转序列（那样会在 L31 尾调用时再改一次）；把 `and`/`or` 做成可变 arity 的 `prim`。

## 原理

### 为何展开而不是新后端

`and`/`or` 的语义是 `if` 加短路。若在 `emit-prim` 里为它们各写一套 `b.eq`，会出现：

- 与 L10 重复的标签/假值逻辑；
- L31 要识别「`or` 的最后一项是尾调用」时，后端得再懂一次派生形式。

合同：短路结构只存在于前端。`emit-if` 已经保证未选中分支不求值，展开后自动短路。

### 展开规则（芯片无关）

`and`：

```
(and)          ⇒  #t
(and e)        ⇒  e
(and e1 e2 …)  ⇒  (if e1 (and e2 …) #f)
```

`or` 若写成：

```
(or)           ⇒  #f
(or e)         ⇒  e
(or e1 e2 …)   ⇒  (if e1 e1 (or e2 …))     ; 危险：e1 求值两次
```

在纯立即数层 `(or (fxadd1 1) 0)` 仍能得到 `2`，因为无副作用。L23 的 `set!`、L24 的调用会让双求值变成错。合同要求本层就 **禁止双求值**。

用户层 `let` 是 L19。但 IR 从 ARCHITECTURE 起就有：

```
(let ((<id> Ir) ...) Ir)
(ref <id>)
```

因此 `or` 的展开发生在 **降 IR 时**，直接构造 IR `let`，而不是构造用户语法 `(let ((t e1)) (if t t …))` 再喂给还没实现的用户 `let` 解析器。

正确的 IR 形状（单绑定、嵌套——见下节为何不能并行）：

```
(or)           ⇒  (imm BOOL_F)

(or e)         ⇒  (expr->ir e)

(or e1 e2 …)   ⇒  (let ((tmp (expr->ir e1)))
                    (if (ref tmp)
                        (ref tmp)
                        <or 对剩余参数的 IR>))
```

`tmp` 由前端卫生化生成（`or.0`、`or.1`、…），保证不与将来用户变量或其它 `or` 撞名。

### IR `let` ≠ 用户 `let`

| | IR `(let ((id Ir)) Ir)` | 用户 `(let ((x e)) e)` |
|--|-------------------------|------------------------|
| 谁写 | 只有编译器（本层是 `or` 展开器） | 程序员 |
| 本层 | **必须 emit** | **必须编译期拒绝** |
| 开放层 | L11 后端 | L19 前端 |
| 绑定名 | 卫生化的 `or.N` 一类 | 源程序标识符 |

若本层为了省事把用户 `let` 也解析了，L18/L19 的测例边界会被破坏（那些层要单独教 `env` 与单绑定语义）。请在 `expr->ir` 里：看到源程序的 `let` 符号 → `error`；只有展开器内部调用 `(ir-let tmp rhs body)` 构造 IR。

实现上用两套入口最干净：

```
expr->ir     ; 读用户语法，遇到 'let / 'and / 'or 分别 error / 展开
and-args->ir, or-args->ir  ; 只被 expr->ir 调用，产出 if / let / ref
```

### 为何 `or` 的多个绑定必须嵌套，不能并行

ARCHITECTURE 写 IR `let` 是并行绑定：所有右值先求值，再入环境。若写成：

```
(let ((t1 Ir_a) (t2 Ir_b) (t3 Ir_c))
  (if (ref t1) (ref t1) (if (ref t2) (ref t2) (ref t3))))
```

则 `a`、`b`、`c` **全部先算**，`or` 不再短路。`(or #t (fxadd1 #t))` 会去执行非法的 `fxadd1`。

本层 expander **每次只生成一个绑定**，剩余参数放在 `if` 的 else 里继续展开：

```
(or a b c)
⇒ (let ((t0 a))
     (if t0 t0
         (let ((t1 b))
           (if t1 t1
               c))))
```

`and` 不需要 `let`：`(if e1 (and e2 …) #f)` 里 `e1` 只作为 test 求值一次，真时值被丢弃（R4RS `and` 在中间项为真时继续，不返回那一项——对，中间项只看真假；**最后一个** 操作数的值才是结果）。不要把 `and` 也做成 `(if t t …)`，那会改变非尾项的返回值：`(and 1 2)` 必须是 `2` 不是 `1`。

### 尾位置

```
(and e1 e2 e3)  ⇒  (if e1 (if e2 e3 #f) #f)
                   ；e3 在内层 if 的 then，而该 if 在外层 then：尾位置

(or e1 e2 e3)   ⇒  嵌套 let+if，最后的 e3 在最内层 if 的 else：尾位置
```

本层无 `call`，emit 不必特殊处理尾。但展开必须保持这个形状，以便 L31 只对 `if`/`let` body/`ref` 谈尾调用，不必再认识 `and`。

`(and e1 e2)` 作为 **另一个** `if` 的 test 时，整个 `and` 不在尾位置，这是对的：它是 test。

### 假值规则沿用 L10

`(and 0 1)` → `1`，因为 `0` 为真。`(or 0 1)` → `0`，因为 `0` 为真，短路，返回 **那个真值本身**（不是把它变成 `#t`）。`(or #f ())` → `()`。`(and #t #f 3)` → `#f`，第三项不求值。

### 后端本层要新做的：`emit-let` / `emit-ref`

IR `let` 单绑定语义（本层只收到一个 binding）：

1. 用当前 `ctx` 求值 rhs → `x0`
2. `emit-stack-save` 于当前 `si`
3. 求值 body，环境增加 `id → (stack . si)`，`si'` = `si - WORDSIZE`

```
env 条目： (cons id (cons 'stack si))
即 (id stack . si)
```

`emit-ref`：查 `ctx` 的 `env`，`ldr x0, [x29, #slot]`。找不到 id：编译器 bug（展开器卫生化失败），`error`。

本层若收到两个以上 binding：`error`（并行多绑定是 L20）。不要静默左到右依次绑，以免 L20 语义被提前「做对/做错」。

栈帧：继续用 L07 的 256 字节局部区。`or` 嵌套越深占越多槽；256 对本层测例足够。

`and` 展开 **不产生** `let`/`ref`，只产生 `if` 与 `imm`。可以先只测 `and`，再打开 `or` 验证 `emit-let`。

### 后端仍然不能见到 `and` / `or`

`emit-prim` 的 `case` 里没有 `and`/`or`。若见到，说明前端忘了展开，应 `error`，不要「顺手当函数」。

## 与上一层的差异

| 项 | L10 | L11 |
|----|-----|-----|
| 用户语法 | `if` + prim + 字面量 | 增加 `and` / `or` |
| 展开 | 无 | 前端把 `and`/`or` 变成 `if`（`or` 还变成 IR `let`） |
| IR 新节点 | `if` | 本层开始 emit `let`、`ref`（仅内部） |
| 用户 `let` | 拒绝 | 仍拒绝 |
| 短路 | `if` 已有 | `and`/`or` 免费获得 |
| 栈 | 仅 prim 临时 | `or` 的 tmp 也是命名栈槽 |

## 代码骨架

### 可移植：卫生化 id 与 IR 构造

```scheme
(define *or-tmp-n* 0)
(define (reset-or-tmps!) (set! *or-tmp-n* 0))
(define (fresh-or-id)
  (set! *or-tmp-n* (+ *or-tmp-n* 1))
  (string-append "or." (number->string *or-tmp-n*)))

;; 一次编译开始时与 reset-labels! 一起调用 reset-or-tmps!
```

id 用字符串或 intern 过的符号皆可，但 `assq` 必须与 `ref` 用同一指针/相等性。推荐 intern 成符号：`(string->symbol (fresh-or-id))`。

### 可移植：`and` / `or` 降 IR

```scheme
(define (and-args->ir args)
  (cond
    ((null? args) `(imm ,BOOL_T))
    ((null? (cdr args)) (expr->ir (car args)))
    (else
     `(if ,(expr->ir (car args))
          ,(and-args->ir (cdr args))
          (imm ,BOOL_F)))))

(define (or-args->ir args)
  (cond
    ((null? args) `(imm ,BOOL_F))
    ((null? (cdr args)) (expr->ir (car args)))
    (else
     (let ((tmp (string->symbol (fresh-or-id))))
       `(let ((,tmp ,(expr->ir (car args))))
          (if (ref ,tmp)
              (ref ,tmp)
              ,(or-args->ir (cdr args))))))))
```

`expr->ir`：

```scheme
(define (expr->ir expr)
  (cond
    ((and (pair? expr) (eq? (car expr) 'and))
     (and-args->ir (cdr expr)))
    ((and (pair? expr) (eq? (car expr) 'or))
     (or-args->ir (cdr expr)))
    ((and (pair? expr) (eq? (car expr) 'if))
     (unless (length=? expr 4)
       (error "L11: if expects 3 operands" expr))
     `(if ,(expr->ir (cadr expr))
          ,(expr->ir (caddr expr))
          ,(expr->ir (cadddr expr))))
    ((and (pair? expr) (eq? (car expr) 'let))
     (error "L11: user let is L19" expr))
    ;; … prim / 字面量 …
    (else (error "L11: bad expr" expr))))
```

子表达式里的 `and`/`or` 会在递归 `expr->ir` 时展开，故 `(fx+ (and 1 2) 3)`、`(if (or #f 1) 2 3)` 自动合法。

### 可移植 + aarch64-apple：`emit-let` / `emit-ref`

```scheme
(define (emit-ir ir ctx)
  (case (car ir)
    ((imm)  (emit-imm (cadr ir)))
    ((prim) (emit-prim (cadr ir) (cddr ir) ctx))
    ((if)   (emit-if (cadr ir) (caddr ir) (cadddr ir) ctx))
    ((let)  (emit-let (cadr ir) (caddr ir) ctx))
    ((ref)  (emit-ref (cadr ir) ctx))
    (else (error "L11: unknown ir" ir))))

(define (emit-let bindings body ctx)
  (unless (and (pair? bindings) (null? (cdr bindings)))
    (error "L11: IR let expects exactly 1 binding" bindings))
  (let* ((b   (car bindings))
         (id  (car b))
         (rhs (cadr b))
         (si  (ctx-si ctx))
         (ctx2 (make-ctx (- si WORDSIZE)
                         (cons (cons id (cons 'stack si))
                               (ctx-env ctx)))))
    (string-append
      (emit-ir rhs ctx)
      (emit-stack-save si)
      (emit-ir body ctx2))))

(define (emit-ref id ctx)
  (let ((hit (assq id (ctx-env ctx))))
    (unless hit
      (error "L11: unbound IR ref" id))
    (let ((place (cdr hit)))
      (unless (eq? (car place) 'stack)
        (error "L11: ref place" place))
      (emit-stack-load (cdr place) "x0"))))
```

`emit-stack-save` / `emit-stack-load` 与 L07 相同：`str`/`ldr` `[x29, #si]`。`ref` 把值装回 `x0`（不是 `x9`），因为 `ref` 是完整表达式。

`if` 的 test 若是 `(ref tmp)`：先 `ldr x0, [fp, #slot]`，再 `emit-jfalse`。then 分支再 `ldr` 一次同一槽——这是「test-once」：求值 `or` 的操作数只发生在 `let` 的 rhs，两次 `ref` 只是两次加载，没有第二次 `fxadd1`。

aarch64 片段示例（`(or (fxadd1 1) 0)` 的核心）：

```
    ; rhs: (fxadd1 1) → x0
    ; …
    str x0, [x29, #-8]
    ldr x0, [x29, #-8]
    cmp x0, #0x2F
    b.eq L_if_else_1
    ldr x0, [x29, #-8]      ; then: 同一个 tmp
    b L_if_end_1
L_if_else_1:
    ; else: (imm 0)
    movz x0, #0
    …
L_if_end_1:
```

不要把 `then` 优化成「x0 里已经是 tmp 就免去第二次 ldr」除非你能证明 `emit-jfalse` 不破坏 `x0`（当前实现 `cmp` 不破坏）。**可以**省略 then 的第二次 `ldr`，但这是优化；骨架按两次 `ref` 各一次 `ldr` 写，语义最贴 IR。两种都合格，测例不区分。

临时仍是 `x9`–`x15`。禁止 `x18`。Darwin `_` 前缀不用于 `or.1` 这种 IR id：它们只出现在栈上，不是汇编符号。汇编标签仍是 `L_if_*`。

## 测例清单

上一层全部测例仍须通过。

1. `(and)` → `#t`
2. `(or)` → `#f`
3. `(and 42)` → `42`；`(or #f)` → `#f`；`(or 7)` → `7`
4. `(and 1 2)` → `2`；`(and #t 3)` → `3`
5. `(and #f 2)` → `#f`（第二项不求值）
6. `(and 1 #f 3)` → `#f`；`(and 1 2 3)` → `3`
7. `(or #f #f 3)` → `3`；`(or #f 1 2)` → `1`
8. `(or 0 1)` → `0`（零为真，返回那个真值，不是 `#t`）
9. `(and 0 1)` → `1`（零为真，继续）
10. `(or #f ())` → `()`；`(and () #t)` → `#t`
11. `(and (fixnum? 1) (boolean? #f))` → `#t`
12. `(or (null? 0) (char? #\A))` → `#t`
13. `(if (and #t 1) 2 3)` → `2`；`(if (or #f #f) 1 2)` → `2`
14. `(or #t (fxadd1 #t))` → `#t`（else 不得求值；双求值或并行 let 会炸）
15. `(and #f (fxadd1 #t))` → `#f`（同样短路）
16. `(fx+ (and 1 2) 3)` → `5`；`(or (or #f #f) 4)` → `4`（嵌套）
17. 用户语法 `(let ((x 1)) x)`：编译期错误（IR let 不得从此处入口暴露）。`(and 1 2 3 4)` 与 `(or #f #f #f #t)` 为合法多操作数，分别 → `4`、`#t`。

测例 8、9、14 是本层合同的核心：假值规则、返回真值本身、`or` 单次求值。

## 验收标准

- 测例 1–16 及 17 中合法程序的输出与上表一致。
- `.s` 中 **没有** 名为 `and`/`or` 的 prim 路径；能看到 `if` 的 `cmp #0x2F` / `b.eq`。`or` 的多操作数测例能看到 `str`/`ldr`（tmp 槽）。
- `(and)` 为 `#t`、`(or)` 为 `#f`，不要反。
- `(or 0 1)` 打印 `0` 而不是 `#t`。
- `(or #t (fxadd1 #t))` 退出码 0 且打印 `#t`：证明未双求值、未并行求值所有分支。
- 用户 `let` 编译期失败。IR 多绑定 `let` 若被误造，后端本层应 `error`。
- 最后一个操作数在展开后处于 `if` 的 then/else 末端，没有外面包一层「再 `mov` 到别处才算结果」的非尾 `seq`（本层无 `seq` 节点即可）。

## 常见坑

- **在后端做 `and`/`or`**：能过本层测例，但违反合同，L31 要重写。前端展开。
- **`(or e1 e2)` 展开成 `(if e1 e1 e2)`**：测例 1–13 在无副作用时仍绿，测例 14 失败。必须 IR `let`。
- **并行 IR `let` 绑定所有 `or` 操作数**：同样破坏短路。只生成单绑定嵌套 `let`。
- **把用户 `let` 一并实现**：L19 的课被偷走；本层遇到源程序 `let` 应 `error`。
- **`(and 1 2)` 做成 `(if 1 1 2)`**：返回 `1` 而不是 `2`。`and` 只把中间项当 test，值在最后一项。
- **`(and)` → `#f` 或 `(or)` → `#t`**：与 R4RS 相反。空 `and` 是幺元 `#t`，空 `or` 是幺元 `#f`。
- **把真值规范成 `#t`**：`(or 3 4)` 必须是 `3`。不要 `csel` 出布尔来代替返回原值。
- **`ref` 加载到 `x9` 却当表达式结果**：`or` 的 then 会打出垃圾。`emit-ref` 的目标是 `x0`。
- **`assq` 找不到 `or.N`**：`fresh-or-id` 每次生成新字符串但没 `string->symbol`，与 `ref` 里另一个新字符串不相等。id 必须是同一符号对象。
- **`if` 的 then/else 用了 `ctx-down` 导致找不到 tmp**：`emit-if` 三子树共享 `ctx`（L10 已说）；`let` 只在 body 里扩展 `env`。

## 下一层预告

L12 第一次真正使用堆 bump 指针 `HP`：还没有 `cons`，只证明分配发生且标签体系仍完好。
