# L02 — 布尔立即数 `#t` `#f`

## 目标

语言增加两个立即数对象 `#t` 和 `#f`。它们**不是** fixnum，低 8 位分别为 `0x6F` 与 `0x2F`。`rt_print` 打印 `#t` / `#f`（R4RS `write` 风格，本层先用这个）。

本层仍无 `if`、无 `not`、无变量。程序仍是「单个字面量」。

本层范围之外：把 0/1 当布尔、`#true`/`#false` 读法（那是 R7RS）、`if` 的假值规则（L10 才执行分支）。

## 原理

### 编码

立即数族共享低 3 位 `111`，再用低 8 位区分对象：

```
BOOL_F = 0x2F = 0b00101111
BOOL_T = 0x6F = 0b01101111
差     = 0x40 = bit 6
```

与 fixnum 不冲突：fixnum 低 2 位是 `00`，布尔低 2 位是 `11`。

选择这组魔数是为了和 Ghuloum 论文、许多教学实现对照；不要改成 `0`/`1`，否则 L10 会有人把「整数 0 当假」——那不是 Scheme。

### IR

```
#t → (imm 0x6F)
#f → (imm 0x2F)
```

前端：

```scheme
(define BOOL_F #x2F)
(define BOOL_T #x6F)

(define (expr->ir expr)
  (cond
    ((eq? expr #t) `(imm ,BOOL_T))
    ((eq? expr #f) `(imm ,BOOL_F))
    ((fixnum-range? expr) `(imm ,(* expr 4)))
    (else (error "L02: bad literal" expr))))
```

宿主 Scheme 的 `#t`/`#f` 必须用 `eq?` 识别，不要用 `equal?` 去比字符串 `"#t"`。

### 打印

```c
#define BOOL_F 0x2F
#define BOOL_T 0x6F

void rt_print(ptr x) {
    if ((x & 3) == 0) { printf("%lld\n", (long long)(x >> 2)); return; }
    if (x == BOOL_T) { printf("#t\n"); return; }
    if (x == BOOL_F) { printf("#f\n"); return; }
    rt_error("L02: unprintable value");
}
```

用 `==` 比满字，不要只看低 8 位就当布尔——以免将来其它立即数低 8 位碰巧撞上。合同规定这两个值高 56 位必须为 0。`emit-imm` 已保证。

### 为何本层不做 `if`

`if` 需要标签、跳转、两个子树求值。Ghuloum 把控制结构放在立即数与一元原语之后，是为了先把 **值在寄存器里的形状** 钉死。本层只扩展「程序是一个常量」的常量集合。

## 与上一层的差异

- 前端多两条字面量。
- `rt_print` 多两个满字比较。
- `scheme.h` 增加 `BOOL_F` `BOOL_T`。
- 汇编侧：无新指令；仍走 `emit-imm`。

## 代码骨架

把常量同时写进编译器与 `scheme.h`，数值必须相同。建议编译器顶部：

```scheme
(define BOOL_F 47)   ; 0x2F
(define BOOL_T 111)  ; 0x6F
```

或从一份共享表格生成。不要一边写 `#x2F` 一边在 C 写 `47` 还算错。

aarch64 无特殊点：`0x6F` 很小，`movz` 即可。

## 测例清单

上一层全部测例仍须通过。

1. `#t` → `#t`
2. `#f` → `#f`
3. `0` → `0`（回归：零不要打印成 `#f`）
4. `1` → `1`
5. `-1` → `-1`
6. 输入 `#t` 的二进制返回值不得等于 `1<<2`。可用一个调试测例：暂时让 runtime 打印原始字（不要留在默认 `rt_print`）。或在编译器单测里断言 `(imm 111)`。
7. 非法字面量 `'foo`（若 reader 还没有，驱动不要喂）：编译期错误。
8. 输入 `(if #t 1 2)`：编译期拒绝（本层无 `if`）。

## 验收标准

- `#t`/`#f` 打印形式恰好三字符加换行，无空格。
- `0` 与 `#f` 输出不同。
- `scheme.h` 与编译器常量一致。
- 未实现 `if`：输入 `(if #t 1 2)` 必须编译期拒绝，不能碰巧返回 1。

## 常见坑

- **把 `#f` 编码成 0**：立刻与 fixnum 0 冲突，L10 会把 `0` 当假。
- **打印 `true`/`false`**：测例按 Scheme 字面量。
- **`#T` 大写**：本层 reader 尚未自写；宿主 `read` 通常大小写不敏感。测例文件用小写 `#t`。
- **C 里 `ptr` 与 `#define BOOL_T 0x6F` 比较时符号扩展**：`0x6F` 为正，无此问题。以后 `EMPTY_LIST` 同样是正的小常数。

## 下一层预告

L03 加入空表 `()`，编码 `0x3F`，打印 `()`。
