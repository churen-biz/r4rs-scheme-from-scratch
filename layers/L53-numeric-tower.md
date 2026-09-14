# L53 — 数值塔下一步：bignum

## 目标

用户层算术从「只有 62 位 fixnum」升级到 **任意精度整数（bignum）**。当 `fx+`/`fx*` 等在 62 位有符号范围溢出时，**无前缀**的 R4RS 运算 `+` `-` `*` `=` `<` 提升为堆上 bignum；若结果又变小，**规范化回 fixnum**。`number?` 与 `integer?` 对 fixnum 与 bignum 皆真。

打印：`rt_print` / `write` 把 bignum 打成十进制（负号、无前导零，零就是 `0`）。

本层 **明确不做**：

- **flonum / inexact / 浮点**（不占用标签，不写 IEEE 堆对象）。
- **有理数**与 `/` 的精确分数结果（`/` 本层可缺失或仅在整除时返回整数；锁定：**不提供 `/`**，调用编译期或运行时错误）。
- `complex?`/`real?`/`rational?` 的完整塔（见 L54 清单）。
- `exact->inexact`、`sqrt` 等。

`fx+` `fx*` 等 **保持** L07 语义：只接受 fixnum，溢出可绕回或报错——锁定：**fx 运算溢出运行时错误**（stderr 含 `fixnum`），不悄悄变 bignum。提升只发生在 **无前缀** `+` `-` `*`。

## 原理

### 标签：复用 vector 头判别

3-bit 标签已用尽（ARCHITECTURE §2）。本层 **不新占指针标签**。bignum 使用 `VECTOR_TAG`，但首字不是长度 fixnum，而是立即数魔数：

```
BIGNUM_HDR = 0x7F        /* 低 3 位 111，未与 #f/#t/()/char/void/eof 冲突 */
```

布局（去标签裸指针）：

```
[ header: BIGNUM_HDR ][ sign: fixnum ][ ndigits: fixnum ][ d0 ][ d1 ] … [ d(n-1) ]
```

- `sign`：`1` 正，`-1` 负，**零不出现 bignum**（规范成 fixnum `0`）。
- `d0` 是最低 32 位数字；`di` 存在 64-bit 槽的低 32 位，高 32 位为 0（**不是** tagged fixnum，以便 32-bit 进位加法直接做）。
- `ndigits ≥ 1`；最高位 `d(n-1) ≠ 0`。

`vector?` 必须收紧，否则 bignum 会被当成 vector：

```
vector?  : (x & 7) == VECTOR_TAG  &&  *untag(x) 是 fixnum（低 2 位 00）
bignum?  : (x & 7) == VECTOR_TAG  &&  *untag(x) == BIGNUM_HDR
```

这是对 L16 `vector?` 的合法收紧：旧测例的 vector 头都是 fixnum 长度，不受影响。`objkind` 写 `K_BIGNUM = 8`，GC 按 bignum 扫：header/sign/ndigits 不是堆指针；`di` 是裸 uint32，**不要** `mark_value`。`object_size = 8 * (3 + ndigits)`。

### 范围与提升

fixnum 有效值 `[-2^61, 2^61 - 1]`。转换：

```c
ptr fixnum_to_bignum(int64_t n); /* n 已是未标签整数，非 0 */
int64_t bignum_try_to_fixnum(ptr b); /* 装得下则返回值，否则哨兵 */
ptr normalize(ptr n); /* fixnum 原样；bignum 小则变 fixnum */
```

`+` 的路径：

```
number_add(a, b):
    若两者都是 fixnum:
        用 64 位或 128 位加法算未标签和 s
        若 s 在 fixnum 范围：返回 s << 2
        否则 return normalize(bignum_from_sum)
    否则：把 fixnum 提升为 bignum，做无符号 digits 加减（按符号），normalize
```

检测溢出不要用「tagged `add` 再看 V 标志就当结果正确」单独一条路——tagged 加法在越过 62 位时低 64 位会绕回，V 标志可用，但还要处理负范围。推荐 **先算术右移得到真整数，用 `__int128` 加乘，再判断范围**（C 运行时原语）。汇编 `+` 不要内联成 `add x0, x1, x2`。

锁定用户层原语走 C：

```c
ptr rt_num_add(ptr a, ptr b);
ptr rt_num_sub(ptr a, ptr b);
ptr rt_num_mul(ptr a, ptr b);
ptr rt_num_eq(ptr a, ptr b);   /* #t / #f */
ptr rt_num_lt(ptr a, ptr b);
ptr rt_numberp(ptr a);
ptr rt_integerp(ptr a);        /* 本层与 number? 相同 */
```

`>` `<=` `>=` 用 `lt`/`eq` 组合，可在 prelude 用 Scheme 写，或 C 里同样提供。本层强制 C 实现 `+ - * = <`；`>` `<=` `>=` 至少可用 prelude：

```scheme
(define (>  a b) (< b a))
(define (<= a b) (if (< b a) #f #t))  ; 或 (not (< b a)) 再处理 = 
```

`<=` 对整数是 `(or (< a b) (= a b))`。零参数/多参数 `+`：R4RS `(+)` 为 0、`(+ a)` 为 a、`(+ a b c …)` 左结合。本层锁定 **可变 arity 在前端展开成二元 `rt_num_add` 链**；`(+)` → `(imm 0)`。

### digits 算法（32-bit little-endian）

加法（同号）：从 `d0` 进位，可能增长 1 位。异号：比较绝对值，大的减小的。乘法：学校算法 O(n²)，n 在测例里很小（几步乘即可到 > 2^61）。比较：先比符号，再比 ndigits，再从高位比 `di`。

规范化：去掉高位 0；若 `ndigits==1` 且值与符号能放进 int64 再进 62 位范围，返回 fixnum。`2^61` 必须保持 bignum（上限是 `2^61 - 1`）。

### 打印

```c
void print_bignum(ptr x) {
    /* 不修改原对象：在 C 栈或 malloc 的临时 digits 上反复 /10 得到十进制 */
}
```

不要用 `double` 转打印。零不出现。负号在数字前。`write` 与 `rt_print` 同一路径。

### `number?` / `integer?`

```
number?   = fixnum? OR bignum?
integer?  = 同上   /* 本层没有非整数 */
```

`rational?` `real?` `complex?` 本层 **不提供**（L54 再标明不做或别名）。

### GC

`rt_alloc(..., K_BIGNUM)`。mark：无子 Scheme 指针。compact：整块 `memmove`，无内部 tagged 槽。不要把 `di` 当指针。

### 与 L42 `+` 别名的关系

合同：L42 曾让 `+` 在只有 fixnum 时转发 `fx+`。本层 **替换** 该转发为 `rt_num_add`。旧测例 `(+ 1 2)` 仍为 `3`。溢出测例是新的。

## 与上一层的差异

- 新堆种类 `K_BIGNUM`，判别靠 vector 标签 + `0x7F` 头。
- `vector?` 收紧。
- 用户 `+ - * = <` 可变 arity，走 C；`fx*` 族不变。
- `rt_print`/`write` 认识 bignum。
- 无浮点、无 `/`。

## 代码骨架

### scheme.h

```c
#define BIGNUM_HDR 0x7F
#define K_BIGNUM 8

int is_bignum(ptr x);
int64_t fx_untag(ptr x); /* 调用前须 fixnum? */
```

### 判别与 vector?

```c
int is_vector(ptr x) {
    if ((x & 7) != VECTOR_TAG) return 0;
    ptr h = *(ptr *)(x - VECTOR_TAG);
    return (h & 3) == 0; /* fixnum length */
}
int is_bignum(ptr x) {
    if ((x & 7) != VECTOR_TAG) return 0;
    ptr h = *(ptr *)(x - VECTOR_TAG);
    return h == BIGNUM_HDR;
}
```

汇编 `vector?` 同步加「头是 fixnum」比较，否则测例里对 bignum 做 `vector?` 会假真。

### 构造

```c
ptr make_bignum(int sign, uint32_t *ds, int n) {
    while (n > 1 && ds[n-1] == 0) n--;
    if (n == 1 && ds[0] == 0) return 0; /* fixnum 0 */
    /* 试 fit 62-bit */
    __int128 v = 0;
    int i;
    for (i = n - 1; i >= 0; i--) v = (v << 32) | ds[i];
    if (sign < 0) v = -v;
    if (v >= -((__int128)1 << 61) && v < ((__int128)1 << 61))
        return (ptr)((int64_t)v << FX_SHIFT);
    ptr raw = rt_alloc(8ull * (3 + n), K_BIGNUM);
    ptr *w = (ptr *)raw;
    w[0] = BIGNUM_HDR;
    w[1] = (ptr)((int64_t)sign << FX_SHIFT);
    w[2] = (ptr)((int64_t)n << FX_SHIFT);
    for (i = 0; i < n; i++) w[3 + i] = (ptr)(uint64_t)ds[i];
    return raw | VECTOR_TAG;
}
```

### 加法入口

```c
ptr rt_num_add(ptr a, ptr b) {
    if (!is_number(a) || !is_number(b)) rt_error("+ : not a number");
    if (is_fixnum(a) && is_fixnum(b)) {
        __int128 s = (__int128)fx_untag(a) + fx_untag(b);
        if (s >= -((__int128)1 << 61) && s < ((__int128)1 << 61))
            return (ptr)((int64_t)s << FX_SHIFT);
    }
    return bignum_add(to_bignum_digits(a), to_bignum_digits(b));
}
```

### 打印

```c
static void print_u32_decimal(ptr x) {
    /* 从最高有效 digit 输出；若用反复除 10，复制 digits 到 tmp[] */
    if (is_fixnum(x)) { printf("%lld", (long long)(x >> 2)); return; }
    ptr *w = (ptr *)(x - VECTOR_TAG);
    if ((w[1] >> 2) < 0) putchar('-');
    int n = (int)(w[2] >> 2);
    uint32_t tmp[n];
    int i;
    for (i = 0; i < n; i++) tmp[i] = (uint32_t)w[3 + i];
    char buf[n * 10 + 4];
    int len = 0;
    for (;;) {
        int all0 = 1;
        uint64_t rem = 0;
        for (i = n - 1; i >= 0; i--) {
            uint64_t cur = (rem << 32) | tmp[i];
            tmp[i] = (uint32_t)(cur / 10);
            rem = cur % 10;
            if (tmp[i]) all0 = 0;
        }
        buf[len++] = (char)('0' + rem);
        if (all0) break;
    }
    while (len--) putchar(buf[len]);
}
```

### 前端

```scheme
(define (expand-plus args)
  (cond
    ((null? args) `(imm 0))
    ((null? (cdr args)) (expr->ir (car args)))
    (else
     `(prim num+ ,(expr->ir (car args))
                  ,(expand-plus (cdr args))))))
```

`num+`/`num-`/`num*`/`num=`/`num<` 为 IR prim 名。`emit-prim`：求值两参数，`mov` 到 `x0`/`x1`，`bl _rt_num_add`。注意 C ABI 会弄脏 caller-saved，按 L51 保存 HP/SELF。

二元减：`(- a)` 是变号；`(- a b c)` 为 `((a-b)-c)`。`(-)` 零参数：R4RS 错误。锁定：`(-)` 编译期 arity 错。

## 测例清单

上一层全部测例仍须通过。

1. **仍是小整数** `(+ 1 2)` → `3`

2. **(+) 零参数** `(+)` → `0`

3. **三操作数** `(+ 1 2 3)` → `6`

4. **减法** `(- 5 2)` → `3`；`(- 5)` → `-5`

5. **乘法** `(* 6 7)` → `42`；`(*)` → `1`（R4RS）

6. **比较** `(< 1 2)` → `#t`；`(= 3 3)` → `#t`；`(= 3 4)` → `#f`

7. **fixnum 上界仍是 fixnum**  
   输入字面量 `2305843009213693951`（即 `2^61 - 1`）→ 打印该数。`number?` 为 `#t`。

8. **+ 溢出提升**  
   `(+ 2305843009213693951 1)` → `2305843009213693952`

9. **负向溢出**  
   `(+ -2305843009213693952 -1)` → `-2305843009213693953`  
   （`-2^61` 是最小 fixnum，再减 1 必须 bignum。）

10. **乘法溢出**  
    `(* 2147483648 2147483648)` → `4611686018427387904`（`2^31 * 2^31 = 2^62`，超出 62 位有符号）

11. **规范化回 fixnum**  
    `(- (+ 2305843009213693951 5) 5)` → `2305843009213693951`  
    随后 `(fixnum? …)` → `#t`  
    ```scheme
    (fixnum? (- (+ 2305843009213693951 5) 5))
    ```  
    → `#t`

12. **bignum 不是 vector**  
    `(vector? (+ 2305843009213693951 1))` → `#f`

13. **number? integer?**  
    ```scheme
    (list (number? 3)
          (number? (+ 2305843009213693951 1))
          (integer? (+ 2305843009213693951 1))
          (number? #t))
    ```  
    → `(#t #t #t #f)`

14. **= 跨表示**  
    `(= (+ 2305843009213693951 1) (+ 2305843009213693951 1))` → `#t`  
    `(= 1 (+ 2305843009213693951 1))` → `#f`

15. **< 跨表示**  
    `(< 2305843009213693951 (+ 2305843009213693951 1))` → `#t`

16. **GC 后 bignum 仍在**  
    ```scheme
    (let ((n (+ 2305843009213693951 9)))
      (%gc)
      n)
    ```  
    → `2305843009213693960`

17. **fx+ 不提升**  
    `(fx+ 2305843009213693951 1)` → **运行时错误**。`017-err-fx-overflow.scm`

18. **`/` 不做**  
    `(/ 4 2)` → **编译期或运行时错误**。`018-err-slash.scm`

19. **非数** `(+ 1 #t)` → **运行时错误**。`019-err-add-not-number.scm`

20. **负 bignum 打印**  
    `(- 0 (+ 2305843009213693951 3))` → `-2305843009213693954`

21. **可变 arity 减** `(- 10 1 2 3)` → `4`

## 验收标准

- 测例 1–16、20、21 退出码 0，十进制打印无前导零、无小数点。
- 测例 17–19 非 0。
- `vector?` 对 bignum 为假；旧 vector 测例仍绿。
- 不存在 flonum 堆对象或 `0.5` 字面量支持。
- `fx+` 溢出不返回 bignum。
- bignum 经 L51/L52 GC 安全（测例 16）。

## 常见坑

- **`vector?` 只看标签**：库函数 `vector-ref` 打到 bignum 头上当 length，会把 `0x7F` 当 fixnum 或崩溃。
- **digits 存成 fixnum**：32-bit 满值 `2^32-1` 左移 2 超出 62 位。必须裸 uint32。
- **用 `double` 打印**：大整数丢失低位，测例 8 对不上。
- **零的 bignum 对象**：`eq?`/`=` 与 fixnum `0` 分叉；打印 `-0`。normalize 掉。
- **tagged `add` 当 `+`**：测例 8 绕回成负数 fixnum。
- **GC 跟随 digit 字**：`di` 低 3 位碰巧为 `001` 会当 pair 跟飞。
- **`(+)` 当 arity 错误**：R4RS 是 0。
- **字面量 `2305843009213693952` 在 reader**：L43 若只收 fixnum，大字面量应在 read 时建成 bignum，或编译期 `error`。锁定：**reader 与立即数前端把超出 62 位的整数字面量建成 bignum 常量**（编译期 `make_bignum` 或运行时一次构造）。测例 8 用 `(+ 大fixnum 1)` 避免「字面量路径」；另加测例 8b 可选直接写大字面量。必过仍是测例 8 的加法形式。

## 下一层预告

L54 对照 R4RS 库，列出已有、本层补上、以及明确不做的项；并实现一小撮强制填料（named let、`do`、`delay`/`force`、字符串与整除）。
