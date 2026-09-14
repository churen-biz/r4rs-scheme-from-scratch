# L17 — 基本 string（可变）

## 目标

R4RS 字符串是**可变**的。布局：

```
[ len : fixnum ][ bytes … 垫齐到 8 字节 ]
```

指针标签 `STRING_TAG=0b011`。本层用户原语：

| 原语 | 含义 |
|------|------|
| `(make-string n fill-char)` | `n` 个字节，每个初始化为 `fill-char` 的 Latin-1 码 |
| `(string-ref s i)` | 返回字符（立即数，`CHAR_TAG`） |
| `(string-set! s i c)` | 写入一个字符，**返回该 string** |
| `(string? x)` | `(x & 7) == STRING_TAG` |
| `(string-length s)` | 头里的 fixnum 长度 |

本层字符码 **0–255**（ASCII / Latin-1）。`n`、`i` 为 fixnum。越界与类型错误走 `rt_error`。`string-set!` 返回 string，理由与 L15/L16 相同，L22 再改为 unspecified/`VOID`。

`rt_print` 用双引号打印字符串，至少转义 `"` 与换行；建议同时转义 `\\`。

本层范围之外：码点 >255 的 Unicode、UTF-8 存储、字符串 intern、符号、字符串字面量 `"foo"` 作为源语法、不可变 string、`string-append` 库过程。

## 原理

### 为何 payload 是字节

vector 的槽是带标签的字，因为元素是任意 Scheme 值。字符串的元素是字符，字符已经是立即数族；若每个字符存 8 字节，浪费 8 倍且让 `string-ref` 与 `vector-ref` 无法在标签上区分。合同：堆上只存 **8 位码**，`string-ref` 再打成 char 立即数：

```
CHAR_TAG   = 0x0F
CHAR_SHIFT = 8
tagged_char = (code << 8) | 0x0F
code        = (tagged_char >> 8) & 0xFF
```

与 L04 / L06 的 `fixnum->char` / `char->fixnum` 一致。本层 `make-string` 的 fill 必须 `char?` 为真；码点已经落在 bit[15:8] 的 8 位里，所以自然 ≤255。不要在本层发明 32 位码点槽。

### 尺寸与对齐

```
payload_bytes = n                 ; 未对齐
block         = 8 + align8(n)     ; 头 + 垫齐的 payload
align8(n)     = (n + 7) & ~7
```

`n=0`：只分配 8 字节长度头，打印 `""`。垫齐的尾部字节建议写成 0，避免 `rt_print` 若误读越界看到垃圾；打印不得读取超过 `n` 的字节。

`HP` 仍 8 对齐。`align8` 已在 L12 的 `emit-alloc` 里；这里对 **整块** 做 `8+align8(n)`，不要只对齐 `n` 却忘了头。

### 求值与检查

`make-string`：先 `n` 后 `fill-char`。`n` 是 ≥0 的 fixnum；`fill-char` 是 char。然后按上式分配，`str` 长度头，用 `strb` 循环写 `n` 个字节（从 `raw+8` 起）。`n=0` 仍求值 fill，再跳过循环。

`string-ref`：`s` 是 string，`i` 是 fixnum，`0 <= i < len`。`ldrb` 那个字节，左移 8，`orr CHAR_TAG`，放入 `x0`。用 `ldrb w9, [raw, xoff]` 再 `lsl x0, x9, #8`——`ldrb` 到 `w9` 会零扩展到 `x9`。

`string-set!`：同样检查，再确认 `c` 是 char，`strb` 码点，返回 **tagged s**。

`string-length`：检查 string，`ldr` 头。

`string?`：`(x & 7) == 3`。vector 是 `2`，pair 是 `1`，立即数是 `7`。`#t`（`0x6F`）低 3 位是 `111`，不是 string。

### 打印与转义

顶层与嵌套（pair/vector 的元素）都走同一 `print_value`：

- 输出 `"`
- 对每个字节 `b`（仅 `0 .. len-1`）：
  - `b == '"'` → `\"`
  - `b == '\\'` → `\\`（建议；测例 若含反斜杠则依赖它）
  - `b == '\n'`（10）→ `\n`
  - 其余本层测例只用可打印 ASCII（32–126）。其它字节（0–31、127–255）允许原样输出或 `\xNN`；**回归不依赖**这些形式，只通过 `string-ref` 观察码点。
- 输出 `"`

不要在字符串两端加 `#\`。不要打印成 Scheme 字符列表。

换行测例用 `(make-string 1 #\newline)`（若 L04 提供该字面量）或 `(make-string 1 (fixnum->char 10))`。期望标准输出的那一行是 `"\n"` 再加 `rt_print` 自己的换行，即文件内容为：

```
"\n"
```

共 5 个字符：`"`, `\`, `n`, `"`, newline。不要把 payload 换行直接打到输出里把期望文件拆成两行——那就是「至少要转义 newline」的原因。

引号：`(make-string 1 #\")` → `"\""` 再加顶层换行。

### 源语法里没有字符串字面量

宿主 `read` 遇到 `"hi"` 会得到宿主 string。本层锁定：**编译期错误**。测例一律 `make-string` / `string-set!`。若你自愿把宿主 string 降成一串 `make-string`+`string-set!`，须在实现注释写死，且仍要走 bump（不要把 NUL 结尾字节串指针打上 `STRING_TAG`——那不在堆上，将来 GC 必炸）。推荐报错，避免和 L43 reader、L46 intern 缠在一起。

### IR

```
(prim make-string    Ir Ir)
(prim string-ref     Ir Ir)
(prim string-set!    Ir Ir Ir)
(prim string?        Ir)
(prim string-length  Ir)
```

Arity 2 / 2 / 3 / 1 / 1。`%begin` 继续可用。

### 指令选择

| 操作 | 指令 |
|------|------|
| 长度头、vector 式的字 | `ldr`/`str` 64 位 |
| payload 字节 | `ldrb`/`strb`（`w` 寄存器） |
| 禁止 | `x18`；不要用 `ldrh` 存 Latin-1 |

`strb w12, [x0, x15]` 的索引是字节偏移。先 `add x14, raw, #8` 再 `strb w12, [x14, x15]`，`x15` 从 0 走到 `n-1`。

## 与上一层的差异

| 项 | L16 vector | L17 string |
|----|------------|------------|
| 标签 | `010` | `011` |
| 元素 | 带标签字 | 裸字节 |
| 访存 | `ldr`/`str` | 头用 `ldr`/`str`，payload 用 `ldrb`/`strb` |
| 填充 | 任意 Scheme 值 | 必须是 char |
| `*-ref` 结果 | 原槽里的值 | 新打标签的 char |
| 打印 | `#(…)` | `"…"` 带转义 |
| 对齐 | `8*(n+1)` 已对齐 | `8+align8(n)`，`n` 不必是 8 的倍数 |

`vector?` 对 string 为 `#f`，`string?` 对 vector 为 `#f`。

## 代码骨架

### 可移植前端

```scheme
(define STRING_TAG 3)

(define (expr->ir expr)
  (cond
    ((string? expr)
     (error "L17: string literal not yet" expr))
    ((and (pair? expr) (eq? (car expr) 'make-string) (length=? expr 3))
     `(prim make-string ,(expr->ir (cadr expr)) ,(expr->ir (caddr expr))))
    ((and (pair? expr) (eq? (car expr) 'string-ref) (length=? expr 3))
     `(prim string-ref ,(expr->ir (cadr expr)) ,(expr->ir (caddr expr))))
    ((and (pair? expr) (eq? (car expr) 'string-set!) (length=? expr 4))
     `(prim string-set!
            ,(expr->ir (cadr expr))
            ,(expr->ir (caddr expr))
            ,(expr->ir (cadddr expr))))
    ((and (pair? expr) (eq? (car expr) 'string?) (length=? expr 2))
     `(prim string? ,(expr->ir (cadr expr))))
    ((and (pair? expr) (eq? (car expr) 'string-length) (length=? expr 2))
     `(prim string-length ,(expr->ir (cadr expr))))
    ;; vector / %begin / pair / … 以及更早形式
    (else (error "L17: bad expr" expr))))
```

### aarch64-apple：`make-string` 填充

```asm
    ; x0  = raw
    ; x12 = tagged fill char（已 char?）
    ; x13 = untagged n
    ; x14 = tagged n（写入头）
    str     x14, [x0]
    lsr     x12, x12, #8
    and     x12, x12, #0xFF      ; Latin-1 码在 w12
    add     x10, x0, #8          ; payload
    mov     x15, #0
.Lfill:
    cmp     x15, x13
    b.ge    .Lfille
    strb    w12, [x10, x15]
    add     x15, x15, #1
    b       .Lfill
.Lfille:
    orr     x0, x0, #3
```

标签名由编译器生成，避免一个程序里两个 `make-string` 撞标签。

尺寸：

```scheme
(define (string-block-bytes n) ; n 无标签宿主整数或寄存器里的值
  (+ 8 (align8 n)))
```

运行时：`asr x9, tagged_n, #2` → `add x9, x9, #7` → `and x9, x9, #~7` → `add x9, x9, #8` → `emit-alloc-reg`。

### `string-ref`

```asm
    ; 检查后：x0 tagged s, x10 tagged i
    bic     x0, x0, #7
    asr     x9, x10, #2          ; untagged i
    add     x0, x0, #8
    ldrb    w0, [x0, x9]
    lsl     x0, x0, #8
    orr     x0, x0, #0x0F
```

`ldrb w0` 后 `x0` 高位已清。不要 `ldr` 64 位再 `& 0xFF` 却忘了只取一字节——那会把相邻字节卷进字符码。

### runtime 打印

```
; 算法伪代码：实现必须是 runtime 汇编，不是 C。
; STRING_TAG 3

static int is_string(ptr x) { return (x & 7) == STRING_TAG; }

if (is_string(x)) {
    ptr *raw = (ptr *)(x - STRING_TAG);
    i64 n = raw[0] >> 2;
    unsigned char *s = (unsigned char *)(raw + 1);
    putchar('"');
    for (i64 i = 0; i < n; i++) {
        unsigned char b = s[i];
        if (b == '"' || b == '\\') { putchar('\\'); putchar(b); }
        else if (b == '\n') { fputs("\\n", stdout); }
        else putchar(b);
    }
    putchar('"');
    return;
}
```

`raw + 1` 是跳过一个 `ptr`（8 字节）到达 payload，与汇编 `+8` 一致。

## 测例清单

上一层全部测例仍须通过。

1. `(string? (make-string 1 #\a))` → `#t`
2. `(string? (make-vector 1 #\a))` → `#f`；`(vector? (make-string 1 #\a))` → `#f`；`(pair? (make-string 1 #\a))` → `#f`
3. `(string-length (make-string 3 #\x))` → `3`
4. `(string-length (make-string 0 #\a))` → `0`
5. `(string-ref (make-string 1 #\Z) 0)` → `#\Z`
6. `(string-ref (string-set! (make-string 1 #\a) 0 #\b) 0)` → `#\b`
7. `(make-string 3 #\x)` → `"xxx"`
8. `(make-string 0 #\a)` → `""`
9. `(make-string 1 #\")` → `"\""`（输出四个字符再加顶层换行：`"`, `\`, `"`, `"`）
10. `(make-string 1 (fixnum->char 10))` → `"\n"`（转义换行，不是把输出拆成两行）
11. `(string-length (string-set! (make-string 2 #\a) 1 #\z))` → `2`（返回 string 而非 void）
12. `(string-ref (make-string 2 #\a) 2)`：运行时越界
13. `(string-set! (make-string 1 #\a) 0 65)`：运行时类型错误（65 是 fixnum 不是 char）
14. `(make-string -1 #\a)` / `(string-ref #\a 0)` / `(string-length (cons 1 2))`：运行时错误
15. `(make-string 1)` / `(string-set! (make-string 1 #\a) 0)` / `(string?)`：编译期 arity 错误
16. `(%begin (make-string 1 #\a) 9)` → `9`
17. `(char? (string-ref (make-string 1 #\nul) 0))` → `#t`

测例 6 是本层合同句：`string-set!` 返回 string，才能嵌套 `string-ref`。

## 验收标准

- 测例 1–11、16–17 输出与上表一致。测例 9、10 的转义按字节核对，不要靠肉眼「差不多」。
- 测例 12–14 非 0 退出；越界不得返回 `#\nul` 充数。
- payload 用 `ldrb`/`strb`；长度头用 64 位 `ldr`/`str`。
- `string-set!` 的返回值 `string?` 为真。
- 不使用 `x18`。不把 C 静态字符串指针打上 `STRING_TAG` 当 Scheme 字符串。
- 源文件 `"hi"` 编译期错（锁定选择）。
- L12–L16 回归全绿；pair / vector 打印不被 string 分支误伤。

## 常见坑

- **`ldr` 取代 `ldrb`**：一次读 8 字节，`string-ref` 得到错误码点，邻近 `string-set!` 会踩相邻字符。
- **分配 `align8(n)` 却忘了 `+8`**：长度头被 payload 覆盖，或 `HP` 少 8。
- **`n` 不是 8 倍数时不垫齐**：`HP` 低 3 位非 0，下一个 `cons` 的 tagged 指针与 tag 冲突，`pair?` 随机失败。必须 `8+align8(n)`。
- **`string-set!` 返回 char 或 `VOID`**：测例 6 崩。返回 tagged string。
- **打印不转义换行**：期望文件无法写成单行；驱动以为输出多了一行。
- **打印不转义 `"`**：`"\""` 与 `"""` 不同，后者不是合法 `write` 形态。
- **fill 接受 fixnum**：`(make-string 1 65)` 应类型错误，不要默默当 `#\A`。
- **`string-ref` 返回 fixnum 码点**：打印 `65` 而不是 `#\A`。必须打 `CHAR_TAG`。
- **去标签用 `sub #3` 却先没检查**：fixnum 减 3 会变成看起来像指针。先 `& 7 == 3`。
- **把宿主 `"abc"` 的 C 指针 OR 上 tag**：对象不在 bump 堆，长度头不在 `[-8]` 那种错地址上，GC 与打印都会读野内存。
- **循环用 `x18` 作下标**：Darwin 上静默损坏。

## 下一层预告

L18 引入环境里的变量引用。有了名字，同一个 pair / vector / string 才能被多次 `set-car!` / `vector-set!` / `string-set!` 而不再依赖「mutation 返回容器本身」这一偏离。
