# L43 — Reader：从端口读入 datum

## 目标

实现 **本系统自己的 reader**：从输入端口读一个（或在 `load` 之前：反复读到 EOF）外部表示，返回堆上/立即数上的 Scheme 对象。本层语言增加 `(read)`，无参数，从 **当前输入** 读一个 datum。

此前各层测例文件是 `.scm` 文档；自托管前由人手写等价 `.s`。自托管之后，编译器读 `.scm`。那条路 **可以用来编译 compiler 自己的源**；但「用户程序里的 `read`」和「把源文本变成 datum 的规范」必须以本层实现为准。自研 reader 的测例通过往进程 **stdin** 灌文本、程序调用 `(read)` 来观察。

本层锁定：

- 十进制 **有符号 fixnum**（可选前导 `+`/`-`）。
- 布尔 `#t` `#f`（不是 `#true`）。
- 字符 `#\` *char*，以及名字 `#\space`、`#\newline`。
- 字符串 `"…"`，转义仅 R4RS 要求的 `\\` 与 `\"`。
- 表、点对表、空表。
- 缩写：`'` `` ` `` `,` `,@` → `quote` / `quasiquote` / `unquote` / `unquote-splicing`。
- 行注释 `;` 直到换行（含该换行作为空白）。
- 符号：**intern** 后返回带 `SYMBOL_TAG` 的对象。intern 表用 L41 已放入 runtime 的那张（若你把 intern 拖到本层才写，也必须是 runtime 汇编或后续 Scheme 里这一份）。

本层范围之外：块注释 `#| … |#`；datum 注释 `#;`（那是 R6RS/R7RS，**不要做、测例也不要依赖**）；字符串口（string port）；`(read port)` 多端口；十六进制/二进制数值前缀；浮点、有理数；符号大小写折叠（R4RS 不区分大小写，本教程 **锁定大小写敏感**，与现有测例标识符一致；L54 再列入缺口）。向量外部表示 `#(…)` **本层要做**（见原理）。

## 原理

### 谁调用 reader

```
runtime:  `_rt_read` 从 fd 读一个 datum（SYS_read）；EOF → EOF_OBJ 0x5F
Scheme: (prim read)            ; 无参，FILE* = stdin（current-input）
```

`main` **不要**改成自己 `rt_read` 再 eval——没有 `eval`。编译器前端可以：

- 继续用自托管编译器自己的 parser 编译测例文件（最少改动，回归稳）；或
- 用本 reader 的 Scheme/asm 实现解析源文件。

不要用 Chez / Guile / Python 的 `read` 当宿主编译器。

锁定：**本层验收不要求编译器改用自研 reader**；要求 `(read)` 在生成的程序里行为正确。L45 `load` 再强制用这份 `rt_read` 读文件。

EOF：再读时返回立即数 `EOF_OBJ = 0x5F`。本层可提供 `eof-object?` 谓词（掩码/满字比较），测例需要区分「读到 `#f`」与「读完」。若暂不暴露 `eof-object?`，测例不要在 EOF 上断言，只读恰好一个 datum。推荐本层加上 `(eof-object? x)`，打印 EOF 为 `#<eof>`。

### 字符流

在输入端口上做 **一个字符的 peek**：一字节 lookahead 缓冲。空白：space、tab、newline、return。注释：peek 到 `;` 则吞到（含）newline，再当空白继续。不要依赖 libc `FILE*` / `ungetc`。

token 分类：

| 下一字符 | 动作 |
|----------|------|
| `(` | 读表 |
| `)` | 错（多余右括号） |
| `"` | 读字符串 |
| `'` `` ` `` `,` | 缩写 |
| `#` | 派发 `#t` `#f` `#\` ；`#(` 见向量 |
| `;` | 注释（通常在空白循环里已处理） |
| 数字或 `+`/`-` 后跟数字 | fixnum |
| 其它 identifier 字符 | 符号 |

单独的 `+`、`-`、`...` 是符号，不是数。`+1`、`-42` 是数。`1+`：本层锁定为 **符号**（不是错误），intern `"1+"`。含小数点 `1.2`：本层 **读错误**（既不当 flonum 也不当符号），避免以后数值塔无法改语义。

### 数

在 62 位有符号范围内累加。溢出 → `rt_error("read number")`。不允许 `#x`、`#o`、`#b`。前导零合法：`007` → fixnum `7`。

打标签：`n << FX_SHIFT`，与 L01 相同。

### 布尔与字符

`#t` `#f` 必须是恰好这两个 token；`#true`、`#T` 读错误（大小写敏感）。`#t` 后若紧跟 identifier 字符（`#tf`）也是错误。

字符：

- `#\a`、`#\A`、`#\(` —— `#\` 后面读 **一个** 字符，即使它是空白：`#\` 后立刻是 space 则是 `#\space` 的另一种写法吗？R4RS：`#\` 后若下一字符是字母，则可能是名字。锁定：
  - 若 `#\` 后是字母，继续读完 identifier，若结果为 `space` 或 `newline`（恰好）则用对应码；若长度为 1，则该字母本身；若长度 >1 且不是这两个名字 → 读错误。
  - 若 `#\` 后不是字母（数字、标点、`(`），只取那一个字符。
- `#\space` → 码点 32，`#\newline` → 码点 10。
- 编码：`(code << CHAR_SHIFT) | CHAR_TAG`，`CHAR_SHIFT=8`，`CHAR_TAG=0x0F`。

`#\nul` 范围之外（L04 若测过 nul，那是立即数字面，不是本 reader 必读的名字）。

### 字符串

读到关闭 `"`。`\\` → 一个反斜杠；`\"` → 一个引号。其它反斜杠：本层读错误（不要默默丢掉反斜杠）。换行可以出现在字符串里（裸 newline 计入一个字符）。分配 L17 布局：`[len:fixnum][bytes…]` 垫 8，指针 OR `STRING_TAG`。

### 表与点对

```
read-list:
  skip whitespace
  if ')' → return ()
  if '.' → 读一个 datum，空白，必须 ')'，返回该 datum（作为当前 cdr）
  else → cons(read-datum(), read-list())
```

非法：`(.)`、`(a .)`、`(a . b c)`、`(a . b . c)`、开头的 `.` 当作 token 在表外（`.` 单独可以是符号——R4RS 的 `...` 和 `.` 规则）。锁定：**表外单独 `.` 是读错误**（避免与点对语法纠缠）；`...` 是符号。

循环列表的外部表示本层没有（`#n=` 是 R7RS），读入的表都是有限树。

缩写：读完一个 datum `d` 后返回 `(cons intern("quote") (cons d '()))` 等。`,'@`：peek `,` 后若下一字符是 `@` 则 `unquote-splicing`，否则 `unquote`。

### 向量外部表示

`#(1 2 3)` 在 R4RS 合法。本层 **必须** 读成 vector 对象，元素不能用点对语法。`#(` 后按 `read-list` 同样的元素规则直到 `)`，再分配 L16 布局。

### intern（本层最小，L46 扩 API）

```
; 算法伪代码：实现必须是 runtime 汇编，不是 C。
_rt_intern_bytes(buf, n)          ; reader 读到符号名时
ptr rt_string_to_symbol(ptr str);           /* 给 L46 用，本层可先写好 */
```

表：线性扫描即可（容量 1024 或可增长）。命中返回旧 symbol ptr。未命中：分配 string 副本（不要指向 reader 的栈缓冲），分配 8 字节 symbol 格，槽 0 = tagged string，打 `SYMBOL_TAG`，插入表。

Reader **禁止**返回未 intern 的「看起来像符号」的字符串。`eq?` 两个独立读入的 `foo` 必须 `#t`。

分配必须走与 `cons` 相同的 bump。runtime reader 辅助 在 `scheme_entry` **之外** 第一次被 `main` 调用吗？本层 `(read)` 在用户程序里调用，此时 `x19` 已是 HP。`emit` 对 `read` 做 `emit-rt-call` 前后同步 HP 到 runtime 全局：

```
; 算法伪代码：实现必须是 runtime 汇编，不是 C。
ptr *rt_hp;
ptr *rt_hl;
ptr rt_alloc(u64 nbytes); /* 8 对齐，失败 rt_error */
```

汇编：`bl _rt_read` 前 `str x19, [rt_hp 的页]` 或把 HP 放进已知符号 `_scheme_hp`。回来 `ldr x19`。这是 L41 `%intern` 若走 runtime 辅助 时同一套约定；本层必须写进 `runtime.s` 注释。

### `(read)` 的 IR

```
(read)  →  (prim read)
```

Arity ≠ 0 → 编译期错误。本层不实现 `(read port)`。current-input 固定 stdin。字符串口范围之外。

读错误（未闭合的 `"`, 多余 `)`, 非法 `#`）：`rt_error`，进程退出非 0。不要返回 `#f`。

## 与上一层的差异

- 运行时第一次从字节流构造任意 datum，而不只是执行编译好的常量图。
- intern 表被 reader 真正用起来（L41 只给 `quote` 符号用）。
- 新增 prim `read`、建议 `eof-object?`。
- 自托管编译器的 parser 可以仍用同一套读法；用户可见语言变了。

## 代码骨架

### runtime 汇编：空白、peek、datum

```
; 算法伪代码：实现必须是 runtime 汇编，不是 C。
static int peek(fd/port in) {
    int c = getc(in);
    if (c != EOF) ungetc(c, in);
    return c;
}

static void skip_ws(fd/port in) {
    for (;;) {
        int c = peek(in);
        if (c == ';' ) {
            while (c != EOF && c != '\n') c = getc(in);
            continue;
        }
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
            getc(in);
            continue;
        }
        return;
    }
}

ptr rt_read(fd/port in); /* 实现 read_datum */

static ptr read_list(fd/port in); /* 已吞掉 '(' */
static ptr read_string(fd/port in);
static ptr read_hash(fd/port in);
static ptr read_number_or_symbol(fd/port in);
```

`read_list` 用递归 `cons`。深度过大（恶意输入）本层不设限，测例保持浅表。

### 符号缓冲

```
; 算法伪代码：实现必须是 runtime 汇编，不是 C。
enum { NAME_MAX = 256 };
static ptr intern_buf(char *buf, int n) {
    buf[n] = 0;
    return rt_intern_bytes(buf, (size_t)n);
}
```

超长符号 → `rt_error`。identifier 字符锁定为：

```
letter | digit | ! $ % & * + - . / : < = > ? @ ^ _ ~
```

第一个字符不能是数字（否则走数）；`+` `-` 单独或后跟非数字 → 符号。

### Scheme 侧

```scheme
((and (pair? expr) (eq? (car expr) 'read) (null? (cdr expr)))
 '(prim read))
((and (pair? expr) (eq? (car expr) 'eof-object?) (length=? expr 2))
 `(prim eof-object? ,(expr->ir (cadr expr))))
```

### aarch64-apple

```asm
    ; emit-prim read
    adrp x9, _scheme_hp@PAGE
    str  x19, [x9, _scheme_hp@PAGEOFF]
    mov  x0, #0            ; 若 rt_read 无 FILE* 参数则内部用 stdin
    bl   _rt_read_stdin
    adrp x9, _scheme_hp@PAGE
    ldr  x19, [x9, _scheme_hp@PAGEOFF]
```

C：

```
; 算法伪代码：实现必须是 runtime 汇编，不是 C。
ptr scheme_hp; /* 或 ptr *；与汇编约定一种并写死 */

ptr rt_read_stdin(void) {
    return rt_read(stdin);
}
```

Darwin 符号带 `_`。`FILE*` 不要从汇编塞进 `x0` 除非你声明了正确类型；推荐无参封装 `rt_read_stdin`。

## 测例清单

上一层全部测例仍须通过。

测例程序调用 `(read)`，驱动把下列文本送进 **stdin**（不含程序源）。期望是 `rt_print` 打印的对象（含末尾换行）。

1. stdin: `42` → `42`
2. stdin: `-7` → `-7`
3. stdin: `+3` → `3`
4. stdin: `#t` → `#t`
5. stdin: `#f` → `#f`
6. stdin: `#\a` → `#\a`（打印形式沿用 L04/将与 L44 对齐；本层 `rt_print` 对 char 仍按 L04）
7. stdin: `#\space` → 码点 32 的字符（打印可能是 `#\space` 或空格，本层锁定 **仍用 L04 规则**；若 L04 打印空格字符本身，期望文件按 L04）
8. stdin: `#\newline` → 码点 10 的字符
9. stdin: `"hi"` → 与 L17 对字面量 `"hi"` 的 `rt_print` 期望相同（L44 起改为带引号的 `write` 形式 `"hi"`）
10. stdin: `"a\"b\\c"` → 内容为 `a"b\c` 的字符串
11. stdin: `(1 2 3)` → `(1 2 3)`
12. stdin: `(1 . 2)` → `(1 . 2)`
13. stdin: `(1 2 . 3)` → `(1 2 . 3)`
14. stdin: `()` → `()`
15. stdin: `'x` → `(quote x)`
16. stdin: `` `(a ,b ,@c) `` → `(quasiquote (a (unquote b) (unquote-splicing c)))`
17. stdin: `; comment\n9` → `9`
18. stdin: `foo` 与程序 `(eq? (read) (read))`、stdin `foo foo` → `#t`（intern）
19. stdin: `#(1 2)` → `#(1 2)`
20. 程序 `(eof-object? (read))`、stdin 空 → `#t`
21. stdin: `(1 2` （未闭合）：运行时 `read` 错误。
22. stdin: `"unterminated`：运行时错误。
23. stdin: `#x10` 或 `#true`：运行时错误。
24. stdin: `)`：运行时错误。
25. 空白与注释：stdin `  ;c\n  (  1  ;x\n  2 )` → `(1 2)`

测例 18 的程序是 `(eq? (read) (read))`，不是单次 `read`。驱动须支持「源程序与 stdin 分离」。

测例 6–8 的字符打印与 L04 相同；测例 9–10 的字符串打印与 L17 相同。L44 会把 `rt_print` 改成 `write` 并更新这些期望。

## 验收标准

- 1–20、25 退出码 0；21–24 非零，stderr 含 `read`。
- 两次读入同一符号名 `eq?` 为真；`string=?` 级相等但未 intern 的假实现不合格。
- `;` 注释不进入字符串内部：`"a;b"` 是三字符字符串。
- `#|` 若误实现，不要在测例里依赖；碰到 `#|` 本层按非法 `#` 派发错误即可。
- `(read)` 不从汇编 `svc` 读，只经 runtime `SYS_read`。
- HP 在 `read` 返回后仍一致：随后 `(cons 1 2)` 仍然可跑（可手测 `(cons (read) '())` + stdin `1` → `(1)`）。

## 常见坑

- **在字符串里处理 `;` 或空白折叠**：注释只在 inter-token 空白循环。
- **`ungetc` EOF**：有的 libc 对 EOF `ungetc` 行为特殊；peek 时若 `getc==EOF` 不要 ungetc。
- **`#\space` 被读成 `#\s` + 符号 `pace`**：字母名字要读完整 token。
- **符号缓冲指向 reader 栈**：intern 之后覆盖缓冲，所有符号变成最后一个名字。必须拷贝到堆 string。
- **runtime 分配不 bump `x19`**：`read` 回来后 `cons` 覆盖 reader 对象。
- **大小写折叠**：`Foo` 与 `foo` 本教程必须是不同符号。
- **把编译器内部 `read` 的结果直接当目标机指针**：自托管编译器里的 pair 不是你的堆对象。`(read)` 是 **运行时** 原语。
- **`,'@` 拆错**：`,` 后 peek `@` 才能拼 `unquote-splicing`；` ,@` 中间空白则是 `unquote` 加上符号 `@`。

## 下一层预告

L44 要按 R4RS 分清 **`write` 与 `display`**，并让打印遇到环时停下来，而不是无限递归。
