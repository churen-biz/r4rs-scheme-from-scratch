# L36 — 只向下逃逸的 continuation

## 目标

实现 `call-with-current-continuation`（别名 `call/cc`）：把当前延续做成一个**一元过程**交给接收者。本层该对象**只能向下逃逸**——在 `call/cc` 的接收者尚未正常返回之前调用它，用来放弃内层的 `if`/`let`/`begin` 往外跳。`call/cc` 一旦已经正常返回，再调用这个对象必须 **`rt_error`**。不做栈拷贝，因此不能「返回之后再进来」也不能多次从同一快照复活。

本层范围之外：完整 `call/cc`（栈拷贝、多次 invoke、非本地返回后再 invoke）、`dynamic-wind`、多值延续（延续仍是一元；`(k)` / `(k 1 2)` 走普通 arity 错）。

## 原理

### 用户语法

```
(call-with-current-continuation receiver)
(call/cc receiver)
```

两者降成同一 IR。`receiver` 是单参过程。`call/cc` 把它调用为 `(receiver k)`，`k` 是当前延续。

在本层，`k` 的合法使用只有一种：在 `receiver` 的动态范围内执行 `(k v)`，效果是 **`call/cc` 表达式以 `v` 为值完成**，`receiver` 里尚未完成的计算被放弃。

非法（本层运行时 `rt_error`）：

- `receiver` 正常返回（返回值是 `k` 或任意值）之后，外层再 `(k v)`。
- 把 `k` 存进盒子/全局，等到包着它的 `call/cc` 已经结束再调。
- 同一逃逸 continuation 在已经成功逃逸、且该 `call/cc` 已完成之后再调（见「活标志」）。

合法：`(call/cc (lambda (k) (k 42)))` → `42`。`(call/cc (lambda (k) 42))` → `42`（从不调用 `k`，对象在返回时作废）。

### 表示：不要新标签

延续是堆上的**闭包**，`CLOSURE_TAG=0b110`。`code` 指针指向运行时桩 `_rt_escape_cont`（汇编或 C 包装的汇编入口），不是用户 `lambda`。布局与 L26 相同：

```
[ code = &_rt_escape_cont ]
[ nfree = fixnum 4 ]
[ fv0 = saved SP ]      ; 裸指针，不是 Scheme 值；打印不要走 fv
[ fv1 = saved FP ]
[ fv2 = saved HP ]
[ fv3 = live flag ]     ; Scheme 值：#t 活 / #f 死，或一个堆盒子
```

`nfree` 用 fixnum 标签。SP/FP/HP 是原始地址，低 3 位为 0，看起来会像 fixnum；它们不是给 Scheme 算术用的。不要给 continuation 新开 heap tag。

`live flag` 推荐单独一个 `box`（`BOX_TAG`），`call/cc` 与 `receiver` 正常返回路径、以及桩代码共享这一个盒子：任何「该 `call/cc` 已完成」的路径把盒子写成 `#f`。用栈上一个槽当 flag 也可以，但逃逸时我们会把 `SP` 弹回去，栈槽内容必须放在**捕获时的那一帧里**，逃逸会恢复它——更绕。盒子在堆上，本层逃逸还要恢复 `HP`（见下），可能把盒子 bump 掉；因此 **flag 必须分配在捕获之前**，恢复 `HP` 时不得退到 flag 之前。锁定：

1. 先 `cons`/`box` 分配 `live=#t`（以及 continuation 闭包本身）。
2. 再把**当前** `HP` 写入 continuation 的 `fv2`。这样逃逸后扔掉的是 receiver 里后续分配的对象，不扔掉 continuation 与 flag。
3. `SP`/`FP` 在分配完成、即将调用 `receiver` 之前采样。

### 捕获

`call/cc` 降为调用一个 runtime 辅助，或前端内联：

1. 分配 flag 盒子 = `#t`。
2. 分配闭包，填 code、nfree、采样的 `SP`、`FP`、`HP`、flag。
3. 以 `argc=1`、`x0=k` 调用 `receiver`（非尾：`call/cc` 自己还要在 receiver 正常返回后把 flag 置死并交出返回值；若 `call/cc` 在尾位置，receiver 正常返回值就是外层的值，仍须在返回前把 flag 置死——见下）。

尾位置 `call/cc`：不能简单尾调 `receiver` 而忘了「正常返回则 flag 死」。做法：始终用非尾调用 `receiver`；若 `call/cc` 处于尾位置，receiver 返回后再把值装进 `x0` 按尾返回。逃逸路径直接把值交到捕获的 `SP`/`FP`/`LR`，等价于 `call/cc` 返回，不经过这段后置代码。

### 调用 `k`

`(k v)` 走普通闭包调用：入口是 `_rt_escape_cont`。桩约定与用户过程相同：`x0` 是第一实参（即 `v`），`x21` 是这个 continuation 闭包，`x8=argc`。

```
_rt_escape_cont:
    cmp x8, #1
    b.ne arity_error
    ; 从 x21 取 fv
    ; 若 flag 为 #f → rt_error("stale continuation")
    ; 恢复 HP、FP、SP
    ; x0 保持 v
    ; x22 = 1（单值）
    ; 把 LR 设成捕获时的返回地址：捕获时应把当时的 x30 也存下来
```

补充字段：真正要回到的是「`call/cc` 的延续」，即捕获瞬间的 `x30`（若捕获代码是 `bl` 进 helper，应存 helper 的返回地址的**调用方**，也就是 `call/cc` 之后那条指令）。更清晰的存法：存 `saved_LR` 作为 `fv4`。

锁定 continuation 闭包 fvs：

| 槽 | 内容 |
|----|------|
| 0 | `SP` |
| 1 | `FP` |
| 2 | `HP` |
| 3 | live box |
| 4 | `LR`（`x30`） |

`nfree=5`。调用桩：校验 live；`mov x19, saved_HP`；`mov x29, saved_FP`；`mov x0, v`；`mov x22, #1`；`mov x30, saved_LR`；`mov sp, saved_SP`；`ret`（或 `br x30`）。`ret` 前 `sp` 必须是捕获时的值，且 16 字节对齐。

恢复 `HP` 会扔掉逃逸之后 bump 的对象。本层接受；那些对象本应随被放弃的计算一起消失。不要在逃逸路径上恢复 `HL`。`SELF`（`x21`）回到调用方后由调用方自己用；桩不必恢复捕获时的 `x21`。

### 正常返回则作废

`receiver` 若没用 `k` 就返回：

1. `set-box! live #f`
2. `x0` = receiver 的返回值，作为 `call/cc` 的值
3. `x22` 按 L35 单值检查

之后任何 `(k v)` 进桩，看见 `#f`，`rt_error`。

逃逸成功一次之后：`call/cc` 已经完成。若有人仍握着 `k`（例如先把它放进 receiver 外的盒子——但逃逸本层不允许「完成后再调」），flag 也应为死。何时置死？

- **方案 A**：逃逸时不置死，只在正常返回时置死。则同一 `receiver` 内可以 `(k (k 1))` 这种怪式——内层 `k` 逃逸，外层不再执行。receiver 内多次 `(begin (k 1) (k 2))` 第二次不可达。若把 `k` 传给尚未返回的外层兄弟帧……本层是逃逸 only，栈上更浅的帧还在（我们把 SP 弹到捕获点），捕获点之外的代码若已经拿过 `k` 的副本，在 `call/cc` 返回后会调它。所以必须在**离开 `call/cc` 时**置死，包括逃逸路径。
- **锁定**：桩在恢复栈**之前**把 live 置 `#f`。正常返回路径同样置 `#f`。每个逃逸 continuation 最多成功交付一次。`receiver` 里第一次 `(k v)` 成功；若实现把 flag 在跳转前关掉，同一次 receiver 里无法二次调用——第二次不可达，无所谓。

「`call/cc` 正常返回后再调」覆盖：`(let ((p (cons #f '()))) (let ((v (call/cc (lambda (k) (begin (set-car! p k) 1))))) ((car p) 2)))` —— 正常返回 `1`，然后调用 `k`。flag 已死，`rt_error`。这是本层的合同测例。

### 与嵌套 `if` / `let`

逃逸只改 `SP`/`FP`/`HP`/`LR`，不解释 Scheme 语法。只要捕获点在 `call/cc` 调用处，`(k v)` 就会让 `(if (call/cc …) …)` 或 `(let ((x (call/cc …))) …)` 看见 `v`。内层尚未执行的 `let` 绑定、`if` 另一支全部消失。

### aarch64

- 调用 `receiver` 用 `blr`。
- 桩返回用 `ret` 或 `br x30`，不要再 `blr`。
- 改 `sp` 用 `mov sp, xN`（先把 saved SP 放到通用寄存器）。立即数不能直接写 `sp`。
- 16 字节对齐；禁止 `x18`。

## 与上一层的差异

- 新用户绑定：`call/cc` / `call-with-current-continuation`（核心形式或 runtime 闭包；推荐核心形式，避免尚未有全局环境）。
- 闭包的 code 指针第一次指向**不是**本次 `emit-program` 里 `code` 块的地址。链接时 runtime.o 提供 `_rt_escape_cont`。
- 第一次在 Scheme 里保存 / 恢复 `sp`。
- 本层仍无栈拷贝：continuation 对象很小（一个闭包）。

## 代码骨架

### 可移植 IR

```
(call-cc Ir-receiver)           ; 非尾或尾由 ctx 决定
```

前端：`(call/cc e)` 与 `(call-with-current-continuation e)` 都变成 `(call-cc (expr->ir e env #f))`。

### aarch64：发出捕获

```asm
    ; 1. box live = #t
    ; 2. alloc closure 6 words: code, nfree=5, sp, fp, hp, box, lr
    adrp    x9, _rt_escape_cont@PAGE
    add     x9, x9, _rt_escape_cont@PAGEOFF
    str     x9, [raw]
    mov     x10, #(5 << 2)
    str     x10, [raw, #8]
    mov     x10, sp
    str     x10, [raw, #16]
    str     x29, [raw, #24]
    str     x19, [raw, #32]
    str     xBOX, [raw, #40]
    str     x30, [raw, #48]
    orr     x0, raw, #6         ; k
    ; 3. 调 receiver：x1 先不要用错，receiver 在槽里
    ; x0=k 将作为 arg0；先把 k 挪到安全处，把 receiver 放 x21
    mov     x8, #1
    ldr     x9, [receiver_raw]
    blr     x9
    ; 4. 正常返回：live := #f，x0 已是值
```

采样 `sp`/`x30` 的时刻：闭包填完之后、`blr` 之前。不要在 `bl _rt_alloc` 一类 runtime 辅助里采样 `x30`——那是 **回 runtime 辅助的地址**，不是 Scheme 延续。在汇编里、对 Scheme receiver 的 `blr` 之前采样。

### `_rt_escape_cont`

```asm
    .globl _rt_escape_cont
    .p2align 2
_rt_escape_cont:
    cmp     x8, #1
    b.ne    L_arity
    and     x9, x21, #~7
    ldr     x10, [x9, #40]      ; live box
    and     x11, x10, #~7
    ldr     x12, [x11]          ; unbox
    mov     x13, #0x2F          ; #f
    cmp     x12, x13
    b.eq    L_stale
    str     x13, [x11]          ; live := #f
    ldr     x14, [x9, #16]      ; SP
    ldr     x29, [x9, #24]      ; FP
    ldr     x19, [x9, #32]      ; HP
    ldr     x30, [x9, #48]      ; LR
    mov     x22, #1
    ; x0 已是 v
    mov     sp, x14
    ret
L_stale:
    adrp    x0, stale_msg@PAGE
    add     x0, x0, stale_msg@PAGEOFF
    b       _rt_error
```

Darwin 上 C 符号仍带下划线。消息放 `.cstring`。

## 测例清单

上一层全部测例仍须通过。

1. **立即逃逸**  
   `(call/cc (lambda (k) (k 42)))` → `42`

2. **别名全名**  
   `(call-with-current-continuation (lambda (k) (k 1)))` → `1`

3. **从不调用 k**  
   `(call/cc (lambda (k) 99))` → `99`

4. **逃逸自 `if` 真支**  
   `(call/cc (lambda (k) (if #t (k 3) 4)))` → `3`

5. **逃逸自 `if` 假支**  
   `(call/cc (lambda (k) (if #f 4 (k 5))))` → `5`

6. **放弃另一支**  
   `(fx+ 1 (call/cc (lambda (k) (if #t (k 2) 100))))` → `3`

7. **逃逸自 `let` body**  
   `(call/cc (lambda (k) (let ((x 1)) (k (fx+ x 2)))))` → `3`

8. **放弃 `let` 之后的代码**  
   `(call/cc (lambda (k) (let ((x (k 7))) (fx+ x 1))))` → `7`

9. **嵌套 `let` + `if`**  
   `(call/cc (lambda (k)
      (let ((a 1))
        (if (fx= a 1)
            (let ((b 2)) (k (fx+ a b)))
            0))))` → `3`

10. **`begin` 中间逃逸**  
    `(call/cc (lambda (k) (begin 1 (k 2) 3)))` → `2`

11. **外层运算看见逃逸值**  
    `(fx* 2 (call/cc (lambda (k) (begin (k 21) 0))))` → `42`

12. **嵌套 `call/cc`，内层逃逸到内层**  
    `(call/cc (lambda (k1)
       (call/cc (lambda (k2) (k2 6)))
       9))` → `9`  
    内层 `(k2 6)` 使内层 `call/cc` 得 `6`，值被丢弃，外层得 `9`。

13. **嵌套，内层调用外层 k**  
    `(call/cc (lambda (k1)
       (call/cc (lambda (k2) (k1 8)))
       1))` → `8`

14. **`letrec` 递归里逃逸**  
    `(call/cc (lambda (k)
       (letrec ((f (lambda (n)
                     (if (fx= n 0) (k 42) (f (fxsub1 n))))))
         (f 1000))))` → `42`

15. **正常返回后 invoke（运行时）**  
    `(let ((p (cons #f '())))
       (begin
         (call/cc (lambda (k) (begin (set-car! p k) 1)))
         ((car p) 2)))` → 非 0，stderr 含 stale / continuation / escape。

16. **返回 k 本身再调用（运行时）**  
    `((call/cc (lambda (k) k)) 1)` → 非 0。这是完整 call/cc 的经典用法，本层必须拒绝。

17. **arity：`(k)`（运行时）**  
    `(call/cc (lambda (k) (k)))` → 非 0。

18. **arity：`(k 1 2)`（运行时）**  
    `(call/cc (lambda (k) (k 1 2)))` → 非 0。

19. **receiver 非闭包（运行时）**  
    `(call/cc 1)` → 非 0。

20. **编译期操作数个数**  
    `(call/cc)` → 编译期错。`(call/cc (lambda (k) 1) 2)` → 编译期错。

21. **逃逸后 HP 丢弃：不死，结果仍对**  
    `(call/cc (lambda (k)
       (let ((x (cons 1 2)))
         (k (cdr (cons 3 4))))))` → `4`  
    不要求观察 HP；只要求不崩。

22. **`values` 仍过**  
    `(call-with-values (lambda () (values 1 2)) (lambda (a b) (fx+ a b)))` → `3`

23. **逃逸值是 `#f`**  
    `(if (call/cc (lambda (k) (k #f))) 1 2)` → `2`

24. **逃逸值是 `'()`**  
    `(null? (call/cc (lambda (k) (k '()))))` → `#t`

25. **深层 `begin`/`let*`**  
    `(fxadd1
      (call/cc (lambda (k)
        (let* ((a 1) (b (fx+ a 1)))
          (begin (fx+ a b) (k 41) 0)))))` → `42`

## 验收标准

- 测例 1–14、21–25 退出码 0，输出匹配。
- 测例 15–19 运行时非 0；20 编译期非 0。测例 16 不得打印 `1`（那是 L37 的行为）。
- continuation 对象带 `CLOSURE_TAG`，无新标签。
- 逃逸恢复 `SP`、`FP`、`HP`、`LR`；`x22` 置 1。
- 活标志在 `call/cc` 完成后为死。
- 上一层全部测例仍须通过。

## 常见坑

- **采样了 helper 的 `x30`**：逃逸回到 C 或桩中间，`sp` 对不上。在即将 `blr receiver` 的那条汇编处采样。
- **先采样 HP 再分配闭包**：逃逸把闭包和 flag 一起扔掉，二次检查读野指针。
- **不恢复 HP**：本层合同要求恢复。不恢复也能过很多测例，但与 `_contract.md` 不符，且 L37 要反过来「不回滚堆」，两层差异必须可见。
- **`mov sp, #imm`**：不合法。先装进 `xN`。
- **拆帧后 `ret` 却用捕获前的 `sp`**：顺序必须是先写 `x30`/`x29` 再 `mov sp` 再 `ret`。
- **允许测例 16**：实现做成了完整 call/cc。本层要显式拒绝。
- **桩不查 `argc`**：`(k 1 2)`  silently 用第一个。
- **用 `x18` 存 saved SP**。
- **正常返回不置死**：测例 15 会以 `2` 假绿，变成 L37。

## 下一层预告

L37 要把从当前 `SP` 到栈底的字节拷进 continuation 对象：同一延续可多次调用，且 `call/cc` 正常返回之后仍能再进入。
