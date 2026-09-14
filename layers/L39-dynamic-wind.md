# L39 — `dynamic-wind`

## 目标

实现 `(dynamic-wind before thunk after)`，语义对齐 R4RS：始终先以零参调用 `before`，再 `thunk`，再 `after`。若 `thunk` 里的延续向外逃逸，离开本层风障时仍要跑 `after`；若完整 `call/cc` 从外面再进入 `thunk` 的延续，必须先再跑 `before`，离开时再跑 `after`。运行时维护一张 **wind 栈**。与 `call/cc` 的测例是本层的重心。

本层范围之外：`with-exception-handler`、参数对象（Racket 式）、把 `before`/`after` 做成可再入的完整续延库以外的语法糖、多值与 wind 的交叉（`thunk` 仍按 L35 的单值/多值规则；`before`/`after` 的返回值丢弃，且它们处于单值上下文）。

## 原理

### R4RS 规则（落到可实现的句子）

```
(dynamic-wind before thunk after)
```

三个操作数都是零参过程。

1. 调用 `(before)`。
2. 把 `(before . after)` 这条记录 **push** 到 wind 栈，然后调用 `(thunk)`。
3. `thunk` 正常返回：先 **pop**，再调用 `(after)`，然后以 `thunk` 的返回值作为 `dynamic-wind` 的值。
4. 任何时候通过延续**离开**当前动态范围（wind 栈变短）：对将要丢掉的记录从内到外调用 `after`（且每调用完一条就 pop，或按快照遍历，见下）。
5. 通过延续**进入**另一动态范围（wind 栈变长或换成另一条链）：对将要进入的记录从外到内调用 `before`，并 push 成当前栈。
6. `before` 与 `after` 自己也受 wind 约束：它们运行期间，对应那条记录**尚未**入栈（before）或**已经**出栈（after），因此在 `before` 里逃逸不会触发这条的 `after`（从未进入）；在 `after` 里逃逸也不会再跑一次这条 `after`。

`thunk` 的延续被调用时，R4RS 要求：先执行必要的 `after`/`before`，再跳进该延续。这不是用户在 `thunk` 里手写的。

### Wind 栈表示

放在 runtime 全局（汇编）或一个 callee-saved / 线程全局 Scheme 盒子。本层单线程，runtime 全局即可：

```
; 算法伪代码：实现必须是 runtime 汇编，不是 C。
typedef struct wind {
    ptr before;     /* 闭包 */
    ptr after;      /* 闭包 */
    struct wind *prev;
} Wind;

static Wind *wind_top = NULL;   /* 当前 in-extent 的最内层 */
```

`Wind` 节点本身用 Scheme 堆（不要堆外分配）。推荐 Scheme 堆上的 pair 链：`wind_top` 是 Scheme 值，存在 `x25` 或 runtime 的 `ptr rt_wind`。为少占寄存器，锁定：

- runtime 全局 `ptr rt_wind_list`，`'()` 为空。
- 每条记录是 `(cons before after)`，栈是这些 pair 的列表，**表头为最内层**。
- `scheme_entry` 入口把 `rt_wind_list = EMPTY_LIST`；不要靠汇编清。

捕获 continuation 时（L37 的拷贝之外）**再存一份当时的 `rt_wind_list` 指针**进 continuation 对象（新增一个 fv：`saved_wind`）。列表在堆上，HP 不回滚，所以这份指针仍有效。不要把整张栈再深拷贝一份 before/after 闭包。

### Invoke 时的进出（核心算法）

设当前栈 `cur`，目标延续里保存的栈 `tgt`。两者都是从内到外的列表。

1. 求共同后缀（共同的外层记录）。因每次 `dynamic-wind` 分配新 pair，**指针 `eq?` 相同才是同一帧**。从两边的最外层对齐：先把两列表 reverse 成外→内，找最长公共前缀，再映回。
2. **离开**：对 `cur` 中不在公共祖先内的记录，从内到外 `(after)`。每跑完一个，把 `rt_wind_list` 的 cdr 作为新当前（或先全部记在临时数组再调，避免 after 里再 call/cc 看到半更新的栈——见下）。
3. **进入**：对 `tgt` 中不在公共祖先内的记录，从外到内 `(before)`，同时把 `rt_wind_list` 更新成与 `tgt` 一致的形状。
4. 然后按 L37 恢复栈 / `ret` 进延续。

`after`/`before` 是 Scheme 闭包：要用与普通零参 `blr` 相同的约定（`x8=0`，`x21=闭包`），且它们可能再 `call/cc`。R4RS 对「after 里再逃逸」的规定是：那次逃逸会再次走本算法。实现必须在调 `after` **之前**就把该记录从当前 wind 栈拿掉，否则递归 wind 会再调一次同一 `after`。

锁定顺序（离开一条记录）：

```
pop 该记录（rt_wind_list = cdr）
调用 after      ; 此时栈已不含本记录
```

进入一条记录：

```
调用 before     ; 此时栈尚不含本记录
push 该记录
```

这与「正常路径」一致：正常路径是 `before` → push → `thunk` → pop → `after`。

### 与 `call/cc` 的挂钩

改 `_rt_full_cont`（以及若仍保留的逃逸桩）：在 `mov sp` / `ret` **之前**调用 `rt_wind_switch(tgt_list)`。`rt_wind_switch` 用 C 或汇编循环，内部 `blr` Scheme 闭包。注意 C 与 Scheme 交错：

- 调 `before`/`after` 前保存 `HP`/`SELF`/`STACK_BASE`/`MV`（callee-saved 本就会被 C 保存；若 `rt_wind_switch` 是汇编，自己 `stp`）。
- `before`/`after` 返回后 `x22` 必须回到单值；它们的返回值丢弃。若它们用 `values` 交付非 1 个值：`rt_error`（单值上下文）。

不要在恢复 Scheme 栈之后再跑 `before`：那时 `sp` 已在目标帧，C/辅助的帧会破坏目标栈。顺序锁定：

1. `rt_wind_switch(tgt)`    ；仍在 invoke 当下的 Scheme 栈上
2. `mov sp, saved_SP` + memcpy 快照
3. 恢复 FP/LR，`x0=v`，`ret`

### 正常路径骨架

不必走 `rt_wind_switch`：

```
(before)           ; argc=0
push (cons before after)
(thunk)            ; 保存返回值
pop
(after)
返回 thunk 的值
```

`dynamic-wind` 在尾位置：不能尾调 `thunk` 而跳过 `after`。`thunk` 必须非尾调用；`after` 之后若 `dynamic-wind` 处于尾位置，把值尾返回给外层。

### 错误

- 三个操作数不是闭包：运行时 `rt_error`。
- `before`/`thunk`/`after` 的 arity 不是 0：它们自己的序言报错。
- 编译期：不是正好 3 个操作数。

### 打印与副作用顺序

测例用 `set!` / `set-car!` 往共享盒子里 `cons` 事件符号（fixnum 编码即可，避免本层还没有符号：用 `1=before` `2=thunk` `3=after`）。

## 与上一层的差异

- 新核心形式 `dynamic-wind`。
- continuation 对象多一个 `saved_wind` 槽；捕获时读 `rt_wind_list`。
- invoke 不再直接 `ret`，先做 wind 切换。
- 无 wind 的 L37/L38 测例：`rt_wind_list` 恒 `'()`，公共祖先为空，switch 是 no-op。

## 代码骨架

### 可移植前端

```scheme
(define (expr->ir expr env tail?)
  (cond
    ((and (pair? expr) (eq? (car expr) 'dynamic-wind)
          (= (length expr) 4))
     `(dw ,(expr->ir (cadr expr) env #f)
          ,(expr->ir (caddr expr) env #f)
          ,(expr->ir (cadddr expr) env #f)))
    ;; …
    ))
```

`tail?` 不影响对 `thunk` 的调用方式（永远非尾），只影响 `dw` 表达式自己的返回。

### runtime 汇编：`rt_wind_switch`

```
; 算法伪代码：实现必须是 runtime 汇编，不是 C。
ptr rt_wind_list = EMPTY_LIST;

static int list_len(ptr p) { /* 只用于 wind 栈，已知真列表 */ }

void rt_wind_switch(ptr tgt) {
    ptr cur = rt_wind_list;
    /* 1. 把 cur、tgt 变成数组（内→外），找 common 外层前缀长度 */
    /* 2. 离开：i from 0 to n_cur-common-1：
          rec = car(cur); rt_wind_list = cdr(cur); cur = rt_wind_list;
          call0(cdr(rec));  // after
     */
    /* 3. 进入：从最外要进入的到最内
          call0(car(rec));  // before
          rt_wind_list = cons(rec, rt_wind_list);
     */
}

static void call0(ptr clos) {
    /* 不能在纯 runtime 汇编里 blr。提供汇编桩： */
    rt_call0(clos);
}
```

汇编桩 `rt_call0`：

```asm
    .globl _rt_call0
_rt_call0:
    stp     x29, x30, [sp, #-16]!
    mov     x21, x0
    mov     x8, #0
    and     x9, x0, #~7
    ldr     x9, [x9]
    blr     x9
    ldp     x29, x30, [sp], #16
    ret
```

`sp` 16 字节对齐。禁止 `x18`。`rt_call0` 返回后检查 `x22==1`。

### `emit-dw`

```scheme
(define (emit-dw before thunk after ctx)
  (string-append
    (emit-ir before ctx) (emit-call0)          ; before
    ;; cons (before . after) 并 cons 到 rt_wind_list
    ;; 通过 bl _rt_wind_push
    (emit-ir thunk ctx) (emit-call0)           ; thunk，保存 x0
    (emit-rt-call "rt_wind_pop_run_after" 0)    ; pop + after
    ;; 恢复 thunk 的 x0
    ))
```

`rt_wind_pop_run_after`：`rec=car(list); list=cdr; call0(cdr(rec))`。

### 捕获时

```asm
    adrp    x9, _rt_wind_list@PAGE
    ldr     x9, [x9, _rt_wind_list@PAGEOFF]
    str     x9, [cont, #WIND_OFF]
```

Darwin 上全局要 `_rt_wind_list`。若 PIC：`adrp`+`ldr` 的 GOT 形式按 Apple 要求写；也可把 wind 列表放在 `scheme_entry` 帧里一个固定槽，用 `x24` 保存指针——更简单则用 runtime 全局 + 一行 `bl _rt_wind_get`。

### `_rt_full_cont` 插入点

```asm
    ; x0 = v，x21 = cont 闭包。先 spill v。
    ldr     x0, [raw, #WIND_OFF]
    bl      _rt_wind_switch
    ldr     x0, [sp, #saved_v]
    ; 然后 mov sp / memcpy / ret 同 L37
```

## 测例清单

上一层全部测例仍须通过。

1. **无逃逸，顺序 before → thunk → after**  
   `(let ((p '()))
      (begin
        (dynamic-wind
          (lambda () (set! p (cons 1 p)))
          (lambda () (set! p (cons 2 p)))
          (lambda () (set! p (cons 3 p))))
        p))` → `(3 2 1)`

2. **返回值是 thunk 的**  
   `(dynamic-wind (lambda () 0) (lambda () 42) (lambda () 1))` → `42`

3. **before / after 返回值丢弃**  
   `(fx+ 1 (dynamic-wind (lambda () 100) (lambda () 2) (lambda () 100)))` → `3`

4. **thunk 里逃逸仍跑 after**  
   `(let ((p '()))
      (begin
        (call/cc (lambda (k)
          (dynamic-wind
            (lambda () (set! p (cons 1 p)))
            (lambda () (begin (set! p (cons 2 p)) (k 0)))
            (lambda () (set! p (cons 3 p))))))
        p))` → `(3 2 1)`

5. **逃逸值作为 call/cc 的值，after 在交付前跑完**  
   `(let ((p '()))
      (let ((v (call/cc (lambda (k)
                 (dynamic-wind
                   (lambda () (set! p (cons 1 p)))
                   (lambda () (k 7))
                   (lambda () (set! p (cons 3 p))))))))
        (cons v p)))` → `(7 3 1)`  
    thunk 未往 p 写 2。after 已跑。

6. **再入：离开跑 after，进来跑 before，再继续 thunk**  
    `(let ((p '()))
       (let ((inner (call/cc (lambda (out)
                       (dynamic-wind
                         (lambda () (set! p (cons 1 p)))
                         (lambda ()
                           (begin (call/cc (lambda (in) (out in)))
                                  (set! p (cons 2 p))
                                  0))
                         (lambda () (set! p (cons 3 p))))))))
         (begin
           (if (fixnum? inner) 0 (inner 0))
           p)))` → `(3 2 1 3 1)`  
    顺序：`before` 写 1，thunk 捕获 `in`，`(out in)` 离开 → `after` 写 3，`p=(3 1)`；`(inner 0)` 进入 → `before` 写 1，`p=(1 3 1)`，thunk 继续 `set!` 写 2，`p=(2 1 3 1)`，`after` 写 3，`p=(3 2 1 3 1)`。

7. **再入后 thunk 的返回值**  
   `(let ((inner (call/cc (lambda (out)
                    (dynamic-wind
                      (lambda () #t)
                      (lambda () (begin (call/cc (lambda (in) (out in))) 42))
                      (lambda () #t))))))
      (if (fixnum? inner) inner (inner 0)))` → `42`

8. **嵌套 wind，从内层逃到外层：内 after 然后外 after**  
   `(let ((p '()))
      (begin
        (call/cc (lambda (k)
          (dynamic-wind
            (lambda () (set! p (cons 1 p)))
            (lambda ()
              (dynamic-wind
                (lambda () (set! p (cons 2 p)))
                (lambda () (k 0))
                (lambda () (set! p (cons 3 p)))))
            (lambda () (set! p (cons 4 p))))))
        p))` → `(4 3 2 1)`

9. **嵌套，再入内层：外 before 已在，只再跑内 before**  
   `(let ((p '()))
      (let ((inner (call/cc (lambda (out)
                      (dynamic-wind
                        (lambda () (set! p (cons 1 p)))
                        (lambda ()
                          (dynamic-wind
                            (lambda () (set! p (cons 2 p)))
                            (lambda ()
                              (begin (call/cc (lambda (in) (out in)))
                                     (set! p (cons 9 p))))
                            (lambda () (set! p (cons 3 p)))))
                        (lambda () (set! p (cons 4 p))))))))
        (begin (if (fixnum? inner) 0 (inner 0)) p)))`  
    第一次离开内+外：after3、after4。p=`(4 3 2 1)`。再入：before1、before2，thunk 写 9，after3、after4。  
    → `(4 3 9 2 1 4 3 2 1)`

10. **before 里逃逸：不跑 after**  
    `(let ((p '()))
       (begin
         (call/cc (lambda (k)
           (dynamic-wind
             (lambda () (begin (set! p (cons 1 p)) (k 0)))
             (lambda () (set! p (cons 2 p)))
             (lambda () (set! p (cons 3 p))))))
         p))` → `(1)`

11. **after 里逃逸：不重复同一 after**  
    `(let ((p '()))
       (begin
         (call/cc (lambda (k)
           (dynamic-wind
             (lambda () (set! p (cons 1 p)))
             (lambda () (set! p (cons 2 p)))
             (lambda () (begin (set! p (cons 3 p)) (k 0)))))
         p))` → `(3 2 1)`  
    不得出现两个 3。

12. **无 dynamic-wind 的 call/cc 仍过**  
    `(call/cc (lambda (k) (k 5)))` → `5`

13. **L38 计数器仍过**  
    `(let ((n 0))
       (let ((k (call/cc (lambda (c) c))))
         (set! n (fxadd1 n))
         (if (fx< n 3) (k k) n)))` → `3`

14. **thunk 非零 arity（运行时）**  
    `(dynamic-wind (lambda () 1) (lambda (x) x) (lambda () 1))` → 非 0。

15. **操作数不是闭包（运行时）**  
    `(dynamic-wind 1 (lambda () 2) (lambda () 3))` → 非 0。

16. **编译期 arity**  
    `(dynamic-wind (lambda () 1) (lambda () 2))` → 编译期错。

17. **before 的 arity 错则不进 thunk（运行时）**  
    `(dynamic-wind (lambda (x) x) (lambda () 1) (lambda () #t))` → 非 0。

18. **wind 与 apply**  
    `(let ((p '()))
       (begin
         (dynamic-wind
           (lambda () (set! p (cons 1 p)))
           (lambda () (apply (lambda () (set! p (cons 2 p))) '()))
           (lambda () (set! p (cons 3 p))))
         p))` → `(3 2 1)`

19. **尾递归 thunk 外层仍保证 after**（thunk 内自尾，dynamic-wind 本身非尾调 thunk）  
    `(let ((p '()))
       (begin
         (dynamic-wind
           (lambda () (set! p (cons 1 p)))
           (lambda ()
             (letrec ((f (lambda (n)
                           (if (fx= n 0) 0 (f (fxsub1 n))))))
               (f 10000)))
           (lambda () (set! p (cons 3 p))))
         p))` → `(3 1)`

20. **values：thunk 单值**  
    `(dynamic-wind (lambda () 0)
                   (lambda () (values 42))
                   (lambda () 0))` → `42`

21. **两层再入只内层（外层从未离开）** — 用外层 thunk 里保存的 k  
    `(let ((p '()))
       (dynamic-wind
         (lambda () (set! p (cons 1 p)))
         (lambda ()
           (let ((inner (call/cc (lambda (out)
                           (dynamic-wind
                             (lambda () (set! p (cons 2 p)))
                             (lambda () (begin (call/cc (lambda (in) (out in))) 0))
                             (lambda () (set! p (cons 3 p))))))))
             (if (fixnum? inner) inner (inner 0))))
         (lambda () (set! p (cons 4 p))))
       p)`  
    外 before1 一直在。内：before2，逃到外层 thunk（只 after3），再入 inner（before2），after3，然后外 after4。  
    → `(4 3 2 3 2 1)`

22. **continuation 在 wind 外创建，在 wind 内 invoke：只跑 after 离开 wind**  
    `(let ((p '()))
       (let ((k (call/cc (lambda (c) c))))
         (if (fixnum? k)
             p
             (begin
               (dynamic-wind
                 (lambda () (set! p (cons 1 p)))
                 (lambda () (k 0))
                 (lambda () (set! p (cons 3 p))))
               p))))` → `(3 1)`  
    invoke 目标在 wind 外，离开时 after。

23. **在 wind 内捕获，在 wind 外 invoke：进入时先跑 before**  
    `(let ((p '()))
       (let ((k (call/cc (lambda (out)
                   (dynamic-wind
                     (lambda () (set! p (cons 1 p)))
                     (lambda () (call/cc (lambda (in) (out in))))
                     (lambda () (set! p (cons 3 p))))))))
         (begin
           (if (fixnum? k) 0 (k 0))
           p)))` → `(3 1 3 1)`  
    与测例 6 的差别：thunk 在再入后没有额外 `set!` 2，因此最终只有进出各一次的 1 与 3。离开时 p=`(3 1)`；再入 before 写 1、after 写 3。

24. **`call-with-values` 包在 thunk 里**  
    `(dynamic-wind
       (lambda () #t)
       (lambda () (call-with-values (lambda () (values 1 2))
                                    (lambda (a b) (fx+ a b))))
       (lambda () #t))` → `3`

25. **even/odd 一万次仍过**  
    `(letrec ((even (lambda (n) (if (fx= n 0) #t (odd (fxsub1 n)))))
              (odd (lambda (n) (if (fx= n 0) #f (even (fxsub1 n))))))
       (even 10000))` → `#t`

## 验收标准

- 测例 1–13、18–25 退出码 0，输出匹配。pair 打印顺序与 L13 一致（头是最后 cons 的）。
- 测例 4、5、8、10、11、22 证明逃逸时 after 的次数与顺序。
- 测例 6、7、9、21、23 证明再入时 before 再跑。
- 测例 10：before 逃逸则 after 次数为零。测例 11：after 不因自身逃逸而重复。
- 测例 14、15、17 运行时非 0；16 编译期非 0。
- invoke 路径先 `rt_wind_switch` 再改 `sp`。
- 无 wind 时 L37/L38 行为不变。
- 上一层全部测例仍须通过。

## 常见坑

- **尾调 thunk**：`after` 永远不跑。
- **先 `mov sp` 再跑 after**：after 的 Scheme 帧写在目标栈上，目标帧损坏。
- **after 仍在栈上时调用 after**：after 里 `call/cc` 再离开会第二次进同一 after，测例 11 出现两个 3。
- **共同祖先用值相等而不是 `eq?`**：两个 `lambda` 文本一样也会被当成同一帧，进出顺序错。
- **再入时从内往外跑 before**：嵌套测例 9 的 1 与 2 颠倒。
- **HP 回滚导致 wind 列表悬空**：L37 已禁止；本层列表在堆上，更不能回滚 HP。
- **`rt_call0` 不对齐 `sp`**。
- **用 `x18` 存 wind_top**。
- **before 计入 thunk 的返回值**：测例 2 会变成 0。
- **事件 cons 方向写反**：期望 `(3 2 1)` 实际 `(1 2 3)` 只是打印顺序，按你的 `set! p (cons x p)` 从头 cons，期望必须头是最后一次事件。

## 下一层预告

L40 回到语法：用展开器把 `cond` 与 `case` 变成已有的 `if` / `eq?` / `begin`，不再改调用约定。
