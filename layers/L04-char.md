# L04 — 字符立即数

## 目标

增加字符立即数。源程序里的 `#\A`、`#\nul`、`#\space`、`#\newline` 等，经宿主 `read` 得到 char 对象后，编码进 64 位字：低 8 位为 `CHAR_TAG=0x0F`，字符码在 bit[15:8]。`rt_print` 按 R4RS `write` 风格打印 `#\a`、`#\space`、`#\newline`，其余用 `#\xHH` 或字面 `#\X`。

本层仍是「程序 = 单个字面量」。无 `char?`（L05）、无 `char->integer`（L06 的 `char->fixnum`）、无 Unicode。

本层范围之外：码点 > 255、UTF-8 源文件里的非 Latin-1 字符、`#\x3BB` 一类 R6RS 语法、字符比较 `char<?`。

## 原理

### 编码

```
CHAR_TAG   = 0x0F = 0b00001111
CHAR_SHIFT = 8
tagged     = (code << 8) | 0x0F
code       = (tagged >> 8) & 0xFF
谓词（L05）：(x & 0xFF) == 0x0F
```

例：

| 字符 | code | 标签字 |
|------|------|--------|
| `#\nul` | 0 | `0x000F` |
| `#\newline` | 10 | `0x0A0F` |
| `#\space` | 32 | `0x200F` |
| `#\A` | 65 | `0x410F` |
| `#\a` | 97 | `0x610F` |

低 8 位 `0x0F` 的低 3 位是 `111`，落入立即数族，与 fixnum（`00`）、pair（`001`）都不撞。payload 只占 **8 位**：本层字符是 0–255 的 Latin-1 码。R4RS 不规定 Unicode，这样选是为了 `CHAR_SHIFT=8` 一条移位就能取出码点，和 Ghuloum 32 位论文同一形状。

不要把字符放进 fixnum（`65` 与 `#\A` 必须是不同的值）。不要把码点放进低 8 位——那会毁掉 tag。

### 前端

宿主 Scheme 的 `char?` / `char->integer`：

```scheme
(define CHAR_TAG #x0F)
(define CHAR_SHIFT 8)

(define (char-code-ok? n)
  (and (integer? n) (<= 0 n 255)))

(define (expr->ir expr)
  (cond
    ((char? expr)
     (let ((n (char->integer expr)))
       (if (char-code-ok? n)
           `(imm ,(logior CHAR_TAG (ash n CHAR_SHIFT)))
           (error "L04: char out of Latin-1" expr))))
    ((null? expr) `(imm ,EMPTY_LIST))
    ((eq? expr #t) `(imm ,BOOL_T))
    ((eq? expr #f) `(imm ,BOOL_F))
    ((fixnum-range? expr) `(imm ,(* expr 4)))
    (else (error "L04: bad literal" expr))))
```

测例文件写 `#\A` 而不是整数 65。若宿主 `read` 把 `#\newline` 读成 code 10，不要在前端再把名字解析一遍。

`#\space` 与 `#\ `（反斜杠后一个空格）在 R4RS 都是合法写法；测例用 `#\space`，避免编辑器把尾空格吃掉。

### 打印

```c
#define CHAR_TAG 0x0F
#define CHAR_SHIFT 8

static int is_char(ptr x) { return (x & 0xFF) == CHAR_TAG; }

void rt_print(ptr x) {
    if ((x & 3) == 0) { printf("%lld\n", (long long)(x >> 2)); return; }
    if (x == BOOL_T) { printf("#t\n"); return; }
    if (x == BOOL_F) { printf("#f\n"); return; }
    if (x == EMPTY_LIST) { printf("()\n"); return; }
    if (is_char(x)) {
        unsigned c = ((unsigned)x >> CHAR_SHIFT) & 0xFFu;
        if (c == ' ') printf("#\\space\n");
        else if (c == '\n') printf("#\\newline\n");
        else if (c >= 33 && c <= 126) printf("#\\%c\n", (char)c); /* 可见 ASCII 不含空格 */
        else printf("#\\x%02X\n", c);
        return;
    }
    rt_error("L04: unprintable value");
}
```

R4RS 对 `#\space` / `#\newline` 有规定名字；其它字符用 `#\` 后跟该字符。不可见字符用 `#\xHH` 是本教程的合同（R4RS 对此未规定），测例 8、9 锁死这种输出。

`#\\` 在 C 字符串里是一个反斜杠。打印 `#\A` 时不要漏反斜杠变成 `#A`。

### aarch64-apple

无新指令。`0x410F` 仍走 L01 的 `emit-imm`（`movz`/`movk`）。不要为字符写第二条装载路径。

## 与上一层的差异

- 前端多一种字面量：宿主 `char?`。
- `scheme.h` 增加 `CHAR_TAG`、`CHAR_SHIFT`。
- `rt_print` 多一条立即数族分支。
- 标签体系不变；空表 / 布尔 / fixnum 回归必须仍绿。

## 代码骨架

`scheme.h`：

```c
#define CHAR_TAG   0x0F
#define CHAR_SHIFT 8
```

编译器与 C 数值必须同为 `15` 与 `8`。

IR 仍只是 `(imm tagged)`。芯片无关前端负责移位；后端不知道「这是字符」。

## 测例清单

上一层全部测例仍须通过。

1. `#\A` → `#\A`
2. `#\a` → `#\a`（大小写不同对象）
3. `#\0` → `#\0`（字符零，不是 fixnum 0）
4. `0` → `0`（回归：fixnum 0 不是 `#\nul`）
5. `#\space` → `#\space`
6. `#\newline` → `#\newline`
7. `#\nul` 或 `(integer->char 0)` 若宿主能写出 `#\nul`：→ `#\x00`（按上面打印合同）。若宿主没有 `#\nul` 名字，测例用能 `read` 出 code 0 的写法，或在编译器单测里直接喂 char 对象。
8. 码点 1（SOH）：→ `#\x01`
9. 码点 127（DEL）：→ `#\x7F` 或 `#\x7f`（锁定小写十六进制、两位、`#\x` 前缀：`#\x7F`）。请实现为 **两位大写** hex，与骨架 `printf("#\\x%02X")` 一致。
10. `#\(` → `#\(`
11. `#f` → `#f`；`()` → `()`（回归）
12. 输入 65：→ `65`（不是 `#\A`）
13. 宿主 char 码点 > 255：编译期错误。

## 验收标准

- `#\A` 与 `65` 输出不同。
- `#\space` / `#\newline` 用名字而不是 `#\ ` 或真实换行（否则 `.expected` 文件会坏）。
- 标签字低 8 位为 `0x0F`：编译器单测可断言 `(imm #x410F)` 对应 `#\A`。
- 未实现 `char?`：输入 `(char? #\A)` 编译期拒绝。

## 常见坑

- **把 `#\A` 编成 fixnum 65**：L05 的 `char?` 会全假，L06 的 `char->fixnum` 会变成空操作。
- **payload 放低 8 位**：tag 被覆盖，打印走「未知值」。
- **`printf("#\%c")` 少一个反斜杠**：C 把 `#\%c` 当格式错误或打印 `#A`。
- **`#\newline` 打印成真换行**：期望文件变成两行，`diff` 失败。
- **用 `== 0x0F` 比满字**：`#\nul` 才是满字 `0x0F`，`#\A` 是 `0x410F`。打印必须先 `is_char` 掩码。
- **测例文件编码**：UTF-8 的 `λ` 不要出现在本层测例里。

## 下一层预告

L05 用掩码实现 `fixnum?` `boolean?` `null?` `char?`，程序第一次变成原语调用树。
