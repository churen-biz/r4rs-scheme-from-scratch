# L25 — 多参数与 arity 检查

## 目标

`lambda` 形参改为 **0 个及以上的固定列表**（仍无 rest）。调用时把实参放进 `x0`–`x7`，超过 8 个的走栈。每个 Scheme 过程序言用 `x8` 里的 argc 与编译期期望值比较，不等则 `rt_error`。

做完本层：`((lambda (a b c) (fx+ a (fx+ b c))) 1 2 3)` 打印 `6`；少参、多参都非 0 退出。L24 的 0/1 参测例仍过——**不改闭包布局**。

本层范围之外：rest / `apply`、自由变量、尾调用、把 arity 暴露成用户原语。可变 arity 的 R4RS `+` 仍不要做（继续用 `fx+`）。

## 原理

### 布局：不reshape

L24 已经写出：

```
+0  code     raw
+8  arity    fixnum（形参数）
+16 nfree    fixnum（本层仍为 0）
+24 fv…
```

L25 **禁止**把 arity 插到别的偏移，或改回两字头。若实现者曾误把 nfree 放在偏移 8，必须在本层之前（即按 L24）改过来：L24 测例按三字头编写。本层只是开始 **使用** 那个 arity 字（调试可读），序言比较本身用编译期常数，不必每次从堆加载。

### 传参

| 实参下标 | 位置 |
|----------|------|
| 0–7 | `x0`–`x7` |
| 8+ | 调用瞬间的栈槽：`[sp, #0]`、`[sp, #8]`、… |

调用点 `sp` 仍须 16 字节对齐。若溢出参数占用奇数个 8 字节槽，**多留 8 字节填充**。例如 9 个实参：8 个寄存器 + 栈上 16 字节（1 个值 + 1 个 pad）。

求值顺序：左到右。因为 `x0` 会被下一个参数的求值覆盖，已求值的实参先 `str` 到 **当前帧** 的临时槽，全部求完再装填 `x0`–`x7` 与溢出区，最后装 `x10`（闭包）和 `x8`（argc），`blr x9`。

`argc` 在 `x8`：**原始整数**（例如 3），与堆上 arity 字（fixnum `3<<2`）表示不同。序言：

```
    cmp  x8, #3
    b.eq L_arity_ok
    ; 装消息指针到 x0，走 Darwin 整数约定（asm runtime 辅助）
    adrp x0, L_err_arity@PAGE
    add  x0, x0, L_err_arity@PAGEOFF
    bl   _rt_error
L_arity_ok:
```

`cmp` 的立即数是原始个数，**不要** `cmp x8, #12`（那是 3 的 fixnum）。太多或太少都走同一错误路径。stderr 关键字锁定为 `arity`（大小写不限，驱动按子串匹配）。

0 个形参：`cmp x8, #0`。L24 允许不检查；本层 **必须检查**，包括 0/1 参过程。因此 `((lambda () 1) 2)` 本层起为运行时错误。

### 被调方绑定

序言在 arity 检查通过之后：

- 形参 0–7：`str xN, [fp, #slotN]`，env 登记。
- 形参 8+：从 **调用方溢出区** 加载。callee 已经 `stp … [sp, #-FRAMESIZE]!` 且 `mov x29, sp`，于是调用瞬间的 `[sp, #8*i]` 现在位于 `[fp, #FRAMESIZE + 8*i]`。

```
调用前 sp  ──►  [ overflow0 ][ pad ]
blr
序言减 sp  ──►  [ saved fp ][ saved lr ][ saved x21 ][ pad ][ locals… ]
                 ^fp
overflow0 = [fp, #FRAMESIZE]
```

不要假设溢出实参紧贴在 `fp` 下面——中间隔着整个 callee 帧。

### 超过 8 个参数的 caller 帧

```
; 临时槽里已经有全部求值后的实参（含闭包）
sub  sp, sp, #16              ; 1 个溢出 + 对齐
ldr  x9, [fp, #slot8]
str  x9, [sp]
ldr  x0, [fp, #slot0]
…                             ; x1–x7
ldr  x10, [fp, #slot_proc]
sub  x9, x10, #6
ldr  x9, [x9]
mov  x8, #9
blr  x9
add  sp, sp, #16              ; 收回溢出区；结果在 x0
```

`sub sp` 必须在装 `x0`–`x7` 之后还是之前都可以，只要 `blr` 时溢出区已在 `[sp]` 且 16 对齐。**不要**把溢出区写进 callee 以后才会建的帧。

### IR

`(code lid (a b c) () body)` 的 formals 长度即为期望 arity。`(call proc a b c)` 的实参 IR 个数写入 `x8`。前端仍可在编译期对「字面 `lambda` 直接应用且个数明显不对」报错，但 **不能只靠编译期**：`(let ((f (lambda (x) x))) (f 1 2))` 必须是运行时错误。

### 错误路径与 Darwin 整数约定

`_rt_error` 是 runtime 汇编：Darwin 符号 `_rt_error`，第一个参数 NUL 结尾字节串指针在 `x0`。这会打乱 `x8`/`x10`，但函数不返回。消息放 `.cstring` / `.asciz`，用 `adrp`/`add` 或 `adr` 取址，与 L24 取代码标签相同的 Darwin 规则。生成代码不要 `svc`；`_rt_error` 内部用 `SYS_write`/`SYS_exit`。

非闭包调用继续走 L24 的 `not a procedure`。arity 错误走另一条消息，便于测例区分。

## 与上一层的差异

- 形参由「0 或 1」改为任意固定 n（测例至少覆盖 2、3、8、9）。
- 序言强制 `cmp x8, #n`；L24 的可选不检查作废。
- 出现 `x1`–`x7` 与栈溢出实参；`emit-call` 必须在 `blr` 前装填这些寄存器。
- 闭包布局不变。L24 测例全部仍须通过（含 `((lambda (x) x) 3)`）。

## 代码骨架

### 可移植前端

```scheme
(define (compile-lambda formals body env add-code)
  (unless (and (list? formals) (every symbol? formals) (unique? formals))
    (error "L25: formals must be a proper list of unique symbols" formals))
  (when (null? body) (error "L25: empty lambda body"))
  (let* ((body-expr (if (null? (cdr body)) (car body) `(begin ,@body)))
         (fvs (free-vars body-expr formals env)))
    (unless (null? fvs)
      (error "L25: lambda has free variables" fvs))
    (let* ((lid (gen-label "L_code_"))
           (body-env (bind-formals formals env))
           (body-ir (expr->ir body-expr body-env add-code)))
      (add-code `(code ,lid ,formals () ,body-ir))
      `(close ,lid))))
```

`close` 仍 `emit-alloc 24`，arity 字改为 `(ash (length formals) 2)`。nfree 仍 0。

### aarch64-apple：序言检查

```scheme
(define (emit-arity-check n)
  (string-append
    "\tcmp x8, #" (number->string n) "\n"
    "\tb.eq " (label-here "ok") "\n"
    (emit-load-label "L_err_arity_msg")  ; 字符串地址 → x0，见下
    "\tmov x0, x9\n"                     ; 若 emit-load-label 用了 x9
    "\tbl _rt_error\n"
    (label-here "ok") ":\n"))
```

更干净：共享全局 stub，只 `b L_rt_arity`，stub 里装消息再 `bl _rt_error`。注意进入 stub 前不必保存寄存器。

```asm
    .p2align 2
L_rt_arity:
    adrp    x0, L_err_arity_msg@PAGE
    add     x0, x0, L_err_arity_msg@PAGEOFF
    bl      _rt_error

    .cstring
L_err_arity_msg:
    .asciz  "arity"
```

`.cstring` 与 `.text` 分开；`adr` 跨 section 在 Mach-O 上可能失败，**字符串地址用 `adrp`/`add` + `@PAGE`/`@PAGEOFF`**。代码标签仍可用 `adr`。

### `emit-call` 装填

```scheme
(define (emit-call operator-ir arg-irs ctx)
  (let* ((n (length arg-irs))
         (proc-slot (ctx-push-slot ctx))
         (arg-slots (map (lambda (_) (ctx-push-slot ctx)) arg-irs)))
    (string-append
      (emit-ir operator-ir ctx)
      (emit-stack-save proc-slot)
      (emit-save-each arg-irs arg-slots ctx)
      (emit-overflow-area (list-tail arg-slots (min n 8)))
      (emit-load-regs arg-slots)          ; x0..x7
      (emit-stack-load proc-slot)
      "\tmov x10, x0\n"
      "\tand x9, x10, #7\n"
      "\tcmp x9, #6\n"
      "\tb.ne L_err_not_proc\n"
      "\tsub x9, x10, #6\n"
      "\tldr x9, [x9]\n"
      "\tmov x8, #" (number->string n) "\n"
      "\tblr x9\n"
      (emit-pop-overflow-area (list-tail arg-slots (min n 8))))))
```

`mov x8, #n` 必须在 `blr` 直前：前面的 `cmp` 会改条件码，但不会改 `x8`；不要借用 `x8` 当临时。

### 被调方取溢出实参

```scheme
(define (emit-bind-formals formals framesize)
  (let loop ((fs formals) (i 0) (acc ""))
    (if (null? fs)
        acc
        (let ((src (if (< i 8)
                       (string-append "\tstr x" (number->string i)
                                      ", [fp, #" (slot-off i) "]\n")
                       (string-append "\tldr x9, [fp, #"
                                      (number->string (+ framesize (* 8 (- i 8))))
                                      "]\n"
                                      "\tstr x9, [fp, #" (slot-off i) "]\n"))))
          (loop (cdr fs) (+ i 1) (string-append acc src))))))
```

`x9` 在序言里此时已空闲（代码指针用完）。不要用 `x18`。`x19`/`x20` 不要当临时。

## 测例清单

上一层全部测例仍须通过。

1. `((lambda (a b) (fx+ a b)) 3 4)` → `7`
2. `((lambda (a b c) (fx+ a (fx+ b c))) 1 2 3)` → `6`
3. `((lambda () 1) 2)`：运行时错误，stderr 含 `arity`。
4. `((lambda (x) x))`：运行时错误，stderr 含 `arity`。
5. `((lambda (x) x) 1 2)`：运行时错误，stderr 含 `arity`。
6. `(let ((f (lambda (x y) (fx- x y)))) (f 10 3))` → `7`
7. `((lambda (a b) (if a b 0)) #t 5)` → `5`
8. `((lambda (a b c d e) (fx+ e a)) 1 2 3 4 5)` → `6`
9. 八个形参：`((lambda (a b c d e f g h) (fx+ a h)) 1 2 3 4 5 6 7 8)` → `9`
10. 九个形参（第一个溢出槽）：`((lambda (a b c d e f g h i) (fx+ a i)) 1 2 3 4 5 6 7 8 9)` → `10`
11. 九个形参读中间：`((lambda (a b c d e f g h i) h) 1 2 3 4 5 6 7 8 9)` → `8`
12. `((lambda (x y) x) 1)`：运行时错误（少一个），含 `arity`。
13. `(lambda (x x) x)`：编译期错（重复形参）。
14. `(let ((f (lambda (x y) (fx+ x y)))) (f 1 2 3))`：运行时错误，含 `arity`（编译期看不出）。
15. `((lambda (a b) ((lambda (c d) (fx+ (fx+ c d) 0)) 3 4)) 1 2)` → `7`（嵌套调用、内层不捕获；外层 `a` `b` 未使用）
16. `((lambda (x y) (begin (set! x (fx+ x y)) x)) 10 5)` → `15`

## 验收标准

- 测例 1–2、6–11、15–16 输出与上表一致。
- 测例 3–5、12、14：退出码非 0，stderr 含 `arity`，**不含**把错误当成 `#<procedure>` 或 fixnum 打出来。
- 测例 13 编译期失败。
- L24 全部测例仍绿，包括返回 `#<procedure>` 与 0 参调用。
- 9 参测例证明溢出槽被读写；若只把第 9 个实参丢在 `x8` 或忘了对齐，测例 10–11 会红或 SIGBUS。
- 生成代码无 `x18`；Scheme 调用 `blr x9`；`x8` 仅作 argc，不把 fixnum arity 放进 `x8`。

## 常见坑

- **改布局**：把 arity 挪到偏移 16、nfree 挤走。L24 的 24 字节对象就全错位。本层不 `emit-alloc` 更大的无 fv 闭包。
- **`cmp x8, #4` 当 1 个参数**：`x8` 是 1 不是 fixnum 4。堆上才是 4。
- **少参仍读 `x1`**：未传入的寄存器是垃圾；必须先 `cmp`。
- **溢出实参用 `[fp, #16]`**：那是 saved `x21`。要用 `FRAMESIZE` 做底。
- **9 参只 `sub sp, #8`**：破坏 16 字节对齐，`blr` 可能 SIGBUS。
- **装填 `x0`–`x7` 之后再求值某个实参**：会覆盖已装填寄存器。先全部求值进栈槽。
- **`mov x8, #n` 之后又用 `x8` 做 `ldr` 临时**：argc 被打掉，偶发 arity 错误。
- **共享 arity stub 却 `bl L_rt_arity` 而不保存 `lr`**：stub 里再 `bl _rt_error` 可以（noreturn）。不要 `blr x18`。
- **字符串用 `adr` 跨 `.cstring`**：改 `adrp`/`@PAGEOFF`。

## 下一层预告

过程仍然不能提到外层 `let` 或外层形参的名字。L26 要让 `(let ((x 10)) (lambda (y) (fx+ x y)))` 成为名副其实的闭包。
