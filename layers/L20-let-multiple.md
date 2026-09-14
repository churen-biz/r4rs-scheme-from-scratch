# L20 — 多绑定并行 `let`

## 目标

用户语法扩展为 R4RS **并行** `let`：

```scheme
(let ((id1 E1) (id2 E2) … (idk Ek)) Body)
```

`k ≥ 1` 必须继续支持（L19 回归）；本层加上 `k ≥ 2`。`k = 0` 即 `(let () Body)`：合法，等价于 `Body`（R4RS 允许空绑定表）。

求值合同：

1. 在 **旧 `env`** 里从**左到右**依次求值 `E1 … Ek`；
2. 每求完一个，立刻 `str` 进**连续**栈槽 `si, si+1, …, si+k-1`；
3. **全部**存完后，一次性把 `id1…idk` 加进 `env`；
4. 在新 `env` 下求值 `Body`。

因此：

```scheme
(let ((x 1) (y x)) y)              ; 若无外层 x：E2 里的 x 编译期 unbound
(let ((x 1)) (let ((x 2) (y x)) y)) ; → 1   y 看见的是外层 x
```

同一组绑定里名字重复：`(let ((x 1) (x 2)) x)` 编译期错误（R4RS：error）。

本层范围之外：`let*`、`begin`、`set!`、多表达式 body。并行语义**不要**用「先展开成嵌套 `let`」实现——那会变成 `let*`。

## 原理

### 并行不是「同时」，是「右值彼此看不见新名字」

机器上必须左到右，因为只有一个 `x0`，而且副作用（L15 的 `set-car!` 等）可观察顺序。并行指的是 **名字的作用域**：`Ei` 的自由变量只在进入本 `let` **之前**的 `env` 里找。

经典交换：

```scheme
(let ((a 1) (b 2))
  (let ((a b) (b a))
    (cons a b)))         ; → (2 . 1)
```

内层：`a` 的 rhs 是外层 `b`（2），`b` 的 rhs 是外层 `a`（1）。若误实现成 `let*`，结果是 `(2 . 2)`。

### 连续槽

`k` 个绑定占用 `si … si+k-1`，中间不插洞。body 的 `si` 为 `si+k`。嵌套时内层从外层 body 的 `si` 继续往下。

```
外 (let ((x 1) (y 2)) …)     x:slot0  y:slot1
内 (let ((z 3)) …)            z:slot2
```

对齐：占用 3 个字时 `emit-stack-alloc` 仍把 word 数升到 4，多出来的一格是填充，**不是**某个绑定。下一个 `si` 仍按逻辑槽 3 走，不要因为对齐跳过编号——否则 `env` 与偏移公式不一致。填充格可以暂时闲着，或被更高编号的槽使用（slot 3 的偏移是 `-32`，而 4 字分配恰好覆盖 `-8…-32`）。

### 左到右与副作用

L22 之前 mutator 仍返回**容器**（L15–L17 合同）。可用这一点观察顺序，而不需要 `begin`：

```scheme
(let ((p (cons 1 2)))
  (let ((x (set-car! p 9))
        (y (car p)))
    y))
```

`E1` 先执行 `set-car!`，`E2` 的 `(car p)` 为 `9`。若从右往左求值，`y` 会是 `1`。本测例锁定左到右。

（L22 会把 `set-car!` 的返回值改成 VOID；到时本测例应改成 `begin` 包一层，或接受 `x` 为 VOID 而 `y` 仍为 9——左到右仍然成立。本层期望：`y` 为 `9`；`x` 为改过的 pair，body 只返回 `y`。）

### IR

```
(let ((id1 Ir1) (id2 Ir2) …) Ir_body)
```

前端把每个 `Ei` 在**同一份前端 env**（尚未含本组 `id`）下降 IR，然后一次性扩展前端 env 再降 `Body`。不要把 `E2` 放到 `id1` 已绑定的前端 env 里降——那会让 `(let ((x 1) (y x)) y)` 在无外层 `x` 时错误地通过检查。

### `emit-let` 算法（芯片无关）

```
emit-let bindings body ctx:
  old-env = ctx.env
  si0 = ctx.si
  code = ""
  对 bindings 左到右，下标 i = 0..k-1:
      code += emit-ir(Ei, {si: si0+i, env: old-env})
      code += ensure-frame-covers(si0+i)
      code += emit-stack-save(si0+i)
  new-env = 从右到左或从左到左把每个 id 加到 old-env 前面
            （最左绑定可以在最前或最后，查找必须让后写的同名……
              本组禁止同名，故顺序只影响 alist 形状；
              推荐从左到右 cons，则最右绑定在 alist 头部。
              查找 eq? 唯一，二者都合格。）
  code += emit-ir(body, {si: si0+k, env: new-env})
```

要点：循环里 emit `Ei` 的 `env` **始终**是 `old-env`，`si` 用 `si0+i` 以免右值内部临时打掉已经 save 的 `E0…E(i-1)`。

`Ei` 内部临时从 `si0+i` 起用：求值期间可以覆盖「即将写入的槽」以及更高槽；求完后结果在 `x0`，再 save 到 `si0+i`。已经 save 的 `si0…si0+i-1` 不得当作 `Ei` 的临时。这就是为什么第 `i` 个右值的起始 `si` 是 `si0+i` 而不是 `si0`。

### 空绑定

`(let () E)` → IR 可以是 body 本身，或 `(let () Ir)`。后端对 `k=0` 不 save、不改 `env`、不改 `si`。不要为「空 let」分配 16 字节，除非你的 `emit-stack-alloc(0)` 本来就是空串。

### 重复绑定

前端在扩展前检查 `id` 列表：`eq?` 重复则 `error`，建议关键字 `duplicate`。不要靠 alist 遮蔽假装合法。

## 与上一层的差异

| 项 | L19 | L20 |
|----|-----|-----|
| 绑定个数 | 必须 1 | `≥ 0`，含多个 |
| 右值环境 | 旧 env（只有一项） | 每个 `Ei` 都是**同一**旧 env |
| 槽 | 一个 | 连续 `k` 个 |
| `(let ((x 1) (y x)) y)` | 语法错（多绑定） | 无外层 `x` 则 **unbound**（语法合法） |
| 空 `let` | 拒绝 | `(let () Body) ≡ Body` |

## 代码骨架

### 可移植：前端

```scheme
(define (unique-ids? ids)
  (or (null? ids)
      (and (not (memq (car ids) (cdr ids)))
           (unique-ids? (cdr ids)))))

(define (parse-let expr)
  ;; → (values ((id rhs) ...) body)
  (if (not (and (pair? expr)
                (eq? (car expr) 'let)
                (= (length expr) 3)
                (list? (cadr expr))))
      (error "L20: bad let" expr)
      (let ((raw (cadr expr))
            (body (caddr expr)))
        (let loop ((xs raw) (acc '()))
          (cond
            ((null? xs)
             (let ((binds (reverse acc)))
               (if (not (unique-ids? (map car binds)))
                   (error "duplicate let variable" expr)
                   (values binds body))))
            ((and (pair? (car xs))
                  (symbol? (caar xs))
                  (pair? (cdar xs))
                  (null? (cddar xs)))
             (loop (cdr xs) (cons (car xs) acc)))
            (else (error "L20: bad binding" (car xs))))))))

(define (expr->ir expr env)
  (cond
    ((and (pair? expr) (eq? (car expr) 'let))
     (call-with-values
       (lambda () (parse-let expr))
       (lambda (binds body)
         (let* ((ids (map car binds))
                (rhs* (map cadr binds))
                (ir-rhs* (map (lambda (e) (expr->ir e env)) rhs*))
                (env2 (append-extends ids env)))
           `(let ,(map list ids ir-rhs*)
              ,(expr->ir body env2))))))
    ((symbol? expr)
     (begin (env-lookup-exists expr env) `(ref ,expr)))
    (else (expr->ir-core expr env))))

(define (append-extends ids env)
  (if (null? ids)
      env
      (append-extends (cdr ids) (env-extend (car ids) 'bound env))))
```

每个 `Ei` 都在**同一个**旧 `env` 上调用 `expr->ir`。`env2` 只用于 body。自托管编译器骨架里的 `let*` 是编译器自己的顺序绑定，与用户 `let*` 无关。

### aarch64-apple：循环 save

```scheme
(define (emit-let bindings body ctx)
  (let* ((old-env (ctx-env ctx))
         (si0 (ctx-si ctx)))
    (let loop ((bs bindings)
               (i 0)
               (acc "")
               (new-env old-env))
      (if (null? bs)
          (string-append
            acc
            (emit-ir body (make-ctx (+ si0 i) new-env)))
          (let* ((id (caar bs))
                 (rhs (cadar bs))
                 (slot (+ si0 i))
                 (rhs-ctx (make-ctx slot old-env)))
            (loop (cdr bs)
                  (+ i 1)
                  (string-append
                    acc
                    (emit-ir rhs rhs-ctx)
                    (ensure-frame-covers slot)
                    (emit-stack-save slot))
                  (env-extend id slot new-env)))))))
```

`new-env` 在循环中累积，但 **`rhs-ctx` 的 env 固定为 `old-env`**。这是本层唯一允许写多绑定循环的地方。

连续槽的 store：

```asm
    ; E1 结果
    str     x0, [x29, #-8]
    ; E2 结果
    str     x0, [x29, #-16]
    ; body 里 ref x / ref y
    ldr     x0, [x29, #-8]
    ldr     x0, [x29, #-16]
```

## 测例清单

上一层全部测例仍须通过。

1. `(let ((x 1) (y 2)) (fx+ x y))` → `3`
2. `(let ((x 1) (y 2) (z 3)) (fx+ (fx+ x y) z))` → `6`
3. `(let ((x 1) (y 2)) x)` → `1`
4. `(let ((x 1) (y 2)) y)` → `2`
5. `(let ((x 1) (y x)) y)`：无外层 `x` → 编译期 `unbound`
6. `(let ((x 1)) (let ((x 2) (y x)) y))` → `1`（并行看见外层）
7. `(let ((a 1) (b 2)) (let ((a b) (b a)) (cons a b)))` → `(2 . 1)`（交换；若得 `(2 . 2)` 则做成了 `let*`）
8. 左到右：

   ```scheme
   (let ((p (cons 1 2)))
     (let ((x (set-car! p 9))
           (y (car p)))
       y))
   ```

   → `9`
9. `(let ((x 1) (x 2)) x)`：编译期 `duplicate`（或文档锁定的同一关键字）
10. `(let () 42)` → `42`
11. `(let ((x 1) (y 2)) (let ((x 9)) (fx+ x y)))` → `11`（body 内单绑定遮蔽）
12. `(let ((x 1) (y 2)) (let ((z 3)) (fx+ (fx+ x y) z)))` → `6`（连续槽 + 嵌套）
13. `(let ((x #t) (y #f)) (if y x y))` → `#f`
14. `(let ((x 1) (y 2)) z)`：编译期 `unbound`
15. `(let ((n 4)) (let ((a n) (b n)) (fx+ a b)))` → `8`（两个 rhs 都读外层，互不相依）
16. 单绑定回归：`(let ((x 3)) (fx+ x x))` → `6`

## 验收标准

- 测例 1–4、6–8、10–13、15–16 打印正确。
- 测例 5、9、14 编译期失败。
- 测例 7 不得为 `(2 . 2)`。
- 测例 8 不得为 `1`（那是右到左）。
- 三个绑定的偏移是 `-8`、`-16`、`-24`（或你锁定的等价公式），中间不跳号。
- 后端对 rhs **禁止**使用已扩展的 `new-env`。

## 常见坑

- **用嵌套 `let` 实现多绑定**：`(let ((x E1) (y E2)) B)` 变成 `(let ((x E1)) (let ((y E2)) B))` 后，测例 5 会变成「绑定 `x` 之后 `y` 看见 `x`」，期望从 unbound 变成 `1`。并行必须在后端或降 IR 时保持「一组绑定一个 `let` 节点」。
- **第 2 个 rhs 的 `si` 仍从 `si0` 起**：会把已 save 的 `E1` 当临时覆盖。第 `i` 个从 `si0+i` 起。
- **对齐跳过 slot 编号**：逻辑槽必须连续；对齐只影响 `sub sp` 的字节数。
- **重复名字靠遮蔽「能跑」**：R4RS 这是 error，本层编译期拒绝。
- **`(let ((x 1) (y x)) y)` 在前端用新 env 降 `y` 的 rhs**：L21 的 `let*` 才允许。本层测例 5 是守卫。

## 下一层预告

并行 `let` 故意让「后一个绑定用前一个名字」失败或看到外层。下一层要顺序绑定 `let*`：`(let* ((x 1) (y x)) y)` 为 `1`，且不新写后端。
