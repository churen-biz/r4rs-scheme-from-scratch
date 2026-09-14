# L44 — `write` / `display`

## 目标

实现 R4RS 的两个打印过程，并把 runtime 入口的 `rt_print` **改为走 `write` 再换行**。从此所有旧测例的期望格式必须与 `write` 一致（字符串带引号、字符带 `#\`、真表与点对、符号名为 identifier）。

| 过程 | 行为 |
|------|------|
| `(write obj)` | 外部表示，目标是 `read` 能再读回来（在本系统已实现的 subset 内） |
| `(display obj)` | 给人看：字符串与字符 **不** 加引号/前缀 |

本层锁定环：**检测环，打印 `#<cycle>`**，避免无限递归。不实现 R7RS 的 `#n=` / `#n#` 共享标记。未知标签打印 `#<0x…>` 十六进制满字（小写 hex，宽度不强制，锁定前缀 `#<0x` 与后缀 `>`）。

本层范围之外：`pretty-print`；`format`；对输出端口的第二参数（`(write obj port)` 允许做，不强制；测例只走当前输出 stdout）；`write-char` 可作为 `display` 字符的别名但不要求；循环共享的 DAG 去重（只检 **正在访问栈** 上的环，共享非环结构打印两次）。

## 原理

### `write` vs `display`

对大多数类型二者相同。不同点只有：

| 类型 | `write` | `display` |
|------|---------|-----------|
| 字符串 | `"…"`，内部 `"` → `\"`，`\` → `\\` | 原始字节，无引号 |
| 字符 | `#\` 后跟字面或名字 | 只输出那一个字节 |
| 其它 | 相同 | 相同 |

字符名字：码点 32 → `write` 为 `#\space`；码点 10 → `#\newline`。其它图形字符（ASCII 33–126 且不是必须用名字的）→ `#\` 加该字符，例如 `#\a`、`#\(`。非图形（0–31 除 newline、127+）本层锁定：`write` 打印 `#\<hex>` **不采用**；改为 `#\x` 不是 R4RS。本层 **只保证** `#\space` `#\newline` 与可打印 ASCII；其它码点 `write` 为 `#\` 后跟该字节（即使不可打印）。测例不覆盖 DEL。

布尔：`#t` `#f`。空表：`()`。fixnum：十进制，负号，**不要**前导 `+`。EOF：`#<eof>`。VOID：`#<void>`。

符号：`write`/`display` 都输出 intern 字符串的内容（不加 `'`）。若名字需要转义才能被 reader 读回（含空白、括号）：本层范围之外的「竖线符号」；测例只用 reader 能原样读回的名字。

### 真表 vs 点对

```
(1 2 3)     ; cdr 链以 () 结束
(1 2 . 3)   ; 最后 cdr 不是 () 也不是 pair
(1 . 2)     ; 第二元素就是非表
```

算法（`write`/`display` 共用结构，只把「元素怎么打」的标志 `displayp` 往下传）：

```
print_pair(p):
  putchar('(')
  loop:
    print(car(p))
    cdr = cdr(p)
    if cdr == () : break
    if is_pair(cdr):
       if cyclic_on_stack(cdr): write " . #<cycle>"; break
       putchar(' ')
       p = cdr
       continue
    else:
       write " . "
       print(cdr)
       break
  putchar(')')
```

元素之间 **一个空格**。不要逗号。不要在 `(` 后、`)` 前加空格。

向量：`#(` 然后空格分隔元素再 `)`。空向量 `#()`。环：向量槽里指回自身 → 该槽 `#<cycle>`。

### 环检测（访问栈，不是全局 seen）

把「当前递归路径上的 pair 与 vector 指针」放进一张表（C 数组或 Scheme 列表）。进入对象时 push，离开 pop。

- **环**：打印到已在栈上的同一指针 → 输出 `#<cycle>`，不再递归。
- **DAG 共享**（两处 `cdr` 指向同一非祖先序对）：栈上没有它，打印两次。这是刻意简化。

不要用「曾经打印过就永远 `#<cycle>`」：`(let ((x '(1))) (list x x))` 应打印 `((1) (1))` 而不是 `((1) #<cycle>)`。

字符串、符号、闭包、box 不作为「结构环」的节点（box 若 L23 暴露且可能 `(set-box! b b)`：本层若打印 box，遇到已在栈上的同一 box 也打 `#<cycle>`；若 `rt_print` 尚不打印 box 内容，维持原样）。闭包打印锁定 `#<closure>`，不挖自由变量（避免又一层环）。

### `rt_print` 对齐

```c
void rt_print(ptr x) {
    rt_write(stdout, x, 0); /* 0 = write 模式 */
    fputc('\n', stdout);
}
```

`main` 仍调用 `rt_print` 印程序结果。因此：

- 旧测例里字符串程序 `"hi"` 的期望从可能的 `hi` 改为 `"hi"`（含引号）。
- 字符 `#\a` 期望 `#\a`。
- 本层必须 **更新** L17 等层中与新格式冲突的 `.expected`（这是合同允许的「打印策略分层」，ARCHITECTURE §7）。若仓库只是文档、测例由读者自建，读者在本层改自己的期望文件。

Scheme：

```
(write x)    → (prim write x)    ; 副作用后返回 VOID
(display x)  → (prim display x)  ; 同上
```

测例若以 `(write obj)` 为程序，stdout 先是 `write` 的文本（无强制换行），然后 `rt_print` 印 `#<void>\n`。期望文件必须包含这两段。更干净：`(begin (write obj) #\newline)` 仍会多印一个字符的 `write` 形式。推荐测副作用时用：

```scheme
(begin (display "x") 1)
```

期望：`x1\n`（`display` 无换行，随后 `rt_print` 写 `1\n`）。

### 未知值

低 3 位对不上已知标签、立即数也不是已列常量：

```c
fprintf(out, "#<0x%llx>", (unsigned long long)(uint64_t)x);
```

不要尝试当指针解引用。

## 与上一层的差异

- 打印从「runtime 认识几种类型就 printf」变成 **规范的 `write`/`display`**。
- 环不再能把测例卡死。
- 新增用户过程 `write`、`display`。
- `rt_print` 必须调用同一套 `rt_write`，禁止两套格式分叉。
- L43 测例 6–9 的期望若曾依赖旧 string/char 打印，本层起以本节为准。

## 代码骨架

### C：`rt_write`

```c
#define SEEN_MAX 256

static int seen_has(ptr *stk, int n, ptr x) {
    int i;
    for (i = 0; i < n; i++) if (stk[i] == x) return 1;
    return 0;
}

static void rec(FILE *out, ptr x, int displayp, ptr *stk, int n);

void rt_write(FILE *out, ptr x, int displayp) {
    ptr stk[SEEN_MAX];
    rec(out, x, displayp, stk, 0);
}

void rt_display(FILE *out, ptr x) { rt_write(out, x, 1); }

void rt_print(ptr x) {
    rt_write(stdout, x, 0);
    fputc('\n', stdout);
}
```

`rec` 内按标签分派。pair：

```c
if (seen_has(stk, n, x)) { fputs("#<cycle>", out); return; }
if (n >= SEEN_MAX) { rt_error("write nest"); }
stk[n] = x;
/* print as described; recursive rec(..., stk, n+1) */
```

字符串 `write`：

```c
fputc('"', out);
for each byte b:
    if (b == '"' || b == '\\') { fputc('\\', out); fputc(b, out); }
    else fputc(b, out);
fputc('"', out);
```

`display` 字符串：逐字节 `fputc`，无引号。

符号：取出槽 0 的 string，按 **display 字符串** 规则输出（名字本身不当成要加引号的 string 对象）。

### Scheme prim

```scheme
(define (emit-prim name args ctx)
  (case name
    ((write)
     (string-append (emit-ir (car args) ctx)
                    (sync-hp)
                    (emit-c-call "rt_write_stdout" 1)
                    (emit-imm VOID)))
    ((display)
     ;; 同，rt_display_stdout
     )
    ...))
```

C 封装：

```c
ptr rt_write_stdout(ptr x) { rt_write(stdout, x, 0); return VOID; }
ptr rt_display_stdout(ptr x) { rt_write(stdout, x, 1); return VOID; }
```

`write`/`display` 的 Scheme 结果是 `VOID`，不是被打印的对象。

同步 HP：本层打印 **不分配**（`#<cycle>` 是 C 栈上的字面），可以不碰 `x19`。仍建议与其它 `emit-c-call` 同一序言，免得以后改 `rt_write` 忘了。

### 端口

当前输出固定 stdout。`(current-output-port)` 范围之外。不要 `svc` 写文件。

## 测例清单

上一层全部测例仍须通过（**含因 `write` 格式而更新后的字符串/字符期望**）。

1. `1` → `1`（回归 fixnum）
2. `#t` → `#t`
3. `'()` 或 `()` → `()`
4. `#\a` → `#\a`
5. `#\space` → `#\space`
6. `#\newline` → `#\newline`
7. `"hi"` → `"hi"`
8. `"a\"b"` → `"a\"b"`
9. `"\\"` → `"\\"`
10. `(cons 1 (cons 2 '()))` → `(1 2)`
11. `(cons 1 2)` → `(1 . 2)`
12. `(cons 1 (cons 2 3))` → `(1 2 . 3)`
13. `'foo` → `foo`
14. `(begin (display "hi") 1)` → `hi1`（第二行无：整个 stdout 为 `hi1\n`）
15. `(begin (display #\a) 1)` → `a1\n` 即字符 `a` 后接 `1\n`
16. `(begin (write "hi") 1)` → `"hi"1\n`
17. `(begin (write #\a) 1)` → `#\a1\n`
18. 环 pair：

    ```scheme
    (let ((p (cons 1 2)))
      (begin (set-cdr! p p) p))
    ```

    → `(1 . #<cycle>)`
19. 环更长：

    ```scheme
    (let ((a (cons 1 (cons 2 '()))))
      (begin (set-cdr! (cdr a) a) a))
    ```

    → `(1 2 #<cycle>)`  
    锁定：回头指向访问栈上的 pair 时，按真表元素打印空格 + `#<cycle>` + `)`，不要改走 `. #<cycle>`。
20. DAG 非环（共享但共享点不在访问栈上）：`(let ((x (cons 1 '()))) (cons x x))` → `((1) 1)`  
    （结构是 `(x . x)`，`write` 对 pair-cdr 用真表糖，故第二份 `x` 打成空格分隔的 `(1)`；不得打 `#<cycle>`。）
21. 向量环：`(let ((v (make-vector 1 0))) (begin (vector-set! v 0 v) v))` → `#(#<cycle>)`
22. `(lambda () 1)` → `#<closure>`
23. `(write)` 或 `(write 1 2)`：编译期 arity 错误。
24. `(display "a\nb")` 作为程序：stdout 恰好 `a\nb#<void>\n`。

## 验收标准

- `rt_print` 与 `(write x)` 对同一 `x` 的主体相同，仅 `rt_print` 多一个末尾 newline。
- 测例 18–21 在有限时间内结束；输出含 `#<cycle>`，不含无限重复。
- 测例 20 不含 `#<cycle>`。
- 字符串 `write` 能被 L43 `(read)` 读回（可手测管道）；`display` 的 `"hi"` 读回的是符号 `hi` 或非法，不要用 `display` 当外部表示。
- 没有为打印走 `malloc` 建拷贝；seen 栈在 C 自动存储。

## 常见坑

- **全局 seen 把 DAG 当环**：测例 20。
- **真表循环走 `. #<cycle>` 还是空格 `#<cycle>`**：不锁定会死对测例 19；本层已锁 `(1 2 #<cycle>)`。
- **`display` 字符串仍加引号**：测例 14。
- **`write` 字符打成单个字节**：测例 17。
- **环检测用 `equal?` 而不是指针**：结构相等的不同序对不是环。
- **`rt_print` 忘了改**：用户 `write` 一套、进程结果另一套。
- **在 `write` 里递归打印时对新分配 intern**：打印不应 intern。
- **hex 未知值解引用**：立刻 SIGSEGV。

## 下一层预告

L45 要让程序跨文件：`(load "path")` 与真正的 **顶层 `define`**（全局环境），而不是只有一个表达式。
