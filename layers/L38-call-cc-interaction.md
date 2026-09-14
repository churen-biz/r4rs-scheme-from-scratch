# L38 — `call/cc` × `set!` × 闭包

## 目标

本层几乎不增加用户语法。任务是用测例与实现注释钉死完整 `call/cc` 与可变状态的交互：**堆不回滚，栈与寄存器回滚**。共享的 box / pair / 闭包自由变量槽里的可变单元，在 continuation 被 invoke 之后看见的是**最新一次赋值**；若错误地把 `set!` 做成未装箱的栈槽，invoke 会把赋值快照回去，典型症状是计数器死循环。

本层范围之外：新 IR、`dynamic-wind`、多值延续、把「栈槽 set!」做成合法的可观察语义（合同选择盒子持久）。实现若尚未对所有 `set!` 变量装箱，本层要求补上。

## 原理

### 恢复什么、不恢复什么

Invoke `_rt_full_cont` 时（L37）：

| 状态 | 是否回到捕获瞬间 |
|------|------------------|
| `SP` / `FP` / `LR` | 是 |
| 栈上每一个保存的 Scheme 字（局部槽、溢出参数、保存的 `SELF` 指针） | 是（随栈字节拷贝） |
| `x0` | 否：改成 invoke 的实参 `v` |
| `x22`（MV） | 置 `1` |
| `HP` / 堆对象内容 | **否** |
| 堆上 box 的一格、pair 的 car/cdr、vector 槽、string 字节 | **否**（保持 invoke 当下） |
| 闭包的 `fv` 槽 | 闭包在堆上：槽里的**指针**不回滚；若 fv 是 box 指针，盒子内容不回滚。栈拷贝可能把某个局部重新指向「捕获时的那个闭包」，但那仍是同一堆对象 |

因此：

- `(set-car! p …)`、`(%set-box! b …)`、对**已装箱**变量的 `set!`：invoke 之后仍在。
- 对**栈槽**变量的 `set!`：invoke 把槽写回旧立即数，赋值消失。
- 捕获前后 `cons` 出来的对象都还在（HP 不退）。被逃逸「放弃」的计算若曾把指针只放在已丢掉的寄存器里，对象成为垃圾，L51 才回收；本层不回收。

### 实现锁定（本层必须遵守）

L23 允许本地 `set!` 用栈槽。L26 规定「被 lambda 捕获且被 `set!`」才装箱。完整 `call/cc` 引入第三类：**未被 lambda 捕获、但被 continuation 跨越的 `set!` 变量**。若仍用栈槽，测例 3 会无限 `(k k)`。

本层起合同收窄为：

- **所有被 `set!` 的绑定一律分配 heap box**（L23 已有 `%box` / `%unbox` / `%set-box!`）。未 `set!` 的绑定仍可放栈槽。
- 前端在绑定处若看见 body 内有对该 id 的 `assign`，就分配 box，`ref` 变成 unbox，`assign` 变成 set-box!。
- 不要试图做「是否被 call/cc 跨越」的静态分析。

这样「最新赋值」语义稳定，与堆不回滚一致。

### 共享可变 box 与闭包

```scheme
(let ((b 0))
  (let ((inc (lambda () (set! b (fxadd1 b))))
        (rd  (lambda () b)))
    …))
```

`inc` 与 `rd` 的 fv 都是**同一个** box。`call/cc` 拷栈只会拷这两闭包的指针，不会拷盒子。从延续再入后 `rd` 看见 `inc` 写下的新值。

若错误地在捕获时把盒子内容复制进 continuation 对象，再入会「快照赋值」——本层禁止。continuation 对象只含栈字节与 SP/FP/LR，不含堆 DFS。

### `set!` 与「看见 k 的返回值」

```scheme
(let ((x 0))
  (set! x (call/cc (lambda (k) k)))
  …)
```

第一次 `x` 被设成延续；`(x 1)` 让 `call/cc` 返回 `1`，`set!` **再执行一遍**，`x` 变成 `1`。这不是回滚，是那段代码又跑了一次。测例必须区分：

- **同一段 `set!` 因再入而执行第二次**（控制流重放）；
- **第一次 `set!` 的效果在再入后还在**（堆持久）。

计数器放在 `set!` **之外**的 box 里最容易看清第二种。

### 实现改动清单（应很小）

1. 前端：所有 `set!` 变量装箱（若 L26 已做完全，本层零 diff）。
2. runtime：确认 `_rt_full_cont` 不写 `x19`。
3. 不要为 continuation 做深拷贝。
4. 没有新 prim。可选调试 prim `(%unbox b)` 已存在则够用。

若测例 3 死循环：先查变量是不是栈槽，再查 HP 是否被恢复。

## 与上一层的差异

- 用户可见语法不变。
- `set!` 装箱政策从「捕获才 box」改为「凡赋值都 box」。
- 回归集加重 continuation × 赋值。
- L37 的实现若已不回滚堆，后端可不动。

## 代码骨架

### 前端：赋值变量装箱

```scheme
(define (assigned-ids expr)
  ;; 收集 (set! id …) 的 id，含 lambda / letrec 体内
  …)

(define (let->ir bindings body env tail?)
  (let* ((ids (map car bindings))
         (asg (assigned-ids body))
         (boxed (filter (lambda (id) (memq id asg)) ids)))
    ;; 右值仍不在 box 里求值
    ;; 对 boxed：绑定 (id (prim box Ir))，ref 走 unbox
    …))
```

`lambda` 形参若在 body 里被 `set!`，入口把寄存器里的实参立刻 `%box` 进槽。

### 确认桩不回滚堆

```asm
; _rt_full_cont 中禁止：
;   ldr x19, [x9, #HP_OFF]
; L36 的那一行必须删除。
```

### 共享 box 的 IR 形状（示意）

```
(let ((b (prim box (imm 0))))
  (let ((k (call-cc (close …))))
    (seq
      (prim set-box! (ref b) (prim fxadd1 (prim unbox (ref b))))
      …)))
```

## 测例清单

上一层全部测例仍须通过。

1. **堆 pair 计数器，最新值**  
   `(let ((box (cons 0 '())))
      (let ((k (call/cc (lambda (c) c))))
        (set-car! box (fxadd1 (car box)))
        (if (fx< (car box) 3)
            (k k)
            (car box))))` → `3`

2. **`set!` 局部计数器（必须 box）**  
   `(let ((n 0))
      (let ((k (call/cc (lambda (c) c))))
        (set! n (fxadd1 n))
        (if (fx< n 3)
            (k k)
            n)))` → `3`  
   若 `n` 是栈槽：每次再入 `n` 回到 0，死循环或永不 `≥3`。

3. **两次 `set!`，中间 invoke**  
   `(let ((n 0))
      (let ((k (call/cc (lambda (c) c))))
        (set! n (fxadd1 n))
        (if (fx= n 1)
            (k 0)
            n)))` → `2`  
   第一次 n=1 后 `(k 0)` 使 `call/cc` 返回 `0`（绑定到 `k` 那个 `let` 的右值被**重新**求值成 0，`k` 不再是延续）。注意：`(let ((k (call/cc …))) …)` 再入会**重新绑定** `k` 为 `0`。`set! n` 在再入后跑第二次，n 从 1 到 2。→ `2`

4. **闭包共享 box：invoke 后另一闭包看见新值**  
   `(let ((b 0))
      (let ((inc (lambda () (set! b (fxadd1 b))))
            (get (lambda () b)))
        (let ((k (call/cc (lambda (c) c))))
          (inc)
          (if (fx< (get) 4)
              (k k)
              (get)))))` → `4`

5. **两个闭包交错 set!**  
   `(let ((b 0))
      (let ((a (lambda () (set! b (fx+ b 1))))
            (c (lambda () (set! b (fx+ b 10)))))
        (let ((k (call/cc (lambda (x) x))))
          (if (fx= b 0)
              (begin (a) (k k))
              (if (fx= b 1)
                  (begin (c) (k k))
                  b)))))` → `11`

6. **`set!` 的右值是 call/cc**  
   `(let ((x 0))
      (begin
        (set! x (call/cc (lambda (k) k)))
        (if (fixnum? x) x (x 42))))` → `42`  
   再入时 `set!` 把 `x` 写成 `42`。

7. **闭包 fv 是不可变捕获，旁边有独立 box**  
   `(let ((imm 100) (b 0))
      (let ((f (lambda () (fx+ imm b))))
        (let ((k (call/cc (lambda (c) c))))
          (set! b (fxadd1 b))
          (if (fx< b 2)
              (k k)
              (f)))))` → `102`  
   `imm` 不应被当成可变而回滚；`b` 最新为 2。

8. **嵌套 lambda set! 外层变量**  
   `(let ((n 0))
      (let ((k (call/cc (lambda (c) c))))
        ((lambda () (set! n (fxadd1 n))))
        (if (fx< n 3) (k k) n)))` → `3`

9. **vector-set! 持久**  
   `(let ((v (make-vector 1 0)))
      (let ((k (call/cc (lambda (c) c))))
        (vector-set! v 0 (fxadd1 (vector-ref v 0)))
        (if (fx< (vector-ref v 0) 3)
            (k k)
            (vector-ref v 0))))` → `3`

10. **string-set! 持久**（字符测例）  
    `(let ((s (make-string 1 #\a)))
       (let ((k (call/cc (lambda (c) c))))
         (if (eq? (string-ref s 0) #\a)
             (begin (string-set! s 0 #\b) (k 1))
             (string-ref s 0))))` → `#\b`

11. **set-cdr! 做计数表**  
    `(let ((p (cons 0 '())))
       (let ((k (call/cc (lambda (c) c))))
         (set-car! p (fxadd1 (car p)))
         (set-cdr! p (cons (car p) (cdr p)))
         (if (fx< (car p) 2)
             (k k)
             (cdr p))))` → `(2 1)`  
    再入不丢掉第一次 `cons` 到 cdr 上的 `1`。

12. **invoke 不撤销 call/cc 之后、invoke 之前的 set!**  
    `(let ((b 0) (p (cons #f '())))
       (let ((r (call/cc (lambda (k) (begin (set-car! p k) 0)))))
         (set! b (fxadd1 b))
         (if (fx= r 0)
             ((car p) 1)
             b)))` → `2`  
    第一次 b=1 后 invoke；再入 b 再加到 2。不是 1。

13. **被放弃的分支里的 set! 已经发生且持久**  
    `(let ((b 0))
       (call/cc (lambda (k)
         (begin (set! b 5) (k 1) (set! b 9))))
       b)` → `5`  
    `(set! b 9)` 未执行；`5` 在堆上留下。

14. **两个 continuation 共享一 box**  
    `(let ((b 0))
       (let ((ka (call/cc (lambda (k) k))))
         (if (fixnum? ka)
             b
             (let ((kb (call/cc (lambda (k) k))))
               (if (fixnum? kb)
                   b
                   (begin (set! b (fxadd1 b)) (ka 0)))))))` → `1`  
    `(ka 0)` 让第一个 `call/cc` 返回 0（fixnum），于是返回 `b`；`b` 已是 1，证明堆赋值未随内层延续回滚。

15. **`set!` 一个变量为闭包，再经 call/cc 传入**  
    `(let ((f 0))
       (set! f (lambda (k n)
                 (if (fx= n 0) k (f k (fxsub1 n)))))
       (let ((v (call/cc (lambda (k) (f k 5)))))
         (if (fixnum? v) v (v 42))))` → `42`

16. **非尾递归帧里的 set! + 再入**  
    `(let ((b 0))
       (letrec ((f (lambda (n)
                     (if (fx= n 0)
                         (call/cc (lambda (k) k))
                         (begin (set! b (fxadd1 b))
                                (fx+ 1 (f (fxsub1 n))))))))
         (let ((v (f 3)))
           (if (fixnum? v)
               (cons v b)
               (v 10)))))` → `(13 . 3)`  
    先 `f` 三次 `set!` 得 b=3，返回延续；`(v 10)` 最内层返回 10，三层 `fx+1` 得 13；`b` 仍为 3 不翻倍（再入不重做那三次 `set!`，因为它们在捕获点**之前**。捕获在 n=0 时，三次 set 已发生。再入只重做 `fx+1` 链。）  
    打印 pair：`(13 . 3)`。

17. **捕获点之后的 set! 在再入时会再跑**  
    `(let ((b 0))
       (let ((k (call/cc (lambda (c) c))))
         (set! b (fxadd1 b))
         (if (fx= b 1) (k k) b)))` → `2`

18. **eq? 同一 box**  
    `(let ((b (cons 0 '())))
       (let ((k (call/cc (lambda (c) c))))
         (if (fx= (car b) 0)
             (begin (set-car! b 1) (k b))
             (eq? k b))))`  
    `(k b)` 让 `call/cc` 返回那张 pair，绑定到 `k`。第二次 `k` 是 pair，`(car b)` 为 1，`(eq? k b)` → `#t`

19. **apply 再入仍看见 set!**  
    `(let ((n 0))
       (let ((v (call/cc (lambda (k) k))))
         (set! n (fxadd1 n))
         (if (fixnum? v) n (apply v '(0)))))` → `2`

20. **values 夹在赋值之间**  
    `(let ((n 0))
       (call-with-values
         (lambda () (begin (set! n 1) (values 2 3)))
         (lambda (a b) (begin (set! n (fx+ n a)) n))))` → `3`

21. **逃逸路径上的 set! 持久（完整 call/cc 同样）**  
    `(let ((n 0))
       (begin (call/cc (lambda (k) (begin (set! n 8) (k 1)))) n))` → `8`

22. **死循环检测（驱动超时即失败）**  
    测例 2 的 n=3 必须在有限步结束。实现若回滚 `n`，本测例是红灯。不要在实现里给循环加硬上限来假绿。

23. **L37 多次 invoke 计数仍过**  
    与 L37 测例 4 相同 → `3`

24. **未赋值的 let 绑定仍可在栈上（正确性）**  
    `(let ((a 1) (b 2))
       (let ((k (call/cc (lambda (c) c))))
         (if (fixnum? k)
             (fx+ a b)
             (k 0))))` → `3`  
    `a`、`b` 无 `set!`。再入后栈恢复它们为 1、2。

## 验收标准

- 测例 1–21、23–24 退出码 0，输出匹配；测例 2、4、17 不得超时/死循环。
- 所有 `set!` 变量经 box；可用反汇编 / IR 打印抽查测例 2 含 `box`/`set-box!`。
- `_rt_full_cont` 不加载捕获的 HP 到 `x19`。
- 没有新标签、没有新 IR 节点。
- 不引入新的 `x18` 用途；栈仍 16 字节对齐。
- 上一层全部测例仍须通过。

## 常见坑

- **只 box 被 lambda 捕获的变量**：测例 2 的 `n` 只被同一 `let` body `set!`，没有「嵌套 lambda 捕获」，L26 规则会漏掉。
- **把盒子建在栈上**：那仍是栈字节，会被拷贝回滚。box **对象**必须在堆上；栈槽只存带 `BOX_TAG` 的指针。
- **continuation 深拷贝堆**：invoke 看见旧 `car`，测例 1 返回 1 或死循环。
- **混淆「代码重跑」与「值回滚」**：`(set! x (call/cc …))` 再入会再执行 `set!`，这是控制流，不是堆回滚。
- **`(let ((k (call/cc …))) (k k))` 把 `k` 重新绑定**：再入后 `k` 不再是延续。计数器应放在该 `let` **之外**。
- **用 `eq?` 比较两次捕获的 continuation**：它们是两次分配，不必 `eq?`。测例不要依赖。
- **vector/string 测例失败只因 L16/L17 打印格式**：按已锁定的 `rt_print` 写期望。
- **为防死循环在 compiler 里限制递归次数**：那是假绿。

## 下一层预告

L39 加入 `dynamic-wind`：逃逸离开时仍要跑 `after`，从延续再进来时先跑 `before`，用一张 wind 栈对齐 R4RS。
