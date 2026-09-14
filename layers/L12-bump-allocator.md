# L12 — bump 分配器：HP / HL / `emit-alloc`

## 目标

第一次真正使用 C 传入的堆。`scheme_entry` 的序言必须保存 callee-saved 的 `x19`/`x20`，把堆基址写入 `HP`（`x19`），把上限写入 `HL`（`x20`）。后端实现 `emit-alloc`：按 8 字节对齐，把**旧** `HP` 放进 `x0`（裸指针，无标签），然后 `HP += 对齐后的字节数`。

本层**没有**用户可见的 pair / vector / string。可观测性完全靠两个测试原语：

- `(%bump n)`：`n` 是 fixnum，表示要推进的**字节数**（必须为正且已是 8 的倍数）。副作用 `HP += n`，返回值就是 `n` 本身。
- `(%hp-fixnum)`：返回 `(HP - heap_base)` 编码成的 fixnum，即「本进程从堆基址起已经 bump 了多少字节」。

因为 ASLR，堆基址每次运行都不同，测例不能断言绝对地址。`(%hp-fixnum)` 必须返回**相对偏移**，两个测例相减才稳定等于 `n`。

本层范围之外：`cons`、用户 pair、任何对象标签、GC、把裸指针当 Scheme 值打印。不要在本层实现 `pair?`。不要把 `%bump` 的返回值做成带 `PAIR_TAG` 的指针。

## 原理

Ghuloum 把堆放到「已经能算、能跳」之后，是因为分配一旦出错，后面所有 `cons` 的失败都会被误诊成标签问题。本层只证明三件事：

1. C 传进来的堆基址和长度，汇编侧按合同接住了。
2. bump 按 8 字节对齐前进，`HP` 低 3 位恒为 `000`。
3. 溢出或非法 `n` 走 `rt_error`，而不是静默写到堆外面。

### 为何 L00 就要传入堆，L12 才用

C 原型从 L00 起就是：

```c
ptr scheme_entry(ptr *heap, uint64_t heap_nbytes);
```

Darwin/arm64 进入 `scheme_entry` 时：`x0` = 堆基址，`x1` = 堆的**字节数**（不是「上限指针」）。L00–L11 可以不理这两个寄存器。本层起它们变成不变量：

```
HP  = x19 = heap          ; 下一空闲字节，8 对齐
HL  = x20 = heap + size   ; 第一个不可用字节
```

若 L00 把 `scheme_entry` 定义成零参数，本层就要改 C 原型、改全部旧测例的链接方式。所以原型早已定死，本层只填序言。

### 机器字、对齐、标签空位

合同（与 `ARCHITECTURE.md` §2 一致）：

| 项 | 值 |
|----|-----|
| 字宽 | 8 字节 |
| 分配对齐 | 8 字节，因此裸地址低 3 位为 `000` |
| `PAIR_TAG` | `0b001`（本层不 OR 上去） |
| `VECTOR_TAG` | `0b010` |
| `STRING_TAG` | `0b011` |
| `HP` | `x19`（callee-saved） |
| `HL` | `x20`（callee-saved） |
| 临时 | `x9`–`x15` |
| **禁止** | `x18`（Darwin 保留）；不要用 `x16`/`x17` 当长期临时 |

fixnum 只占低 2 位 `00`。8 对齐的指针低 3 位已是 0，所以「把 `HP` 原样 `mov` 进 `x0`」在位型上看起来**像**一个 fixnum，`rt_print` 会把它当 `地址/4` 打印。这不能当测例：地址随 ASLR 变，且「除以 4 的差值」等于 `n/4` 而不是 `n`。

因此 `%hp-fixnum` **禁止** `mov x0, x19` 完事。必须返回字节偏移的 fixnum：

```
tagged = (HP - heap_base) << FX_SHIFT
```

`HP` 与 `heap_base` 都 8 对齐，差值是 8 的倍数；左移 2 位后低 2 位仍为 0，打印出来就是「已经用掉的字节数」。

### `heap_base` 存在哪

`HP` 会前进，基址必须另存。不要用 `x21`（L26 的 `SELF`）或 `x22`（L35 的多值标志）。合同允许两种合格存放，本层锁定第一种：

1. **C 全局 `heap_base`**（推荐、本层锁定）：`main` 在调用 `scheme_entry` 之前赋值。`%hp-fixnum` 通过 `bl _rt_hp_fixnum` 计算偏移，汇编不必自己 `adrp` GOT。
2. 入口帧上的一个 8 字节槽：序言 `str x0, [x29, #off]`，`%hp-fixnum` 从该槽加载。这在「`x29` 一直指向 `scheme_entry` 帧」时可行；L18 起若你改 `x29` 含义，这个槽会悄悄读错。所以不要把它当长期方案。

```c
ptr heap_base;

ptr rt_hp_fixnum(ptr hp_raw) {
    int64_t bytes = (int64_t)((uintptr_t)hp_raw - (uintptr_t)heap_base);
    return (ptr)(bytes << 2); /* FX_SHIFT */
}
```

汇编侧：

```asm
    mov     x0, x19
    bl      _rt_hp_fixnum     ; 结果已是 fixnum，在 x0
```

`bl` 会写 `x30`。这没问题：**跋里从栈恢复 `x30`**，不要指望寄存器里的 `x30` 仍是回 C 的地址。`bl` 当下 `sp` 必须 16 字节对齐——L07 起每次为二元原语腾栈请 `sub sp, sp, #16`（一个 Scheme 字只占 8，但多出来的 8 字节是对齐垫）。

### 序言 / 跋：相对 L00 的硬变化

L00 最小序言只保存 `x29, x30`，栈减 16。本层必须同时保存 `x19, x20`，并保持 16 字节对齐。后端 README 的形状就是合同：

```asm
    .globl  _scheme_entry
    .p2align 2
_scheme_entry:
    stp     x29, x30, [sp, #-32]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    mov     x19, x0              ; HP = heap base
    add     x20, x19, x1         ; HL = base + nbytes
    ; … 编译体，结果在 x0 …
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret
```

要点：

- `#-32` 不是随便挑的：两对 callee-saved，32 是 16 的倍数。写成 `#-24` 会 SIGBUS 或损坏 ABI。
- `mov x19, x0` **必须在任何编译体之前**。编译体第一件事常常是 `emit-imm`，那会覆盖 `x0`。顺序反了，堆基址就丢了。
- `add x20, x19, x1` 假定 `x1` 仍是 C 传来的 size。不要先用 `x1` 当临时。
- 本层不必保存 `x21`。L26 再加。
- 旧测例（L00–L11）**仍然通过**：它们不读 `HP`，只是现在多了合法的寄存器保存。若你不保存 `x19`/`x20` 就写进去，C 的 `main` 在返回后可能损坏（callee-saved 被你偷了）。简单的 `main` 碰巧仍绿，这是假绿。

### `emit-alloc nbytes`（编译期常量尺寸）

这是后端接口，L13 的 `cons` 会调用 `emit-alloc 16`。`nbytes` 是宿主整数，不是 Scheme fixnum。

```
aligned = (nbytes + 7) & ~7
if HP + aligned > HL:  bl 溢出
x0 = HP                 ; 裸指针
HP = HP + aligned
```

比较用无符号：`HP == HL` 表示堆恰好用尽，**这一次**分配若使 `HP` 变成 `HL` 则成功；下一次任意正尺寸分配失败。实现时先算 `x9 = HP + aligned`，`cmp x9, x20`，`b.hi` 才报错，**通过后再改 `x19`**。不要先加再改回来。

aarch64 的 `add` 立即数是 12 位（可选左移 12）。`16` 没问题；更大的常量请先 `mov` 进 `x9`/`x10`。不要用 `w19`：堆地址是 64 位。

本层可以（也建议）把溢出检查做进 `emit-alloc`。合同写「可选」，但骨架按「做了」验收；溢出测例在清单里。

`emit-alloc` 返回的 `x0` 是裸指针。它低 3 位为 0，**看起来像 fixnum**。若你把它当程序结果返回，`rt_print` 会印出一个随 ASLR 变的整数——这就是合同禁止 `%bump` 返回裸地址的原因。

### 测试原语 `(%bump n)`

`n` 是 Scheme 表达式，求值后必须是 **fixnum，表示字节数**，不是字数。`( %bump 16 )` 把 `HP` 推进 16 字节。

求值顺序：

1. 求值 `n` → `x0`（已标签）。
2. 检查 `(x0 & 3) == 0`，否则 `rt_error`（关键字 `bump` 或 `type`）。
3. 算术右移 2 位得到无标签字节数 `nbytes`（用 `asr`，以便负数保持符号）。
4. `nbytes > 0` 且 `(nbytes & 7) == 0`，否则 `rt_error`（关键字 `bump`）。
5. `x9 = HP + nbytes`；若 `x9 > HL`，`rt_error`（关键字 `heap`）。
6. `HP = x9`。
7. 把**原来的标签 `n`** 放回 `x0` 返回。

第 7 步要求你在破坏 `x0` 之前把 tagged `n` 存进临时（`x10`）或栈。返回 `n` 而不是新 `HP`，这样 `(%bump 16)` 的打印是稳定的 `16`。

非法 `n` 的检查在 bump **之前**做：`(%bump 4)` 不得改变 `HP`。没有变量，本层不强制用第二个 `%hp-fixnum` 证明「失败未 bump」；靠「进程以非 0 退出」即可。

`%bump` **不是** `emit-alloc` 的用户语法：`emit-alloc` 吃编译期常量，`%bump` 吃运行时 fixnum。不要试图用 `emit-alloc` 实现 `%bump`（除非你先把 `n` 的立即数在前端常量折叠——那会让 `( %bump (fx+ 8 8) )` 失败）。一律走运行时路径。

### 测试原语 `(%hp-fixnum)` 与「两测例之差等于 n」

`(%hp-fixnum)` 零个操作数。实现：`mov x0, x19` 然后 `bl _rt_hp_fixnum`。

没有 `let`、没有用户 `begin`。每个测例是**独立进程**，堆从零开始：

| 程序 | 期望 |
|------|------|
| `(%hp-fixnum)` | `0` |
| `(and (%bump 16) (%hp-fixnum))` | `16` |

二者相减得 `16`，等于 `n`。这是 `_contract.md` 说的可观测性。

为何能用 `and`：L11 已把 `and` 展开成 `if`，并且 Scheme 里只有 `#f` 为假。`(%bump n)` 返回正 fixnum，不是 `#f`，所以 `(and (%bump n) (%hp-fixnum))` 会先 bump 再读偏移。`(and (%hp-fixnum) (%bump 24) (%hp-fixnum))` 同样合法：开头的 `0` 仍为真。

不要用 `or` 做顺序：`(%bump n)` 为真，后面的 `%hp-fixnum` 会被跳过。

本层**不**引入 `%begin`。那个内部顺序形式从 L15 才加入（为了在没有变量时观察 mutation）。L12 借用 `and` 足够。

### IR

```
(prim %bump      Ir)
(prim %hp-fixnum)
```

前端把 `(%bump e)` 降成 `(prim %bump (expr->ir e))`，把 `(%hp-fixnum)` 降成 `(prim %hp-fixnum)`。名字带 `%` 表示为编译器测试脚手架，不是 R4RS。未知 `%foo` 仍编译期错。

Arity：`%bump` 必须恰好 1 个操作数，`%hp-fixnum` 必须 0 个，否则编译期 `error`。

### 运行时辅助（C）

```c
void rt_error(const char *msg);          /* 已有：stderr + exit(1) */
ptr  rt_hp_fixnum(ptr hp_raw);           /* 本层新增 */
void rt_err_heap(void);                  /* 可选包装：rt_error("heap overflow") */
void rt_err_bump(void);                  /* 可选包装：rt_error("invalid bump") */
```

推荐用无参数包装函数，让汇编只 `bl _rt_err_heap`，不必在 `.s` 里放 `cstring` 再 `adrp`。两种都合格，须在实现注释写死你选了哪一种。`rt_error` 的 C 签名保持 ARCHITECTURE 原样。

`rt_print` 本层不必改：程序结果仍是 fixnum 或旧立即数。若你把裸 `HP` 漏出去，会印出巨大整数或 `#<unknown>`——把它当失败，不要放宽打印。

### 本层不做的选择（写死）

- 不在对象头加 type word。类型在指针标签里；本层还没有带标签的堆对象。
- 不回收。L51 之前分配只 bump。
- 不把 `%bump` 做成返回 tagged pair 的「假 cons」。
- 不在汇编里 `svc` / `brk` 做 OOM；走 `rt_error`。
- 堆大小仍由 C `main` 决定（64MiB）。测例不要假设能 bump 超过这个数。

## 与上一层的差异

L11 是 `and`/`or` 展开与短路，仍然没有堆。

| 项 | L11 | L12 |
|----|-----|-----|
| `scheme_entry` 序言 | 至少 `x29,x30` | 必须再保存 `x19,x20`，32 字节帧 |
| `x0`/`x1` 入口 | 可忽略 | `mov x19,x0`；`add x20,x19,x1` |
| 新 IR | 无 | `(prim %bump …)` `(prim %hp-fixnum)` |
| 第一次 `bl` C | 无（打印在 `main`） | 溢出 / 非法 bump / `%hp-fixnum` |
| 用户堆对象 | 无 | 仍无；只有 HP 副作用 |

旧测例全部仍须通过：它们不依赖 `HP` 的值，只要求序言不破坏 C ABI 与返回值。

## 代码骨架

### 可移植前端

```scheme
(define (expr->ir expr)
  (cond
    ((and (pair? expr) (eq? (car expr) '%bump) (length=? expr 2))
     `(prim %bump ,(expr->ir (cadr expr))))
    ((and (pair? expr) (eq? (car expr) '%hp-fixnum) (length=? expr 1))
     '(prim %hp-fixnum))
    ;; … L11 及更早的 and/or/if/prim/literal …
    (else (error "L12: bad expr" expr))))
```

把 `%bump` / `%hp-fixnum` 加进已知原语表。`length=?` 对 `%hp-fixnum` 而言 `expr` 只有符号本身，长度为 1。

### 可移植：`emit-alloc`

```scheme
(define (align8 n)
  (logand (+ n 7) -8))

(define (emit-alloc nbytes)
  (let ((n (align8 nbytes)))
    (string-append
      "\tmov x9, #" (number->string n) "\n"
      "\tadd x9, x19, x9\n"
      "\tcmp x9, x20\n"
      "\tb.hi _rt_err_heap\n"    ; 或 bl 到本地标签再 bl C
      "\tmov x0, x19\n"
      "\tmov x19, x9\n")))
```

`b.hi _rt_err_heap` 把溢出做成尾跳进永不返回的 C；若你用 `bl _rt_err_heap`，后面仍应有一条不会走到的指令或 `brk`，以免 fall-through。`_rt_err_heap` 要在 C 里定义为 `void rt_err_heap(void)`。

本层用户程序不必调用 `emit-alloc`（`%bump` 走运行时尺寸）。把它写出来是为了 L13 原样调用，本层可用一个内部自检：编译器在注释测试里 `emit-alloc 8` 一次，但**不要**把它的裸指针返回给 `rt_print`。

### aarch64-apple：`scheme_entry` 与 `%bump`

```scheme
(define (emit-program ir)
  (string-append
    "\t.globl _scheme_entry\n"
    "\t.p2align 2\n"
    "_scheme_entry:\n"
    "\tstp x29, x30, [sp, #-32]!\n"
    "\tmov x29, sp\n"
    "\tstp x19, x20, [sp, #16]\n"
    "\tmov x19, x0\n"
    "\tadd x20, x19, x1\n"
    (emit-ir ir)
    "\tldp x19, x20, [sp, #16]\n"
    "\tldp x29, x30, [sp], #32\n"
    "\tret\n"))

(define (emit-prim-%hp-fixnum)
  (string-append
    "\tmov x0, x19\n"
    "\tbl _rt_hp_fixnum\n"))

(define (emit-prim-%bump)
  ;; 操作数已在 x0
  (string-append
    "\tmov x10, x0\n"              ; 保存 tagged n，供返回
    "\tand x9, x0, #3\n"
    "\tcbnz x9, _rt_err_bump\n"
    "\tasr x9, x0, #2\n"           ; nbytes
    "\tcmp x9, #0\n"
    "\tb.le _rt_err_bump\n"
    "\ttst x9, #7\n"
    "\tb.ne _rt_err_bump\n"
    "\tadd x11, x19, x9\n"
    "\tcmp x11, x20\n"
    "\tb.hi _rt_err_heap\n"
    "\tmov x19, x11\n"
    "\tmov x0, x10\n"))            ; 返回原 n
```

`cbnz` / `b.le` / `b.ne` / `b.hi` 的目标若是 C 符号，在 Mach-O 上通常要 `bl` 而不是条件直接跳进外部。更稳：本地标签再 `bl`：

```asm
    cbnz    x9, .Lerr_bump
    ; ...
.Lerr_bump:
    bl      _rt_err_bump
```

`tst x9, #7` 检查低 3 位；非 0 即不是 8 的倍数。

**禁止使用 `x18`。** 上面用了 `x9`–`x11`、`x10` 保存 tagged `n`。

### aarch64-apple：runtime 增补

```c
/* runtime/aarch64-apple/scheme.h — 在已有内容上增加 */
extern ptr heap_base;
ptr  rt_hp_fixnum(ptr hp_raw);
void rt_err_heap(void);
void rt_err_bump(void);
```

```c
ptr heap_base;

ptr rt_hp_fixnum(ptr hp_raw) {
    int64_t bytes = (int64_t)((uintptr_t)hp_raw - (uintptr_t)heap_base);
    return (ptr)(bytes << 2);
}

void rt_err_heap(void) { rt_error("heap overflow"); }
void rt_err_bump(void) { rt_error("invalid bump"); }

int main(void) {
    size_t n = 64u * 1024u * 1024u;
    ptr *heap = aligned_alloc(8, n);
    if (!heap) rt_error("heap alloc failed");
    heap_base = (ptr)heap;
    ptr r = scheme_entry(heap, n);
    rt_print(r);
    return 0;
}
```

`aligned_alloc(8, n)` 的 `n` 必须是 8 的倍数：64MiB 满足。不要改成 `malloc` 再心算对齐。

## 测例清单

上一层全部测例仍须通过。

1. `(%hp-fixnum)` → `0`（新进程，尚未 bump）
2. `(%bump 8)` → `8`
3. `(%bump 16)` → `16`
4. `(and (%bump 16) (%hp-fixnum))` → `16`（与测例 1 之差等于 `n`）
5. `(and (%hp-fixnum) (%bump 24) (%hp-fixnum))` → `24`（`0` 为真，两端夹一次 bump）
6. `(and (%bump 8) (%bump 8) (%hp-fixnum))` → `16`（两次 bump 累加）
7. `(%bump (fx+ 8 8))` → `16`（`n` 不是字面量；HP 推进 16，可用 `(and (%bump (fx+ 8 8)) (%hp-fixnum))` → `16` 再钉一次）
8. `(fixnum? (%bump 8))` → `#t`
9. `(fx+ (%bump 8) 1)` → `9`（返回值参与算术，副作用仍发生）
10. `(%bump 0)`：运行时错误，stderr 含 `bump`，退出码非 0
11. `(%bump 4)`：运行时错误（非 8 倍数），stderr 含 `bump`
12. `(%bump -8)`：运行时错误（非正），stderr 含 `bump`
13. `(%bump #t)`：运行时错误（非 fixnum），stderr 含 `bump` 或 `type`
14. `(%bump)` 或 `(%bump 8 8)` 或 `(%hp-fixnum 0)`：编译期 arity 错误
15. `(%bump 67108872)`：运行时错误（64MiB 堆上 bump 64MiB+8），stderr 含 `heap`。`67108872` 是 8 的倍数，排除「先因对齐失败」。

测例 4 与 1 合在一起就是合同句「两个 `(%hp-fixnum)` 夹一次 `(%bump n)`，差等于 `n`」：差在两个独立进程的打印值上算，不是同一个表达式里用 `fx-` 减绝对地址。

## 验收标准

- 测例 1–9 标准输出仅为一个十进制整数或 `#t`，末尾一个换行。
- 测例 10–13、15 退出码非 0；不得打印一个「看起来合理」的 fixnum 后以 0 退出。
- 生成的 `_scheme_entry` 含 `stp x19, x20` 与对应 `ldp`，帧大小为 16 的倍数；含 `mov x19, x0` 与 `add x20, x19, x1`（或等价：先把 `x0`/`x1` 拷到 callee-saved 再算 `HL`）。
- `%bump` 把 **untagged** 的 `n` 加到 `HP`。用测例 4 侦测「把 tagged `16`（机器字 64）加到 `HP`」：那种实现会打印 `64`。
- `%hp-fixnum` 打印值在空程序上为 `0`，不随 ASLR 变化。
- 汇编不出现 `x18`。不出现把 `HP` 当程序结果交给 `rt_print` 的路径。
- L00–L11 回归全绿。

## 常见坑

- **忘了保存 `x19`/`x20`**：当前测例可能绿，`main` 返回后寄存器被毁，将来加局部变量的 C 运行时会随机炸。按 ABI 保存。
- **`mov x19, x0` 写在 `emit-imm` 之后**：`x0` 已是程序结果，`HP` 变成 `42<<2` 一类垃圾，第一次 bump 就 SIGSEGV。
- **`HL = x1` 而不是 `base+size`**：`x1` 是长度。把它当上限指针会让 `cmp HP, HL` 毫无意义。
- **`%hp-fixnum` 写成 `mov x0, x19`**：打印随 ASLR 变；两地址相减若当 fixnum 打印，差是 `n/4`。必须 `(HP-heap_base)<<2`。
- **`%bump` 把 tagged `n` 加到 `HP`**：`(%bump 16)` 实际推进 64 字节。测例 4 会得到 `64`。
- **`add w19, w19, w9`**：截断堆指针高 32 位。全程 64 位。
- **`sp` 在 `bl` 时只减了 8**：SIGBUS 或毁掉栈上的 `x29` 链。二元原语的临时槽按 16 字节分配。
- **溢出检查用 `b.lt`（有符号）**：堆地址是用户空间大正数，有符号比较会反。用无符号 `b.hi` / `b.ls`。
- **`(%bump 0)` 被当成成功**：零不是正数；推进 0 还会让「差等于 n」的测例变钝。
- **用 `x18` 或 `x16` 保存 tagged `n`**：Darwin 上表现为无规律损坏。
- **把本层做成假 `cons`**：返回带 `PAIR_TAG` 的未初始化 16 字节。打印会读垃圾，L13 的回归会缠在一起。

## 下一层预告

L13 第一次把 `emit-alloc 16` 用在用户原语 `cons` 上，并给裸指针 OR 上 `PAIR_TAG`；`rt_print` 要能递归打印 pair。
