# L05 — 类型谓词 `fixnum?` `boolean?` `null?` `char?`

## 目标

程序不再只是一个字面量：允许 **一层** 原语调用，原语是四个谓词之一。`(fixnum? 12)`、`(boolean? #f)`、`(null? ())`、`(char? #\A)` 在运行时根据标签返回 `#t` 或 `#f`。

本层范围之外：嵌套调用 `(fixnum? (fixnum? 1))` 可以做（建议做，骨架按「任意 expr 子树」写），但还没有 `and`/`if`/变量。未知原语编译期报错。不检查 arity 以外的运行时类型错误——谓词对任何已编码值都有定义。

## 原理

### 语言形状

```
P ::= literal | (fixnum? P) | (boolean? P) | (null? P) | (char? P)
literal ::= fixnum | #t | #f | () | char
```

求值：先求值唯一操作数到 `x0`，再按位运算改写成布尔立即数，仍放 `x0`。

### 位运算（芯片无关）

```
fixnum?  : (x & 0b11) == 0            → #t / #f
boolean? : (x & ~0x40) == BOOL_F      → 即 x 是 #t 或 #f
null?    : x == EMPTY_LIST
char?    : (x & 0xFF) == CHAR_TAG
```

`boolean?` 不要写成 `(x == #t) || (x == #f)` 以外的「非零即真」。用掩码可一条比较：`#t` 与 `#f` 只差 bit 6，清掉该 bit 后都等于 `BOOL_F`。须保证没有其它立即数在清 bit 6 后也等于 `0x2F`。当前集合：

| 值 | 清 bit6 后 |
|----|------------|
| `#f` 0x2F | 0x2F |
| `#t` 0x6F | 0x2F |
| `()` 0x3F | 0x3F |
| char `0x??0F` | 仍以 `0F` 结尾 |
| void 0x1F | 0x1F |

不冲突。若你以后加立即数，重新核对这条掩码。

### IR

```
(prim fixnum?  Ir)
(prim boolean? Ir)
(prim null?    Ir)
(prim char?    Ir)
```

前端把 `(fixnum? e)` 降成 `(prim fixnum? (expr->ir e))`。后端 `emit-prim` 分派。

### 为何在 `if` 之前做谓词

谓词强迫你写出 **「值在 x0 → 改写成另一个值仍在 x0」** 的 emit 模式，且第一次发出 `cmp`/`csel`（或分支设值）。这是后面所有原语的样板。若先做 `if`，会把「设布尔」和「跳转」缠在一起，更难点测。

### aarch64 设布尔的推荐序列

以 `fixnum?` 为例（结果必须是 `0x6F`/`0x2F`，不是 0/1）：

```asm
    ; 操作数已在 x0
    and  x9, x0, #3
    cmp  x9, #0
    mov  x0, #0x2F          ; #f
    mov  x10, #0x6F         ; #t
    csel x0, x10, x0, eq    ; eq 则 #t
```

不要用条件执行的旧 ARM 语法；aarch64 用 `csel`/`cset`。若 `cset w9, eq` 得到 0/1，还要映射到 `#f`/`#t`：

```asm
    cset x9, eq
    ; x9=1 → #t, 0 → #f ：  #f + x9 * 0x40
    lsl  x9, x9, #6
    mov  x0, #0x2F
    orr  x0, x0, x9
```

两种都合格。`null?` 用满字 `cmp x0, #0x3F`（`0x3F` 可进 `cmp` 立即数）。

**可移植**：IR 不描述 `csel`。换 x86 时变成 `cmp`+`sete`+映射。

## 与上一层的差异

- 程序是表达式树，不是单叶。
- 第一次出现 `(prim name …)`。
- 后端第一次改写寄存器里的值（不再只是 `emit-imm`）。
- 仍无栈：谓词是一元、结果覆盖操作数，不必保存。

## 代码骨架

### 可移植前端

```scheme
(define (expr->ir expr)
  (cond
    ((and (pair? expr) (eq? (car expr) 'fixnum?) (length=? expr 2))
     `(prim fixnum? ,(expr->ir (cadr expr))))
    ((and (pair? expr) (eq? (car expr) 'boolean?) (length=? expr 2))
     `(prim boolean? ,(expr->ir (cadr expr))))
    ((and (pair? expr) (eq? (car expr) 'null?) (length=? expr 2))
     `(prim null? ,(expr->ir (cadr expr))))
    ((and (pair? expr) (eq? (car expr) 'char?) (length=? expr 2))
     `(prim char? ,(expr->ir (cadr expr))))
    ((null? expr) `(imm ,EMPTY_LIST))
    ((eq? expr #t) `(imm ,BOOL_T))
    ((eq? expr #f) `(imm ,BOOL_F))
    ((char? expr) `(imm ,(logior CHAR_TAG (ash (char->integer expr) CHAR_SHIFT))))
    ((fixnum-range? expr) `(imm ,(* expr 4)))
    (else (error "L05: bad expr" expr))))
```

Arity 不是 1 的谓词调用：编译期 `error`。

### aarch64-apple：`emit-prim`

```scheme
(define (emit-prim name args ctx)
  (string-append
    (emit-ir (car args) ctx)  ; 结果在 x0
    (case name
      ((fixnum?)  (emit-mask-eq 3 0))
      ((char?)    (emit-mask-eq 255 CHAR_TAG))
      ((null?)    (emit-cmp-eq EMPTY_LIST))
      ((boolean?) (emit-boolean-pred))
      (else (error "unknown prim" name)))))
```

`emit-boolean-pred`：`and x9, x0, #~0x40` 在 aarch64 上逻辑立即数 `~0x40` 要选能编码的形式。更简单：`mov x9, #0x40` / `bic x9, x0, x9` / `cmp x9, #0x2F`。

## 测例清单

上一层全部测例仍须通过。

1. `(fixnum? 0)` → `#t`
2. `(fixnum? 42)` → `#t`
3. `(fixnum? #t)` → `#f`
4. `(fixnum? #f)` → `#f`
5. `(fixnum? ())` → `#f`
6. `(fixnum? #\A)` → `#f`
7. `(boolean? #t)` → `#t`
8. `(boolean? #f)` → `#t`
9. `(boolean? 0)` → `#f`
10. `(boolean? ())` → `#f`
11. `(null? ())` → `#t`
12. `(null? #f)` → `#f`
13. `(null? 0)` → `#f`
14. `(char? #\A)` → `#t`
15. `(char? #\nul)` → `#t`（若 L04 支持）
16. `(char? 65)` → `#f`（fixnum 65 不是字符）
17. `(fixnum? (fixnum? 1))` → `#f`（内层返回 `#t`，外层谓词为假）建议支持嵌套。
18. `(fixnum?)` 或 `(fixnum? 1 2)`：编译期 arity 错误。

## 验收标准

- 测例 1–16 输出仅为 `#t\n` 或 `#f\n`。
- 谓词绝不把 fixnum `0` 或空表当成 `#f` 输入以外的「假」——它们作为操作数时，`boolean?` 为 `#f`，`null?` 仅对 `()` 为 `#t`。
- 未知符号 `(foo 1)` 编译期错。
- 生成代码不得调用 C（本层纯位运算）。

## 常见坑

- **`cset` 后把 0/1 当 Scheme 布尔打印**：`rt_print` 会走「未知值」或把 0 打成 fixnum `0`。必须映射到 `0x2F`/`0x6F`。
- **`boolean?` 写成 `x != 0`**：`42` 会变成 `#t`。
- **`char?` 只比低 4 位**：`CHAR_TAG` 是低 **8** 位 `0x0F`。低 4 位 `1111` 会把其它立即数算进去。
- **忘记嵌套时覆盖 `x0`**：一元谓词覆盖是对的；以后二元原语就必须用栈。本层不要引入第二操作数。

## 下一层预告

L06 加入更多一元原语（`not`、`fxadd1`、`fxneg`…），仍无变量，但会第一次对 fixnum 做算术移位。
