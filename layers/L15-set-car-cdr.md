# L15 — `set-car!` / `set-cdr!`

## 目标

二元原语 `set-car!` / `set-cdr!` 把 pair 的槽改写成新值。目标必须是 pair，否则运行时 `rt_error`。新值可以是任意已编码 Scheme 值。

**本层故意偏离 R4RS：`set-car!` / `set-cdr!` 返回被修改的那个 pair**（仍带 `PAIR_TAG`），而不是 unspecified。原因：L18 才有变量，L22 才有用户语法 `begin`。没有绑定就无法「先 `set-car!` 再 `car` 同一个对象」，除非 mutation 原语把 pair 交回来。锁定测例：

```
(car (set-car! (cons 1 2) 9))  →  9
```

L22 起改回 unspecified / `VOID=0x1F`，测例届时改用 `begin`。本层不要提前返回 `VOID`，否则本层测例全部不可观察。

同时引入**编译器测试脚手架** `%begin`：≥1 个子表达式，只保留最后一个值。IR 用已有的 `(seq Ir …)`。用户语法 `begin` 仍是 L22，前端只认符号 `%begin`。

本层范围之外：用户 `begin`、`let`、环打印检测、把返回值改成 `VOID`、`vector-set!`。

## 原理

### 为何返回 pair 而不是 void

没有名字时，`(set-car! (cons 1 2) 9)` 分配一个 pair、改 car、然后 pair 从表达式结果里消失——你无法再 `car` 它。可选方案与否决理由：

| 方案 | 为何不用 |
|------|----------|
| 提前引入用户 `begin` | 打乱 L22 的顺序合同 |
| 提前引入 `let` | 打乱 L18–L20 |
| 只提供 `%begin`，set-car! 返回 VOID | `(%begin (set-car! (cons 1 2) 9) (car ???))` 仍然拿不到那个 pair |
| **set-car! 返回 pair** | 可以嵌套 `(car (set-car! p v))`；本层锁定 |

`%begin` 仍然有用：测「副作用发生但结果取后一个表达式」，以及为 L16/L17 的多步构造打样。它**不能**单独解决「保住刚分配的 pair」——那必须靠返回 pair。

R4RS 的 `set-car!` 返回值未指定。`ARCHITECTURE.md` 里的 `VOID=0x1F` 给 L22 用。本层 `rt_print` **仍然要认识** `VOID`：遇到 `0x1F` 打印 `#<void>`（无空格）。本层测例不会返回它；加上分支是为了以后改返回值时打印已经稳定，以及避免有人把 `0x1F` 当 fixnum。

### 求值顺序

`(set-car! P V)`：先求值 `P`，栈保存，再求值 `V`。然后检查保存的 `P` 是 pair（不是检查 `V`）。去标签，`str V, [raw]` 或 `[raw, #8]`。把 **tagged P** 放回 `x0`。

`V` 不做类型限制：可以是 fixnum、pair、空表、`#f`。

```
eval P
str  x0, [sp, #-16]!
eval V                       ; x0 = V
mov  x10, x0
ldr  x0, [sp]                ; tagged P（先别 pop，还要返回它）
assert pair
bic  x9, x0, #7              ; raw；x0 仍是 tagged P
str  x10, [x9]               ; 或 [x9, #8]
ldr  x0, [sp], #16           ; 返回 tagged P
```

不要在去标签之后用 raw 当返回值却忘了 `orr PAIR_TAG`：低 3 位变成 0，打印成 fixnum 地址/4。最简单是全程保留 tagged `P`。

### `%begin` 与 IR `seq`

```
(%begin E1 E2 … En)   n≥1
→  (seq Ir1 Ir2 … Irn)
```

求值：依次求值，丢弃前 n−1 个结果（它们的堆副作用保留），返回 `En`。空 `%begin`：编译期错。单元素 `%begin` 是恒等。

这不是用户 `begin`。源程序写 `begin` 仍是未知符号，编译期错。文档与测例文件名、表达式都写 `%begin`。

后端 `emit-seq`：对每个子 IR 调用 `emit-ir`；不必在子表达式之间保存 `x0`。若某个子表达式是 `set-car!`，它的返回值被下一个子表达式覆盖——这正是「丢弃」。

### 打印与环

`set-cdr!` 可以把 cdr 指回自己，但**没有变量时构不成环**：需要把同一个指针存进自己的槽，而表达式树里两次 `(cons 1 2)` 是两个对象。`(set-cdr! (cons 1 2) (cons 1 2))` 不是环。本层不要求环检测。若你用以后的 `let` 手工试验环，`rt_print` 会无限递归——L44 再处理。本层测例禁止依赖环。

### IR

```
(prim set-car! Ir Ir)
(prim set-cdr! Ir Ir)
(seq Ir ...)
```

`set-car!` / `set-cdr!` arity ≠ 2：编译期错。

## 与上一层的差异

| 项 | L14 | L15 |
|----|-----|-----|
| 堆 | 只读槽 | 可 `str` 回槽 |
| mutation 返回值 | 无 | **返回被改的 pair**（非 R4RS） |
| 新核心形式 | 无 | `%begin` → `seq` |
| `VOID` 打印 | 无 | 认识 `0x1F` → `#<void>`（测例不返回它） |
| 运行时错 | `car`/`cdr` 非 pair | `set-car!`/`set-cdr!` 的第一参数非 pair |

## 代码骨架

### 可移植前端

```scheme
(define (expr->ir expr)
  (cond
    ((and (pair? expr) (eq? (car expr) '%begin))
     (if (null? (cdr expr))
         (error "%begin: need >= 1 expression")
         `(seq ,@(map expr->ir (cdr expr)))))
    ((and (pair? expr) (eq? (car expr) 'set-car!) (length=? expr 3))
     `(prim set-car! ,(expr->ir (cadr expr)) ,(expr->ir (caddr expr))))
    ((and (pair? expr) (eq? (car expr) 'set-cdr!) (length=? expr 3))
     `(prim set-cdr! ,(expr->ir (cadr expr)) ,(expr->ir (caddr expr))))
    ;; car/cdr/cons/… 
    (else (error "L15: bad expr" expr))))
```

### 可移植：`emit-seq`

```scheme
(define (emit-ir ir ctx)
  (case (car ir)
    ((seq)
     (let loop ((xs (cdr ir)) (out ""))
       (if (null? xs)
           (error "empty seq")
           (if (null? (cdr xs))
               (string-append out (emit-ir (car xs) ctx))
               (loop (cdr xs)
                     (string-append out (emit-ir (car xs) ctx)))))))
    ;; …
    (else (error "unknown ir" ir))))
```

### aarch64-apple：`set-car!` / `set-cdr!`

`args` = `(P-ir V-ir)`。`off` 为 `0`（car）或 `8`（cdr）。

```scheme
(define (emit-set-pair-slot args ctx off)
  (string-append
    (emit-ir (car args) ctx)       ; P
    "\tstr x0, [sp, #-16]!\n"
    (emit-ir (cadr args) ctx)      ; V in x0
    "\tmov x10, x0\n"
    "\tldr x0, [sp]\n"             ; tagged P
    "\tand x9, x0, #7\n"
    "\tcmp x9, #1\n"
    "\tb.ne _rt_err_type\n"
    "\tbic x9, x0, #7\n"
    "\tstr x10, [x9, #" (number->string off) "]\n"
    "\tldr x0, [sp], #16\n"))      ; return tagged P

(define (emit-set-car args ctx) (emit-set-pair-slot args ctx 0))
(define (emit-set-cdr args ctx) (emit-set-pair-slot args ctx 8))
```

注意：`emit-ir` 求值 `V` 时若内部也是 `cons`/`set-car!`，会继续用栈。先 `str P` 再求值 `V` 是安全的，只要每层配对 push/pop。

### runtime：VOID

```c
#define VOID 0x1F

static void print_value(ptr x) {
    if (x == VOID) { fputs("#<void>", stdout); return; }
    /* … 其余与 L13 相同 … */
}
```

满字比较。不要只看低 8 位。

## 测例清单

上一层全部测例仍须通过。

1. `(car (set-car! (cons 1 2) 9))` → `9`
2. `(cdr (set-car! (cons 1 2) 9))` → `2`
3. `(cdr (set-cdr! (cons 1 2) 9))` → `9`
4. `(car (set-cdr! (cons 1 2) 9))` → `1`
5. `(pair? (set-car! (cons 1 2) 9))` → `#t`（返回 pair，不是 void）
6. `(car (set-car! (set-cdr! (cons 1 2) 3) 4))` → `4`
7. `(cdr (set-car! (set-cdr! (cons 1 2) 3) 4))` → `3`
8. `(car (set-car! (cons 1 2) (cons 8 9)))` → `(8 . 9)`
9. `(%begin 1 2 3)` → `3`
10. `(%begin (cons 1 2) 42)` → `42`
11. `(%begin (set-car! (cons 1 2) 9) 0)` → `0`（mutation 发生但结果取后一个；无法再观察该 pair，本测例只钉 `%begin`）
12. `(set-car! 1 2)`：运行时类型错误
13. `(set-cdr! () 1)`：运行时类型错误
14. `(set-car! (cons 1 2))` / `(set-car!)` / `(%begin)`：编译期 arity / 空 seq 错误
15. `(car (set-cdr! (cons 1 ()) (cons 2 ())))` → `1`；该表达式的值若改成整个 pair：`(set-cdr! (cons 1 ()) (cons 2 ()))` → `(1 2)`

测例 5 防止有人提前返回 `VOID`：`pair?` 对 `#<void>` 为 `#f`。

## 验收标准

- 测例 1–11、15 输出与上表一致。尤其测例 1 是本层合同句，不得改成 `#<void>`。
- 测例 12–13 非 0 退出，stderr 含 `type` 或 `pair`。
- 源程序 `(begin 1 2)` 编译期错（尚未实现用户 `begin`）。
- `set-car!` 路径上有向 `[raw+0]` 的 `str`，`set-cdr!` 向 `[raw+8]`；返回前 `x0` 低 3 位为 `001`。
- 不使用 `x18`。
- `rt_print` 对 `0x1F` 输出 `#<void>`（可另写一个不进回归的手工检查；本层回归不返回 void）。

## 常见坑

- **返回 `VOID` 或返回 `v`**：`(car (set-car! (cons 1 2) 9))` 会变成类型错误或恒等于 9 的假绿（若返回 v，测例 1 碰巧过、测例 2 的 `cdr` 会对 9 报错）。必须返回 pair。
- **返回去标签的 raw**：打印成巨大 fixnum。
- **检查 `V` 是 pair 而不是 `P`**：`(set-car! (cons 1 2) 9)` 会误报类型错误。
- **求值顺序反了**：先 `V` 后 `P` 在本层纯值时测不出来，但 `(set-car! (cons 1 2) (%bump 8))` 的 HP 与栈会乱。锁定左到右。
- **实现了用户 `begin` 却不认 `%begin`**：测例 9 失败。符号必须是 `%begin`。
- **空 `%begin` 生成代码**：合同是编译期错。
- **`str w10, [x9]`**：截断堆指针当 car 存进去。
- **以为本层能测环**：没有变量，做不出 `(set-cdr! p p)`。不要写依赖环的测例。

## 下一层预告

L16 用同一套 bump 做 vector：对象头是一个 fixnum 长度，后面是带标签的元素槽；`vector-set!` 同样先返回 vector 本身。
