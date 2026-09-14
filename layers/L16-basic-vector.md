# L16 — 基本 vector

## 目标

堆对象 vector：去标签后的布局是

```
[ len : fixnum ][ elt0 ][ elt1 ] … [ elt_{n-1} ]
```

指针标签 `VECTOR_TAG=0b010`。本层用户原语（均为固定 arity，无可选参数）：

| 原语 | 含义 |
|------|------|
| `(make-vector n fill)` | `n` 个槽，每个初始化为 `fill` |
| `(vector-ref v i)` | 返回第 `i` 个元素（0 起） |
| `(vector-set! v i x)` | 写入第 `i` 个元素，**返回该 vector** |
| `(vector? x)` | `(x & 7) == VECTOR_TAG` |
| `(vector-length v)` | 返回头里那个已是 fixnum 的长度 |

`n`、`i` 必须是 fixnum。越界、负长度、非 vector 目标 → `rt_error`。`vector-set!` 返回 vector 与 L15 同一技巧：L18 之前没有变量，L22 之前没有用户 `begin`；L22 起再改为 unspecified/`VOID`。

`rt_print` 打印 `#(…)`。空向量 `#()`。

本层范围之外：可变 arity 的 `(make-vector n)`（省略 fill）、vector 字面量 `#(1 2)`、`list->vector`、GC、返回 `VOID` 的 `vector-set!`。

## 原理

### 布局与尺寸

`len` 槽存 **已标签** 的 fixnum，这样 `vector-length` 只是一次 `ldr`，不必左移。元素槽存带标签值，与 pair 的 car/cdr 相同。

字节数：`8 * (n + 1)`，已经是 8 的倍数，`emit-alloc` 的对齐是恒等。`n = 0` 只分配 8 字节的长度头，值为 tagged `0`。`fill` 在 `n = 0` 时仍要先求值再丢弃（左到右：先 `n` 后 `fill`），然后分配。

`make-vector` 必须两个参数。省略 fill、由实现填「未指定内容」是 L42 库层的事。

### 标签

```
tagged = raw | 2
raw    = tagged bic #7
vector?  (x & 7) == 2
```

`pair?` 对 vector 为 `#f`，`vector?` 对 pair 为 `#f`。不要用 `(x & 2) != 0`。

### `make-vector` 求值与循环

1. 求值 `n`，检查 fixnum 且 `n >= 0`（有符号比较 tagged 即可：tagged `0` 是 `0`，负数 tagged 仍为负）。
2. 栈保存 tagged `n`。
3. 求值 `fill`，栈保存（或放 callee-saved 临时 `x12`；不要用 `x19`/`x20`/`x18`）。
4. `nbytes = 8 * (untagged(n) + 1)`。注意 **先 untag 再乘 8**，不要 `n_tagged * 8`（那会大 4 倍）。也可 `nbytes = (n_tagged * 2) + 8`，因为 `n_tagged = n<<2`，`n*8 = n_tagged*2`。两种都要在乘法前确认 `n >= 0`，否则位移技巧对负数无意义。
5. `emit-alloc nbytes` 的尺寸是运行时的：与 `%bump` 一样，不能把宿主常量塞进 `emit-alloc`。写一个 `emit-alloc-reg`：尺寸在 `x9`，检查 `HP+x9` 对 `HL`，旧 HP → `x0`。
6. `str tagged_n, [raw]`。
7. 用循环把 `fill` 写入 `raw + 8, +16, …` 共 `n` 次。`n=0` 跳过循环。
8. `orr x0, raw, #VECTOR_TAG`。

溢出：`n` 巨大时 `8*(n+1)` 可能绕回 64 位。先检查 `n` 是否超过 `(HL-HP)/8 - 1`，或做加法后确认 `x9` 无符号大于加数。最简单：算 `nbytes`，若 `nbytes < 8` 且 `n != 0` 则视为溢出；再 `cmp HP+nbytes, HL`。测例用中等 `n` 即可；爆堆走 L12 的 `heap` 关键字。

循环用 `x13` 作字节偏移或元素下标。**禁止 `x18`。** 不要调用 C 来填循环——这是生成代码里的短循环。

### `vector-ref` / `vector-set!`

共同检查：

1. `v` 是 vector。
2. `i` 是 fixnum。
3. `0 <= i < len`（两边都是 tagged fixnum 时，有符号比较顺序与 untagged 相同）。

然后：

```
raw = v bic #7
byte_off = 8 + untagged(i)*8
         = 8 + tagged(i)*2     ; i>=0 时
```

`vector-ref`：`ldr x0, [raw, x9]`。`vector-set!`：`str x, [raw, x9]`，返回 **tagged v**（先保存在栈上的那个）。

越界包括 `i == len`、`i < 0`。stderr 关键字 `bounds` 或 `range`。类型错误关键字 `type` 或 `vector`。

`vector-length`：检查 vector，`ldr` 头，已经是 fixnum。不要对非 vector 返回 0。

### 打印

```
#(e0 e1 e2)
#()           ; n=0
#((1 . 2) 3)  ; 元素是 pair 时走 L13 的 print_value
```

左括号紧贴 `#`，元素之间单个空格，没有逗号。顶层 `rt_print` 仍只在最后换行。实现：`print_value` 认 `VECTOR_TAG`，`putchar('#'); putchar('(');` 然后 `for i in 0..n-1` 打印元素，中间空格，再 `)`。

不要打印 `#3(...)` 这种带长度的非 R4RS 形式。

### `%begin`

L15 的 `%begin` 继续可用。例如构造后立刻 `vector-ref` 仍应靠 **返回 vector 的 `vector-set!`** / 嵌套调用，而不是 `%begin` 加变量。

### IR

```
(prim make-vector   Ir Ir)
(prim vector-ref    Ir Ir)
(prim vector-set!   Ir Ir Ir)
(prim vector?       Ir)
(prim vector-length Ir)
```

`vector-set!` 三个操作数：先 `v`，再 `i`，再 `x`。栈上要同时保住 `v` 与 `i`（或 `x`）。建议求值顺序 v → i → x，与表面上的参数顺序一致。

## 与上一层的差异

| 项 | L15 | L16 |
|----|-----|-----|
| 新标签 | 无 | `VECTOR_TAG=010` |
| 对象头 | pair 无长度头 | 第一个字是 fixnum 长度 |
| 分配尺寸 | 恒 16 | `8*(n+1)`，运行时尺寸 |
| 循环 | 无 | `make-vector` 填充循环 |
| mutation 返回 | pair | vector（同一偏离，L22 再改） |
| 打印 | pair | 加上 `#(…)` |
| 越界 | 无 | `vector-ref`/`vector-set!` 检查 |

pair 测例打印不变。`pair?` 与 `vector?` 互斥。

## 代码骨架

### 可移植前端

```scheme
(define VECTOR_TAG 2)

(define (expr->ir expr)
  (cond
    ((and (pair? expr) (eq? (car expr) 'make-vector) (length=? expr 3))
     `(prim make-vector ,(expr->ir (cadr expr)) ,(expr->ir (caddr expr))))
    ((and (pair? expr) (eq? (car expr) 'vector-ref) (length=? expr 3))
     `(prim vector-ref ,(expr->ir (cadr expr)) ,(expr->ir (caddr expr))))
    ((and (pair? expr) (eq? (car expr) 'vector-set!) (length=? expr 4))
     `(prim vector-set!
            ,(expr->ir (cadr expr))
            ,(expr->ir (caddr expr))
            ,(expr->ir (cadddr expr))))
    ((and (pair? expr) (eq? (car expr) 'vector?) (length=? expr 2))
     `(prim vector? ,(expr->ir (cadr expr))))
    ((and (pair? expr) (eq? (car expr) 'vector-length) (length=? expr 2))
     `(prim vector-length ,(expr->ir (cadr expr))))
    (else (error "L16: bad expr" expr))))
```

未知 `vector` 字面量（宿主 `read` 到 vector 对象）：编译期错。测例写 `make-vector`，不要写 `#(1 2)`。

### aarch64-apple：运行时尺寸分配

```scheme
(define (emit-alloc-reg) ; nbytes 已在 x9，>=0，已 8 对齐
  (string-append
    "\tadd x11, x19, x9\n"
    "\tcmp x11, x20\n"
    "\tb.hi _rt_err_heap\n"
    "\tmov x0, x19\n"
    "\tmov x19, x11\n"))
```

`make-vector` 填充（`x0`=raw，`x12`=fill，`x13`=untagged n）：

```asm
    str     x14, [x0]              ; tagged n 在 x14
    mov     x15, #1                ; 从第 1 个字开始写元素
1:
    cmp     x15, x13
    b.gt    2f                     ; n=0 时 1>0，立刻结束。若 n 在 x13，应 cmp index, n
    str     x12, [x0, x15, lsl #3]
    add     x15, x15, #1
    b       1b
2:
    orr     x0, x0, #2
```

下标约定要写清：若 `x13` 是 `n`，循环 `i = 1 … n` 写 `n` 个元素（跳过槽 0）。`n=0` 时 `cmp #1, #0` → `b.gt` 成立，不写。不要用 `x18` 顶替 `x15`。

局部数字标签 `1:`/`2:` 在一个 `emit-program` 里会撞。改用编译器生成的唯一标签 `.Lfill42` / `.Lfill42e`。

### `vector-ref` 核心

```asm
    ; x0 = tagged v, x10 = tagged i（已检查类型与范围，len 在 x11 已标签）
    bic     x0, x0, #7
    lsl     x9, x10, #1            ; tagged i * 2 = untagged i * 8
    add     x9, x9, #8
    ldr     x0, [x0, x9]
```

`vector-set!` 把 `ldr` 换成 `str x12, [x0, x9]`，然后 `mov x0, saved_tagged_v`。

`vector?` 复用 L05 的 `emit-mask-eq`，掩码 `7`、目标 `VECTOR_TAG`。`vector-length`：

```asm
    ; x0 = tagged v，已 assert vector
    bic     x0, x0, #7
    ldr     x0, [x0]               ; 已是 fixnum
```

### runtime 打印

```c
#define VECTOR_TAG 2

static int is_vector(ptr x) { return (x & 7) == VECTOR_TAG; }

/* 在 print_value 里，pair 分支之前或之后均可，按 tag 分派 */
if (is_vector(x)) {
    ptr *raw = (ptr *)(x - VECTOR_TAG);
    int64_t n = raw[0] >> 2;
    fputs("#(", stdout);
    for (int64_t i = 0; i < n; i++) {
        if (i) putchar(' ');
        print_value(raw[i + 1]);
    }
    putchar(')');
    return;
}
```

`scheme.h` 增加 `VECTOR_TAG`。长度用算术右移解码；头里必须是 fixnum，由 `make-vector` 保证。不要信任负长度。

越界 C 包装：

```c
void rt_err_bounds(void) { rt_error("index out of range"); }
```

## 测例清单

上一层全部测例仍须通过。

1. `(vector? (make-vector 1 0))` → `#t`
2. `(vector? 1)` → `#f`；`(vector? (cons 1 2))` → `#f`；`(pair? (make-vector 1 0))` → `#f`
3. `(vector-length (make-vector 3 #f))` → `3`
4. `(vector-length (make-vector 0 0))` → `0`
5. `(vector-ref (make-vector 1 42) 0)` → `42`
6. `(vector-ref (make-vector 3 #\a) 2)` → `#\a`
7. `(vector-ref (vector-set! (make-vector 1 0) 0 9) 0)` → `9`
8. `(vector-length (vector-set! (make-vector 2 1) 1 8))` → `2`（返回 vector 而非 void）
9. `(make-vector 3 1)` → `#(1 1 1)`
10. `(make-vector 0 #f)` → `#()`
11. `(vector-ref (make-vector 1 (cons 1 2)) 0)` → `(1 . 2)`
12. `(vector-ref (make-vector 2 0) 2)`：运行时越界
13. `(vector-ref (make-vector 2 0) -1)`：运行时越界
14. `(make-vector -1 0)`：运行时错误（负长度），关键字 `type`/`vector`/`bounds` 任一
15. `(vector-ref 1 0)` / `(vector-length (cons 1 2))`：运行时类型错误
16. `(make-vector 1)` / `(vector-set! (make-vector 1 0) 0)` / `(vector?)`：编译期 arity 错误
17. `(%begin (make-vector 2 0) 7)` → `7`

测例 7 是本层与 L15 平行的合同句：mutation 原语返回容器本身。

## 验收标准

- 测例 1–11、17 输出与上表一致：`#(` 无空格，元素单空格，空向量 `#()`。
- 测例 12–15 非 0 退出；越界不得静默返回 `#f` 或 `0`。
- `make-vector` 先求 `n` 再求 `fill`；`n=0` 仍求值 `fill`（可用 `(make-vector 0 (%bump 8))` 再 `%hp-fixnum` 观察 bump——可选自检，不强制）。
- `vector-set!` 返回值 `vector?` 为真（测例 8）。
- 64 位 `ldr`/`str`；循环与临时不用 `x18`。
- 未把宿主 vector 字面量当程序执行。

## 常见坑

- **分配 `8*n` 忘了长度头**：`vector-ref` 的 0 号元素读到长度，打印 `#(3 …)` 一类错乱。
- **`nbytes = tagged_n * 8`**：大 4 倍，HP 猛进，小测例仍可能绿直到 `%hp-fixnum`。
- **`vector-set!` 返回 `x` 或 `VOID`**：测例 7 碰巧过或变成类型错误。必须返回 vector。
- **填充循环写成 `i = 0 … n-1` 却写到 `raw+i*8` 覆盖长度**：0 号槽是长度。元素从偏移 8 起。
- **`b.gt` 与无符号 `n` 混用**：负 `n` 应在循环前拒绝。
- **打印 `#3(1 1 1)` 或 `#( 1 1 1 )`**：空格位置与 R4RS `write` 最小子集不一致。
- **`vector-ref` 不去标签**：地址 +2，未对齐 `ldr` SIGBUS。
- **越界用 `i <= len` 当合法**：`i == len` 是越界。
- **`make-vector` 一个参数**：本层编译期错，不要默默填 `0`。
- **用 C 的 `malloc` 做 vector**：打破 HP 合同，GC 以后找不到对象。必须 bump。

## 下一层预告

L17 做可变字符串：长度头仍是 fixnum，但 payload 是裸字节而不是带标签字，加载要用 `ldrb`/`strb`。
