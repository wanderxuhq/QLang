# QLang → LLVM AOT 编译器(编译器与运行时全 QLang)设计

- **日期**:2026-08-14
- **状态**:待评审
- **范围**:新子系统 —— QLang 源代码 → LLVM IR(文本)→ 各平台原生可执行文件;编译器本体用 QLang 写;编译产物的运行时语义层用 QLang 实现
- **目标**:产出可独立运行的原生二进制;宿主依赖压到"仅 LLVM 自带工具链 + 极薄 C 垫底";保持与既有 host/boot 解释器的字节级一致验证纪律

## 硬性约束(Global Constraints)

1. **编译器用 QLang 写**。qlangc 的源码是 `.ql`,逻辑全部是 QLang 数据与 QLang 函数。
2. **编译产物的运行时语义层用 QLang 实现**("QLang 的数据必须用 QLang 的"):字符串/数组/对象/JSON/Error/Math 等语义全部由编译进产物的 QLang 代码承担;不链接任何 host stdlib 原生函数。
3. **只允许一层极薄机制垫底**(leaf,见 §6):`alloc/free/write/exit/mem8/mem64` 级别的原始机制,相当于"给 QLang 一块 libc 形状的地基"。垫底不实现任何语言语义。
4. **编译驱动不新增 native**。`--compile` 由现有 host CLI 承载,零新原生函数;qlangc 的输出经 stdout 捕获。
5. **宿主工具链依赖最小**:目标平台只要求 LLVM 自带工具链(`llc`/`clang`/`lld`);**不要求 gcc / build-essential / MSVC / Windows SDK**。产物链接仅依赖 libc 级三五个符号或纯 syscall。
6. **验证纪律不变**:HOST / BOOT / NATIVE 三端输出**逐字节一致**;`demo/type_gymnastics.ql` 419/419 为 M3 终极目标;difftest 从三端扩为四端(加 NATIVE 列)。
7. **性能计时只在同窗口 A/B/A/B 交错下进行**,决策门沿用既有规则;AOT 性能提升是 M4 自举之后的评估项,不是 M0–M3 的门。

## 背景

QLang 目前是纯解释架构:host Rust tree-walking 解释器,以及自托管的 boot 解释器(QLang 写,跑在 host 之上)。本设计增加第三条执行路径:把 QLang 源码直接编译为原生二进制。

编译器走"文本 IR → 外部 LLVM 工具链"而非内嵌 LLVM 库,原因:编译器是 QLang 写的,QLang 无法链接 LLVM C API;文本 IR 是唯一现实可行的接缝。这也带来红利:**IR 平台无关** —— 换目标平台只换 `llc`/`clang`,qlangc 本身跨平台。

已实测(2026-08-13):目标机(aarch64 Termux)LLVM 21.1.8 的 `llc`/`clang`/`opt` 齐全;最小 IR → `llc` → `.o` → `clang` 链接 → 原生 ELF 可执行,跑通;生成代码可调用外部 C 函数。

## 总体架构

```
source.ql
  → bootstrapped/lexer.ql + parser.ql(复用,已在 host 上跑,产出 boot AST)
  → qlangc.ql(编译器,QLang 写,逐节点 emit 文本 LLVM IR)
  → host CLI `qlang --compile`(捕获 stdout 的 IR,写临时 .ll)
  → LLVM 工具链(llc 汇编 → lld/clang 链接,加上 runtime.c)
  → 原生可执行文件(运行时 = runtime.ql 编译进产物 + leaf 垫底)
```

- **编译器是工具**(跑在 boot 解释器上,可以吃 host 机制);**编译产物的运行时是纯 QLang**(语义层零 host)。这是"离开 rust 的摇篮"的完整形态。
- 编译器复用 boot 的 lexer/parser,把 boot interpreter 的 evaluate 换成 emit —— 语义决策(真值、包装、错误传播)已在 boot 用 QLang 写死,emit 逐节点镜像。

## 值模型与 ABI(NaN-boxing)

一个 i64 传遍所有寄存器/栈;数字用普通 double 位模式,非数字用 NaN 载荷:

| 值 | 编码(64 位) | 判定 |
|---|---|---|
| Number(普通) | 普通 double 位模式 | 指数非全 1 |
| Number = NaN | `0x7FF8_0000_0000_0000`(标准 qNaN) | 高 16 位 == `0x7FF8` |
| Null / Void | `0xFFF8_0000_0000_0001` | 高 16 位 == `0xFFF8` 且低位 tag |
| False / True | `0xFFF8_0000_0000_0002` / `...0003` | 同上 |
| 指针(字符串/数组/对象/函数/错误) | `0xFFF8_0000_0000_0000 \| ptr` | 高 16 位 == `0xFFF8` 且低 3 位为 0(8 字节对齐) |

- 普通 double 指数不为全 1,与 tag 域天然互斥;类型判定 = 一次掩码。
- 指针承载对象的类型从对象头部字段读取(不占 NaN 载荷位)。
- 数字 NaN 归一:运算产生带载荷的 NaN 统一归一到哨兵模式(实现时对齐 host 语义)。

**调用约定**:`define i64 @ql_fn(i64 %env, i64* %args, i64 %argc)`,返回 NaN-boxed i64。函数值 = 堆上 16 字节块 `{code: fn指针, env: i64}`,调用时解引用。v1 柯里化后置,先支持精确匹配 + 多传忽略。

**环境** = 链式帧 `{parent: ptr, slots: [i64]}`;let 绑定当前帧新槽,assign 沿链查找,逐字镜像 boot Environment 链语义。

## 编译器设计(qlangc.ql)

- 复用 boot lexer/parser,输入 = 源码文本,输出 = 文本 LLVM IR(stdout)。
- 每 QLang 函数 → 一个 LLVM `define i64` 函数;顶层代码 → `main`(建全局帧 + 顺序执行)。无 goto,if/while 用 `br` + 基本块;`&&`/`||` 短路用 `br`(真值语义对齐 boot)。
- **v1 支持的语言面**:Number/算术/比较/逻辑、let/assign、if/while、函数定义与调用(含递归)、闭包环境帧、字符串字面量(`.rodata`)、调用外部 leaf 函数。这是"数值+控制流"的最小闭包(println 与运行时函数需要)。

## 运行时设计

### leaf(runtime.c,约 60 行,clang 编译,不依赖 CRT)

```c
void*   ql_alloc(size_t n);                    // brk/mmap 分配
void    ql_free(void* p);
void    ql_write(int fd, const void* buf, size_t n);   // syscall
void    ql_exit(int code);                     // syscall
uint8_t ql_mem8_get(void* p, size_t off);      // QLang 建世界的两个扳手
void    ql_mem8_store(void* p, size_t off, uint8_t v);
uint64_t ql_mem64_get(void* p, size_t off);
void    ql_mem64_store(void* p, size_t off, uint64_t v);
```

### runtime.ql(随编译器分发的固定文件,QLang 写)

qlangc 编译目标程序时把 runtime.ql 一并编译进产物(与 rustc 预编译 std 同款做法):

- **v1**:`__itoa`(数字→十进制字节缓冲,经 `ql_mem8_store` 构建)、`__print`(`ql_write` 输出)、字符串对象 = `{buf: ptr, len: i64}`。
- **M2+** 膨胀:字符串全操作、数组、对象(哈希表,QLang 写在 `ql_alloc` 原始内存上)、JSON、Error、Math —— 全部 QLang,通过 leaf 的 mem8/alloc 自建。

## 驱动设计(host CLI 子命令)

`qlang --compile <src.ql> -o <out>`:

1. host 读 `<src.ql>` 文本;
2. 跑 boot 解释器执行 `qlangc.ql`(参数 = 源文本),捕获 stdout 的 IR;
3. 写临时 `.ll`;
4. spawn `clang -fuse-ld=lld <tmp.ll> runtime.c -o <out>`(clang 内置 IR 前端,自动走 llc + lld 链接;不碰 gcc/系统 ld);
5. 报告产物路径。

零新 native;编译过程对用户透明。

## 验证策略

1. 每个里程碑的测试集在 **HOST / BOOT / NATIVE** 三端运行,输出**逐字节一致**(`diff` 空)。v1 测试集:阶乘、递归、Fib、素数判断、循环累加、比较/逻辑短路。
2. difftest 从三端扩为四端(新增 NATIVE 列),全绿。
3. M3 出口:type_gymnastics.ql 419/419 在 NATIVE 端通过且与 HOST/BOOT 输出一致。
4. 字节级 host/boot 对照纪律不因新路径改变;NATIVE 端输出是第四路证据。

## 里程碑

| 里程碑 | 内容 | 出口标准 |
|---|---|---|
| **M0 风险解除** | 手写最小 IR + leaf C 层 + runtime.ql 的 `__itoa`;不写编译器 | 打通 NaN-boxing ABI、alloc/write/exit、数字→文本;产物输出与预期一致 |
| **M1** | qlangc.ql v1 + host `--compile` 驱动 | v1 测试集三端字节一致 |
| **M2** | 字符串/数组/对象(纯 QLang 内存实现)+ 字符串插值 | 中量级程序三端一致 |
| **M3** | 错误值/`?`/`??`/JSON/Math/全部 stdlib + import | difftest 四端 + 419/419 编译通过 |
| **M4 自举** | 编译 boot 解释器本体 → 原生快速解释器;编译 qlangc 自己 → 原生编译器 | 编译器提速 + 自举闭环 |

## 不做的事(YAGNI)

- 不内嵌 LLVM 库(编译器是 QLang 的,只能文本 IR)。
- v1 不做 GC —— 内存策略 = 泄漏 + arena(一次性程序跑完即退);GC/引用计数作为独立里程碑后置,不影响 IR 形态。
- 不做 JIT(留作 M4 之后路线图;Termux aarch64 上 LLVM JIT 支持差)。
- 不依赖 gcc/build-essential/MSVC(只用 LLVM 自带工具链 + 薄 C 垫底)。
- 不做类型特化/静态推断(v1 全动态 boxed 值;类型格是 M4+ 方向)。
- 不做尾调用优化(后置)。
- 不把编译器编译期性能当作 M0–M3 的门(自举在 M4 才提速)。
