# L37 — 完整 `call/cc`

## 目标

把 `call/cc` 升级为 R4RS 的一等延续：捕获时把 **`[SP, STACK_BASE)`** 的栈字节拷进堆对象，连同需要的寄存器一起保存。调用该延续则把栈拷回去、恢复寄存器，交付那一个实参。可以多次 invoke，可以在 `call/cc` **已经正常返回之后**再进入（「往上」回到已经结束的帧）。延续仍是**一元过程**。

本层范围之外：`dynamic-wind` 进出包装（L39）、多值延续、把逃逸-only 的 stale 检查留下来当错误（本层废止「正常返回后 invoke → 错误」；L36 测例 15、16 的期望在本层**改写**为成功语义，见测例清单）。

## 原理

### `STACK_BASE`（`x23`）

Scheme 栈向下增长。`scheme_entry` 在建立自己的帧**之后**，把此时的 `sp` 写入 callee-saved **`x23`**。这个值是「最老的 Scheme 帧的高地址」：之后每次 Scheme 调用只让 `sp` 更小，`x23` 不变。

```
高地址  x23 = STACK_BASE   （scheme_entry 序言末尾的 sp）
          … scheme_entry 保存的 x19–x23、x29、x30 …
          … 用户过程帧 …
低地址  sp = 当前 SP
```

拷贝长度 `len = STACK_BASE - SP`，必须是 16 的倍数（每帧对齐）。`len=0` 只可能在 `scheme_entry` 顶层立刻 `call/cc`；仍合法，拷贝空字节。

C 也可以把栈上限当第三参数传入；本层锁定更简单的做法：**不必改 `scheme_entry` 的 C 原型**，由汇编把序言后的 `sp` 抄进 `x23`。`x23` 加入 `scheme_entry` 的保存集。禁止用 `x18`。

### continuation 对象

仍用 `CLOSURE_TAG`，code = `_rt_full_cont`（本层替换 L36 的 `_rt_escape_cont`，或同一符号改实现）。不要新标签。

```
[ code ]
[ nfree = 固定头槽数的 fixnum ]
[ saved_SP ]
[ saved_FP ]
[ saved_LR ]
[ saved_x21 ]          ; 捕获时 SELF，invoke 时不强制恢复给调用方；见下
[ stack_len : fixnum 字节 ]   ; 未移位的字节数要能还原；存裸 u64 也可以，打印勿当 Scheme 值
[ copy_ptr  : 裸指针，指向紧随本对象之后的字节，或独立 bump 块 ]
[ 随后 len 字节的栈快照 ]
```

实现可把快照放在闭包后面同一 bump（先知道 `len` 再 `emit-alloc`），`copy_ptr` 则是 `raw + header`。`HP` **不要**存进对象用于回滚——本层锁定与 L38、合同一致：

> **完整 call/cc 只恢复栈与寄存器（SP、FP、LR、以及为实现正确返回所必须的 callee-saved 视图）。堆不回滚。`HP` 保持 invoke 当下的值。** 盒子上的 `set!`、`set-car!` 继续在。

L36 恢复 `HP`；本层**停止**这样做。写在「与上一层的差异」里，避免实现者原样复制桩。

捕获的寄存器窗口：至少 `SP`、`FP`、`LR`。不必保存 `x0–x15`（捕获点在 `call/cc` 内部，那些是死值）。`x19`/`x20`（HP/HL）不回滚 HP；HL 保持。`x22` 在 invoke 时置 `1`（一元交付）。`x23` 在 `scheme_entry` 生命周期内不变，invoke 不必改。

### 捕获算法

1. `len = x23 - sp`。
2. `emit-alloc` 对齐到 8 的 `header + len`。
3. `memcpy`：从 `sp` 拷 `len` 字节到快照区（汇编循环 `ldp`/`stp` 或 `bl _memcpy`；若用 C `memcpy`，注意 Darwin 符号 `_memcpy`，且它会弄脏 caller-saved）。
4. 填 header，打 `CLOSURE_TAG` 得 `k`。
5. `(receiver k)`。本层 **不再** 在正常返回时把 `k` 作废。`receiver` 返回值就是 `call/cc` 的值；`k` 仍可用。

### invoke 算法（`_rt_full_cont`）

1. `argc==1` 否则 `rt_error`。
2. `v = x0`。从 `x21` 读 saved_SP、saved_FP、saved_LR、len、copy_ptr。
3. `memcpy`：把快照写回 `saved_SP` 起 `len` 字节。此时当前 `sp` 可能比 `saved_SP` 更低或更高：
   - 更低：我们在更深的栈上 invoke，覆盖中间无关。
   - 更高（`call/cc` 已返回，那些帧已弹掉）：必须先把 `sp` **降到** `saved_SP`（或更低），否则 `memcpy` 写在当前栈上方的「未拥有」区域，虽然那正是我们弹掉的 Scheme 帧空间，通常仍属于进程栈，可以写。锁定：**先 `mov sp, saved_SP`，再把快照拷进 `[sp, STACK_BASE)`**，然后恢复 `FP`/`LR`。
4. `x0 = v`，`x22 = 1`。
5. `mov x29, saved_FP`；`mov x30, saved_LR`；`ret`。

效果：程序计数回到 `call/cc` 里 `(receiver k)` 那次调用即将返回的位置，但返回值是 `v` 而不是 `receiver` 的返回值。对 `(let ((k (call/cc (lambda (c) c)))) …)` 而言，第一次 `receiver` 返回 `c` 本身，`k` 绑定为延续；之后 `(k 42)` 让那份 `call/cc` 好像重新返回了 `42`。

多次 invoke：每次都从同一份快照恢复。快照本身在堆上不变（除非你在 invoke 时改它——不要改）。每次看到的**栈局部**是捕获时的副本；堆上的盒子不是副本。

### 与 L36 测例期望的关系

回归规则是「上一层全部测例仍须通过」。L36 的 15、16 在本层语义下应变为成功。处理方式锁定为：

- **不要改 L36 文档的期望**（那一层的实现确实该报错）。
- 本层驱动：L36 目录里标记为 stale-continuation 的两个测例，从 L37 起换用 `tests/L37/` 中语义更新的副本参与回归；或者驱动对这两个文件按层号切期望。推荐：**L36 测例文件保持不动；L37 回归仍跑 L36 除 15、16 以外的全部；15、16 在 L37 用新编号复述成功语义。** 若你的驱动无法排除单测，则从 L37 起把那两个 `.expected` 改成成功输出，并在 L36 文档加一句「实现完整 call/cc 后这两则期望被 L37 覆盖」——两种做法选一。**本教程推荐第一种（排除 + 新测例），以免 L36 单独验收失真。**

L36 的逃逸测例（1–14 等）在完整实现下仍然成立：向下跳只是完整 invoke 的特例（当时 `sp` 更低，拷贝把较深帧覆盖掉，等价于放弃它们）。

### 一元

`(k)`、`(k a b)` 运行时 arity 错。`(k v)` 的 `v` 可以是任意 Scheme 值，包括另一个延续。

### 栈上的可变槽 vs 盒子

捕获拷的是当时的栈字节。若 `set!` 变量是栈槽，invoke 会把槽恢复成快照里的旧值。若是堆盒子，槽里是盒子指针，指针随栈回来，盒子内容不回滚。L23/L26 对「被 lambda 捕获的 set! 变量」已经用盒子；本层起，**被 `call/cc` 跨越且之后还会 `set!` 的绑定建议一律 box**，否则会出现「invoke 把计数器倒回去」的死循环。L38 专门测这一点。本层测例用 `cons`/`set-car!` 做计数器，避免依赖你是否 box 了局部 `set!`。

## 与上一层的差异

- continuation 含栈字节拷贝；对象大小随深度变。
- invoke 可在 `call/cc` 返回之后发生；无 stale 错误（除非你对「从未捕获」的损坏对象仍 `rt_error`）。
- **不再恢复 `HP`**。
- `scheme_entry` 增加 `x23 = STACK_BASE`。
- `_rt_escape_cont` 换成 `_rt_full_cont`（或同一入口改逻辑）。

## 代码骨架

### `scheme_entry`

```asm
_scheme_entry:
    stp     x29, x30, [sp, #-64]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    str     x23, [sp, #48]
    mov     x19, x0
    add     x20, x19, x1
    mov     x22, #1
    mov     x23, sp             ; STACK_BASE
    ; body
    ldr     x23, [sp, #48]
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #64
    ret
```

64 字节对齐。`#48` 到 `#63` 含填充。

### 捕获（汇编循环拷贝）

```asm
    mov     x9, x23
    sub     x9, x9, sp          ; len
    ; alloc header+len → x10 raw
    mov     x11, sp             ; src
    add     x12, x10, #HEADER   ; dst
    mov     x13, x9
L_cpy:
    cbz     x13, L_done
    ldr     x14, [x11], #8
    str     x14, [x12], #8
    sub     x13, x13, #8
    b       L_cpy
L_done:
    ; fill header, tag → k in x0
```

`len` 保证整字。不要用 `x18`。

### `_rt_full_cont`

```asm
_rt_full_cont:
    cmp     x8, #1
    b.ne    L_arity
    and     x9, x21, #~7
    ldr     x10, [x9, #SP_OFF]
    ldr     x11, [x9, #LEN_OFF]
    ldr     x12, [x9, #COPY_OFF]
    mov     sp, x10
    ; memcpy copy → sp, x11 bytes
    ldr     x29, [x9, #FP_OFF]
    ldr     x30, [x9, #LR_OFF]
    mov     x22, #1
    ret                         ; x0 仍是 v
```

先 `mov sp` 再写栈，避免写在 sp 下方被信号打成红区之前：Apple 上向下碰 sp 过远会 SIGSEGV。若 `saved_SP` 比当前 `sp` 更低（更深），先 `mov sp, saved_SP` 是安全的（向低地址移，探栈）。若 `saved_SP` 更高，先把 `sp` 抬上去再 memcpy 也行；抬高 sp 等于丢弃深帧，正是我们想做的。两种都先 `mov sp, saved_SP`。

## 测例清单

上一层全部测例仍须通过（L36 的 stale 两则按上文「排除 + 本层复述」处理）。

1. **L36 立即逃逸仍过**  
   `(call/cc (lambda (k) (k 42)))` → `42`

2. **返回延续本身再调用（L36 曾报错）**  
   `(let ((v (call/cc (lambda (k) k)))) (if (fixnum? v) v (v 41)))` → `41`  
   第一次 `v` 是闭包，走 `(v 41)`；第二次 `v` 是 fixnum `41`。本层没有 `procedure?`，用 `fixnum?` 分支。

3. **`call/cc` 正常返回后从盒子取出 k**  
   `(let ((p (cons #f '())))
      (let ((r (call/cc (lambda (k) (begin (set-car! p k) 1)))))
        (if (fx= r 1)
            ((car p) 2)
            r)))` → `2`

4. **多次 invoke，堆计数器**  
   `(let ((box (cons 0 '())))
      (let ((k (call/cc (lambda (c) c))))
        (set-car! box (fxadd1 (car box)))
        (if (fx< (car box) 3)
            (k k)
            (car box))))` → `3`  
   每次 `(k k)` 让 `call/cc` 再返回那个延续；`set-car!` 不回滚。

5. **invoke 三次以上**  
   同上，把 `3` 改成 `5` → `5`

6. **逃逸自深层再在外层用同一 k（向下）**  
   `(fx+ 10 (call/cc (lambda (k) (let ((x 1)) (k 5)))))` → `15`

7. **已经返回后「往上」再进入加法**  
   `(let ((p (cons #f '())))
      (let ((s (fx+ 10 (call/cc (lambda (k) (begin (set-car! p k) 1))))))
        (if (fx= s 11)
            ((car p) 2)
            s)))` → `12`  
   第一次 `fx+` 得 11；再 invoke 把 2 送给 `fx+` 得 12。

8. **延续是闭包，可当 `apply` 目标**  
   `(let ((v (call/cc (lambda (k) k))))
      (if (fixnum? v) v (apply v '(7))))` → `7`

9. **一元 arity 错（运行时）**  
   `(let ((v (call/cc (lambda (k) k)))) (if (fixnum? v) v (v)))` → 非 0。

10. **`(k 1 2)`（运行时）**  
    `(call/cc (lambda (k) (k 1 2)))` → 非 0。

11. **嵌套延续，调用外层**  
    `(let ((v (call/cc (lambda (k1)
                 (call/cc (lambda (k2) (k1 3)))
                 9))))
       v)` → `3`

12. **嵌套，调用内层之后外层继续**  
    `(call/cc (lambda (k1)
       (begin (call/cc (lambda (k2) (k2 1)))
              (k1 2))))` → `2`

13. **在递归里保存 k，返回后再调（堆盒子）**  
    `(let ((p (cons #f '())))
       (letrec ((f (lambda (n)
                     (if (fx= n 0)
                         (call/cc (lambda (k) (begin (set-car! p k) 0)))
                         (fxadd1 (f (fxsub1 n)))))))
         (let ((r (f 3)))
           (if (fx= r 0) ((car p) 10) r))))` → `13`  
    `f` 三层 `fxadd1` 包着；第一次得 3；再把 10 送进最内层 `call/cc`，三层加一得 13。

14. **k 作为 rest 过程的实参传来传去仍能 invoke**  
    `(let ((v (call/cc (lambda (k) ((lambda r (car r)) k)))))
       (if (fixnum? v) v (v 6)))` → `6`

15. **`values` 路径不受影响**  
    `(call-with-values (lambda () (values 1 2)) (lambda (a b) (fx+ a b)))` → `3`

16. **尾调用深度下捕获**  
    `(letrec ((f (lambda (n k)
                   (if (fx= n 0) (k 42) (f (fxsub1 n) k)))))
       (call/cc (lambda (k) (f 10000 k))))` → `42`  
    自身尾调用不涨栈，拷贝长度仍短。

17. **非尾递归深度下捕获（n 小，避免爆栈）**  
    `(letrec ((f (lambda (n)
                   (if (fx= n 0)
                       (call/cc (lambda (k) (k 1)))
                       (fx+ 1 (f (fxsub1 n)))))))
       (f 10))` → `11`

18. **两个独立 continuation**  
    `(let ((a (cons 0 '())) (b (cons 0 '())))
       (let ((ka (call/cc (lambda (k) k))))
         (if (fixnum? ka)
             ka
             (let ((kb (call/cc (lambda (k) k))))
               (if (fixnum? kb)
                   kb
                   (begin (set-car! a 1) (ka 9)))))))` → `9`

19. **receiver 非闭包（运行时）**  
    `(call/cc 1)` → 非 0。

20. **同一延续 invoke 三次，堆计数器**  
    `(let ((box (cons 0 '())))
       (let ((v (call/cc (lambda (k) k))))
         (set-car! box (fxadd1 (car box)))
         (if (fx= (car box) 1)
             (v 0)
             (if (fx= (car box) 2)
                 (v 0)
                 (car box)))))` → `3`  
    第一次 `v` 是延续、box=1，`(v 0)`；第二次 `v` 是 `0`、box=2，再 `(v 0)`；第三次 box=3，返回 `3`。

21. **HP 不回滚：逃逸/再入后旧 pair 仍在**  
    `(let ((p (cons 1 2)))
       (let ((v (call/cc (lambda (k) k))))
         (if (fixnum? v)
             (car p)
             (begin (set-car! p 7) (v 0)))))` → `7`  
    若错误恢复了 HP 且把 `p` 的 bump 丢掉，可能崩或读到垃圾。

22. **与 `apply` + rest**  
    `(let ((v (call/cc (lambda (k) k))))
       (if (fixnum? v) v (apply (lambda (x) (x 8)) (cons v '()))))` → `8`

## 验收标准

- 测例 1–8、11–18、20–22 退出码 0，输出匹配。测例 4 不得死循环（那通常是栈槽 `set!` 被回滚，或 HP 回滚毁掉盒子）。
- 测例 9、10、19 运行时非 0。
- 生成 / runtime 使用 `x23`；`scheme_entry` 保存它。
- invoke 路径无 `HP` 赋值来自快照。
- 栈拷贝长度随深度变化：测例 17 的对象大于测例 1（可用 `%hp` 调试，不强制进驱动）。
- `sp` 16 字节对齐；无 `x18`。
- 上一层全部测例仍须通过（stale 两则按本节方法处理）。

## 常见坑

- **仍恢复 HP**：测例 4 的计数器被抹掉或指针悬空，表现为死循环或 SIGSEGV。
- **memcpy 方向搞反**：把空快照写到堆，或把堆写到错误的 sp。
- **先 memcpy 再 `mov sp`**：当 `saved_SP` 高于当前 `sp` 时写的是「当前帧上面」，可能碰巧成功；当更低时未探栈。统一先改 `sp`。
- **`STACK_BASE` 取成 C 调用前的 sp**：拷进 `scheme_entry` 以外的 C 帧，invoke 破坏 `main`。在 Scheme 序言之后采样。
- **`memcpy` 长度不是 8 的倍数**：最后几个保存的寄存器残缺。对齐帧则自动整字。
- **保存 `x30` 过早**：同 L36，必须是 `call/cc` 返回点。
- **忘记 `x23` 是 callee-saved**：C 调用后 `STACK_BASE` 变了，拷贝长度爆炸。
- **用 `blr` 进 `_rt_full_cont` 却在桩里 `br` 到 saved_LR 同时留下桩的帧**：桩应是闭包入口，用户 `(k v)` 已经 `blr` 进桩；桩自己不要再为「返回到 call/cc」建第二帧，直接 `mov sp` + `ret` 用的 `x30` 是**快照里的 LR**，不是进桩时的 LR。进桩时的 LR 要丢掉（那是 `(k v)` 的返回地址）。这正是逃逸/再入的含义。
- **len 用 Scheme fixnum 移位搞错**：拷少了半帧。

## 下一层预告

L38 几乎不加指令，专门用测例钉死：continuation 与 `set!`、共享盒子、闭包自由变量谁被回滚、谁保持最新赋值。
