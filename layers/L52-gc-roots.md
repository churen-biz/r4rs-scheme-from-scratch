# L52 — GC 根：赋值、栈、continuation

## 目标

L51 已经能从寄存器、Scheme 栈区间、intern/全局表标记并压缩。本层补上 **赋值与控制** 留下的根，使 GC 与 `set!`、盒子、`call/cc`、`dynamic-wind` 同时正确：

- **盒子**：`BOX_TAG` 对象一旦可达，跟其槽；栈/闭包里的 box 指针本身必须被扫到。盒子不是额外根类型，是「跟着堆走」；本层用测例证明 `set!` 捕获变量经 GC 仍可变。
- **continuation**：L37 的栈拷贝里是 **带标签字**，必须逐字 `mark_value` / `relocate`。压缩后 continuation 对象自己也移动。
- **`dynamic-wind`**：wind 栈（before/after thunk）是全局根；记录里的闭包经 GC 仍可跑。
- **`set!` 的栈槽**：可变槽在 Scheme 栈上，L51 的栈扫描已覆盖；本层写测例钉死，并处理「槽里是 box 指针」的 L26 约定。

提供强制 GC：`(%gc)`（L51）以及小堆。测例模式固定为：留下活对象 → 分配垃圾 → `%gc` 或挤爆 bump → 再使用活对象。

本层范围之外：弱根、guardian、精确栈图（仍用 `is_heap_ptr` 过滤）、不恢复 HP 以外再恢复「逃逸 continuation 的堆快照」（L51 已禁）。

## 原理

### 盒子与 `set!`

合同 L23/L26：未被 lambda 捕获的 `set!` 可直接 `str` 到栈槽；被捕获且赋值的变量是 **box**。两种根路径：

```
栈槽 ──含 tagged box──► [ val ] ──► 其它堆对象
闭包 fv ──含 tagged box──► 同上
```

GC 不必把「所有 box」登记到全局；**不可达的 box 应被回收**。测例：局部 box 只被死 list 引用，GC 后内存应能腾出（用小堆 + 再分配证明，不必数对象）。

全局 `define` 的可变顶层变量：若你用 box 存在 C 数组 `globals[]`，该数组是根。若顶层可变就是 intern 旁的 cell，同样登记。

### Continuation 布局（本层锁定）

L37 允许把 continuation 做成闭包。为让 GC 看见栈拷贝，**禁止**只 `memcpy` 一段裸字节却不把这段当作带标签字数组。锁定布局（`K_CONT = 7`，指针标签仍用 `CLOSURE_TAG`，靠 kind 图区分；或 kind 为 `K_CLOSURE` 且 code 指向 `cont_invoke`——两种选一，**推荐独立 `K_CONT`**）：

```
cont raw:
  [ code: cont_invoke ]          ; 裸代码指针，不 relocate 到堆
  [ nwords: fixnum ]             ; 下面 Scheme 槽个数
  [ saved_x0 … saved_x7 ]
  [ saved_x21 SELF ]
  [ saved_x22 MV ]
  [ saved_fp : 栈地址，非堆 ]
  [ saved_sp : 栈地址，非堆 ]
  [ stack_len: fixnum ]          ; 栈拷贝字数 N
  [ w0 w1 … w(N-1) ]             ; 每字按 tagged 扫描
```

大小：`8 * (1 + 1 + 8 + 2 + 2 + 1 + N)` 按你实际字段数写进 `object_size`。`saved_fp`/`saved_sp` **不是**堆指针，`is_heap_ptr` 为假则 `mark_value` 立即返回——即使偶然位型像指针，范围检查 `raw < HP && raw >= heap_base` 会挡住绝大多数栈地址（Darwin 栈在高地址，堆在 `aligned_alloc` 区）。仍可能假阳性：若栈地址碰巧落在堆区间，会钉住或错误 `relocate`。缓解：字段打 **fixnum 化的偏移**（`sp - stack_base` 编成 fixnum）而不是裸地址。锁定：**SP/FP 存「相对 `stack_base` 的字节差」打成 fixnum**，invoke 时加回。这样 GC 把它们当 fixnum，永不 follow。

invoke continuation：

1. 校验 `K_CONT`。
2. 恢复寄存器窗口（已经是 relocate 后的 tagged 值）。
3. `memcpy` 栈拷贝回到 `stack_base + offset`（或绝对 SP）。
4. **不改 HP**。
5. 跳到保存的 LR/返回点（LR 若存在栈拷贝里，同样是裸代码地址，扫描时 `is_heap_ptr` 为假）。

栈拷贝中的 LR、保存的 `x19`（HP）等：HP 不得从 continuation 恢复（用当前 HP）。拷贝里若含旧 HP 位型，invoke 后忽略，以 C 全局 HP 为准。实现：保存窗口时 **不要把 x19/x20 放进扫描区**；或放了但 invoke 时丢弃。

### 多值与 continuation

`x22`（MV）在窗口里。若多值块是堆上 list/vector，它必须出现在 `saved_x*` 或栈拷贝中以便 mark。L35 合同：多值块是堆对象则跟着走。

### `dynamic-wind` 记录

L39 wind 栈：每个记录至少 `(before after)` 两个闭包，加上可选 `depth`。存在 runtime 全局：

```c
ptr wind_stack; /* list of pairs/vectors，Scheme 值 */
```

`mark_roots` 增加 `mark_value(wind_stack)`；compact 后 `wind_stack = relocate(wind_stack)`。进出 wind 时对栈的 `set-car!` 与堆上 pair 一致，GC 后指针已转发，无需手改 Scheme 侧。

`call/cc` 捕获瞬间应把当时 `wind_stack` 存在 continuation 的一个 Scheme 槽里（L39 已要求 invoke 时跑 before/after）。该槽本层被扫描，thunk 不会变成野指针。

### 根清单（本层完整）

```
1. root_regs: x0–x7, x21, x22
2. Scheme 栈 [scheme_sp, stack_base) 每字
3. intern 表
4. 顶层 globals / 顶层 boxes
5. wind_stack
6. 从以上出发跟到的 heap，含 K_CONT 的寄存器窗口与栈拷贝字
7. 若 values 溢出块有单独全局，列入
```

`mark` 对 `K_CONT`：对每个 Scheme 槽 `mark_value`；跳过 code 字。相对 SP 的 fixnum 字段跳过（fixnum 本来就会在 `mark_value` 开头 return）。

### `%gc` 与活 continuation 测例结构

```scheme
(define k #f)
(call/cc (lambda (c) (set! k c) 0))
;; 若第一次落到这里：制造垃圾并 GC，再 (k 1)
;; 若第二次：返回 1
```

注意：第一次 `(set! k c)` 后若表达式值是 `0`，程序可能结束。要用 `begin` / 顶层顺序：

```scheme
(begin
  (define k #f)
  (let ((r (call/cc (lambda (c) (set! k c) 0))))
    (if r
        r
        (begin
          (waste-garbage)
          (%gc)
          (k 42)))))
```

第一次 `r` 为 `0`（假？**0 是真**）。R4RS 只有 `#f` 为假。要用标志：

```scheme
(begin
  (define k #f)
  (define once #t)
  (let ((r (call/cc (lambda (c) (set! k c) 0))))
    (if once
        (begin (set! once #f)
               (waste 5000)
               (%gc)
               (k 42))
        r)))
```

→ `42`

### L36 HP 复位：删除

搜索实现里 invoke 时 `HP = saved_hp` 并删掉。注释写：堆所有权在 GC。

## 与上一层的差异

- `objkind` 增加 `K_CONT`（若 L51 已把 cont 当闭包扫 fv，本层改为显式槽列表 + 相对 SP）。
- `mark_roots` 增加 `wind_stack` 与 globals boxes。
- continuation 保存格式可能相对 L37 有一次破坏性调整：相对 `stack_base` 的 fixnum 偏移。L37/L38 测例必须仍过。
- 不改标签数值；不新增用户语法（`%gc` 已有）。

## 代码骨架

### kind 与 size

```c
#define K_CONT 7

size_t object_size(ptr raw, uint8_t k) {
    switch (k) {
    case K_CONT: {
        ptr *w = (ptr *)raw;
        int64_t n = w[CONT_NWORDS] >> FX_SHIFT;
        return 8ull * (size_t)n; /* 或 header+N 按你的字段 */
    }
    /* … L51 的 case … */
    default: rt_error("size"); return 0;
    }
}
```

### 标记 K_CONT

```c
case K_CONT: {
    ptr *w = (ptr *)raw;
    int64_t n = w[1] >> FX_SHIFT;
    int64_t i;
    for (i = 2; i < n; i++)
        mark_value(w[i]);
    /* w[0] code：不跟 */
    break;
}
```

若 SP/FP 已是 fixnum，循环包含它们也安全。

### 保存 continuation（汇编/C 混合）

```c
ptr rt_capture_cont(ptr *stack_lo, ptr *stack_hi,
                    ptr *regwin, int nwin, ptr resume_code) {
    int64_t nstack = stack_hi - stack_lo;
    uint64_t bytes = /* 按布局 */;
    ptr raw = rt_alloc(bytes, K_CONT);
    /* 填 code、nwords、regwin、fixnum 偏移、复制 stack 字 */
    return raw | CLOSURE_TAG;
}
```

`regwin` 来自汇编 `stp` 的数组，已含 x0–x7、x21、x22。不要存 x19/x20。

### wind 根

```c
ptr wind_stack = EMPTY_LIST; /* 0x3F */

void mark_roots(void) {
    /* L51 regs + stack + intern + globals */
    mark_value(wind_stack);
    mark_drain();
}
```

compact 的 patch 阶段：`wind_stack = relocate(wind_stack)`。

### 活盒子测例用的内部原语（已有）

`(%box v)` `(%unbox b)` `(%set-box! b v)` —— L23。不要新发明第四个。

## 测例清单

上一层全部测例仍须通过。

1. **栈上可变槽经 GC**  
   ```scheme
   (let ((x 1))
     (set! x 2)
     (waste 3000)
     (%gc)
     x)
   ```  
   → `2`  
   `waste` 同 L51：分配丢弃的 pair。可在 prelude 定义，或测例内 `letrec`。

2. **捕获赋值（box）经 GC**  
   ```scheme
   (let ((x 1))
     (let ((f (lambda () (set! x (fxadd1 x)) x)))
       (waste 3000)
       (%gc)
       (f)))
   ```  
   → `2`

3. **死 box 可回收（小堆）**  
   `HEAP=65536`。构造大 list of boxes，丢掉，再 `%gc`，再分配与测例 8 同量的 pair，最后返回 `1`。  
   ```scheme
   (begin
     (letrec ((fill (lambda (n acc)
                      (if (fx= n 0) acc
                          (fill (fxsub1 n) (cons (%box n) acc))))))
       (fill 2000 '()))
     (%gc)
     (let ((p (cons 1 2)))
       (waste 1000)
       (car p)))
   ```  
   → `1`

4. **活 continuation 经 GC 再调用**  
   ```scheme
   (begin
     (define k #f)
     (define once #t)
     (let ((r (call/cc (lambda (c) (set! k c) 0))))
       (if once
           (begin (set! once #f)
                  (waste 4000)
                  (%gc)
                  (k 42))
           r)))
   ```  
   → `42`

5. **continuation 关闭的栈变量**  
   ```scheme
   (begin
     (define k #f)
     (define once #t)
     (let ((x 7))
       (let ((r (call/cc (lambda (c) (set! k c) 0))))
         (if once
             (begin (set! once #f) (waste 4000) (%gc) (k x))
             r))))
   ```  
   → `7`  
   （第二次路径返回的是 `(k x)` 传入的 `x`，仍是 7。）

6. **多次 invoke 同一 continuation 夹 GC**  
   ```scheme
   (begin
     (define k #f)
     (define n 0)
     (let ((r (call/cc (lambda (c) (set! k c) 0))))
       (set! n (fxadd1 n))
       (if (fx< n 3)
           (begin (waste 2000) (%gc) (k r))
           n)))
   ```  
   → `3`

7. **dynamic-wind 的 after 在 GC 后仍跑**  
   ```scheme
   (begin
     (define log '())
     (define k #f)
     (define once #t)
     (let ((r
            (dynamic-wind
              (lambda () (set! log (cons 'in log)))
              (lambda ()
                (call/cc (lambda (c) (set! k c) 0)))
              (lambda () (set! log (cons 'out log))))))
       (if once
           (begin (set! once #f) (waste 2000) (%gc) (k 1))
           (car log))))
   ```  
   期望：`in`（最后一次进入后 car；完整 log 因实现顺序可能是 `(in out in …)`）。锁定打印 **整个 log**：把返回值改成 `log`，期望前若干符号稳定。更稳：  
   ```scheme
   (begin
     (define flag 0)
     (dynamic-wind
       (lambda () #f)
       (lambda () (waste 2000) (%gc) 9)
       (lambda () (set! flag 1)))
     flag)
   ```  
   → `1`  
   本号用稳的这一版：`007-wind-after-gc.scm`。逃逸版作为测例 8。

8. **逃逸 continuation × wind × GC**  
   ```scheme
   (begin
     (define k #f)
     (define seen 0)
     (dynamic-wind
       (lambda () (set! seen (fxadd1 seen)))
       (lambda ()
         (call/cc (lambda (c) (set! k c)))
         (waste 1000)
         (%gc)
         'body)
       (lambda () #f))
     (if (fx= seen 1)
         (k 0)
         seen))
   ```  
   期望：`seen` 在第二次进入 before 后 ≥ 2。锁定 → `2`（一次初始进入 + 一次 invoke 再入）。若 L39 实现每次 dynamic-wind 结束已跑 after，invoke 会再跑 before，`seen` 为 2。

9. **闭包 + box + GC + 调用**  
   ```scheme
   (let ((x 0))
     (let ((inc (lambda () (set! x (fxadd1 x)) x))
           (get (lambda () x)))
       (waste 2000)
       (%gc)
       (inc)
       (%gc)
       (get)))
   ```  
   → `1`

10. **values 块经 GC**（若 L35 多值在堆上）  
    ```scheme
    (call-with-values
      (lambda () (waste 1000) (%gc) (values 1 2))
      (lambda (a b) (cons a b)))
    ```  
    → `(1 . 2)`  
    若单值路径不分配，再测：  
    ```scheme
    (let ((p (call-with-values
               (lambda () (values (cons 1 2) 3))
               (lambda (a b) a))))
      (waste 2000)
      (%gc)
      (car p))
    ```  
    → `1`

11. **小堆 + 活 cont**  
    `HEAP=131072`。测例 4 的程序把 `waste 4000` 加大到 `waste 3000` 仍返回 `42`。`011-tiny-heap-cont.scm`

12. **`%gc` 不弄丢 `#t/#f/()`**  
    `(begin (%gc) (cons (cons #t #f) '()))` → `((#t . #f))`

## 验收标准

- 测例 1–12（除 8 若与你的 L39 进出次数差 1：以 L39 文档的 wind 次数为准，本层 `.expected` 与之相同）退出码 0。
- invoke continuation **从不**写回旧 HP。
- `K_CONT` 的栈拷贝每个字经过 `mark_value`/`relocate`；SP/FP 以相对偏移 fixnum 存储。
- `wind_stack` 在 `mark_roots` 中出现。
- 回归 L36–L39、L51 全绿。

## 常见坑

- **栈拷贝当 `char[]` memcpy，GC 当 opaque**：压缩后栈上仍是旧堆地址，invoke 即野指针。测例 4–6 典型红法。
- **把 `x19` 存进 cont 再恢复**：HP 倒退，后续分配覆盖存活对象。
- **`call/cc` 捕获的 `k` 在 `set!` 到顶层前没有别的根**：确保 `set!` 的全局 cell 已被标记；否则 `k` 在第一次返回途中被回收。测例 4 的 `define k` 必须是根。
- **`once` 用 fixnum `0` 当假**：`if` 不会走「第一次」枝，测例 4 直接返回 `0`。用 `#t/#f`。
- **wind thunk 只存在 C 的函数指针**：必须是 Scheme 闭包且在堆上。
- **相对偏移用 64 位裸差当 fixnum 溢出**：栈差远小于 2^61 字节，左移 2 即可。
- **假阳性 relocate 栈地址**：所以不要存绝对 SP。

## 下一层预告

L53 在数值上跨出 fixnum：溢出时升级为堆上 bignum；不引入浮点。
