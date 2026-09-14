# L46 — 符号、intern、`string->symbol`

## 目标

把符号做成 **一等用户值**，并公开 R4RS 过程：

| 过程 | 语义 |
|------|------|
| `(symbol? x)` | 低 3 位等于 `SYMBOL_TAG=0b101` |
| `(string->symbol str)` | intern：相同内容（字节级）永远返回 **同一** 指针 |
| `(symbol->string sym)` | 取出布局里的 tagged string |

`eq?` 两个由相同字符串 intern 得到的符号 → `#t`。`eq?` 与 `eqv?` 对符号均为指针相等（L09 立即数规则的堆推广：同一 intern 槽）。

布局（ARCHITECTURE 已锁定，本层不得改）：

```
symbol heap cell (8 bytes):  [ tagged-string ]
pointer tag: SYMBOL_TAG = 0b101
```

intern 表在 **C runtime**（哈希或线性）。L41/L43 若已建表，本层 **复用**，只补 Scheme 入口与缺测例；禁止第二张表。

本层范围之外：未 intern 符号（R4RS 无 `string->uninterned-symbol`）；`gensym`；竖线转义符号；intern 表参加「用户可清空」；大小写折叠。GC 下 intern 表作为根：本层堆仍 bump、不回收，表里的指针不会变。L51+ 必须把 intern 表列入根——本层注释提一句，实现留 L52。

## 原理

### 为何符号要 intern

`(eq? 'foo 'foo)` 必须真，否则 `assq`/`case`/全局 alist 全碎。reader 每次看见 `foo`、`quote` 的 `foo`、`string->symbol` 的 `"foo"` 都走 `rt_intern`。

字符串 **内容** 相等则同一符号；不同 string 对象、相同字节，仍同一符号：

```scheme
(eq? (string->symbol "ab")
     (string->symbol (string-append "a" "b")))
```

→ `#t`（若尚无 `string-append`，用 `string-set!` 拼一个新 string）。

`symbol->string` 返回的字符串与 intern 槽共享还是拷贝：

- R4RS：返回的字符串 **不可变** 语义上不应被 `string-set!` 破坏 intern 表。本教程字符串是可变的（L17）。
- 锁定：**`symbol->string` 返回拷贝**（新 heap string，相同字节）。用户 `string-set!` 不得改表里的键。测例覆盖。
- intern 表内的 string 视为 intern 私有，用户拿不到同一指针（`eq?` 与 `symbol->string` 两次结果也可以不 `eq?`，但 `string=?` 真）。

若你返回共享指针，测例「`string-set!` 后 intern 错乱」会红——那就改成拷贝。不要改测例来迁就共享。

### intern 表

线性：

```c
typedef struct { ptr sym; } intern_entry;
static intern_entry intern_tab[1024];
static int intern_n;
```

或开链哈希，key 用 string 字节。比较：长度 fixnum 相等再 `memcmp` 去标签后的字节。不要用 C `strcmp` 当中间有 `0` 字节时（R4RS 字符串可含 nul；测例可不含，但仍应用长度）。

满表 → `rt_error("intern full")` 或realloc（realloc 的块须仍 8 对齐且将来 GC 可见——线性固定容量 4096 本层够用）。

插入：`rt_alloc` 出 string 副本（从用户 string 拷贝字节）+ 8 字节 symbol 格。表里只存 tagged symbol ptr；string 从 symbol 槽取。

### prim 与 eta

```
(prim symbol? Ir)
(prim string->symbol Ir)
(prim symbol->string Ir)
```

`string->symbol` 非 string → 运行时错误。`symbol->string` 非 symbol → 运行时错误。`symbol?` 对一切值有定义。

需要当值传递时由用户 `lambda` 包一层（同 L42 prim 约定）。

前端也可把 `'foo` 继续降成 `(prim string->symbol <string-ir>)`，与 L41 `%intern` **合并成一个 C 函数**。删除重复的 `%intern` 入口，或让 `%intern` 成为 `string->symbol` 的别名。锁定：C 只有 `rt_string_to_symbol(ptr str)`。

### `eq?`

已有实现是指针/位型比较，**不要**为符号改成比字符串。intern 保证指针相同。未 intern 的假符号（每次 `quote` 新分配）会让 `eq?` 假——那是 L41 的 bug，本层回归抓住。

### 打印

L44 已按 string 槽 display 名字。本层无新格式。`write` 不自动加 `'`。

### 与全局环境

L45 的 alist key 必须是 intern 符号。`%global-ref` 用 `eq?` 比符号。`string->symbol` 造出的符号若与源里 `'foo` 同一 intern，可以动态拼出全局名字——本层不要求「按字符串取全局」API，但测例可以：

```scheme
(define foo 1)
((lambda ()
   ; 无 eval，无法用字符串当标识符
   foo))
```

不做 `eval`。拼名字只测 `eq?` 与 `assq`。

## 与上一层的差异

- 符号从「reader/quote 内部机制」变成带谓词与转换的数据类型。
- 明确 `symbol->string` 拷贝语义。
- intern 容量与 C API 写死为公开合同，不只是 stub。
- 无新标签；若 L41 未做 `SYMBOL_TAG`，本层必须补上且旧测例 `'foo` 仍绿。

## 代码骨架

### C

```c
ptr rt_string_to_symbol(ptr str) {
    if ((str & 7) != STRING_TAG) rt_error("string->symbol");
    /* lookup by bytes */
    int i;
    for (i = 0; i < intern_n; i++) {
        ptr s = symbol_string(intern_tab[i].sym);
        if (bytes_eq(s, str)) return intern_tab[i].sym;
    }
    if (intern_n >= INTERN_CAP) rt_error("intern full");
    ptr copy = rt_string_copy(str);
    ptr raw = rt_alloc(8);
    ((ptr *)raw)[0] = copy;
    ptr sym = (ptr)raw | SYMBOL_TAG;
    intern_tab[intern_n++].sym = sym;
    return sym;
}

ptr rt_symbol_to_string(ptr sym) {
    if ((sym & 7) != SYMBOL_TAG) rt_error("symbol->string");
    return rt_string_copy(((ptr *)(sym - SYMBOL_TAG))[0]);
}

ptr rt_symbolp(ptr x) {
    return ((x & 7) == SYMBOL_TAG) ? BOOL_T : BOOL_F;
}
```

`rt_string_copy`：`emit-alloc` 同类的 bump 分配，拷贝 len+bytes。从 C 调时同步 `scheme_hp`。

reader 的 `rt_intern_bytes(buf,n)`：先做成堆 string 再 `rt_string_to_symbol`，或查找路径共用 `bytes_eq`。不要复制两套 memcmp。

### 后端

```scheme
((symbol?) (emit-tag-pred SYMBOL_TAG))
((string->symbol)
 (sync-hp)
 (emit-c-call "rt_string_to_symbol" 1)
 (reload-hp))
((symbol->string)
 (sync-hp)
 (emit-c-call "rt_symbol_to_string" 1)
 (reload-hp))
```

`symbol?` 纯位运算，不必调 C（与 `pair?` 相同模式）。

### Scheme 库（可选 eta）

不必把三者写成 prelude 闭包。操作符位置走 prim。

## 测例清单

上一层全部测例仍须通过。

1. `(symbol? 'foo)` → `#t`
2. `(symbol? "foo")` → `#f`
3. `(symbol? 1)` → `#f`
4. `(symbol? #t)` → `#f`
5. `(eq? 'foo 'foo)` → `#t`
6. `(eq? 'foo 'bar)` → `#f`
7. `(eq? (string->symbol "foo") 'foo)` → `#t`
8. 新 string 对象：

    ```scheme
    (let ((s (make-string 3 #\a)))
      (begin
        (string-set! s 0 #\f)
        (string-set! s 1 #\o)
        (string-set! s 2 #\o)
        (eq? (string->symbol s) 'foo)))
    ```

    → `#t`
9. `(symbol? (string->symbol "z"))` → `#t`
10. `symbol->string` 内容：`(string-ref (symbol->string 'a) 0)` → `#\a`
11. 拷贝：修改返回的 string 不影响 intern：

    ```scheme
    (let ((s (symbol->string 'foo)))
      (begin
        (string-set! s 0 #\x)
        (eq? (string->symbol "foo") 'foo)))
    ```

    → `#t`
12. 两次 `symbol->string` 不必 `eq?`，但各自改不影响：

    ```scheme
    (eq? (symbol->string 'foo) (symbol->string 'foo))
    ```

    → `#f`（因拷贝；若你错误共享则 `#t`，本测例锁定 `#f`）
13. `assq` 用 intern 符号：`(assq 'b '((a . 1) (b . 2)))` → `(b . 2)`
14. `case` 符号（L40 曾拒绝，L41+ 合法）：`(case 'b ((a) 1) ((b) 2) (else 3))` → `2`
15. reader intern 与 `string->symbol`：程序 `(eq? (read) (string->symbol "ok"))`，stdin `ok` → `#t`
16. `(string->symbol 1)`：运行时错误。
17. `(symbol->string "no")`：运行时错误。
18. `(symbol?)` / `(string->symbol)` arity：编译期错误。
19. 空名：`(string->symbol "")` 合法，`(symbol? (string->symbol ""))` → `#t`；打印为空名字（`write` 输出空串可见性差）。本测例只断言 `symbol?`。
20. 不同长度：`(eq? (string->symbol "f") (string->symbol "fo"))` → `#f`

## 验收标准

- 测例 1–15、19–20 退出码 0；16–17 运行时错；18 编译期错。
- 全进程 intern 表唯一：reader、`quote`、`string->symbol` 三路 `eq?`。
- `symbol->string` 后 `string-set!` 不破坏表（测例 11）。
- `symbol?` 不调 C、不对堆解引用。
- 标签仍是 3-bit `101`，不要改成立即数符号（无法 intern 共享堆外立即数）。

## 常见坑

- **两张 intern 表**：编译期宿主 intern 与 runtime intern。`quote` 若在编译期把宿主符号的地址塞进 `imm`，运行时是野指针。必须运行时 intern 或静态数据 + 启动时 intern。
- **`symbol->string` 共享**：测例 11–12。
- **`eq?` 改成比字符串**：破坏 `eq?` 对 pair 的指针语义，且更慢。intern 才是对的。
- **比较 string 用 C 字符串规则**：长度前缀，不要遇 `0` 停。
- **`string->symbol` 不拷贝就入表**：用户随后 `string-set!` 原串，表键被改，查找失败或撞车。入表前拷贝；用户侧 `symbol->string` 再拷一次。
- **GC 以后忘记 intern 根**：本层无 GC，但在 `runtime.c` 写明 `intern_tab` 是根。不要用 `malloc` 存 symbol 对象本体。

## 下一层预告

L47 用宿主上的 **非卫生** `define-macro` 当垫脚石：能把 `cond` 写成宏，也会演示绑定捕获——这正是后面卫生宏要修的问题。
