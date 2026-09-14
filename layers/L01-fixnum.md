# L01 — 定点数立即数与标签

## 目标

编译器真正读入一个 Scheme **fixnum 字面量**（小整数），把它编码成带标签的 64 位字，放进 `x0` 返回。`rt_print` 识别 `FX_TAG`，右移 `FX_SHIFT` 位，打印十进制（含负号）。

L00 的管道、两参数入口、`_scheme_entry` 序言/跋保持不动。本层结束后，系统是「只能跑一个整数常量的 Scheme」。仍是纯汇编 runtime：只改 `_rt_print` 的解码，不引入 C。

本层范围之外：布尔、字符、空表、算术、溢出检测、bignum。超出 62 位有效精度的字面量：本层可在编译期 `error`，不必生成代码。

## 原理

### 为何要标签

同一个 64 位寄存器以后会放指针、`#f`、字符。若整数占用全部 64 位，运行时无法区分「整数 0」和「空指针」。Ghuloum 的办法：把类型信息放进低位，让 **fixnum 的低 2 位恒为 `00`**。

合同（与 ARCHITECTURE §2 一致）：

```
FX_SHIFT = 2
FX_TAG   = 0b00
编码：  tagged = (sint64_t)n << 2
解码：  n      = tagged >> 2     ; 算术右移，保留负号
谓词：  (x & 0b11) == 0
```

62 位有符号范围：`[-2^61, 2^61 - 1]`。在 64 位移位时用**有符号**类型，避免 `-1` 变成巨大无符号数。

选择低 2 位而不是 3 位：堆对象对齐 8 字节，有 3 个自由位；fixnum 故意只占 2 位，使得 `fx+` 可以直接 `add` 两个已标签值（`(a<<2)+(b<<2) = (a+b)<<2`），不必先解码。这是 L07 的伏笔，本层按这个编码实现即可。

### 立即数加载（aarch64-apple）

`-1` 的标签值是 `0xFFFFFFFFFFFFFFFC`。一条 `mov x0, #imm` 装不下任意 64 位。后端必须实现通用 `emit-imm`：

```
movz x0, #:abs_g0_nc:IMM
movk x0, #:abs_g1_nc:IMM
movk x0, #:abs_g2_nc:IMM
movk x0, #:abs_g3:IMM
```

或等价的 16-bit 切片 `imm & 0xFFFF`、`(imm>>16)&0xFFFF`… Apple 的 `as` 接受 `movz x0, #0xFFFC` + `movk`。也可对小正整数走快路径 `mov x0, #n`。**快路径不能替代通用路径**：测例含负数与较大正数。

这是芯片相关细节；IR 仍然只是 `(imm tagged-u64)`。

### 前端

```
输入 expr 为整数对象（宿主 Scheme 的 integer）
→ 检查在 fixnum 范围内
→ IR: (imm (ash n FX_SHIFT))
```

若宿主把 `42` 读成自己的 bignum，只要能 `ash` 就行。不要在前端把整数先变成字符串再解析一遍，除非你还没有 reader（本层测试驱动可以直接 `read` 一个 datum）。

### 打印

`rt_print` 现在：若 `(x & 3) == 0`，打印 `(x >> 2)` 的十进制，后面换行。其它标签本层不应出现；若出现，打印 `#<unknown>` 并 `exit(1)` 比默默当整数打印更安全——否则以后 boolean 假绿。

L00 测例「返回裸 42」**不再合法**：同一条管道现在返回的是标签值 `168`，打印仍是 `42`。更新 L00 的 `.expected` **不要改**——L00 输入仍被忽略的话会错。正确做法：从 L01 起 **L00 测例改为输入 `42` 这个字面量**，期望仍 `42\n`。也就是：L00 测例 1 在 L01 被「升级」为真正的 fixnum 程序。若你想保留「忽略输入」的考古测例，把它移出回归，或让 L01 驱动不再跑那个忽略输入的版本。

合同：**回归集从 L01 起，每个测例文件都是一个合法的当前语言程序。** L00 的「忽略输入」只用于验收管道，不进入 L01+ 回归。在 `tests/L00/` 标注：`001` 在 L01 之后由 `tests/L01/001-zero.scm` 等取代回归职责；L00 目录可留作手工管道检查。更干净的做法（推荐）：L00 的 `001-fixed-return.scm` 内容写成 `42`，L00 实现忽略它但仍打印 42；L01 开始解释该文件，输出不变。这样回归文件不用改。**请用这一做法。**

## 与上一层的差异

| 项 | L00 | L01 |
|----|-----|-----|
| 返回值 | 裸 `42` | `(n << 2)` |
| 前端 | 忽略输入 | 输入必须是整数字面量 |
| `rt_print` | 当裸整数 | 识别 fixnum 标签并解码 |
| `emit-imm` | 小正 `mov` | 通用 64-bit 装载 |

## 代码骨架

### 可移植：前端

```scheme
(define FX_SHIFT 2)

(define (fixnum-range? n)
  (and (integer? n)
       (<= (- (expt 2 61)) n (- (expt 2 61) 1))))

(define (expr->ir expr)
  (cond
    ((fixnum-range? expr)
     `(imm ,(ash expr FX_SHIFT)))
    (else (error "L01: expected fixnum literal" expr))))
```

### aarch64-apple：通用立即数

```scheme
(define (u16 n k) (modulo (quotient n (expt 2 (* k 16))) 65536))

(define (emit-imm tagged)
  ;; tagged 视为无符号 64 位
  (string-append
    "\tmovz x0, #" (number->string (u16 tagged 0)) "\n"
    "\tmovk x0, #" (number->string (u16 tagged 1)) ", lsl #16\n"
    "\tmovk x0, #" (number->string (u16 tagged 2)) ", lsl #32\n"
    "\tmovk x0, #" (number->string (u16 tagged 3)) ", lsl #48\n"))
```

负标签在 Scheme 里可能是负的 host 整数：先映射到 `[0, 2^64)` 再切片，或对每个切片用 `bitwise-and`。

### runtime 汇编：解码打印

`_rt_print`（`x0` = 值）改成：

```
FX_SHIFT = 2
FX_TAG_MASK = 3
若 (x0 & 3) == 0：
    asr x0, x0, #2          ; 有符号右移，保留负号
    按 L00 的十进制路径 SYS_write 到 stdout，末尾 '\n'
否则：
    adr x0, 消息 "L01: unprintable value"
    bl _rt_error            ; 永不返回
```

算术右移必须用 `asr`，不要 `lsr`。`lsr` 会把 `-1` 的标签变成巨大正数。标签常量写在编译器与 `runtime.s` 注释，与 ARCHITECTURE 数值一致。没有 `scheme.h` / C 头文件。

## 测例清单

上一层全部测例仍须通过：L00 的 `001` 在文件内容为 `42` 时输出仍为 `42\n`。

1. `0` → `0`
2. `1` → `1`
3. `42` → `42`
4. `-1` → `-1`
5. `-42` → `-42`
6. `256` → `256`
7. `65535` → `65535`
8. `268435455` → `268435455`（2^28-1，逼出 `movk`）
9. `-268435456` → `-268435456`
10. 编译期错误：符号 `foo` 或 `()` 不是 fixnum。期望：编译器非零退出，不生成可执行文件（或生成但不链接）。不要在运行时才炸。

## 验收标准

- 测例 1–9 输出与十进制字面量一致，含负号、无空格、末尾一个换行。
- `nm` 看生成代码：对大常数出现 `movz`/`movk`（或等价）。
- `rt_print` 对低 2 位非 0 的值不静默当整数打印。
- 标签常量与 `runtime.s` 注释、`ARCHITECTURE.md` 数值一致。

## 常见坑

- **逻辑右移**：无符号右移把 `-1` 的标签变成巨大正数。必须 `asr`。
- **只测了 42**：小正整数用一条 `mov` 就过，负数会在 L01 测例 4 失败。
- **宿主 `ash` 对负数**：R5RS `arithmetic-shift` 对负移位才是右移；左移负数应保持二补码。Chez/Guile 通常正确。用 `* 4` 代替 `ash n 2` 更不易错。
- **打印多了空格**：`42 \n` 会让 `diff` 失败。
- **提前实现 `#t`**：不要。本层未知标签应报错，方便发现 IR 发错。

## 下一层预告

L02 增加立即数 `#t` `#f`：低 8 位编码，与 fixnum 的低 2 位模式不冲突。
