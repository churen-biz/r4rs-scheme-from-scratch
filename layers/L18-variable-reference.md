# L18 — 变量引用：`(let ((x Lit)) x)` 与 `(ref id)`

## 目标

第一次让程序里出现**名字**。本层只证明一件事：把一个 L17 表达式的值写进栈槽，再按名字读回来，结果与直接返回该表达式相同。

用户语法**仅**允许这一种绑定形状：

```scheme
(let ((id Lit)) id)
```

约束锁死：

- 恰好 **一个** 绑定；`id` 是符号。
- 右值 `Lit` 是任意 **L17 表达式**（字面量、`if`、原语、`cons` / 向量 / 字符串……），通常是字面量。
- **body 必须是那个被绑定的标识符本身**。不是 `(fxadd1 x)`，不是嵌套 `let`，不是别的变量。
- 空环境里出现标识符、body 写成未绑定名字：皆为**编译期错误**。

本层范围之外：嵌套 `let`、多个绑定、body 不是该变量、`set!`、`let*`、`begin`、隐式 begin 的多表达式 body、顶层 `define`。L17 的无绑定程序仍然合法（回归）。

做完本层，`(let ((x 42)) x)` 打印 `42`，并且 `x` 是从栈槽 `ldr` 出来的，不是右值求值后碰巧留在 `x0` 里。

## 原理

### 为何先做「读回来」而不是完整 `let`

L07 起二元原语已经在用**匿名栈槽**保存第一个操作数。那些槽没有名字，用完即弃。变量是同一块栈，多一张 **环境表**。

若本层直接允许 `(let ((x 1)) (fx+ x x))`，你分不清失败来自「没存上」还是「第二次 `ref` 用错了槽」。把 body 限制成那个标识符，测例只考验：

1. 右值求值到 `x0`；
2. `str` 进槽；
3. `ldr` 回 `x0`；
4. 名字在 `env` 里能查到。

L19 再放开 body。

### `ctx`：`si` 与 `env`

与 ARCHITECTURE §6、层间合同一致。本层把形状钉死：

```
ctx = {si, env}

si   : 下一个可用栈槽编号（整数 ≥ 0，以 word 计）
env  : alist，id → (stack . slot)
```

栈相对帧指针 **向下**增长（低地址方向）。aarch64 默认偏移：

```
off(slot) = -8 * (slot + 1)
```

| slot | `[x29, #off]` |
|------|----------------|
| 0 | `-8` |
| 1 | `-16` |
| 2 | `-24` |

`si` 是编号不是字节：第一次绑定用 `slot = si`（起始为 0），存完后把 `si` 加 1 再编译 body。匿名临时（二元原语的操作数）与命名绑定**共用**这一套编号。编译右值时传入当前 `si`；右值内部的临时从同一个 `si` 起用；右值结束后那些临时已死，绑定就占用这个 `si` 槽把结果存进去。

`env` 在本层只有一种位置：`(stack . slot)`。L26 才会出现 `(free . index)`；不要提前把值留在寄存器里当 `(reg . r)`——本层测例要求能 `ldr`。

查找：从 alist **头部**往下。本层没有嵌套绑定，表里最多一项；L19 起同一名字的内层绑定 `cons` 在前面，即遮蔽。

未命中 → 编译期 `error`，关键字建议含 `unbound`。不要生成「加载槽 0」的汇编碰运气。

### 栈与 16 字节对齐

aarch64 调用点 `sp` 必须 16 字节对齐。一个 Scheme 字 8 字节，因此分配的 **word 数向上取偶数**：

```
n-words 对齐 = (n + 1) 然后清掉最低位
             = (n + 1) & ~1
1 个字 → 分配 2 个字 = 16 字节
2 个字 → 16 字节
3 个字 → 4 个字 = 32 字节
```

`emit-stack-alloc n-words` 发出 `sub sp, sp, #(aligned*8)`。

**锁定的分配策略（本层起，直到有过程调用再复查）**：

1. `scheme_entry` 序言照旧保存 `x29`/`x30`（以及已有的 `x19`/`x20`），然后 `mov x29, sp`，使 **FP 指向保存的 FP/LR 对**。
2. 局部槽在 FP **下方**，不覆盖 `[x29,#0]` / `[x29,#8]`。
3. 需要写入 `slot` 时，若当前已分配字数 `< slot+1`（再对齐到偶数），就再 `sub sp`。
4. **离开 `let` 不把 `sp` 加回去**；整段程序的高水位一直留着。跋里 `mov sp, x29` 一次收回。
5. 已分配字数是后端发射期的可变状态，**不是**可移植 `ctx` 的字段。`ctx` 仍只有 `si` 与 `env`。

序言/跋（在 L12 已保存 `HP` 的前提下；本层若你还把 `HL` 放 `x20`，对称恢复）：

```asm
_scheme_entry:
    stp     x29, x30, [sp, #-32]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    mov     x19, x0
    add     x20, x19, x1
    ; ... 主体：按需 sub sp；局部 str/ldr [x29, #off] ...
    mov     sp, x29              ; 本层起必须有：局部可能压低了 sp
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret
```

`off` 在 ±256 以内可用 `str x0, [x29, #-8]` 这种 9-bit 非缩放立即数。槽很多时超出范围：先把地址算进 `x9` 再访存。本层测例槽数极少，但 `emit-stack-save` / `emit-stack-load` 请写成可扩展的一个函数，不要每层改公式。

若你的序言让局部落在 FP **正**偏移，只改 `off(slot)` 的公式，**不要**改 `si` 从 0 编号、也不要改 `env` 的 `(stack . slot)`。合同是 ctx 形状，不是某一种序言美学。

### IR

ARCHITECTURE 已有：

```
(let ((<id> Ir) ...) Ir)
(ref <id>)
```

本层前端只构造 **单绑定** `let`，body 一定是 `(ref id)`：

```
(let ((x 42)) x)
  →  (let ((x (imm 168))) (ref x))    ; 168 = 42 << 2
```

右值是 L17 表达式时，先 `expr->ir` 再包进 `let`。后端 `emit-let` / `emit-ref` 本层就要能跑；不要在前端把 `let` 降成「求值 + save + load」三连而丢掉 IR——L19 的 body 不是 `ref` 时还要走同一套 `emit-let`。

`id` 本层可用源程序里的符号。没有宏，不必 gensym。后端把 `id` 当不透明键去查 `env`，不要在汇编标签里嵌入用户名字（栈槽没有标签）。

### 前端语法（锁死）

`expr` 是 `let` 当且仅当：

```
(let ((<symbol> <L17-expr>)) <symbol>)
```

且两个 `<symbol>` `eq?`。任一偏离 → 编译期错误，不要「尽量编译」：

| 输入 | 本层 |
|------|------|
| `(let ((x 1)) x)` | 合法 |
| `(let ((x (fx+ 1 2))) x)` | 合法（Lit 是 L17） |
| `(let ((x 1)) (fxadd1 x))` | 错误（body 不是该标识符） |
| `(let ((x 1) (y 2)) x)` | 错误（多绑定） |
| `(let ((x 1)) (let ((y 2)) y))` | 错误（嵌套；内层也不是「仅 ref」所能表达的本层语法） |
| `(let ((x 1)) y)` | 错误（`y` 未绑定；即使你想当 ref 降，也查不到） |
| `x` | 错误（顶层空 `env`） |
| `(let ((x 1)))` | 错误（缺 body） |
| `(let ((x 1)) x x)` | 错误（多 body；隐式 begin 不在本层） |
| `(let (x 1) x)` | 错误（绑定不是 `((id e) …)`） |

「嵌套 let」即使内层单独看合法，外层 body 也不是标识符，整棵树拒绝。不要递归地对内层放行——否则测例无法证明限制还在。

非 `let` 的表达式走 **完整 L17** 的 `expr->ir`（字面量与原语、`if` 等）。回归不要求每个程序都含 `let`。

### 发射 `let` 与 `ref`

芯片无关顺序：

```
emit-let ((id rhs)) body ctx:
  1. emit-ir rhs ctx          ; 仍用旧 env、当前 si；结果在 x0
  2. 保证栈覆盖 slot=si
  3. emit-stack-save si       ; str x0, [fp, off(si)]
  4. ctx' = {si+1, env 加上 id → (stack . si)}
  5. emit-ir body ctx'

emit-ref id ctx:
  查 env 得 (stack . slot)，否则 error
  emit-stack-load slot        ; ldr x0, [fp, off(slot)]
```

aarch64：

```asm
    str     x0, [x29, #-8]     ; save slot 0
    ldr     x0, [x29, #-8]     ; load slot 0
```

对 `(let ((x Lit)) x)`，这两条会紧挨着出现在右值代码之后。评测时可以看生成的 `.s` 里是否真有 `ldr`：若优化掉 load、直接把右值留在 `x0`，L19 第一次「body 里用两次 `x`」会突然坏掉。本层**禁止**这种窥孔优化。

### 与 L07 匿名槽的统一

若 L07 曾用 `[sp, #imm]` 而不是 `[x29, #off]`，本层起 **全部改到 FP 相对**。`si` 从 0 起对两种用途同一计数。`(fx+ 1 2)` 仍无 `env` 项，只是把第一个操作数存进 `slot=si`。旧测例不得因改寻址而红。

## 与上一层的差异

| 项 | L17 | L18 |
|----|-----|-----|
| 名字 | 无；标识符一律编译期错 | `env` 里有的标识符可 `ref` |
| 用户 `let` | 无 | 仅 `((id Lit) id)` 这一种 |
| IR | `imm` / `prim` / `if` / … | 增加 `(let …)`、`(ref id)` |
| 栈 | 匿名临时 | 匿名临时 + 命名槽 |
| `emit-stack-load` | 可能已有（二元原语） | 必须按名字走 `env` |
| 跋 | 往往假设 `sp` 未再降低 | 必须 `mov sp, x29` 再恢复 FP 链 |

## 代码骨架

### 可移植：环境与 `expr->ir`

```scheme
(define (make-ctx si env) (cons si env))
(define (ctx-si ctx) (car ctx))
(define (ctx-env ctx) (cdr ctx))

(define (env-lookup id env)
  (cond
    ((null? env)
     (error "unbound variable" id))
    ((eq? (caar env) id)
     (cdar env))              ; (stack . slot)
    (else (env-lookup id (cdr env)))))

(define (env-extend id slot env)
  (cons (cons id (cons 'stack slot)) env))

(define (simple-let? expr)
  (and (pair? expr)
       (eq? (car expr) 'let)
       (= (length expr) 3)
       (let ((bindings (cadr expr))
             (body (caddr expr)))
         (and (pair? bindings)
              (null? (cdr bindings))
              (let ((b (car bindings)))
                (and (pair? b)
                     (null? (cddr b))
                     (symbol? (car b))
                     (symbol? body)
                     (eq? (car b) body)))))))

(define (expr->ir expr)
  (cond
    ((simple-let? expr)
     (let* ((b (car (cadr expr)))
            (id (car b))
            (rhs (cadr b)))
       `(let ((,id ,(expr->ir rhs))) (ref ,id))))
    ((symbol? expr)
     (error "unbound variable" expr))
    ((and (pair? expr) (eq? (car expr) 'let))
     (error "L18: let must be (let ((id Lit)) id)" expr))
    (else
     (expr->ir-L17 expr))))
```

顶层：

```scheme
(define (compile-program expr)
  (emit-program (expr->ir expr) (make-ctx 0 '())))
```

### aarch64-apple：`emit-let` / `emit-ref` / 栈

```scheme
(define (slot-offset slot)
  (* -8 (+ slot 1)))

(define (emit-stack-save slot)
  (string-append
    "\tstr x0, [x29, #" (number->string (slot-offset slot)) "]\n"))

(define (emit-stack-load slot)
  (string-append
    "\tldr x0, [x29, #" (number->string (slot-offset slot)) "]\n"))

(define (emit-stack-alloc n-words)
  (let ((n (bitwise-and (+ n-words 1) -2)))
    (if (zero? n)
        ""
        (string-append "\tsub sp, sp, #" (number->string (* n 8)) "\n"))))

(define (emit-ref id ctx)
  (let ((loc (env-lookup id (ctx-env ctx))))
    (if (eq? (car loc) 'stack)
        (emit-stack-load (cdr loc))
        (error "L18: ref location" loc))))

(define (emit-let bindings body ctx)
  (if (not (= (length bindings) 1))
      (error "L18: backend let expects 1 binding" bindings)
      (let* ((id (caar bindings))
             (rhs (cadar bindings))
             (si (ctx-si ctx))
             (env (ctx-env ctx)))
        (string-append
          (emit-ir rhs ctx)
          (ensure-frame-covers si)     ; 内部调用 emit-stack-alloc
          (emit-stack-save si)
          (emit-ir body
                   (make-ctx (+ si 1) (env-extend id si env)))))))
```

`ensure-frame-covers` 用后端私有的「已分配字数」与 `emit-stack-alloc` 实现。`emit-ir` 对 `(ref id)` 分派 `emit-ref`，对 `(let …)` 分派 `emit-let`。

`emit-prim` 里保存第一操作数改为 `emit-stack-save`（当前 `si`），递归第二操作数时 `ctx` 的 `si` 加 1，运算前 `emit-stack-load` 到 `x9`（或你 L07 用的临时寄存器）。不要另搞一套偏移。

## 测例清单

上一层全部测例仍须通过。

1. `(let ((x 0)) x)` → `0`
2. `(let ((x 42)) x)` → `42`
3. `(let ((x -1)) x)` → `-1`
4. `(let ((x #t)) x)` → `#t`
5. `(let ((x #f)) x)` → `#f`
6. `(let ((x ())) x)` → `()`
7. `(let ((x (fx+ 1 2))) x)` → `3`
8. `(let ((x (cons 1 2))) x)` → `(1 . 2)`（打印按 L13）
9. `(let ((x (if #f 1 2))) x)` → `2`
10. `(let ((x (car (cons 7 8)))) x)` → `7`
11. `(let ((x (fx+ (fx* 2 3) 4))) x)` → `10`
12. 无 `let` 的回归：`42`、`(cons 1 '())` 等仍过。
13. 顶层 `x`：编译期错误，stderr 含 `unbound`。
14. `(let ((x 1)) y)`：编译期错误，`unbound`。
15. `(let ((x 1)) (fxadd1 x))`：编译期错误（body 不是该标识符）。slug：`err-body-not-id`。
16. `(let ((x 1) (y 2)) x)`：编译期错误（多绑定）。
17. `(let ((x 1)) (let ((y 2)) y))`：编译期错误（嵌套）。
18. `(let ((x 1)) x x)`：编译期错误（多 body）。

错误测例退出码非 0，不生成可执行文件（或生成了也不运行成功）。驱动按 ARCHITECTURE §10。

## 验收标准

- 测例 1–12 标准输出与期望字节级一致，退出码 0。
- 测例 13–18 在**编译期**失败，不得拖到运行时 SIGSEGV。
- 生成的汇编对测例 1 含 `str` 与 `ldr`，偏移与 `slot 0` 的公式一致。
- `scheme_entry` 跋在 `ldp x29, x30` 之前恢复 `sp`（`mov sp, x29` 或等价）。
- `sp` 的调整量是 16 的倍数。
- 未实现 `set!`：`(let ((x 1)) (set! x 2))` 编译期拒绝。
- 没有为变量分配堆对象（本层不是 box）。

## 常见坑

- **右值结束时跳过 `ldr`**：`(let ((x 42)) x)` 会假绿；`(let ((x 1)) (fx+ x x))` 在 L19 爆炸。本层禁止省略 `ref` 的 load。
- **`si` 用字节**：`off` 会变成 `-8*(8+1)`。`si` 是槽编号。
- **绑定写进右值用过的临时槽之前没等右值结束**：顺序必须是「先完整 emit 右值，再 save」。右值的临时可以与将要占用的槽编号相同——它们不同时活着。
- **FP 链**：只 `sub sp` 不在跋里 `mov sp, x29`，`ldp` 会从错误地址恢复，表现为返回后崩溃，而不是打印错误。
- **`[x29, #-8]` 与已保存的 FP/LR 重叠**：若序言 `mov x29, sp` 后局部却写在正偏移，或 slot 公式用了 ` -8*slot` 而不是 `-8*(slot+1)`，会打掉返回地址。
- **把 `let` 当运行时原语**：`let` 不是 `prim`。不要 `emit-prim 'let`。
- **宿主 `let` 与源程序 `let`**：前端用 `eq?` 看符号 `let`，不要在编译器自己的辅助函数里不小心捕获了用户标识符（本层无宏，通常无事；不要把用户 `id` 做成汇编标签）。

## 下一层预告

body 还只能是那个变量。下一层要让 `(let ((x Expr)) Body)` 的 `Body` 成为任意表达式——同一变量读两次、嵌套 `let`、在 `if` 与原语里用名字。
