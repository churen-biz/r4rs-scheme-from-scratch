# L10 — `if`（三操作数，可嵌套）

## 目标

加入核心形式 `if`。语法 **只接受三操作数**：`(if test then else)`。`test` 为 `#f` 时求值 `else`，否则求值 `then`。未选中的分支 **不得求值**。两分支的结果都留在 `x0`。允许任意嵌套。

本层范围之外：两操作数 `(if test then)`（R4RS 允许省略 `else`，结果 unspecified——本层 **编译期错误**，不发 `VOID`、不偷偷当 `#f`）；`cond`/`case`（L40）；`and`/`or`（L11，且是展开而不是新的后端节点）。运行时类型错误：`test` 可以是任何已编码值，不必是布尔。

## 原理

### 假值规则（钉死）

Scheme： **只有 `#f` 为假**。下列在 `test` 位置都为真，走 `then`：

| 值 | 编码 | `if` 走向 |
|----|------|-----------|
| `#f` | `0x2F` | else |
| `#t` | `0x6F` | then |
| `0` | `0` | then |
| `()` | `0x3F` | then |
| `#\A` / `#\nul` | 字符 | then |
| 任意非 `#f` 的 fixnum | `n<<2` | then |
| `(fx= 1 2)` 的结果 `#f` | `0x2F` | else |
| `(fx+ 0 0)` 的结果 `0` | `0` | then |

这与 `not`（L06）一致：`(if (not x) …)` 的含义现在可以靠 `if` 测例交叉验证。

**禁止**用 `cbz x0` / `cmp x0, #0` 当假。那会把 fixnum `0` 当成假，测例 `(if 0 1 2)` 会得到 `2`。

### IR

```
(if Ir Ir Ir)
```

ARCHITECTURE 已列出该节点。前端：

```
(if test then else)  →  (if (expr->ir test) (expr->ir then) (expr->ir else))
```

后端第一次见到非 `imm`、非 `prim` 的控制节点。`emit-ir` 的 `case` 增加 `if` 臂，调用 `emit-if`。

不要把 `if` 降成 `(prim if …)`：它不是原语，它有跳转与未求值分支。

### 控制流（芯片无关）

```
eval test          ; 结果在 RES
if RES == BOOL_F goto L_else
  eval then        ; 结果在 RES
  goto L_end
L_else:
  eval else        ; 结果在 RES
L_end:
```

两个分支结束后 `RES` 都是该 `if` 的值。汇合点不要再改寄存器。

ARCHITECTURE 的后端接口：

```
(emit-jfalse lid)    ; x0 == BOOL_F 则跳
(emit-jmp lid)
(emit-label lid)
```

`emit-if` 只编排这三件加上两次递归 `emit-ir`。`BOOL_F=0x2F` 写进 `emit-jfalse` 一处，不要每个 `if` 手写立即数。

### 标签必须唯一

嵌套 `(if (if …) (if …) (if …))` 会发出多组跳转。若 `L_else` / `L_end` 是全局固定字符串，汇编器报重复标签，或更糟：跳到错误分支。

用计数器生成不透明标签 id，后端当字符串：

```
L_if_else_1
L_if_end_1
L_if_else_2
…
```

Mach-O / Apple `as`：以 `L` 开头的标签是局部符号，适合这种一次性跳转。不要用 `.globl` 修饰它们。

计数器在一次 `compile-program` 开始时归零。不要用随机数（测例的 `.s` 应稳定，方便 diff）。

### 栈与 `ctx`

`test`、`then`、`else` **共用同一个 `ctx`**（同一个 `si`、同一个 `env`）。`test` 内部的二元原语会使用 `si`、`si-8`、… 但那些槽在 `test` 结束后已死亡，分支可以重用同一组槽。不要给 `then` 一个更深的 `si`「以防 test 占用」——那会浪费且让以后 `let` 的槽计算变复杂。

`then` 与 `else` 互斥执行，也可以共用同一组槽。

### 两操作数 `if`

R4RS：`(if test then)` 在 `test` 为假时结果 unspecified。本教程本层要求：

- 列表长度不是 4（`if` + 三个表达式）→ 编译期 `error`
- 不要生成 `else` 为 `(imm VOID)` 的代码（`VOID=0x1F` 要到有 unspecified 值的层才出现）
- 不要把缺省 else 当成 `#f`

这是合同，不是疏忽。L11 的 `and` 展开会显式填上 `#f`，正好总是三操作数。

### 尾位置（为 L31 记账，本层无调用）

`then` 与 `else` 都在该 `if` 的尾位置。本层没有 `lambda`/`call`，emit 不必区分尾与非尾。展开与 IR 形状现在就要对：不要把 `if` 包进多余的 `seq` 让「最后值」落在 seq 的最后一个之外。

建议从本层起保持：表达式结果一律在 `x0`，`if` 汇合后也是。不必 A-normalize `test`；`test` 作为 `Ir` 求值到 `x0` 即可。

## 与上一层的差异

| 项 | L09 | L10 |
|----|-----|-----|
| 核心形式 | 无（只有字面量与 prim） | `(if Ir Ir Ir)` |
| 跳转 | 无 | `b` / `b.eq`，唯一标签 |
| 求值 | 每个子树都求值 | 只有 test + 一条分支 |
| 假值 | `not`/`eq?` 已用 `0x2F` | `emit-jfalse` 与 `BOOL_F` 比较 |
| 栈 | 二元 prim 使用 | `if` 本身不额外占槽 |

## 代码骨架

### 可移植：前端

```scheme
(define (expr->ir expr)
  (cond
    ((and (pair? expr) (eq? (car expr) 'if))
     (unless (length=? expr 4)
       (error "L10: if expects 3 operands" expr))
     `(if ,(expr->ir (cadr expr))
          ,(expr->ir (caddr expr))
          ,(expr->ir (cadddr expr))))
    ;; … prim 与字面量，同 L09 …
    (else (error "L10: bad expr" expr))))
```

先匹配 `if` 再匹配 prim：否则永远走不到。`(if)`、`(if 1)`、`(if 1 2)`、`(if 1 2 3 4)` 全部编译期错。

### 可移植：标签与 `emit-ir`

```scheme
(define *label-n* 0)
(define (reset-labels!) (set! *label-n* 0))
(define (unique-label prefix)
  (set! *label-n* (+ *label-n* 1))
  (string-append prefix "_" (number->string *label-n*)))

(define (emit-ir ir ctx)
  (case (car ir)
    ((imm)  (emit-imm (cadr ir)))
    ((prim) (emit-prim (cadr ir) (cddr ir) ctx))
    ((if)   (emit-if (cadr ir) (caddr ir) (cadddr ir) ctx))
    (else (error "L10: unknown ir" ir))))

(define (emit-if test then else ctx)
  (let ((L-else (unique-label "L_if_else"))
        (L-end  (unique-label "L_if_end")))
    (string-append
      (emit-ir test ctx)
      (emit-jfalse L-else)
      (emit-ir then ctx)
      (emit-jmp L-end)
      (emit-label L-else)
      (emit-ir else ctx)
      (emit-label L-end))))
```

`compile-program` 入口调用 `reset-labels!`。

### aarch64-apple：跳转

```scheme
(define (emit-label lid)
  (string-append lid ":\n"))

(define (emit-jmp lid)
  (string-append "\tb " lid "\n"))

(define (emit-jfalse lid)
  (string-append
    "\tcmp x0, #0x2F\n"
    "\tb.eq " lid "\n"))
```

`0x2F` 可进 `cmp` 立即数。不要 `cbz`（那是比零）。不要 `tbz x0, #0` 之类试图「看标签位」。

`then` 在跳到 `L-end` 之前结果已在 `x0`；`else` 结束后直接落在 `L-end`，不必再 `mov`。

嵌套时内层 `if` 消耗一对标签，外层另一对，互不干扰。Apple `as` 的 `b` 是 26-bit PC 相对，对本层函数体足够。

临时寄存器：`emit-jfalse` 只碰标志与 `x0` 的比较，不必占用 `x9`。分支内部的 prim 仍用 `x9`–`x15`。禁止 `x18`。

Darwin `_` 前缀仍只用于 `_scheme_entry`，局部标签不加下划线前缀也可以（它们不是 C 符号）。

## 测例清单

上一层全部测例仍须通过。

1. `(if #t 1 2)` → `1`
2. `(if #f 1 2)` → `2`
3. `(if 0 1 2)` → `1`（零为真）
4. `(if () 1 2)` → `1`（空表为真）
5. `(if #\A 1 2)` → `1`
6. `(if #t #t #f)` → `#t`；`(if #f #t #f)` → `#f`
7. `(if (fx= 1 1) 10 20)` → `10`；`(if (fx= 1 2) 10 20)` → `20`
8. `(if (if #f #f #t) 1 2)` → `1`（嵌套在 test）
9. `(if #t (if #f 1 2) 3)` → `2`（嵌套在 then）
10. `(if #f 1 (if #t 4 5))` → `4`（嵌套在 else）
11. `(if (not #f) 1 2)` → `1`；`(if (not 0) 1 2)` → `2`
12. `(if (fx+ 0 0) 7 8)` → `7`（算术结果 `0` 仍为真）
13. `(if #f (fxadd1 #t) 0)` → `0`（then 不得求值；若求值了会对 `#t` 做 `fxadd1` 得到非 fixnum，打印失败或垃圾）
14. `(if (eq? 0 #f) 1 2)` → `2`
15. `(if #t 1)` / `(if #t)` / `(if)` / `(if 1 2 3 4)`：编译期错误（必须三操作数）。

测例 13 是「短路」验收：不能先算完两个分支再 `csel`。`csel` 适合 L05 设布尔，不适合 `if` 的表达式分支。

## 验收标准

- 测例 1–14 输出与上表一致。
- `(if 0 1 2)` 为 `1`，`(if #f 1 2)` 为 `2`：假值规则正确。
- `.s` 中每个 `if` 有一对唯一标签；嵌套测例 8–10 的标签编号不重复。
- 未选中分支不出现其副作用（本层用测例 13 的非法 `fxadd1` 间接证明）。不要用「两个 `emit-ir` 都跑完再 `csel x0, …`」实现 `if`。
- 两操作数 `if` 编译期拒绝。
- `emit-jfalse` 比较的是 `0x2F`，不是 `0`。

## 常见坑

- **`cbz` / `cmp #0`**：`(if 0 1 2)` 走 else。唯一合法的假是 `BOOL_F`。
- **两个分支都求值再选择**：纯字面量测例会绿，测例 13 会红或打印 `#<unknown>`。
- **标签重名**：只有最外层 `if` 能跑对。用计数器。
- **`then` 忘了 `b L_end`**：落入 `else`，`(if #t 1 2)` 得到 `2`。
- **else 分支结果不在 `x0`**：例如用了 `x9` 却没 `mov x0, x9`。每个 `emit-ir` 的合同是结果在 `x0`，保持即可。
- **给分支 `ctx-down`**：槽号漂移，以后 `let` 更乱。`if` 三子树共享 `ctx`。
- **接受两操作数 `if` 并返回垃圾**：与合同冲突，L11 的展开也无法依赖「总是三个孩子」。
- **局部标签加了 `.globl` 或与 `_scheme_entry` 撞名**。

## 下一层预告

L11 把 `and` / `or` 在前端展开成 `if`（以及 IR 层的 `let`），后端不再为短路单独发明指令。
