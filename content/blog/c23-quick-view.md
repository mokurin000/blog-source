+++
title = "C23特性简介"
slug = "c23-quickview"
date = "2026-06-04"

[taxonomies]
tags = ["C"]
+++

C23（ISO/IEC 9899:2024）是 C 语言的最新正式修订版，`__STDC_VERSION__` 定义为 `202311L`。它引入了许多提升可读性、安全性、与 C++ 兼容性和现代浮点/整数支持的功能，同时移除或废弃了一些过时特性。

### 核心语言特性

#### 属性（Attributes）
C23 采用 C++11 风格的双中括号属性语法 `[[...]]`，并新增/标准化多个属性。

- `[[nodiscard]]`（带或不带消息）
- `[[maybe_unused]]`
- `[[deprecated]]`（带或不带消息）
- `[[fallthrough]]`
- `[[noreturn]]`
- `[[unsequenced]]` 和 `[[reproducible]]`（用于函数优化提示）

**示例代码**：
```c
[[nodiscard("检查返回值")]]
int create_resource(void);

void process(void) {
    [[maybe_unused]] int unused_var = 42;
    switch (x) {
        case 1:
            [[fallthrough]];
        case 2:
            // ...
    }
}
```

#### 二进制整数常量和数字分隔符
支持 `0b` / `0B` 前缀的二进制字面量，以及 `'` 作为数字分隔符。

**示例代码**：
```c
int flags = 0b1010'1100;
long big = 1'000'000'000;
double pi_approx = 3.141'592'653;
```

#### `static_assert` 简化与关键字化
`static_assert` 现在支持单参数形式（无消息），且成为关键字（兼容宏仍可能存在）。

**示例代码**：
```c
static_assert(sizeof(int) >= 4);  // 无消息版本
static_assert(CHAR_BIT == 8, "字节必须为 8 位");
```

#### `nullptr` 常量和 `nullptr_t` 类型
引入 `nullptr` 关键字和对应的 `nullptr_t` 类型，提升空指针安全性。

**示例代码**：
```c
#include <stddef.h>

nullptr_t np = nullptr;
int* p = nullptr;  // 更清晰
```

#### `true` / `false` 成为关键字
`bool`、`true`、`false` 正式标准化（兼容旧 `_Bool` 等）。

**示例代码**：
```c
bool flag = true;
if (flag == false) { /* ... */ }
```

#### 类型推断 `auto`（对象定义）
`auto` 用于对象定义时进行类型推断（保留原有存储类说明符语义）。仅限对象定义，不支持函数返回类型或参数推断。

**示例代码**：
```c
auto x = 42;           // int
auto y = 3.14;         // double
auto str = "hello";    // const char*
auto arr = (int[]){1,2,3};  // 复合字面量
```

#### `typeof` 和 `typeof_unqual`
类型查询运算符，支持 `unqual` 去除限定符。

**示例代码**：
```c
int i = 10;
typeof(i) j = i;                    // int j
typeof_unqual(const volatile int) k; // int k
```

#### 位精确整数类型 `_BitInt(N)`
精确指定位宽的整数类型（`_BitInt(N)` 和 `unsigned _BitInt(N)`），支持 `wb`/`uwb` 后缀。

**示例代码**：
```c
_BitInt(24) precise24 = 0xABCDEFwb;
unsigned _BitInt(16) u16 = 65535uwb;

_BitInt(128) big = 1;  // 支持大位宽
```

#### 空初始化器 `{}`
支持使用 `{}` 进行零初始化（包括 VLA）。

**示例代码**：
```c
int arr[10] = {};          // 全零
struct S s = {};
int n = 5;
int vla[n] = {};           // VLA 也支持
```

#### 其他语言改进
- 标签可置于声明之前和复合语句末尾。
- 函数定义中允许未命名参数。
- 移除无原型函数定义/声明（K&R 风格废弃）。
- `#elifdef` / `#elifndef`、`#warning`、`__has_include`、`__has_c_attribute`、`__VA_OPT__` 等预处理器增强。
- `#embed` 指令（嵌入二进制资源）。
- `constexpr` 对象（非函数）。
- `u8` 字符常量和字符串字面量类型改为 `char8_t`。
- 十进制浮点类型（`_Decimal32` 等，可选）。

**示例代码**（预处理器）：
```c
#if __has_include(<stdbit.h>)
#  include <stdbit.h>
#else
#  warning "stdbit.h not available"
#endif
```

### 标准库更新

#### `<limits.h>` 新增位宽常量
新增一系列 `*_WIDTH` 宏，用于标准整数类型的位宽。

**示例代码**：
```c
#include <limits.h>

printf("int 位宽: %d\n", INT_WIDTH);
printf("bool 位宽: %d\n", BOOL_WIDTH);
printf("long long 位宽: %d\n", LLONG_WIDTH);
```

#### `<math.h>` 新增 `nextup` / `nextdown` 系列
`nextup`、`nextupf`、`nextupl`、`nextdown`、`nextdownf`、`nextdownl`：返回大于/小于给定值的下一个可表示浮点值。

**示例代码**：
```c
#include <math.h>

double x = 1.0;
double next = nextup(x);      // 大于 1.0 的下一个可表示值
float fnext = nextdownf(0.0f); // 小于 0.0f 的下一个可表示值
```

#### 其他库特性
- `memset_explicit()`：安全清除敏感内存（防止优化消除）。
- `<stdbit.h>`：位操作工具（如 `stdc_count_ones()` 等）。
- `<stdckdint.h>`：带溢出检查的整数运算宏（`ckd_add` 等）。
- 扩展的 `printf`/`scanf` 支持（`%b` 二进制、`%wN` 宽度修饰符等）。
- UTF-8 支持增强（`char8_t`、`mbrtoc8` 等）。
- 更多 IEEE 754 兼容函数和十进制浮点支持。

### 废弃/移除特性
- K&R 无原型函数定义/声明。
- 三字符序列（trigraphs）。
- 非二补码有符号整数表示。
- 某些旧特性测试宏和 `<stdnoreturn.h>` 等。
- `NAN`, `INFINITY` 等常数的 `<math.h>` 定义废弃，现移动至 `<float.h>`。
