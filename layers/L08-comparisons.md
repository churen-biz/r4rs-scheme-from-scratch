# L08 — 比较 `fx=` `fx<` `fx<=` `fx>` `fx>=`

## 目标

增加五个二元 fixnum 比较原语，结果是 Scheme 布尔 `#t` / `#f`（编码 `0x6F` / `0x2F`），不是 0/1，也不是 C 的 `true`。求值与栈约定 **完全复用 L07**：左操作数进栈，右操作数在 `x0`，然后比较。

本层范围之外：泛型 `=` `<` `>`（L42）；`char<?` 等字符比较；溢出或类型错误；无符号比较；`fxmin`/`fxmax`。对非 fixnum 操作数的结果不定义，不要写这类「正确输出」测例。

## 原理

### 求值规则

与 `fx+` 相同的四步，最后一步从「算术」换成「比较并物化布尔」：

1. 求值左 → `x0`
2. `emit-stack-save` 于当前 `si`
3. 求值右（`si - WORDSIZE`）→ `x0`
4. 左值载入 `x9`，**有符号**比较 `x9` 与 `x0`，按关系把 `x0` 写成 `BOOL_T` 或 `BOOL_F`

IR：

```
(prim fx=  Ir Ir)
(prim fx<  Ir Ir)
(prim fx<= Ir Ir)
(prim fx>  Ir Ir)
(prim fx>= Ir Ir)
```

arity 必须为 2。`(fx= a)`、`(fx= a b c)` 编译期错。没有 `fx!=`；不相等请以后用 `(not (fx= a b))`（本层已有 `not`）。

### 为何可以比较已标签值

fixnum 标签是低 2 位 `00`，等价于把真值乘 4。对任意有符号整数 `a`、`b`：

```
a <  b  ⇔  (a<<2) <  (b<<2)
a =  b  ⇔  (a<<2) =  (b<<2)
```

在二补码 64 位里，左移 2 位（低位补 0）保持全序：负数的标签仍是负数（高位全 1，低 2 位 00，例如 `-1` 的标签是 `0xFFFFFFFFFFFFFFFC`），`0` 的标签是 `0`，正数仍为正。因此 **不要去标签再比**——多两拍且容易写成 `lsr` 把负数弄坏。

这只对 fixnum 成立。布尔、字符的低位不是 `00`，本层不保证 `(fx< #f 1)` 的含义。

### 有符号条件码（芯片无关语义 / aarch64 名字）

| 原语 | 数学 | aarch64 `csel`/`b.` 条件 | 不要用 |
|------|------|--------------------------|--------|
| `fx=` | `a = b` | `eq` | |
| `fx<` | `a < b` | `lt` | `lo`（无符号低于） |
| `fx<=` | `a ≤ b` | `le` | `ls` |
| `fx>` | `a > b` | `gt` | `hi` |
| `fx>=` | `a ≥ b` | `ge` | `hs` |

无符号条件会把 `(fx< -1 0)` 判错：标签 `0xF…FC` 作为无符号数大于 `0`。

比较方向：`cmp x9, x0` 是 **左 减 右**（`x9 - x0`）并置标志。条件 `lt` 表示左 < 右，即 `(fx< a b)`。若误写成 `cmp x0, x9`，所有不等关系会翻转。

### 把标志变成 Scheme 布尔

与 L05 `fixnum?` 相同的物化，只是条件码换成上表。推荐 `csel`：

```
cmp  x9, x0
mov  x0,  #0x2F          ; #f
mov  x10, #0x6F          ; #t
csel x0, x10, x0, <cc>   ; 条件成立则 #t
```

`cset` 得到 0/1 后再 `lsl #6` / `orr #0x2F` 也可以（见 L05），但本层五个原语共用一张条件表时，`csel` 更直读。

**禁止**把 0/1 留在 `x0` 当结果：`rt_print` 会把它当 fixnum `0`/`1` 打出来，测例期望却是 `#f`/`#t`。

### 栈与 `ctx`

原样使用 L07 的 `WORDSIZE`、`si`、`ctx-down`、256 字节局部区。比较原语与 `fx+` 可以共享 `emit-binop` 的「求值两参数」前缀，只替换 `emit-binop-body`。

嵌套：`(fx= (fx+ 1 2) 3)` 先按 L07 算出左值 `3` 再比较。`(if …)` 还不存在；比较结果就是程序的值。

## 与上一层的差异

- 新原语五个，结果类型是布尔，不是 fixnum。
- 第一次在二元原语里发 `cmp` + 条件选择（L05 的 `cmp` 只用于一元谓词）。
- 栈协议、`si`、序言/跋、左到右求值：**不改**。
- `rt_print` 不改（已能打印 `#t`/`#f`）。

## 代码骨架

### 可移植：前端

```scheme
(define (fx-cmp? name)
  (memq name '(fx= fx< fx<= fx> fx>=)))

;; 在 expr->ir 的 pair 分支里，与 binary-arith? 并列：
((and (pair? expr) (fx-cmp? (car expr)))
 (unless (length=? expr 3)
   (error "L08: cmp arity" expr))
 `(prim ,(car expr)
        ,(expr->ir (cadr expr))
        ,(expr->ir (caddr expr))))
```

### 可移植：分派

```scheme
(define (emit-prim name args ctx)
  (cond
    ((memq name '(fx+ fx- fx*))
     (emit-binop name (car args) (cadr args) ctx))
    ((fx-cmp? name)
     (emit-binop name (car args) (cadr args) ctx))  ; 同一求值骨架
    (else
     (string-append (emit-ir (car args) ctx)
                    (emit-unary-body name)))))
```

`emit-binop-body` 增加比较臂。条件码是后端细节，但「哪一个原语对应哪一种数学关系」可移植。

### aarch64-apple：比较体

```scheme
(define (emit-binop-body name si)
  (string-append
    (emit-stack-load si "x9")
    (case name
      ((fx+) "\tadd x0, x9, x0\n")
      ((fx-) "\tsub x0, x9, x0\n")
      ((fx*) (string-append "\tasr x9, x9, #2\n"
                            "\tmul x0, x0, x9\n"))
      ((fx=)  (emit-cmp-bool "eq"))
      ((fx<)  (emit-cmp-bool "lt"))
      ((fx<=) (emit-cmp-bool "le"))
      ((fx>)  (emit-cmp-bool "gt"))
      ((fx>=) (emit-cmp-bool "ge"))
      (else (error "binop" name)))))

(define (emit-cmp-bool cc)
  (string-append
    "\tcmp x9, x0\n"
    "\tmov x0, #0x2F\n"
    "\tmov x10, #0x6F\n"
    "\tcsel x0, x10, x0, " cc "\n"))
```

`cc` 是 `eq`/`lt`/… 这些助记符字符串，不要自己发明 `lte`。`csel` 的条件写在末操作数，与 `b.lt` 那一组相同。

临时只用 `x9`、`x10`。不要用 `x18`。`0x2F`/`0x6F` 可直接 `mov`。

## 测例清单

上一层全部测例仍须通过。

1. `(fx= 0 0)` → `#t`
2. `(fx= 1 2)` → `#f`
3. `(fx= -1 -1)` → `#t`
4. `(fx< -1 0)` → `#t`（有符号；无符号比较会失败）
5. `(fx< 0 -1)` → `#f`
6. `(fx< 1 1)` → `#f`
7. `(fx<= 3 3)` → `#t`；`(fx<= 3 4)` → `#t`；`(fx<= 4 3)` → `#f`
8. `(fx> 3 3)` → `#f`；`(fx> 4 3)` → `#t`；`(fx> -5 -8)` → `#t`
9. `(fx>= -5 -5)` → `#t`；`(fx>= 0 1)` → `#f`
10. `(fx= (fx+ 1 2) 3)` → `#t`
11. `(fx< (fx- 0 5) (fxneg -1))` → `#t`（`-5 < 1`）
12. `(not (fx= 1 1))` → `#f`
13. `(fx= (fx* 2 3) (fx+ 4 2))` → `#t`
14. `(fx< 0 0)` → `#f`（回归：相等时严格小于为假）
15. `(fx=)` / `(fx< 1)` / `(fx= 1 2 3)`：编译期 arity 错误。`(= 1 1)`：编译期未知原语。

## 验收标准

- 测例 1–14 输出恰好 `#t\n` 或 `#f\n`。
- `(fx< -1 0)` 为 `#t`：证明用了有符号条件，且比较的是已标签字（或等价的有符号真值）。
- `.s` 里比较原语出现 `cmp` 与 `csel`（或 `cset`+映射到 `0x2F`/`0x6F`），结果路径上不得留下 `0`/`1` 当 Scheme 值。
- `(= 1 1)` 编译期拒绝。
- 栈槽规则与 L07 相同：右子树 `si` 更低。

## 常见坑

- **`lo`/`hi` 代替 `lt`/`gt`**：负数测例 4、8 会反。记住：fixnum 是有符号的。
- **`cmp x0, x9`**：关系翻转，`(fx< 1 2)` 变成 `#f`。固定「`x9` 是左、`x0` 是右」。
- **去标签再用无符号 `cmp`**：负 fixnum 的 `lsr #2` 变成巨大正数。
- **结果是 0/1**：打印成 `0`/`1` 而不是 `#f`/`#t`。必须物化成 `0x2F`/`0x6F`。
- **`fx=` 写成指针比较以外的「差值为 0」却忘了物化布尔**：`subs` 之后 `x0` 里是差值 0，打印 `0`。
- **以为 `0` 与 `#f` 比较该走本层**：`(fx= 0 0)` 是 fixnum 相等；`0` 和 `#f` 的相等是 L09 的 `eq?`。

## 下一层预告

L09 对任意立即数做 `eq?` / `eqv?`：比较的是 64 位字的位型，不再假设操作数是 fixnum。
