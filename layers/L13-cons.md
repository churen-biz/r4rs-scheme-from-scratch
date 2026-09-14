# L13 — `cons` / `pair?`

## 目标

用户原语 `cons` 在堆上分配一个 pair：两个机器字 `{car, cdr}`，指针 OR 上 `PAIR_TAG=0b001`。谓词 `pair?` 用掩码 `(x & 7) == 1`。`rt_print` 递归打印 pair：点对 `(a . b)`，以及适当的 list 糖 `(a b c)`。空表仍是立即数 `0x3F`，不是堆对象。

本层还没有 `car` / `cdr`。打印在 runtime 汇编里走裸指针，不经过 Scheme 原语。

本层范围之外：`car`/`cdr`/`set-car!`、quote 字面量 `'(1 . 2)`、环检测、GC、把 pair 绑到变量。嵌套 `cons` 必须工作。

## 原理

### 布局与标签

去标签后的裸地址（8 对齐）：

```
[ car : word 8 ][ cdr : word 8 ]
```

两个槽里放的已经是 **带标签的 Scheme 值**。`cons` 不重新编码 car/cdr。

带标签指针：

```
tagged_pair = raw | PAIR_TAG     ; PAIR_TAG = 1
raw         = tagged_pair - 1    ; 或 bic #7，因低 3 位恰是标签
```

低 3 位 `001` 与 fixnum `00`、立即数族 `111`、vector `010`、string `011` 都不冲突。`pair?`：

```
(x & 0b111) == PAIR_TAG
```

不要写成 `(x & 1) == 1`：那会把所有奇标签（string `011`、立即数 `111`…）算进去。

### 求值顺序

`(cons a d)`：先求值 `a`，把结果存栈，再求值 `d`，再 `emit-alloc 16`，先存 cdr 再存 car，最后打标签。左到右，与 R4RS 过程调用一致（本层 `cons` 是原语不是闭包，但参数顺序相同）。

关键：`emit-alloc` 把旧 `HP` 写入 `x0`，会覆盖仍在 `x0` 里的 cdr。必须在 `emit-alloc` 之前把 cdr 挪到临时寄存器或栈。同样，从栈加载 car 时不要覆盖仍需保留的裸指针。

推荐寄存器安排（临时仅 `x9`–`x15`）：

```
eval car
str  x0, [sp, #-16]!          ; 或 fp 相对槽；保持 16 对齐
eval cdr
mov  x10, x0                  ; cdr
emit-alloc 16                 ; x0 = raw
str  x10, [x0, #8]            ; cdr 在 +8
ldr  x9, [sp], #16            ; car
str  x9, [x0, #0]
orr  x0, x0, #PAIR_TAG
```

`str`/`ldr` 用 64 位变体，不要 `str w`。

### IR

```
(prim cons  Ir Ir)
(prim pair? Ir)
```

前端：`(cons E1 E2)` → `(prim cons (expr->ir E1) (expr->ir E2))`。Arity 不是 2 / 1 分别编译期错。没有 quote，源文件里的 `(1 . 2)` 是 pair 字面量，car 是整数 `1`，不是符号 `cons`——必须编译期 `error`，不要试图「把 pair 字面量当程序」。测例一律写 `(cons 1 2)`。自托管前用手写 `.s` 发出同等 `cons` 序列。

`eq?` 从 L09 起就是位型相等。两个 `(cons 1 2)` 各 bump 一次，指针不同，`(eq? (cons 1 2) (cons 1 2))` 为 `#f`。不必为 pair 特判。`eqv?` 在本层对 pair 与 `eq?` 相同。

### 打印（runtime 汇编，本层核心）

`rt_print` 必须拆成「打印值、不换行」和「顶层再换行」。否则嵌套 pair 会打出一堆换行。

list 糖规则（与 R4RS `write` 一致的最小集）：

- 空表：`()`
- pair：先 `(`，然后循环：
  - 打印 car（递归、无顶层换行）
  - cdr 是空表 → 结束
  - cdr 是 pair → 打一个空格，继续走那个 pair（不重新开 `(`）
  - 否则 → 打 ` . `，打印 cdr，结束
- 最后 `)`

例子：

| 对象 | 打印 |
|------|------|
| `(cons 1 2)` | `(1 . 2)` |
| `(cons 1 ())` | `(1)` |
| `(cons 1 (cons 2 ()))` | `(1 2)` |
| `(cons 1 (cons 2 3))` | `(1 2 . 3)` |
| `(cons (cons 1 2) (cons 3 4))` | `((1 . 2) 3 . 4)` |

本层没有 `set-cdr!`，构不成环。不必做环检测（L15 之后可以先不管，L44 再做）。

立即数分支保持 L04/L02/L01：fixnum、`#t`/`#f`、`()`、char。未知标签打印 `#<unknown>` 并 `rt_error`，以免以后 vector 假绿。

### `pair?` 的汇编

操作数已在 `x0`：

```asm
    and     x9, x0, #7
    cmp     x9, #1
    mov     x0, #0x2F
    mov     x10, #0x6F
    csel    x0, x10, x0, eq
```

与 L05 谓词同一套 `csel` 映射到 `#t`/`#f`。对空表、fixnum、`#f` 都是 `#f`。

### 堆消耗

每次 `cons` 恰好 `emit-alloc 16`。可用 L12 原语做可选调试：`(and (cons 1 2) (%hp-fixnum))` → `16`，但**不强制**进回归——`cons` 的可观测性是打印形状。保留 `%bump` / `%hp-fixnum`，旧测例仍过。

HP 溢出：`emit-alloc` 已检查。本层不必单写「cons 爆堆」测例；64MiB 装得下回归里的嵌套深度。

## 与上一层的差异

| 项 | L12 | L13 |
|----|-----|-----|
| 用户原语 | `%bump` `%hp-fixnum` | 加上 `cons` `pair?` |
| `emit-alloc` | 写好但用户测例不返回裸指针 | `cons` 每次 16 字节 |
| 返回值标签 | 仍是立即数 | 第一次出现堆指针 `…001` |
| `rt_print` | 不认识堆 | 递归 pair + list 糖 |
| 栈 | 仅 `%bump` 可能用临时 | `cons` 必须保存 car |

## 代码骨架

### 可移植前端

```scheme
(define PAIR_TAG 1)

(define (expr->ir expr)
  (cond
    ((and (pair? expr) (eq? (car expr) 'cons) (length=? expr 3))
     `(prim cons ,(expr->ir (cadr expr)) ,(expr->ir (caddr expr))))
    ((and (pair? expr) (eq? (car expr) 'pair?) (length=? expr 2))
     `(prim pair? ,(expr->ir (cadr expr))))
    ;; %bump / %hp-fixnum / 更早形式 …
    (else (error "L13: bad expr" expr))))
```

`(cons 1 2)` 是三元 list 调用。识别时不要把「程序是 pair」当成「用户写了 pair 字面量」。用户 pair 字面量是 `car` 不是符号的那种。

### aarch64-apple：`emit-prim cons / pair?`

```scheme
(define (emit-prim name args ctx)
  (case name
    ((cons)
     (string-append
       (emit-ir (car args) ctx)
       "\tstr x0, [sp, #-16]!\n"
       (emit-ir (cadr args) ctx)
       "\tmov x10, x0\n"
       (emit-alloc 16)
       "\tstr x10, [x0, #8]\n"
       "\tldr x9, [sp], #16\n"
       "\tstr x9, [x0]\n"
       "\torr x0, x0, #1\n"))
    ((pair?)
     (string-append
       (emit-ir (car args) ctx)
       (emit-mask-eq 7 PAIR_TAG)))
    (else (emit-prim-l12 name args ctx))))
```

`emit-tag` 就是 `orr x0, x0, #tag`。`emit-untag` 本层打印用不到（runtime 去标签）。

嵌套 `cons` 时内层也会 `str [sp, #-16]!`。只要每次配对 `ldr [sp], #16`，栈平衡。不要用固定绝对地址。

### runtime：`print_value`

```
; 算法伪代码：实现必须是 runtime 汇编，不是 C。
; PAIR_TAG 1

static int is_pair(ptr x) { return (x & 7) == PAIR_TAG; }
static ptr unt(ptr x) { return x - PAIR_TAG; }

static void print_value(ptr x) {
    if ((x & 3) == 0) { write_decimal(, (long long)(x >> 2)); return; }
    if (x == BOOL_T) { fputs("#t", stdout); return; }
    if (x == BOOL_F) { fputs("#f", stdout); return; }
    if (x == EMPTY_LIST) { fputs("()", stdout); return; }
    if ((x & 0xFF) == CHAR_TAG) { /* 与 L04 相同，但不自动换行 */ print_char(x); return; }
    if (is_pair(x)) {
        putchar('(');
        for (;;) {
            ptr raw = unt(x);
            print_value(((ptr *)raw)[0]);
            ptr d = ((ptr *)raw)[1];
            if (d == EMPTY_LIST) break;
            if (is_pair(d)) { putchar(' '); x = d; continue; }
            fputs(" . ", stdout);
            print_value(d);
            break;
        }
        putchar(')');
        return;
    }
    rt_error("unprintable value");
}

void rt_print(ptr x) {
    print_value(x);
    putchar('\n');
}
```

`((ptr *)raw)[0]` 是 `car`，`[1]` 是 `cdr`。runtime 侧用去标签后的地址，不要对 tagged 指针解引用——那会偏 1 字节，直接未对齐访问。

`runtime.s` 注释 加上 `; PAIR_TAG 1`，与编译器常数相同。

## 测例清单

上一层全部测例仍须通过。

1. `(cons 1 2)` → `(1 . 2)`
2. `(cons 1 ())` → `(1)`
3. `(cons 1 (cons 2 ()))` → `(1 2)`
4. `(cons 1 (cons 2 (cons 3 ())))` → `(1 2 3)`
5. `(cons 1 (cons 2 3))` → `(1 2 . 3)`
6. `(cons (cons 1 2) (cons 3 4))` → `((1 . 2) 3 . 4)`
7. `(pair? (cons 1 2))` → `#t`
8. `(pair? 1)` → `#f`
9. `(pair? ())` → `#f`
10. `(pair? #f)` → `#f`
11. `(pair? (pair? (cons 1 2)))` → `#f`（内层 `#t` 不是 pair）
12. `(null? (cons 1 ()))` → `#f`
13. `(eq? (cons 1 2) (cons 1 2))` → `#f`（两次分配）
14. `(cons #t #\A)` → `(#t . #\A)`
15. `(cons (fx+ 1 2) (fx- 10 3))` → `(3 . 7)`
16. `(cons)` / `(cons 1)` / `(cons 1 2 3)` / `(pair?)` / `(pair? 1 2)`：编译期 arity 错误
17. 输入 `(1 . 2)`（pair 字面量，不是 `cons` 调用）：编译期错误

## 验收标准

- 测例 1–6、14–15 的打印与上表字节级一致：点对两侧有空格，list 糖元素之间单个空格，没有 `(1 . ())`。
- `pair?` 对空表、fixnum、布尔为 `#f`，只对 `cons` 的结果为 `#t`。
- 每个 `cons` 分配恰好 16 字节（可用 `%hp-fixnum` 手工确认；回归不强制）。
- `rt_print` 顶层恰好一个末尾换行；嵌套元素不再换行。
- 生成代码不使用 `x18`。`cons` 路径上有 `str` 到 `[x0]` 与 `[x0, #8]`（或等价带偏移的 64 位存）。
- 未实现 `car`/`cdr`：源程序 `(car (cons 1 2))` 编译期未知原语。

## 常见坑

- **`emit-alloc` 覆盖 cdr**：alloc 后 `x0` 是 raw。先 `mov x10, x0` 保存 cdr。
- **加载 car 时覆盖 raw**：`ldr x0, [sp]` 之后裸指针没了。用 `x9`/`x11` 留 raw，最后 `orr` 打在留存的 raw 上。
- **对 tagged 指针解引用**：runtime 汇编里必须减 1。汇编里 `ldr` 前必须去标签（本层打印在 runtime，汇编只 `str` 到 raw）。
- **`pair?` 用 `x & 1`**：`#t`（`0x6F`）低位是 1，会假阳性。
- **打印 `(1 . ())` 而不做 list 糖**：测例 2 失败。cdr 是空表就不要打点。
- **list 糖漏空格或多重空格**：`(1  2)` 与 `(1 2)` 不同。
- **顶层递归每层额外 `write("\n")`**：输出变成多行，驱动 `diff` 失败。
- **把 `(1 2)` 当程序**：那是「调用 1」，不是 list 字面量。没有 quote。
- **栈减 8**：`cons` 保存 car 时破坏对齐，随后若 `bl` 溢出检查会炸。
- **`orr w0, w0, #1`**：截断指针。用 `x0`。

## 下一层预告

L14 要从 pair 里取出 car/cdr：汇编 `ldr` 去标签后的 `+0` / `+8`，并对非 pair 做运行时类型错误。
