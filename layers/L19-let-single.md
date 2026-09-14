# L19 — 单绑定 `let`：任意 body

## 目标

放开 L18 对 body 的限制。用户语法：

```scheme
(let ((id Expr)) Body)
```

- 恰好一个绑定。
- `Expr`、`Body` 都是本层表达式：可含原语、`if`、`and`/`or`、堆对象，以及**嵌套的单绑定 `let`**。
- 求值：先把 `Expr` 求到 `x0`，`str` 进新槽，把 `id → (stack . slot)` 加到 `env` 前面，再求值 `Body`；`Body` 的值即 `let` 的值。
- **遮蔽**：内层同名绑定占用**新槽**，查找时先命中内层；外层槽原样保留。不是把外层那一格覆写掉。
- 并行绑定不适用（只有一项）。多绑定留 L20。

本层范围之外：`let` 多个绑定、`let*`、`begin`、`set!`、多表达式 body（隐式 begin）、顶层 `define`。未绑定标识符仍是编译期错误。

做完后 `(let ((x 3)) (fx+ x x))` 为 `6`，`(let ((x 1)) (let ((x 2)) x))` 为 `2`。

## 原理

### 语言形状

```
E ::= L17 的全部（字面量、prim、if、and/or、cons/向量/字符串…）
    | id                          ; 须在 env 中
    | (let ((id E)) E)
```

`id` 出现在表达式位置就是引用，不再要求它是某个 `let` 的唯一 body。L18 的 `(let ((x Lit)) x)` 是本层的特例，须继续通过。

### 为何 `fx+` 两次 `x` 强迫「值在槽里」

```scheme
(let ((x 3)) (fx+ x x))
```

发射 `fx+` 时：

1. 求左操作数：`ref x` → `ldr` 槽 → `x0 = 3`（已标签）；
2. `str` 到**当前 `si`**（匿名临时，不是 `x` 自己的槽）；
3. 求右操作数：再一次 `ref x` → **还是** `x` 的槽，不是临时槽；
4. 把临时 load 进 `x9`，`add`。

若 L18 偷懒没写 `ldr`，或把 `x` 和二元原语临时都挤在 slot 0，这里会读到垃圾或把绑定打掉。`x` 的槽号在进入 body 之后**冻结**；body 里的临时从 `si = 绑定槽 + 1` 起用。

### 嵌套与遮蔽

```scheme
(let ((x 1))           ; x → slot 0
  (let ((x 2))         ; 内层 x → slot 1，env 头部
    x))                ; ref 命中 slot 1 → 2
```

外层 `x` 仍在 slot 0。内层结束（若还有后续表达式——本层 `let` 只有一个 body，所以外层 `let` 的值就是内层值）不需要「恢复」slot 0 的内容，它从未被内层 `str` 覆盖。

**锁定：遮蔽 = 扩展 `env` + 新 `si`，不是 reuse 同名旧槽。**

内层右值看见**外层**环境：

```scheme
(let ((x 1))
  (let ((x (fxadd1 x)))  ; 右侧的 x 是 slot 0
    x))                  ; body 的 x 是 slot 1 → 2
```

这不是 L20 的并行 `let`：这是两个单绑定、先后进入。内层 rhs 求值时 `ctx` 仍是外层的 `{si=1, env: x→slot0}`；存完后才变成 `{si=2, env: x→slot1, x→slot0}`。

更深：

```scheme
(let ((x 1))
  (let ((y x))
    (let ((x 9))
      (fx+ y x))))       ; y=1, 内 x=9 → 10
```

`y` 在中间一层，不受最内层 `x` 遮蔽。

### `if` 两支共用 `si` 与 `env`

L10 的 `if`：test / then / else 都把结果放 `x0`，两支结束时 `si` 相同。本层把同一个 `ctx` 传进两支（或传副本但 `si`/`env` 相等）。不要在 then 里把 `si` 加完却让 else 用更大的 `si` 而当两支汇合——匿名槽在两支是互斥的，汇合后都死；命名槽两支只读（尚无 `set!`）。

```scheme
(let ((x #f))
  (if x 1 2))            ; → 2
```

### IR

与 L18 相同节点，放宽前端：

```
(let ((id Ir_rhs)) Ir_body)
(ref id)
```

`Ir_body` 可以是 `prim`、`if`、另一个 `let`、`ref`。后端 `emit-let` 在 L18 已按「先 rhs、save、扩展 env、再 body」写好的，本层**不应改算法**，只删掉「bindings 长度必须为 1 以外还要求 body 是 ref」的前端检查。后端若 L18 硬编码 `body` 只能是 `ref`，这里改成递归 `emit-ir`。

### 单绑定的「并行」

R4RS 并行绑定在一项时退化为：rhs 在旧 `env` 求值。`emit-let` 对 rhs 传入的必须是**未扩展**的 `ctx`。对单绑定这与「先扩展再求 rhs」的差异只在 rhs 是否能看到即将绑定的名字：

```scheme
(let ((x x)) x)          ; 若无外层 x：编译期 unbound
```

不要先 `env-extend` 再 emit rhs，否则未初始化槽会被当成 `x`（以后 L28 `letrec` 才是那种语义）。

### body 恰好一个表达式

R4RS 的 `let` body 是隐式 `begin`。本层锁定：**恰好一个表达式**。`(let ((x 1)) x x)` 仍编译期错。序列化求值是 L22 的 `begin`，到时写成 `(let ((x 1)) (begin …))`。

## 与上一层的差异

| 项 | L18 | L19 |
|----|-----|-----|
| body | 必须是被绑定的那个标识符 | 任意本层表达式 |
| 嵌套 `let` | 拒绝 | 允许；内层 rhs 见外层 `env` |
| `ref` 出现位置 | 只作为该 `let` 的 body | 任意值位置 |
| 后端 `emit-let` | 可已通用 | 必须对任意 body 递归 |
| 遮蔽 | 无 | 同名新槽 + alist 头部 |

## 代码骨架

### 可移植：前端

```scheme
(define (let-form? expr)
  (and (pair? expr) (eq? (car expr) 'let)))

(define (parse-single-binding expr)
  ;; 成功则 (values id rhs body)，否则 error
  (if (not (and (= (length expr) 3)
                (pair? (cadr expr))
                (null? (cdr (cadr expr)))))
      (error "L19: let must be (let ((id Expr)) Body)" expr)
      (let ((b (car (cadr expr)))
            (body (caddr expr)))
        (if (not (and (pair? b)
                      (symbol? (car b))
                      (pair? (cdr b))
                      (null? (cddr b))))
            (error "L19: bad binding" b)
            (values (car b) (cadr b) body)))))

(define (expr->ir expr)
  (cond
    ((let-form? expr)
     (call-with-values
       (lambda () (parse-single-binding expr))
       (lambda (id rhs body)
         `(let ((,id ,(expr->ir rhs))) ,(expr->ir body)))))
    ((symbol? expr)
     `(ref ,expr))          ; 未绑定在 emit-ref / 或这里查不到顶层 env 时 error
    (else (expr->ir-L17 expr))))
```

顶层 `env` 仍是 `'()`。`expr->ir` 可以不查绑定（把 `(ref id)` 交给后端），也可以在 `expr->ir` 带 `env` 做编译期检查。**锁定：未绑定在生成汇编之前报错。** 推荐前端带 env 的递归，这样错误不依赖后端：

```scheme
(define (expr->ir expr env)
  (cond
    ((let-form? expr)
     (call-with-values
       (lambda () (parse-single-binding expr))
       (lambda (id rhs body)
         `(let ((,id ,(expr->ir rhs env)))
            ,(expr->ir body (env-extend id 'bound env))))))
    ((symbol? expr)
     (begin
       (env-lookup-exists expr env)   ; 只检查名字是否出现；槽号后端再填
       `(ref ,expr)))
    ...))
```

前端 env 可以只记「已绑定」，槽位仍由 `emit-let` 分配。两处都查也可以，但槽号以 emit 时为准。

### aarch64-apple：嵌套时的 `si`

L18 的 `emit-let` 已是对的。确认递归：

```scheme
(define (emit-let bindings body ctx)
  (let* ((id  (caar bindings))
         (rhs (cadar bindings))
         (si  (ctx-si ctx)))
    (string-append
      (emit-ir rhs ctx)                 ; 旧 env
      (ensure-frame-covers si)
      (emit-stack-save si)
      (emit-ir body
               (make-ctx (+ si 1)
                         (env-extend id si (ctx-env ctx)))))))
```

多绑定的 `for` 循环不要在本层写完并「顺便」用新 env 求下一个 rhs——那是错误的 `let*` 后端。L20 再写并行循环。

`emit-if`：then/else 使用**同一个** `ctx`（相同 `si` 与 `env`）。

同一 body 两次 `ref`：

```asm
    ldr     x0, [x29, #-8]     ; x
    str     x0, [x29, #-16]    ; 临时，si=1
    ldr     x0, [x29, #-8]     ; x 再来
    ldr     x9, [x29, #-16]
    add     x0, x9, x0         ; fx+ 已标签相加（L07 合同）
```

具体算术指令与 L07 一致；这里只要求两次 load 都来自 `x` 的槽。

## 测例清单

上一层全部测例仍须通过。

1. `(let ((x 1)) (fxadd1 x))` → `2`
2. `(let ((x 3)) (fx+ x x))` → `6`（同一变量用两次）
3. `(let ((x 3)) (fx* x x))` → `9`
4. `(let ((x 1)) (let ((y 2)) (fx+ x y)))` → `3`（嵌套、异名）
5. `(let ((x 1)) (let ((x 2)) x))` → `2`（遮蔽）
6. `(let ((x 1)) (let ((x (fxadd1 x))) x))` → `2`（内层 rhs 见外层）
7. `(let ((x 1)) (let ((y x)) (let ((x 9)) (fx+ y x))))` → `10`
8. `(let ((x 1)) (let ((y 2)) x))` → `1`（内层结束外层仍在）
9. `(let ((x #f)) (if x 1 2))` → `2`
10. `(let ((x 10)) (if (fx< x 0) x (fxadd1 x)))` → `11`
11. `(let ((x (cons 1 2))) (cons (cdr x) (car x)))` → `(2 . 1)`
12. `(let ((x 1)) (let ((y (let ((x 5)) x))) (fx+ x y)))` → `6`
13. `(let ((x x)) x)`：无外层 `x` → 编译期 `unbound`
14. `(let ((x 1)) y)`：编译期 `unbound`
15. `(let ((x 1) (y 2)) (fx+ x y))`：编译期错误（仍拒绝多绑定）
16. `(let ((x 1)) x x)`：编译期错误（多 body）
17. `(let ((x 1)) (let ((y 2)) (let ((z 3)) (fx+ (fx+ x y) z))))` → `6`
18. L18 形态回归：`(let ((x 42)) x)` → `42`

## 验收标准

- 测例 1–12、17–18 退出码 0，打印正确。
- 遮蔽测例 5、6、7、12：内层绝不能 `str` 到外层 `x` 的槽（可用 `.s` 或逻辑审查：内层 `si` 严格大于外层 slot）。
- `(fx+ x x)` 的两次操作数都来自绑定槽的 `ldr`，不是「第一次 load 后把 `x0` 当第二次」。
- 多绑定、多 body、未绑定：编译期错。
- L18 测例无需改期望。

## 常见坑

- **内层同名覆写 slot 0**：看起来测例 5 仍绿（body 只要内层值），但测例 8、12 会把外层毁掉。环境是栈式表，槽是新下标。
- **内层 rhs 用了已经 extend 的 env**：`(let ((x (fxadd1 x))) …)` 在无外层时会变成读未写槽，而不是 `unbound`。rhs 必须用旧 `env`。
- **`if` 两支各自 `si += n` 且共享后续**：本层 `let` 值就是 `if` 值，汇合后无后续；但 `if` 写在 `fx+` 操作数里时会有后续。两支从同一 `si` 起步。
- **`and`/`or` 展开后的 `if` 里引用变量**：L11 展开须把标识符原样留下，由本层 `ref`。不要在 expand 时求值。
- **把 body 编译进 rhs 的 `si`**：save 绑定后必须 `si+1`。否则 body 里第一个临时 `str` 打掉绑定。

## 下一层预告

还只能写一个绑定。下一层要 `(let ((x E1) (y E2) …) Body)`，并且右值全部在**旧**环境里从左到右求完，再一起进入 `env`——与「边绑边看」不是同一种 `let`。
