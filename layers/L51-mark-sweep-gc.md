# L51 — 停世界标记-压缩 GC

## 目标

堆不再只涨不收。当 `HP + need > HL`（或 `emit-alloc`/`rt_alloc` 失败）时，**停世界**回收。本层采用 **mark-compact（标记后挤压）**：先从根标记可达对象，再把存活对象挤到 `heap_base` 一侧，更新 `HP`，并用转发地址改写所有指针。它属于标记-清扫家族（先 mark 再处理死对象占用的空间），**不是**分代、**不是** concurrent、**不是**纯 Cheney 半空间复制（那样要双倍堆）。不实现「只链空穴、不移动」的自由表——那在无 header 的 pair 上更难。

标记位锁定为 **侧位图**：`uint8_t mark[(heap_words+7)/8]`，索引 `(ptr - heap_base) / 8` 的那一位。**禁止**占用 pair 的 car 高位或任何 payload 位当 mark——fixnum 与指针都可能出现在 car 里。

本层根集：寄存器 `x0`–`x7`、`x21`（SELF）、`x22`（MV）、栈上从 `SP` 到 `stack_base` 的每个字、以及 runtime 全局表（L46 intern、顶层 box/全局列表）。`x19`/`x20` 是 HP/HL，交给 C 当游标，**不当 Scheme 根扫描**。continuation 对象及其栈拷贝的扫描与转发 **L52** 才强制；本层若 L37 的 continuation 仍存活，可先在「范围之外」声明：含 `call/cc` 的旧测例在本层仍须过——因此至少要把 continuation 当闭包跟着走；细扫栈拷贝里的指针留 L52 写死。推荐本层就把栈拷贝做成 **vector of tagged words**，L52 只补测例。

本层范围之外：分代、增量、写屏障、 concurrent、弱引用、精确到「栈槽类型图」以外的派生指针、自由表非移动回收。

## 原理

### 触发

ARCHITECTURE：`HP`=`x19`，`HL`=`x20`。分配 `n = align8(need)` 字节前：

```
if (HP + n > HL) gc_collect(n);
if (HP + n > HL) rt_error("out of memory");
raw = HP; HP += n;
```

`n` 至少 8。L12 的 `(%bump n)` 同样走这条路径，否则测试原语会绕过 GC。

从本层起锁定分配入口为 C：

```c
ptr rt_alloc(uint64_t nbytes, uint8_t kind);
```

汇编 `emit-alloc` 改为：保存需要保留的 Scheme 寄存器后 `bl _rt_alloc`（Darwin 符号 `_rt_alloc`）。这样可以在 C 里记 **对象起始种类图**、检查 HL、触发 GC。种类图解决「对象头不加 type word、类型只在指针标签里」与「清扫必须从 `heap_base` 走到 `HP`」之间的矛盾——偏离 ARCHITECTURE「GC 只按标签走」的部分仅在于：**线性扫堆用种类图；从根跟随仍按指针标签**。何时回到合同：换芯片不改种类编号；若以后加 header word，可删种类图，但本教程不删。

### 种类图与对象大小

与堆等长的并行数组（每 8 字节对象对齐槽一个字节，64MiB 堆约 8MiB）：

```c
enum {
  K_EMPTY = 0,
  K_PAIR = 1,
  K_VECTOR = 2,
  K_STRING = 3,
  K_BOX = 4,
  K_SYMBOL = 5,
  K_CLOSURE = 6
  /* L52: K_CONT = 7; L53: K_BIGNUM = 8 */
};
uint8_t *objkind; /* index = (raw - heap_base) / 8 ，仅对象起始非 0 */
```

`rt_alloc` 在 bump 后写 `objkind[i] = kind`。大小：

| kind | 字节 |
|------|------|
| pair | 16 |
| box | 8 |
| symbol | 8 |
| vector | `8 * (1 + untagged_fixnum(word0))` |
| string | `8 + align8(untagged_fixnum(word0))` |
| closure | `8 * (2 + untagged_fixnum(word1))` ；word0 是 **裸 code 指针**，不是 Scheme 值 |

线性扫描：

```
scan = heap_base
while (scan < HP) {
    k = objkind[idx(scan)];
    if (k == K_EMPTY) rt_error("heap walk desync");
    sz = object_size(scan, k);
    /* 处理该对象 */
    scan += sz;
}
```

`K_EMPTY` 出现在对象起始即实现 bug（碎片只能出现在 compact 之后被挤掉的区域，而扫描在 compact 前/中必须只看见分配时记下的起始）。

### 侧位图

```c
uint8_t *markbits; /* 每位对应一个 heap word */
static inline int idx_of(ptr raw) {
    return (int)(((uint8_t *)untag_any(raw) - (uint8_t *)heap_base) / 8);
}
void mark_bit(ptr raw) { int i = idx_of(raw); markbits[i/8] |= (uint8_t)(1u << (i%8)); }
int  is_marked(ptr raw) { int i = idx_of(raw); return (markbits[i/8] >> (i%8)) & 1; }
```

`idx_of` 用**去标签后的裸指针**。对非堆指针（立即数、fixnum、C 代码地址）禁止调 `mark_bit`。

判断「是不是堆指针」：

```c
int is_heap_ptr(ptr x) {
    if ((x & 7) == 0) return 0;          /* fixnum 或未标签 */
    if ((x & 7) == 7) return 0;          /* immediate */
    ptr raw = x & ~7LL;
    return raw >= heap_base && raw < HP;
}
```

code 指针在闭包第一字：裸的，走 `is_heap_ptr` 为假（通常在 `.text`），不要当对象跟。

### 标记

```
clear markbits
for each root r:
    mark_value(r)

mark_value(x):
    if not is_heap_ptr(x): return
    raw = untag(x)
    if is_marked(raw): return
    mark_bit(raw)
    switch tag(x) / objkind:
      pair:     mark_value(car); mark_value(cdr)
      box:      mark_value(*raw)
      symbol:   mark_value(*raw)          /* tagged string */
      vector:   for each elt: mark_value
      string:   无 Scheme 子指针
      closure:  跳过 word0 (code)；mark nfree 个 fv
```

递归标记在深 cons 链上会爆 C 栈。锁定：**显式栈或把 mark 做成 `grey` 队列**（数组即可）。不要 `mark_value` 纯递归作为唯一实现。

### 压缩与转发

标记后 **不**保留空洞。Lisp-2：

1. **计算转发**：`dest = heap_base`。从低到高走每个对象；若 marked，`forward[idx] = dest; dest += sz`；否则不写。`forward` 是 `ptr *` 数组，长度 `heap_words`，仅对象起始有意义。可用 `malloc` 在 GC 期间分配，结束后 `free`。不要用第一字低位偷 tag 当转发：car 里的 fixnum 无法与裸地址区分。
2. **改写指针**：对每个根、以及每个 **存活**对象的每个 Scheme 槽：`x = slot; if is_heap_ptr(x) slot = retag(forward[idx(untag(x))], tag(x))`。闭包的 code 字不改写（不是堆对象）。string 字节不改写。
3. **搬移**：从低到高，对每个存活对象 `memmove(forward[idx], src, sz)`，并在 **新地址** 写 `objkind`；旧 `objkind` 清掉。因 `dest <= src`，从低到高搬不会覆盖尚未搬的源。
4. `HP = dest`。清 markbits。`forward` 释放。

`retag(raw, tag) = raw | tag`。pair 的 tag 是 `0b001` 等，与 ARCHITECTURE §2 一致。

### 根：本层清单

调用 `rt_alloc` / `gc_collect` 之前，汇编必须把 Scheme 值放到 C 能看见的地方：

```c
ptr root_regs[11]; /* x0..x7, x21, x22, 可选垫齐 */
ptr stack_base;    /* scheme_entry 序言里记下的高地址端 */
```

约定：

- `scheme_entry` 在保存 callee-saved 之后：`stack_base = FP 或 SP 当时值`（高地址）。Scheme 帧向低地址增长。GC 扫描 `[SP, stack_base)` 每 8 字节一个候选。栈上有 LR、保存的 x19 等非 Scheme 字：**保守**地用 `is_heap_ptr` 过滤；假阳性会钉住死对象，本层允许；假阴性（把堆指针拆成两半）不允许——本教程从不把 Scheme 指针拆字。
- `x0`–`x7`：参数与返回值。
- `x21` SELF，`x22` MV（L35，0 表示单值约定；非 0 时其余值还可能在寄存器/堆块，堆块若是 vector/list 会从根跟着走；把 values 块指针放进 `root_regs` 或保证它在 `x0`/`x1`）。
- 全局：intern 表每个 symbol 指针；你维护的 `globals` 链表。
- **不要**扫描整个 C 栈当根（除上述 Scheme 栈区间）。`rt_print` 的局部变量不是根。

aarch64 调用 `bl _rt_alloc` 遵守 C ABI：`x0`=`nbytes` 的低 64 位，`x1`=`kind`。**caller-saved `x0`–`x15` 会被 C 弄脏**，所以 Scheme 值必须先 `str` 到帧上。`x19`–`x22` 是 callee-saved，C 会保存，但 HP 在 GC 后要变：C 改全局 `scheme_hp` 或返回新 HP，汇编 `mov x19, x0`。锁定：

```
rt_alloc 返回裸指针在 x0；全局 scheme_hp 已更新；汇编 mov x19, scheme_hp 或 rt_alloc 不经过返回而写一个 getter。
更干净：rt_alloc 返回 raw，并在 C 写 scheme_hp；序言里 HP 本就来自 C 参数，本层起 HP 以全局为准，scheme_entry 跋里不必把 HP 交回 C（堆是 runtime 的）。
```

推荐全局：

```c
ptr heap_base, HP, HL;
ptr stack_base;
```

汇编每次 `rt_alloc` 前 `str x19, [scheme_hp]` 或让 bump 只发生在 C 内：汇编 **每次分配都 bl**，HP 只活在 C 全局，`x19` 每次从全局加载。两种合格，注释写死。为少改旧 `emit-alloc` 序列：仍用 `x19` bump，进入 GC 时 `HP_global = x19`，离开时 `x19 = HP_global`。

### 与 L36 HP 快照的冲突

L36 逃逸 continuation 曾把 HP 复原从而扔掉逃逸后分配的对象。从本层起：**禁止 invoke continuation 时把 HP 拨回去**。堆只由 GC 收缩。L36/L37 测例若依赖「continuation 扔掉堆」则应已在那些层写明接受；本层回归若因此红，改 continuation 实现以符合本句，而不是关 GC。细节与栈拷贝扫描见 L52。

### `%gc` 原语

用户/测例可见：

```
(%gc) → void
```

IR：`(prim %gc)`。后端 `emit-c-call gc_collect 0`（`need=0` 也做一次完整 mark-compact）。另可保留内部 `gc_collect(need)`。

## 与上一层的差异

- 分配可失败触发 GC；`HL` 第一次真正参与控制。
- runtime 增加 `objkind`、`markbits`、`gc_collect`、`rt_alloc`。
- 闭包/pair/vector/… 在 GC 后地址改变：任何「把裸堆地址存进 C 表」的结构（intern）必须当根并转发。
- 不改标签数值、不改 IR 形状（只加 prim `%gc`）。

## 代码骨架

### C：分配与 GC 入口

```c
ptr rt_alloc(uint64_t nbytes, uint8_t kind) {
    nbytes = (nbytes + 7) & ~7ULL;
    if ((uint8_t *)HP + nbytes > (uint8_t *)HL)
        gc_collect(nbytes);
    if ((uint8_t *)HP + nbytes > (uint8_t *)HL)
        rt_error("out of memory");
    ptr raw = HP;
    HP = (ptr)((uint8_t *)HP + nbytes);
    objkind[idx_raw(raw)] = kind;
    return raw;
}

void gc_collect(uint64_t need) {
    memset(markbits, 0, markbits_nbytes);
    mark_roots();           /* regs + stack + globals */
    compact_and_update();   /* forward[], patch, memmove, HP = dest */
    if ((uint8_t *)HP + need > (uint8_t *)HL)
        return;             /* 调用方再报 OOM */
}
```

### 标记队列

```c
static ptr *grey;
static int grey_n, grey_cap;

void mark_value(ptr x) {
    if (!is_heap_ptr(x)) return;
    ptr raw = x & ~7LL;
    if (is_marked(raw)) return;
    mark_bit(raw);
    grey_push(raw);
}

void mark_drain(void) {
    while (grey_n) {
        ptr raw = grey_pop();
        switch (objkind[idx_raw(raw)]) {
        case K_PAIR:
            mark_value(((ptr *)raw)[0]);
            mark_value(((ptr *)raw)[1]);
            break;
        case K_BOX:
        case K_SYMBOL:
            mark_value(((ptr *)raw)[0]);
            break;
        case K_VECTOR: {
            int64_t n = ((ptr *)raw)[0] >> FX_SHIFT;
            for (int64_t i = 0; i < n; i++)
                mark_value(((ptr *)raw)[1 + i]);
            break;
        }
        case K_STRING:
            break;
        case K_CLOSURE: {
            int64_t n = ((ptr *)raw)[1] >> FX_SHIFT;
            for (int64_t i = 0; i < n; i++)
                mark_value(((ptr *)raw)[2 + i]);
            break;
        }
        default:
            rt_error("gc: bad kind");
        }
    }
}
```

### 转发补丁

```c
ptr relocate(ptr x) {
    if (!is_heap_ptr(x)) return x;
    ptr raw = x & ~7LL;
    ptr dest = forward[idx_raw(raw)];
    if (!dest) rt_error("gc: unmarked pointer in live graph");
    return dest | (x & 7);
}
```

对每个存活对象的槽做 `slot = relocate(slot)`，**先于** `memmove`（转发表指向新地址，旧对象仍在）。根数组同样 `root_regs[i] = relocate(root_regs[i])`。intern 表每格 `relocate`。

### 汇编：撞墙

```asm
; emit-alloc nbytes kind  伪代码
    mov  x0, #nbytes
    mov  x1, #kind
    bl   _rt_alloc          ; 返回 raw @ x0
    ; x19 若由 C 维护：
    adrp x9, _scheme_hp@PAGE
    ldr  x19, [x9, _scheme_hp@PAGEOFF]
```

`scheme_entry` 增加：保存 `x21`/`x22`；把 `sp`/`x29` 记入 `_stack_base`（只在入口记一次高水位，之后 Scheme 的 `SP` 每次 GC 从寄存器读当前值）。GC 从 C 读 `sp`：由汇编在 `bl` 前把 `sp` 存进全局 `_scheme_sp`。

```c
extern ptr scheme_sp, stack_base, root_regs[];
/* mark_roots: for (p = scheme_sp; p < stack_base; p++) mark_value(*p); */
```

### 前端

```scheme
((%gc)  (prim %gc))
```

`emit-prim`：`%gc` → 保存根、`mov x0, #0`、`bl _gc_collect`、恢复、`mov x0, #VOID`。

## 测例清单

上一层全部测例仍须通过。

1. **`%gc` 空堆**  
   `(%gc)` → `#<void>`

2. **活 pair 经 GC 仍可读**  
   ```scheme
   (let ((p (cons 1 2)))
     (%gc)
     (cons (car p) (cdr p)))
   ```  
   → `(1 . 2)`

3. **死对象不阻止再分配**  
   在小堆上（见测例 8）或循环 `cons` 垃圾再 `%gc`：  
   ```scheme
   (let ((p (cons 1 2)))
     (letrec ((waste (lambda (n)
                       (if (fx= n 0)
                           #t
                           (begin (cons n n) (waste (fxsub1 n)))))))
       (waste 10000)
       (%gc)
       (car p)))
   ```  
   → `1`  
   若无 GC，64MiB 也可能撑住 10000 对；本测例检查 **正确性** 而非 OOM。测例 8 才逼触发。

4. **活 vector / string / box**  
   ```scheme
   (let ((v (make-vector 2 0))
         (s (make-string 2 #\a))
         (b (%box 9)))
     (vector-set! v 0 7)
     (string-set! s 1 #\b)
     (%gc)
     (list (vector-ref v 0) (string-ref s 1) (%unbox b)))
   ```  
   → `(7 #\b 9)`（`list` 来自 L42；打印空格与字符格式跟 L44。）

5. **活闭包**  
   ```scheme
   (let ((f (lambda (x) (fxadd1 x))))
     (%gc)
     (f 41))
   ```  
   → `42`

6. **闭包自由变量**  
   ```scheme
   (let ((y 10))
     (let ((f (lambda (x) (fx+ x y))))
       (%gc)
       (f 5)))
   ```  
   → `15`

7. **符号 intern 经 GC 仍 eq?**  
   ```scheme
   (let ((a (string->symbol "gc-sym")))
     (%gc)
     (eq? a (string->symbol "gc-sym")))
   ```  
   → `#t`

8. **小堆上强制回收**  
   驱动或 runtime 提供 `SCHEME_HEAP_BYTES=65536`（或测试原语 `(%with-tiny-heap)`——不要新语言；锁定 **环境变量 `SCHEME_HEAP_BYTES`**，`main` 读它，缺省仍 64MiB）。本测例文件头注释 `HEAP=65536`。程序：  
   ```scheme
   (let ((p (cons 1 2)))
     (letrec ((waste (lambda (n)
                       (if (fx= n 0) p
                           (begin (cons 0 0) (waste (fxsub1 n)))))))
       (car (waste 2000))))
   ```  
   → `1`  
   无 GC 时约 2000×16 字节加帧会超过 64KiB。驱动对本号设小堆。

9. **OOM**  
   小堆 4096 字节，分配无法回收的长活列表（每个 cons 挂到根上）：期望 **运行时错误**，stderr 含 `out of memory`。`009-err-oom.scm`。驱动 `HEAP=4096`。

10. **GC 后 bump 再 cons**  
    `(%gc) (cons 3 4)` → `(3 . 4)`

11. **不把 fixnum 当指针跟**  
    `(let ((n 0)) (%gc) n)` → `0`  
    以及 `(let ((p (cons #f #t))) (%gc) p)` → `(#f . #t)`

## 验收标准

- 测例 1–8、10–11 退出码 0。测例 9 非 0。
- 侧位图存在；pair 的 car 在 GC 前后可以是任意 fixnum，不得因 mark 位破坏测例 11。
- compact 后 `HP - heap_base` 小于 mark 前（测例 3/8 可用 `(%hp-fixnum)` 在 `%gc` 前后相减，可选调试测例；不强制用户可见）。
- 无 concurrent 线程、无第二半空间对用户可见（内部临时 `forward[]` 不算堆）。
- L00–L50 回归仍绿；`call/cc` 测例若本层只把 continuation 当闭包搬，栈拷贝里的堆指针可能暂时陈旧——若回归红，提前做 L52 的扫描，或在本层「原理」注明已扫描 vector 化的栈拷贝。

## 常见坑

- **在 car 上偷高位 mark**：正 fixnum 没问题，负 fixnum 或指针标签会被毁掉。
- **递归 `mark_value`**：长 list 爆 C 栈，表现为随机 SIGSEGV，不像「GC bug」。
- **把闭包 code 字 `relocate`**：跳进垃圾。word0 是裸代码地址。
- **intern 表不转发**：测例 7 两个 symbol 不再 `eq?`，或变成野指针。
- **线性扫堆不看 kind、按标签走**：堆里存的是 payload，没有标签，会把 car 当下一个对象头。
- **从高到低 `memmove`**：`dest < src` 时从高搬会覆盖。锁定从低到高。
- **C 调用后不恢复 `x19`**：后续 `cons` 写到旧 HP，与 C 全局不一致。
- **扫描整个 64MiB 当根**：会把已回收位型「看起来像指针」的垃圾钉死。只扫栈区间与寄存器。
- **`is_heap_ptr` 用 `<= HL`**：空闲区 `[HP, HL)` 里不是对象，指针指向那里是 bug；用 `raw < HP`。

## 下一层预告

L52 把根集补全到赋值盒子、`dynamic-wind` 记录，以及 continuation 栈拷贝里的带标签字，并加「制造垃圾 → 强制 GC → 活 continuation 仍可调用」的测例。
