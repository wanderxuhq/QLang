# QLang → LLVM AOT 编译器 M0+M1 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 打通 M0(手写 LLVM IR + leaf C 层 + runtime.ql 的 `__itoa`,不写编译器)与 M1(qlangc.ql v1 编译器 + host `--compile` 驱动),使 v1 测试集在 HOST / BOOT / NATIVE 三端输出逐字节一致。

**Architecture:** `source.ql` → boot lexer/parser(复用,已在 host 上跑)→ `qlangc.ql`(QLang 写的 AST→文本 IR 翻译器)→ host CLI 捕获 stdout IR → `clang -fuse-ld=lld <ir.ll> aot/runtime.c -o <out>` → 原生 ELF。编译产物的运行时语义层 = runtime.ql(QLang 写,编译进产物)+ leaf 垫底。值模型 = 全盒指针:每个 QLang 值是一个指向堆对象的单字指针,对象头带 u64 tag。

**Tech Stack:** QLang(boot 解释器宿主)、LLVM IR(文本)、clang 21.1.8 / lld(aarch64 Linux)、Rust(host CLI 驱动)、C(leaf 垫底,仅 syscall)。

**Spec:** `docs/superpowers/specs/2026-08-14-qlang-llvm-aot-compiler-design.md`(未追踪 git,已冻结 2026-08-14)。本计划从 spec 论证,spec 与计划同行。

## Global Constraints

以下约束对每个 task 隐式生效,逐字来自 spec:

1. **编译器用 QLang 写**。qlangc.ql 逻辑全部是 QLang 数据与 QLang 函数,跑在 boot 解释器上。
2. **编译产物运行时语义层纯 QLang**:字符串/数组/对象/Error/Math 等语义由编译进产物的 QLang 代码承担;不链接任何 host stdlib 原生函数。
3. **leaf 极薄**:仅 `ql_alloc`(brk bump)/`ql_write`(syscall 64)/`ql_exit`(syscall 93)/`ql_mem_get`(+ 按需 `ql_mem_store`)。内存管理函数(对象头 tag、字符串缓冲)收进 runtime.ql,不暴露给编译器。leaf 不实现任何语言语义。
4. **编译驱动不新增 native**:`--compile` 由现有 host CLI 承载,零新 QLang 原生函数;qlangc 的输出经 stdout 捕获。
5. **宿主工具链依赖最小**:只用 clang/llc/lld;不碰 gcc/build-essential/MSVC。
6. **验证纪律不变**:HOST / BOOT / NATIVE 三端输出**逐字节一致**;`demo/type_gymnastics.ql` 419/419 不受影响(本计划不动 difftest.py,那是 M2/M3 的事)。
7. **性能计时只在同窗口 A/B/A/B 交错下进行**;M0–M3 不以性能为门。
8. **文档不追踪 git**:spec/plan 文档留在磁盘但永不 `git add`。commit 只 add 代码文件(下方每 task 的 commit 命令已明确范围)。

---

## 文件结构

```
aot/                          # 新建 AOT 子系统目录
  runtime.c                   # leaf:ql_alloc/ql_write/ql_exit/ql_mem_get/ql_mem_store(Task 1)
  runtime.ql                  # 运行时语义层:allocBox/readU64/writeU64/__itoa/__print/print/println(Task 2 创建,Task 7 编译进产物)
  qlangc.ql                   # M1 编译器:AST → 文本 LLVM IR(Task 3 骨架,Task 4-7 扩展)
  tests/
    m0_hello.ll               # Task 1 手写 IR(leaf + .rodata + write + exit)
    m0_factorial.ll           # Task 2 手写 IR(全盒数字 ABI + 数字→文本)
    m0_mem_mock.ql            # Task 2 boot 侧 leaf mock(QLang 数组模拟内存)
    m0_itoa_driver.ql         # Task 2 boot 侧 driver:经 mock 调 runtime.ql 的 __itoa
    hello.ql                  # Task 3 编译测试输入(内容任意,产物固定输出 "hi")
    t4_arith.ql               # Task 4 测试:字面量/算术/比较/一元
    t5_let.ql                 # Task 5 测试:let/assign/identifier
    t6_control.ql             # Task 6 测试:if/while/短路
    t7_factorial.ql           # Task 7 测试:递归阶乘
    t7_fib.ql                 # Task 7 测试:递归 Fibonacci
    v1_factorial.ql           # Task 8 正式测试集(与 t7 同构,独立文件)
    v1_recursion.ql           # Task 8
    v1_fib.ql                 # Task 8
    v1_primes.ql              # Task 8
    v1_accum.ql               # Task 8
    v1_shortcircuit.ql        # Task 8
  run_v1_tests.sh             # Task 8:HOST/BOOT/NATIVE 三端 diff runner
src/main.rs                   # 修改:加 --compile 分支(Task 3)
Cargo.toml                    # 修改:加 libc 依赖(Task 3)
```

## IR 与值模型约定(全计划共享)

**盒子布局**(`ql_alloc` 分配,8 字节对齐;对象 = `[tag:u64][payload]`):

| tag | 类型 | 布局 | 尺寸 |
|---|---|---|---|
| 1 | NUMBER | `[tag][f64]` | 16 B |
| 2 | STRING | `[tag][len:u64][buf:ptr]` | 24 B 头 + 字节缓冲 |
| 3 | BOOL | `[tag][u64 0/1]` | 16 B |
| 4 | NULL | 单例(静态地址,payload 无意义) | — |
| 7 | FUNCTION | `[tag][code:ptr][env:ptr]` | 24 B |

ARRAY/OBJECT/ERROR 的 tag 常量(5/6/8)v1 不用,但编号保留。

- **寄存器/参数/返回值一律一个 i64**(盒指针或裸字)。
- **用户函数 ABI**:`define i64 @ql_fn<N>(i64 %env, i64* %args, i64 %argc)`。函数值 = 闭包盒 `[tag=7][code=@ql_fn<N>][env]`;调用时解引用 code 并 call。
- **环境帧** = 堆块 `[parent:ptr][n_slots:u64][slot0..slotN-1]`。slot i 在 offset `16 + 8*i`;parent 在 offset 0。let 绑定当前帧新槽,assign 沿 parent 链查找(逐字镜像 boot Environment 链:doGet/doAssign 先本帧后 parent)。
- **运行时 API(runtime.ql,编译进产物;qlangc 对程序代码只调这些)**:`allocBox(tag,size)` / `readU64(p,off)` / `writeU64(p,off,v)` / `__itoa(n)→{buf,len}` / `__print({buf,len})` / `print(v)` / `println(v)`。
- **leaf extern 声明**(qlangc 对外部函数表固定 emit;runtime.ql 内部引用这些名字 → 直接 extern 调用):
  ```llvm
  declare ptr  @ql_alloc(i64)
  declare void @ql_write(i32, ptr, i64)
  declare void @ql_exit(i32)
  declare i8   @ql_mem_get(ptr, i64)
  declare void @ql_mem_store(ptr, i64, i8)
  ```
- **数字格式目标**(`__itoa` 必须复刻 host `src/value.rs:255-266`):`if n.is_finite() && n.fract()==0.0 && n.abs()<1e15 { (n as i64).to_string() } else { n.to_string() }`。v1 覆盖整数快速路径;非整数/大数 f64 Display(M2 补,计划不实现——v1 测试集全整数)。
- **真值**(`src/value.rs:239-250`):Number → `n != 0.0`(NaN 为真);Bool → 值;Void/Null → 假。v1 只处理 Number/Bool/Null,产出注入的 `@ql_truthy(i64 %box) → i1`(switch tag)。
- **算术 op → LLVM**:`+`→fadd `-`→fsub `*`→fmul `/`→fdiv `%`→frem;比较 `==`→fcmp oeq `!=`→fcmp une `<`→olt `<=`→ole `>`→ogt `>=`→oge。
- **构建命令**(每 task 通用):
  ```bash
  clang -fuse-ld=lld <input.ll> aot/runtime.c -o <out>
  ```
- **三端一致纪律**:boot 端输出剥离 12 行 banner + `Execution complete.` 行后与 host/native diff(沿既有 Step A/B 纪律)。

---

## Task 1: leaf runtime.c + 手写 hello IR(管道打通)

**Files:**
- Create: `aot/runtime.c`
- Create: `aot/tests/m0_hello.ll`

**Interfaces:**
- Produces: `ql_alloc`/`ql_write`/`ql_exit`/`ql_mem_get`/`ql_mem_store` 五个 C 函数,aarch64 Linux 纯 syscall、零 libc 依赖。后续所有 task 依赖这些 extern 声明。

- [ ] **Step 1: 写 `aot/runtime.c`**

```c
/* aot/runtime.c — leaf:QLang 语言表达不了的 syscall 边界。
 * aarch64 Linux 纯 syscall,无 libc 依赖。leak+arena 内存策略:brk bump,程序跑完即退。
 * 编译进产物:clang -fuse-ld=lld <out.ll> aot/runtime.c -o <out> */
#include <stddef.h>
#include <stdint.h>

static inline long syscall1(long n, long a) {
  register long x0 __asm__("x0") = a;
  register long x8 __asm__("x8") = n;
  __asm__ volatile("svc 0" : "+r"(x0) : "r"(x8) : "memory");
  return x0;
}
static inline long syscall3(long n, long a, long b, long c) {
  register long x0 __asm__("x0") = a;
  register long x1 __asm__("x1") = b;
  register long x2 __asm__("x2") = c;
  register long x8 __asm__("x8") = n;
  __asm__ volatile("svc 0" : "+r"(x0) : "r"(x1), "r"(x2), "r"(x8) : "memory");
  return x0;
}

static void* brk_(void* new_brk) { return (void*)syscall1(214, (long)new_brk); } /* aarch64 brk */

static void* heap_end = 0;

void* ql_alloc(size_t n) {
  if (heap_end == 0) heap_end = brk_(0);
  n = (n + 7UL) & ~7UL;                        /* 8 字节对齐 */
  void* p = heap_end;
  void* want = (char*)heap_end + n;
  void* got = brk_(want);
  if (got < want) return 0;                    /* 分配失败:v1 不处理,保持不崩 */
  heap_end = want;
  return p;
}

void ql_write(int fd, const void* buf, size_t n) {
  syscall3(64, fd, (long)buf, n);              /* aarch64 write */
}

void ql_exit(int code) {
  syscall1(93, code);                          /* aarch64 exit */
}

uint8_t ql_mem_get(const void* p, size_t off) { return ((const uint8_t*)p)[off]; }

void ql_mem_store(void* p, size_t off, uint8_t v) { ((uint8_t*)p)[off] = v; }
```

- [ ] **Step 2: 写 `aot/tests/m0_hello.ll`(手写最小 IR)**

```llvm
; aot/tests/m0_hello.ll — leaf 三件套 + .rodata 字符串 + ql_write + ql_exit
; 构建:clang -fuse-ld=lld aot/tests/m0_hello.ll aot/runtime.c -o /tmp/m0_hello
; 期望:运行输出 "hi" 且退出码 0

@msg = private unnamed_addr constant [3 x i8] c"hi\0A"

declare void @ql_write(i32, ptr, i64)
declare void @ql_exit(i32)

define i32 @main() {
entry:
  call void @ql_write(i32 1, ptr @msg, i64 3)
  call void @ql_exit(i32 0)
  unreachable
}
```

- [ ] **Step 3: 构建并运行验证**

```bash
clang -fuse-ld=lld aot/tests/m0_hello.ll aot/runtime.c -o /tmp/m0_hello
/tmp/m0_hello > /tmp/m0_hello.out 2>&1
echo "exit=$?"; cat /tmp/m0_hello.out
```
Expected: `exit=0`,输出恰为 `hi`(含换行)。这证明 clang+lld 链接 leaf 三件套 + 原生 ELF 运行。

- [ ] **Step 4: Commit**

```bash
git add aot/runtime.c aot/tests/m0_hello.ll
git commit -m "feat(aot): leaf runtime.c (ql_alloc/write/exit/mem_get/mem_store) + m0 hello IR"
```

---

## Task 2: 全盒数字 ABI + 数字→文本(M0 出口)

**Files:**
- Create: `aot/tests/m0_factorial.ll`(手写 IR:全盒 5! = 120 + 整数路径 itoa + write)
- Create: `aot/runtime.ql`(QLang 运行时:allocBox/readU64/writeU64/__itoa/__print/print/println)
- Create: `aot/tests/m0_mem_mock.ql`(boot 侧 leaf mock)
- Create: `aot/tests/m0_itoa_driver.ql`(boot 侧 driver)

**Interfaces:**
- Consumes: Task 1 的 `ql_alloc`/`ql_write`/`ql_exit`/`ql_mem_get`/`ql_mem_store`。
- Produces: runtime.ql 的 `__itoa(n) → {buf, len}` 等 API 契约(与「IR 与值模型约定」节一致),供 Task 7 编译进产物;M0 出口 = native 全盒计算 5! 输出 `120`,与 boot 经 mock 的 runtime.ql 输出、host 解释器输出三方一致。

- [ ] **Step 1: 写 `aot/tests/m0_factorial.ll`(完整,可直接构建)**

```llvm
; aot/tests/m0_factorial.ll — M0 风险解除:全盒指针 ABI + 数字→文本
; 语义:以全盒 NUMBER([tag=1][f64]) 计算 5! = 120,解盒为 i64,十进制输出 "120"。
; 构建:clang -fuse-ld=lld aot/tests/m0_factorial.ll aot/runtime.c -o /tmp/m0_factorial
; 期望输出:"120"

declare ptr  @ql_alloc(i64)
declare void @ql_write(i32, ptr, i64)
declare void @ql_exit(i32)

; --- 全盒工具 ---
define internal ptr @make_number(double %v) {
entry:
  %p = call ptr @ql_alloc(i64 16)
  store i64 1, ptr %p
  %pay = getelementptr i8, ptr %p, i64 8
  store double %v, ptr %pay
  ret ptr %p
}

; box_mul(a, b) → 解盒、fmul、新盒
define internal ptr @box_mul(ptr %a, ptr %b) {
entry:
  %pa = getelementptr i8, ptr %a, i64 8
  %fa = load double, ptr %pa
  %pb = getelementptr i8, ptr %b, i64 8
  %fb = load double, ptr %pb
  %r = fmul double %fa, %fb
  %nb = call ptr @ql_alloc(i64 16)
  store i64 1, ptr %nb
  %np = getelementptr i8, ptr %nb, i64 8
  store double %r, ptr %np
  ret ptr %nb
}

; 5! 的全盒计算链
define internal ptr @fact5() {
entry:
  %b5 = call ptr @make_number(double 5.0)
  %b4 = call ptr @make_number(double 4.0)
  %b3 = call ptr @make_number(double 3.0)
  %b2 = call ptr @make_number(double 2.0)
  %b1 = call ptr @make_number(double 1.0)
  %m1 = call ptr @box_mul(ptr %b5, ptr %b4)
  %m2 = call ptr @box_mul(ptr %m1, ptr %b3)
  %m3 = call ptr @box_mul(ptr %m2, ptr %b2)
  %m4 = call ptr @box_mul(ptr %m3, ptr %b1)
  ret ptr %m4
}

; --- 整数十进制输出(整数快速路径,复刻 host Value::to_string 的整数分支) ---
define internal void @print_uint(i64 %n) {
entry:
  %buf = alloca [24 x i8], align 1
  %bp = getelementptr inbounds [24 x i8], ptr %buf, i64 0, i64 0
  %isz = icmp eq i64 %n, 0
  br i1 %isz, label %zero, label %loop
zero:
  store i8 48, ptr %bp
  call void @ql_write(i32 1, ptr %bp, i64 1)
  ret void
loop:
  %i = phi i64 [ 0, %entry ], [ %i1, %loop ]
  %x = phi i64 [ %n, %entry ], [ %q, %loop ]
  %d = urem i64 %x, 10
  %ch = add i64 48, %d
  %c = trunc i64 %ch to i8
  %off = getelementptr i8, ptr %bp, i64 %i
  store i8 %c, ptr %off
  %q = udiv i64 %x, 10
  %i1 = add i64 %i, 1
  %nz = icmp ne i64 %q, 0
  br i1 %nz, label %loop, label %rev
rev:
  %len = phi i64 [ %i1, %loop ]
  %j = phi i64 [ 0, %loop ], [ %j1, %revloop ]
  %half = udiv i64 %len, 2
  %done = icmp uge i64 %j, %half
  br i1 %done, label %out, label %revloop
revloop:
  %jo = getelementptr i8, ptr %bp, i64 %j
  %a = load i8, ptr %jo
  %last = sub i64 %len, 1
  %r2 = sub i64 %last, %j
  %jro = getelementptr i8, ptr %bp, i64 %r2
  %b = load i8, ptr %jro
  store i8 %b, ptr %jo
  store i8 %a, ptr %jro
  %j1 = add i64 %j, 1
  br label %rev
out:
  call void @ql_write(i32 1, ptr %bp, i64 %len)
  ret void
}

define i32 @main() {
entry:
  %r = call ptr @fact5()
  %pa = getelementptr i8, ptr %r, i64 8
  %f = load double, ptr %pa
  %n = fptosi double %f to i64
  call void @print_uint(i64 %n)
  call void @ql_exit(i32 0)
  unreachable
}
```

- [ ] **Step 2: 写 `aot/runtime.ql`(QLang 运行时语义层,Task 7 编译进产物)**

```ql
// aot/runtime.ql — 编译进产物的运行时语义层(QLang)
// 仅依赖 leaf:ql_alloc / ql_mem_get / ql_mem_store / ql_write / ql_exit。
// 内存函数(对象头、字符串缓冲)全部封装于此,不暴露给编译器。
// QLang 无移位符 → u64 字节读写用「除 256 + 取模」分解/合成。

let writeU64 = (p, off, v) -> {
  let b0 = v % 256;        ql_mem_store(p, off,     b0);
  let v1 = (v - b0) / 256;
  let b1 = v1 % 256;       ql_mem_store(p, off + 1, b1);
  let v2 = (v1 - b1) / 256;
  let b2 = v2 % 256;       ql_mem_store(p, off + 2, b2);
  let v3 = (v2 - b2) / 256;
  let b3 = v3 % 256;       ql_mem_store(p, off + 3, b3);
  let v4 = (v3 - b3) / 256;
  let b4 = v4 % 256;       ql_mem_store(p, off + 4, b4);
  let v5 = (v4 - b4) / 256;
  let b5 = v5 % 256;       ql_mem_store(p, off + 5, b5);
  let v6 = (v5 - b5) / 256;
  let b6 = v6 % 256;       ql_mem_store(p, off + 6, b6);
  let v7 = (v6 - b6) / 256;
  let b7 = v7 % 256;       ql_mem_store(p, off + 7, b7);
  null;
};

let readU64 = (p, off) -> {
  let acc = 0;
  let mult = 1;
  let i = 0;
  while i < 8 {
    acc = acc + ql_mem_get(p, off + i) * mult;
    mult = mult * 256;
    i = i + 1;
  };
  acc;
};

let allocBox = (tag, size) -> {
  let p = ql_alloc(size);
  writeU64(p, 0, tag);
  p;
};

// 数字 → 字符串对象 {buf, len}:整数快速路径(host Value::to_string 镜像)
// 非整数/|n|>=1e15 回退到整数截断 —— M2 补完整 f64 Display;v1 测试集全整数
let __itoa = (n) -> {
  let neg = n < 0;
  let x = if neg { -n } else { n };
  let k = 0;
  let t = x;
  while t >= 1 {
    k = k + 1;
    t = (t - t % 10) / 10;
  };
  if k == 0 { k = 1; };                       // "0"
  let start = if neg { 1 } else { 0 };
  let total = start + k;
  let buf = ql_alloc(total);
  if neg { ql_mem_store(buf, 0, 45); };       // '-'
  let v = x;
  let i = 0;
  while i < k {
    let d = v % 10;
    ql_mem_store(buf, start + k - 1 - i, 48 + d);
    v = (v - d) / 10;
    i = i + 1;
  };
  { buf: buf, len: total };
};

let __print = (s) -> { ql_write(1, s.buf, s.len); };

let print = (v) -> { __print(__itoa(v)); null; };

let println = (v) -> {
  __print(__itoa(v));
  let nl = ql_alloc(1);
  ql_mem_store(nl, 0, 10);
  __print({ buf: nl, len: 1 });
  null;
};
```

- [ ] **Step 3: 写 boot 侧 leaf mock + driver,验证 runtime.ql 的 `__itoa` 逻辑**

`aot/tests/m0_mem_mock.ql`(boot 解释器环境模拟 leaf;地址 = 整数,内存 = 对象表):

```ql
// aot/tests/m0_mem_mock.ql — boot 上模拟 leaf 内存函数(数组模拟内存,偏移 = 地址)
// 仅供 M0 boot 侧验证 runtime.ql 逻辑,不进产物。
let mem = {};
let heapTop = 0;
let ql_alloc = (n) -> {
  let p = heapTop;
  heapTop = heapTop + n;
  p;
};
let ql_mem_store = (p, off, v) -> { mem[p + off] = v; };
let ql_mem_get = (p, off) -> mem[p + off];
let ql_write = (fd, buf, len) -> {
  // boot 无裸内存读;把字节序列读回并 println(boot 打印字符串)
  let chars = "";
  let i = 0;
  while i < len {
    chars = chars + std.String.fromCodePoint(mem[buf + i]);
    i = i + 1;
  };
  println(chars);
};
```

`aot/tests/m0_itoa_driver.ql`:

```ql
// aot/tests/m0_itoa_driver.ql — boot 侧:M0 验证 runtime.ql __itoa 与手写 IR 输出一致
import ./m0_mem_mock.ql;
import ../runtime.ql;

// 与 native 手写 IR、host 解释器三方对照:都应是 "120"
let r = __itoa(120);
ql_write(1, r.buf, r.len);
```

> 注:`import ../runtime.ql` 需要 boot import 支持相对路径。若相对路径不可用,把 runtime.ql 内容复制进 driver 顶部(删掉原 import 行)——**二选一,以实际 boot import 行为为准,选通的**。

- [ ] **Step 4: 三端对照验证(M0 出口)**

```bash
# ① native(手写 IR):输出 "120"
clang -fuse-ld=lld aot/tests/m0_factorial.ll aot/runtime.c -o /tmp/m0_factorial
/tmp/m0_factorial > /tmp/native.out
# ② boot(mock + runtime.ql):输出 "120"(剥离 banner 后)
cargo run --quiet -- aot/tests/m0_itoa_driver.ql > /tmp/boot_raw.out
# 剥离 12 行 banner + "Execution complete."(若 driver 直接跑,无 run_file wrapper,则无 banner;按实际剥离)
# ③ host 解释器跑等价程序(语义 = 5! → 120)
printf 'let fact = (n) -> { if n == 0 { 1 } else { n * fact(n - 1) } }; print(fact(5));' > /tmp/m0_host.ql
cargo run --quiet -- /tmp/m0_host.ql > /tmp/host.out
diff <(grep -v -x 'Execution complete.' /tmp/native.out) /tmp/host.out && echo "NATIVE==HOST"
diff <(grep -v -x 'Execution complete.' /tmp/native.out) /tmp/boot.out && echo "NATIVE==BOOT"
```
Expected: `NATIVE==HOST` 与 `NATIVE==BOOT` 都打印,banner 剥离后三端逐字节一致,内容为 `120`。这达成 M0 出口:全盒指针 ABI、alloc/write/exit、数字→文本、QLang 的 `__itoa` 逻辑经 boot 验证与 native 一致。

- [ ] **Step 5: Commit**

```bash
git add aot/runtime.ql aot/tests/m0_factorial.ll aot/tests/m0_mem_mock.ql aot/tests/m0_itoa_driver.ql
git commit -m "feat(aot): M0 risk-reduction — boxed-number ABI + integer itoa (native hand-written IR == boot runtime.ql == host)"
```

---

## Task 3: qlangc.ql 骨架 + host `--compile` 驱动

**Files:**
- Create: `aot/qlangc.ql`
- Create: `aot/tests/hello.ql`
- Modify: `src/main.rs`(加 `--compile` 分支)
- Modify: `Cargo.toml`(加 `libc = "0.2"`)

**Interfaces:**
- Consumes: Task 1 leaf extern 声明;boot `Lexer`/`Parser`(import `./lexer.ql`/`./ast.ql`/`./parser.ql`)。
- Produces: `qlang <src.ql> -o <out>` 子命令(捕获 qlangc.ql 的 stdout IR → 写临时 .ll → `clang -fuse-ld=lld <tmp.ll> aot/runtime.c -o <out>`)。本 task 产物固定输出 `hi`(编译正确性从 Task 4 开始)。

- [ ] **Step 1: `Cargo.toml` 加依赖**

```toml
[dependencies]
thiserror = "1.0"
rand = "0.8"
libc = "0.2"
```

- [ ] **Step 2: 写 `aot/qlangc.ql` 骨架(banner 零输出,IR 纯净到 stdout)**

```ql
// aot/qlangc.ql — QLang → LLVM IR 编译器(QLang 写,跑在 boot 解释器上)
// host --compile 驱动:boot 解释器执行本文件;args[0] = 源码文本,args[1] = 源路径。
// 输出:纯 IR 文本到 stdout(本文件不 import main.ql,故无 banner)。
import ./lexer.ql;
import ./ast.ql;
import ./parser.ql;

// Task 3 骨架:忽略 AST,输出固定 hello IR(管道打通;emit 从 Task 4 开始)
let emitFixedHello = () -> {
  println("@msg = private unnamed_addr constant [3 x i8] c\"hi\\0A\"");
  println("declare void @ql_write(i32, ptr, i64)");
  println("declare void @ql_exit(i32)");
  println("define i32 @main() {");
  println("entry:");
  println("  call void @ql_write(i32 1, ptr @msg, i64 3)");
  println("  call void @ql_exit(i32 0)");
  println("  unreachable");
  println("}");
};

let main = (args) -> {
  emitFixedHello();
};

main(args);
```

> 若 QLang 字符串字面量不支持 `\0A` 转义(实测为准),把 IR 里的换行写成字面换行内嵌在字符串中(即 `.ll` 文件里真实换行),二选一,以 clang 能解析为准。

- [ ] **Step 3: `src/main.rs` 加 `--compile` 分支(host 零新 native)**

在 `main()` 顶部(现有 `let file_path = &args[1];` 之后、文件存在性检查之前)插入:

```rust
    // AOT compile:qlang --compile <src.ql> -o <out>
    if file_path == "--compile" {
        if args.len() < 4 || args[3] != "-o" {
            eprintln!("Usage: {} --compile <src.ql> -o <out>", args[0]);
            std::process::exit(1);
        }
        let src_path = &args[2];
        let out_path = &args[4];
        let src = std::fs::read_to_string(src_path).unwrap_or_else(|e| {
            eprintln!("Error reading {}: {}", src_path, e);
            std::process::exit(1);
        });
        let mut interp = Interpreter::new();
        interp.set_args(&[src, src_path.to_string()]);
        let ir = match interp.run_file(Path::new("aot/qlangc.ql")) {
            Ok(_) => capture_stdout_since_marker(),
            Err(e) => {
                eprintln!("Error running qlangc: {}", e);
                std::process::exit(1);
            }
        };
        let tmp_ll = std::env::temp_dir().join(format!("qlangc_{}.ll", std::process::id()));
        std::fs::write(&tmp_ll, &ir).unwrap();
        let st = std::process::Command::new("clang")
            .args(["-fuse-ld=lld", tmp_ll.to_str().unwrap(), "aot/runtime.c", "-o", out_path])
            .status();
        std::fs::remove_file(&tmp_ll).ok();
        match st {
            Ok(s) if s.success() => {
                println!("compiled: {}", out_path);
            }
            Ok(s) => {
                eprintln!("clang failed with {}", s);
                std::process::exit(1);
            }
            Err(e) => {
                eprintln!("clang spawn error: {}", e);
                std::process::exit(1);
            }
        }
        return;
    }
```

在文件末尾加捕获函数(libc dup2 重定向 stdout 到 pipe,跑完恢复并读回):

```rust
/// 运行 `f` 期间的 stdout 全量捕获(dup2 到 pipe)。qlangc 的 IR 即通过此捕获。
fn capture_stdout_since_marker() -> Vec<u8> {
    use std::io::{Read, Write};
    let saved = unsafe { libc::dup(1) };
    let mut fds = [0 as libc::c_int; 2];
    unsafe {
        libc::pipe(fds.as_mut_ptr());
        libc::dup2(fds[1], 1);
        libc::close(fds[1]);
    }
    // 注意:Interpreter 已在调用方跑完;此函数只是把已写入 pipe 的字节读回。
    // 实现时若发现 qlangc 的 println 需在 dup2 生效期间执行,把 interp.run_file 移入此处闭包。
    let mut buf = Vec::new();
    unsafe {
        let mut tmp = [0u8; 4096];
        loop {
            let n = libc::read(fds[0], tmp.as_mut_ptr() as *mut libc::c_void, 4096);
            if n <= 0 { break; }
            buf.extend_from_slice(&tmp[..n as usize]);
        }
        libc::close(fds[0]);
        libc::dup2(saved, 1);
        libc::close(saved);
    }
    buf
}
```

> **实现修正(以实测为准)**:`capture_stdout_since_marker` 的重定向必须包裹 `interp.run_file(...)`,否则 stdout 已恢复、pipe 无数据。正确形态 = 一个接受闭包的 `capture_stdout(|interp| interp.run_file(...)) -> Vec<u8>`,内部 `dup2` → 跑 → 恢复 → 读回。上面两段按此意图重构:把 `run_file` 调用包进捕获闭包,IR 从捕获结果取。

- [ ] **Step 4: 写 `aot/tests/hello.ql`(内容任意,产物固定输出 `hi`)**

```ql
// aot/tests/hello.ql — Task 3 驱动管道测试输入(骨架期产物固定输出 "hi")
let x = 1;
```

- [ ] **Step 5: 构建 host + 端到端编译验证**

```bash
cargo build --quiet
./target/debug/qlang --compile aot/tests/hello.ql -o /tmp/hello_aot
/tmp/hello_aot > /tmp/hello_aot.out 2>&1
echo "exit=$?"; cat /tmp/hello_aot.out
```
Expected: `compiled: /tmp/hello_aot` 输出;产物运行输出 `hi` 且 exit 0。这打通 host → boot 解释器 → qlangc.ql → stdout IR → clang/lld → 原生 ELF 全管道。

- [ ] **Step 6: Commit**

```bash
git add aot/qlangc.ql aot/tests/hello.ql src/main.rs Cargo.toml Cargo.lock
git commit -m "feat(aot): host --compile driver + qlangc.ql skeleton (pipeline: source -> boot lexer/parser -> IR -> clang/lld -> ELF)"
```

---

## Task 4: 字面量 + 算术/比较/一元 emit(print/println 特例脚手架)

**Files:**
- Modify: `aot/qlangc.ql`
- Create: `aot/tests/t4_arith.ql`

**Interfaces:**
- Consumes: boot AST 节点形状(ast.ql:`Number`/`String`/`Boolean`/`Null`/`BinaryOp`/`UnaryOp`/`Call`/`Identifier`);「IR 与值模型约定」节的盒子布局/op 映射。
- Produces: qlangc 的 emit 基础设施 —— `line/temp/lbl/f64lit` + `emitExpr(node) → 寄存器名` + 顶层表达式语句 emit + **print/println 特例**(识别 `Call(Identifier "print"/"println")`,emit 为内置辅助 `@ql_print_uint`)。本 task 引入的内置辅助在 Task 7 被 runtime.ql 的 QLang 函数编译取代(届时删除)。

**print/println 特例设计(v1 前置脚手架)**:qlangc 在每个产物注入固定辅助函数(整数路径 itoa + write,语义同 Task 2 `print_uint`,加换行):

```llvm
; qlangc 注入(每产物一份)
define internal void @ql_print_uint(i64 %box, i1 %nl) {
  ; %box = NUMBER 盒;解盒 → f64 → (整数路径) fptosi i64 → 十进制 write
  ; %nl 为真时再 write 一个 '\n'(ql_alloc(1) + store 10 + write)
  ; 实现直接复用 Task 2 print_uint 的 div/rev 结构,返回值处理 n==0
}
```

**qlangc.ql 骨架(Task 4 起):**

```ql
// aot/qlangc.ql(Task 4 状态)—— 在 Task 3 骨架上替换 emitFixedHello
import ./lexer.ql;
import ./ast.ql;
import ./parser.ql;

let out = [];
let tmpN = 0;
let lblN = 0;
let line = (s) -> { out[out.length] = s; };
let temp = () -> { tmpN = tmpN + 1; "%t" + std.String.toString(tmpN); };
let lbl = () -> { lblN = lblN + 1; "bb" + std.String.toString(lblN); };
let f64lit = (x) -> { if x % 1 == 0 { std.String.toString(x) + ".0"; } else { std.String.toString(x); }; };

// emit 一个表达式,返回承载其盒值的寄存器名
let emitExpr = (node) -> {
  let t = node.type;
  if t == "Number" {
    emitNumber(node);
  } else if t == "BinaryOp" {
    emitBinaryOp(node);
  } else if t == "UnaryOp" {
    emitUnaryOp(node);
  } else if t == "Call" {
    emitCall(node);
  } else if t == "Identifier" {
    emitIdentifier(node);
  } else {
    line("; unhandled expr: " + t);
    temp();
  };
};
```

- [ ] **Step 1: emit 基础设施 + 数字字面量**

```ql
let emitNumber = (node) -> {
  let t = temp(); let pay = temp();
  line("  " + t + " = call ptr @ql_alloc(i64 16)");
  line("  store i64 1, ptr " + t);
  line("  " + pay + " = getelementptr i8, ptr " + t + ", i64 8");
  line("  store double " + f64lit(node.value) + ", ptr " + pay);
  t;
};
```

- [ ] **Step 2: 算术/比较/一元 emit(模板见「IR 与值模型约定」)**

```ql
let emitBinaryOp = (node) -> {
  let L = emitExpr(node.left); let R = emitExpr(node.right);
  let op = node.operator;
  let a1 = temp(); let f1 = temp(); let a2 = temp(); let f2 = temp();
  line("  " + a1 + " = getelementptr i8, ptr " + L + ", i64 8");
  line("  " + f1 + " = load double, ptr " + a1);
  line("  " + a2 + " = getelementptr i8, ptr " + R + ", i64 8");
  line("  " + f2 + " = load double, ptr " + a2);
  if op == "+" || op == "-" || op == "*" || op == "/" || op == "%" {
    let rr = temp();
    let fop = if op == "+" { "fadd" } else if op == "-" { "fsub" } else if op == "*" { "fmul" } else if op == "/" { "fdiv" } else { "frem" };
    line("  " + rr + " = " + fop + " double " + f1 + ", " + f2);
    // 新 NUMBER 盒
    let b = temp(); let bpay = temp();
    line("  " + b + " = call ptr @ql_alloc(i64 16)");
    line("  store i64 1, ptr " + b);
    line("  " + bpay + " = getelementptr i8, ptr " + b + ", i64 8");
    line("  store double " + rr + ", ptr " + bpay);
    b;
  } else {
    // 比较:== oeq,!= une,< olt,<= ole,> ogt,>= oge
    let cmp = if op == "==" { "oeq" } else if op == "!=" { "une" } else if op == "<" { "olt" } else if op == "<=" { "ole" } else if op == ">" { "ogt" } else { "oge" };
    let c = temp(); let c2 = temp(); let b = temp(); let bpay = temp();
    line("  " + c + " = fcmp " + cmp + " double " + f1 + ", " + f2);
    line("  " + c2 + " = zext i1 " + c + " to i64");
    line("  " + b + " = call ptr @ql_alloc(i64 16)");
    line("  store i64 3, ptr " + b);
    line("  " + bpay + " = getelementptr i8, ptr " + b + ", i64 8");
    line("  store i64 " + c2 + ", ptr " + bpay);
    b;
  };
};
```

一元:

```ql
let emitUnaryOp = (node) -> {
  let O = emitExpr(node.operand);
  if node.operator == "-" {
    // 解盒,fneg,新盒
    let a = temp(); let f = temp(); let n = temp(); let b = temp(); let bpay = temp();
    line("  " + a + " = getelementptr i8, ptr " + O + ", i64 8");
    line("  " + f + " = load double, ptr " + a);
    line("  " + n + " = fneg double " + f);
    line("  " + b + " = call ptr @ql_alloc(i64 16)");
    line("  store i64 1, ptr " + b);
    line("  " + bpay + " = getelementptr i8, ptr " + b + ", i64 8");
    line("  store double " + n + ", ptr " + bpay);
    b;
  } else if node.operator == "!" {
    // 真值反转 → BOOL 盒
    let tr = temp(); let inv = temp(); let b = temp(); let bpay = temp();
    line("  " + tr + " = call i1 @ql_truthy(i64 " + O + ")");
    line("  " + inv + " = xor i1 " + tr + ", true");
    line("  " + b + " = call ptr @ql_alloc(i64 16)");
    line("  store i64 3, ptr " + b);
    line("  " + bpay + " = getelementptr i8, ptr " + b + ", i64 8");
    line("  %z" + std.String.toString(0) + " = zext i1 " + inv + " to i64");
    line("  store i64 %z0, ptr " + bpay);
    b;
  } else {
    O;
  };
};
```

- [ ] **Step 3: `@ql_truthy` + `@ql_print_uint` 注入 + 顶层语句 + print 特例**

```ql
// 产物头部注入(每产物一份)
let emitPrelude = () -> {
  line("; qlangc v1 prelude");
  // @ql_truthy:switch tag —— NUMBER !=0(NaN 真)、BOOL 值、其余假(v1)
  // @ql_print_uint(i64 %box, i1 %nl):解盒 → 整数 itoa → write(复刻 Task 2 print_uint);%nl 追加 '\n'
  // 完整 LLVM 文本:用 line() 逐行输出,结构 = Task 2 print_uint + make_number 的载荷读 + 换行分支
};

let emitTopLevelStmt = (node) -> {
  if node.type == "Let" {
    // Task 5 实现;Task 4 先报"不支持"
    line("; unsupported top-level Let (Task 5)");
  } else if node.type == "Call" && node.callee.type == "Identifier"
            && (node.callee.name == "print" || node.callee.name == "println") {
    // print/println 特例:v1 只处理单参数数字
    let V = emitExpr(node.arguments[0]);
    let nl = if node.callee.name == "println" { "true" } else { "false" };
    line("  call void @ql_print_uint(i64 " + V + ", i1 " + nl + ")");
  } else if node.type == "ExprStmt" {
    // 表达式语句:求值丢弃
    emitExpr(node.value);
  } else {
    line("; unsupported stmt: " + node.type);
  };
};
```

> **AST 现实核对**:boot parser 的语句是直接节点(Program.statements 里是 `LetStmt`/`IfStmt` 等),表达式语句可能是裸表达式节点或带 `ExprStmt` 包装。以 `ast.ql` 实际形状为准:表达式语句若直接是表达式节点,则 `emitTopLevelStmt` 的 ExprStmt 分支改为"其它节点一律 emitExpr 丢弃"。实现时以 boot `parser.parse()` 产出的实际 statement 类型做分派,计划此处允许按实测适配分支名(不改变语义:顶层求值 + print 特例)。

- [ ] **Step 4: `main` 收尾(替换 emitFixedHello)**

```ql
let main = (args) -> {
  let source = args[0];
  let lexer = Lexer(source);
  let tokens = lexer.tokenize();
  let parser = Parser(tokens);
  let program = parser.parse();
  emitPrelude();
  line("define i32 @main() {");
  line("entry:");
  let i = 0;
  while i < program.statements.length {
    emitTopLevelStmt(program.statements[i]);
    i = i + 1;
  };
  line("  ret i32 0");
  line("}");
  let i2 = 0;
  while i2 < out.length {
    println(out[i2]);
    i2 = i2 + 1;
  };
};
main(args);
```

- [ ] **Step 5: 写测试 `aot/tests/t4_arith.ql` 并三端验证**

```ql
println(1 + 2 * 3);       // 7
println(10 - 4);          // 6
println(8 / 2);           // 4
println(10 % 3);          // 1
println(5 > 3);           // true
println(2 == 2);          // true
println(1 != 1);          // false
println(-3);              // -3
println(!false);          // true
```

```bash
# native
cargo run --quiet -- --compile aot/tests/t4_arith.ql -o /tmp/t4_aot 2>/dev/null || \
  ./target/debug/qlang --compile aot/tests/t4_arith.ql -o /tmp/t4_aot
/tmp/t4_aot > /tmp/t4_native.out
# host
./target/debug/qlang aot/tests/t4_arith.ql > /tmp/t4_host.out
# boot(剥离 banner + Execution complete.)
./target/debug/qlang bootstrapped/run_file.ql aot/tests/t4_arith.ql > /tmp/t4_boot_raw.out
tail -n +13 /tmp/t4_boot_raw.out | grep -v '^Execution complete\.' > /tmp/t4_boot.out
diff /tmp/t4_host.out /tmp/t4_native.out && diff /tmp/t4_host.out /tmp/t4_boot.out && echo "T4 三端一致"
```
Expected: `T4 三端一致`,各行分别为 `7` `6` `4` `1` `true` `true` `false` `-3` `true`。

> 注意:`print` 特例对 `println(true)` 这类 BOOL 参数当前不支持(只解盒为 double → fptosi 会错)。因此 Task 4 测试里 `println(5 > 3)` 需要特例先支持 BOOL:实现 `@ql_print_uint` 时按 tag 分派 —— tag 3 则输出 `true`/`false`(`.rodata` 常量)。**这是本 task 的必需实现点**,否则测试无法三端一致。

- [ ] **Step 6: Commit**

```bash
git add aot/qlangc.ql aot/tests/t4_arith.ql
git commit -m "feat(aot): qlangc emit numbers/arith/compare/unary + print scaffold (T4 three-way diff green)"
```

---

## Task 5: let/assign + 环境帧 emit

**Files:**
- Modify: `aot/qlangc.ql`
- Create: `aot/tests/t5_let.ql`

**Interfaces:**
- Consumes: Task 4 emitExpr 基础设施;「IR 与值模型约定」环境帧布局 `[parent][n][slots...]`。
- Produces: 编译期作用域模型 `scopePush/scopePop/defineSlot/lookupSlot(name) → {depth, slot}`;顶层 `let`/`assign`/`Identifier` 的 emit。每个函数一个帧,参数 + 顶层 let 依序占 slot。

**编译期作用域模型(QLang 对象链):**

```ql
// scope = { slots: {name → slotIndex}, parent: scope|null }
let globalScope = { slots: {}, parent: null };
let curScope = globalScope;
let scopePush = (parent) -> { curScope = { slots: {}, parent: parent }; };
let defineSlot = (name) -> {
  let n = 0;
  // 统计 slots 现有键数作为新 slot 索引
  let k = curScope.slots;
  forEachSlot(k, (x) -> { n = n + 1; });
  curScope.slots[name] = n;
  n;
};
let lookupSlot = (name) -> {           // 返回 {depth, slot} 或 null
  let d = 0;
  let s = curScope;
  while s != null {
    let v = s.slots[name];
    if !isError(v) && v != null { { depth: d, slot: v }; }
    else { s = s.parent; d = d + 1; };
  };
  null;
};
```

> `forEachSlot` 若无现成工具,用 `std.Object.keys(k)` 或遍历;以 boot stdlib 实际可用为准,取 slots 键数。

**Identifier emit(从当前 env 寄存器沿 parent 走 depth 步,读 slot):**

```ql
let emitIdentifier = (node) -> {
  let hit = lookupSlot(node.name);
  if hit == null {
    // 未绑定名字:假定为 leaf/内置 —— Task 7 前 qlangc 对 print/println 在 Call 已特判,
    // 其它未绑定名字当前报错
    line("; error: undefined " + node.name);
    temp();
  } else {
    let cur = "env0";            // 当前函数入口 env 参数(main 里 = 全局帧寄存器)
    let d = 0;
    while d < hit.depth {
      let p = temp();
      line("  " + p + " = load i64, ptr " + cur);
      cur = p;
      d = d + 1;
    };
    let off = temp(); let v = temp();
    line("  " + off + " = getelementptr i8, ptr " + cur + ", i64 " + std.String.toString(16 + 8 * hit.slot));
    line("  " + v + " = load i64, ptr " + off);
    v;
  };
};
```

**Let emit(新帧,绑定到当前 env 上):**

```ql
// emitLetStmt(node):node = {type:"Let", name, value}
let emitLetStmt = (node) -> {
  let V = emitExpr(node.value);
  let slot = defineSlot(node.name);
  let frame = temp(); let po = temp(); let no = temp(); let so = temp();
  line("  " + frame + " = call ptr @ql_alloc(i64 24)");       // [parent][1][slot]
  line("  store i64 env0, ptr " + frame);                     // parent = 旧 env
  line("  " + po + " = getelementptr i8, ptr " + frame + ", i64 8");
  line("  store i64 1, ptr " + po);                           // n_slots = 1
  line("  " + so + " = getelementptr i8, ptr " + frame + ", i64 16");
  line("  store i64 " + V + ", ptr " + so);
  line("  env0 = " + frame);                                   // 后续语句 env 更新
};
```

> **env0 管理**:main/函数体里用一个可变的当前 env 寄存器名(`env0` 字符串变量,QLang 侧拼接)。顶层每个 let 生成新帧,更新 env0。函数入口 `env0 = 函数入口 env 参数`。若 LLVM SSA 禁止变量重赋值,改用 `%env_i` 编号变量逐条更新(QLang 侧维护 envN 名字)。**实现时用带编号的 env 寄存器名**,`emitIdentifier` 读当前最新编号。计划此处以编号方案为准。

**Assign emit(沿链找 slot 写):**

```ql
let emitAssignStmt = (node) -> {
  // node = {type:"Assign", target:{type:"Identifier", name}, value}
  let V = emitExpr(node.value);
  let hit = lookupSlot(node.target.name);
  if hit == null { line("; error: assign to undefined " + node.target.name); }
  else {
    // 同 emitIdentifier 走 depth 步得到目标帧寄存器名,再 store
    let cur = "env0"; let d = 0;
    while d < hit.depth { let p = temp(); line("  " + p + " = load i64, ptr " + cur); cur = p; d = d + 1; };
    let off = temp();
    line("  " + off + " = getelementptr i8, ptr " + cur + ", i64 " + std.String.toString(16 + 8 * hit.slot));
    line("  store i64 " + V + ", ptr " + off);
  };
};
```

**测试 `aot/tests/t5_let.ql`:**

```ql
let x = 21;
let y = x * 2;
println(y);          // 42
y = y + 1;
println(y);          // 43
let z = 5;
println(z);          // 5
```

验证命令同 Task 4 Step 5(clang/--compile → native,host 直跑,boot 跑 run_file 剥离 banner,三端 diff)。Expected: `42` `43` `5` 三行一致。

**Commit:**
```bash
git add aot/qlangc.ql aot/tests/t5_let.ql
git commit -m "feat(aot): qlangc env frames + let/assign/identifier emit (T5 three-way diff green)"
```

---

## Task 6: if/while + 短路 emit

**Files:**
- Modify: `aot/qlangc.ql`
- Create: `aot/tests/t6_control.ql`

**Interfaces:**
- Consumes: Task 5 环境帧;Task 4 `@ql_truthy`。
- Produces: `emitIfStmt`/`emitWhileStmt`(br + 基本块)、`&&`/`||` 短路 emit。v1 函数体只支持顶层 let(分支内 let 报"不支持"),以保持函数帧扁平。

**If emit**(ast.ql:`If` = `{branches:[{condition,body}], elseBody}`):

```ql
let emitIfStmt = (node) -> {
  let br = node.branches[0];
  let C = emitExpr(br.condition);
  let tr = temp();
  line("  " + tr + " = call i1 @ql_truthy(i64 " + C + ")");
  let lThen = lbl(); let lElse = lbl(); let lEnd = lbl();
  line("  br i1 " + tr + ", label %" + lThen + ", label %" + lElse);
  line(lThen + ":");
  emitBlockStmts(br.body.statements);
  line("  br label %" + lEnd);
  line(lElse + ":");
  if node.elseBody != null {
    emitBlockStmts(node.elseBody.statements);
  };
  line("  br label %" + lEnd);
  line(lEnd + ":");
};
```

> v1 只有 if/else 单分支(无 else-if)。`emitBlockStmts` 遍历 body 的 statements,复用 emitTopLevelStmt 的语句分派(去掉 print 特例限制的语法允许)。分支内若遇 `Let` 且该 let 名字已在函数帧 → 按 assign 处理;新名字 → 报"v1 分支内 let 不支持"(与 plan 约定一致)。

**While emit:**

```ql
let emitWhileStmt = (node) -> {
  let lCond = lbl(); let lBody = lbl(); let lExit = lbl();
  line("  br label %" + lCond);
  line(lCond + ":");
  let C = emitExpr(node.condition);
  let tr = temp();
  line("  " + tr + " = call i1 @ql_truthy(i64 " + C + ")");
  line("  br i1 " + tr + ", label %" + lBody + ", label %" + lExit);
  line(lBody + ":");
  emitBlockStmts(node.body.statements);
  line("  br label %" + lCond);
  line(lExit + ":");
};
```

**短路 `&&` / `||`**(BinaryOp 分支里特判):

```ql
// && :A 假 → false 盒(不 eval B);否则 B 的值
// || :A 真 → A 的值;否则 B 的值
let emitShortCircuit = (node) -> {
  let op = node.operator;                      // "&&" 或 "||"
  let A = emitExpr(node.left);
  let trA = temp();
  line("  " + trA + " = call i1 @ql_truthy(i64 " + A + ")");
  let lEvalB = lbl(); let lDone = lbl();
  let cond = if op == "&&" { trA } else { temp(); };  // || 需 !trA
  ...
};
```

实现时 `&&` 用 `br i1 %trA, label %evalB, label %done`(A 假短路,结果 = false 盒);`||` 用 `br i1 %trA, label %done, label %evalB`(A 真短路,结果 = A 盒)。`done` 块用 `phi` 合并结果寄存器;`evalB` 块 emit B,`br label %done`。计划给出 phi 合并的具体模板(实现细节由子代理按此规则落地):

```llvm
; A && B
  ; ... emit A → %A(盒)
  %tA = call i1 @ql_truthy(i64 %A)
  br i1 %tA, label %evalB, label %done
evalB:
  ; ... emit B → %B(盒)
  br label %done
done:
  %res = phi i64 [ %A, %entry ], [ %B, %evalB ]   ; A 假 → A(false 盒);A 真 → B
  ; 注:A 真时结果 = B;A 假时结果应为 false 盒。上面的 phi 需在 A 假路径喂 false 盒:
  ; 实际用三个入口:done 的 phi = [ falseBox, %entry 的 A 假分支 ], [ %B, %evalB ]
```

> **短路结果盒修正**:`A && B` 的语义是"短路返回 A 的假值盒"(A 已是 false 值,可直接返回);A 真返回 B。因此 phi 为 `[ %A, %A假分支 ]` + `[ %B, %evalB ]`,不需要造 false 盒。`||` 对称:`[ %A, %A真分支 ]` + `[ %B, %evalB ]`。以 boot 的短路语义为准(host 621-627 行:`&&` = `if !is_truthy(left) { left } else { right }`,`||` = `if is_truthy(left) { left } else { right }`——返回原值盒,不造新盒)。

**测试 `aot/tests/t6_control.ql`:**

```ql
let n = 10;
let acc = 0;
while n > 0 {
  acc = acc + n;
  n = n - 1;
};
println(acc);              // 55

let a = 0;
let b = 5;
println(true && a == 0);   // true
println(false && 1 / 0);   // false(短路,1/0 不求值)
println(true || 1 / 0);    // true(短路)
println(b > 0 && b < 10);  // true

if 7 % 2 == 1 {
  println(1);              // 1
} else {
  println(2);
};
```

验证命令同 Task 4(三端 diff)。Expected: `55` `true` `false` `true` `true` `1` 各行一致。此测试含 `&&`/`||` 短路不求值除零(证明短路生效)。

**Commit:**
```bash
git add aot/qlangc.ql aot/tests/t6_control.ql
git commit -m "feat(aot): qlangc if/while + short-circuit emit (T6 three-way diff green)"
```

---

## Task 7: 函数定义 + 调用 + 闭包 + 递归;runtime.ql 编译进产物

**Files:**
- Modify: `aot/qlangc.ql`
- Modify: `src/main.rs`(`--compile` 时拼接 `aot/runtime.ql` 到源码之前)
- Create: `aot/tests/t7_factorial.ql`, `aot/tests/t7_fib.ql`

**Interfaces:**
- Consumes: Task 5 作用域/环境帧;Task 6 控制流。
- Produces: 函数 ABI(`define i64 @ql_fn<N>(i64 %env, i64* %args, i64 %argc)`)、闭包盒、调用 emit、**删除 Task 4 的 print/println 特例**(print 变为 runtime.ql 的普通 QLang 函数,经拼接编译进产物)。

**Step 1: host 拼接 runtime.ql**(main.rs,`--compile` 分支里读源码前):

```rust
        let runtime_src = std::fs::read_to_string("aot/runtime.ql").unwrap_or_else(|e| {
            eprintln!("Error reading aot/runtime.ql: {}", e);
            std::process::exit(1);
        });
        let combined = format!("{}\n{}", runtime_src, src);
        interp.set_args(&[combined, src_path.to_string()]);
```

**Step 2: 函数定义 emit(两遍:扫描 let 建帧 → emit 函数体)**

```ql
// emitFunction(node, name):node = {type:"Function", parameters, body}
// 产物:define i64 @ql_fn<N>(i64 %env, i64* %args, i64 %argc)
// 帧 = [parent=函数定义时 env][n = 参数数 + 函数体顶层 let 数][参数 slot 0..k-1][let slot k..]
// 闭包盒 [tag=7][code=@ql_fn<N>][env=定义时 env 寄存器]
let emitFunction = (node, name) -> {
  let fname = "ql_fn" + std.String.toString(funcCounter);
  funcCounter = funcCounter + 1;
  // 第一遍:push 作用域 = 函数帧(参数),扫描 body.statements 的顶层 Let 分配 slot
  scopePush(curScopeSnapshot());          // 定义时作用域
  let k = node.parameters.length;
  let p = 0;
  while p < k {
    defineSlotAt(node.parameters[p].name, p);   // 参数占 slot 0..k-1
    p = p + 1;
  };
  let i = 0;
  let bodyStmts = node.body.statements;
  while i < bodyStmts.length {
    if bodyStmts[i].type == "Let" {
      defineSlotAt(bodyStmts[i].name, k); k = k + 1;
    };
    i = i + 1;
  };
  // 第二遍:emit
  line("define i64 @" + fname + "(i64 %env, i64* %args, i64 %argc) {");
  line("entry:");
  // 参数读入帧:args[0..k) → slot 0..k-1
  let a = 0;
  while a < node.parameters.length {
    let ro = temp(); let rv = temp();
    line("  " + ro + " = getelementptr i64, ptr %args, i64 " + std.String.toString(a));
    line("  " + rv + " = load i64, ptr " + ro);
    // 帧构造:[parent=env][n][slots...]
    emitFrameStore(env0, rv, a);
    a = a + 1;
  };
  // 函数体顶层 let 初始化为 NULL 单例?—— v1:let 带初值,emit 时按普通 let 处理(见下)
  emitBlockStmts(bodyStmts);
  line("  ret i64 0");                    // 无返回语句 → 默认 null(v1 简化;显式 return M2)
  line("}");
  scopePop();
  // 闭包盒(定义处):[tag=7][code=@ql_fn<N>][env=当前 env]
  emitClosureBox(fname, env0);
};
```

> **参数/let 帧布局实现要点**:函数体顶层 let 的值来自 `emitLetStmt`(Task 5),但 let 会新建帧 —— 这与"函数体一帧"矛盾。v1 修正:**函数体内的 let 直接写函数帧的固定 slot**(`emitLetStmt` 在函数体内改为 `store` 到函数帧 slot,不新建帧)。实现:emit 函数时维护 `fnFrameSlot = {name→slot}`,`emitLetStmt` 若在函数体内 → 直接 store 到函数帧;顶层(global)→ 新建帧。这是本 task 的**关键语义点**。

**Step 3: 调用 emit**

```ql
let emitCall = (node) -> {
  if node.callee.type == "Identifier" && node.callee.name == "print" || node.callee.name == "println" {
    // 特例已删:print/println 现在是 runtime.ql 普通函数,走通用调用
  };
  // 通用:emit callee → 闭包盒,emit 各参数 → i64,分配 args 数组,解引用 code/env,call
  let FN = emitExpr(node.callee);
  let n = node.arguments.length;
  let arr = temp();
  line("  " + arr + " = call ptr @ql_alloc(i64 " + std.String.toString(8 * n) + ")");
  let a = 0;
  while a < n {
    let AV = emitExpr(node.arguments[a]);
    let ao = temp();
    line("  " + ao + " = getelementptr i64, ptr " + arr + ", i64 " + std.String.toString(a));
    line("  store i64 " + AV + ", ptr " + ao);
    a = a + 1;
  };
  let cp = temp(); let code = temp(); let ep = temp(); let envv = temp(); let r = temp();
  line("  " + cp + " = getelementptr i8, ptr " + FN + ", i64 8");
  line("  " + code + " = load ptr, ptr " + cp);
  line("  " + ep + " = getelementptr i8, ptr " + FN + ", i64 16");
  line("  " + envv + " = load i64, ptr " + ep);
  line("  " + r + " = call i64 " + code + "(i64 " + envv + ", ptr " + arr + ", i64 " + std.String.toString(n) + ")");
  r;
};
```

**Step 4: 递归** —— 递归函数体内引用自身名字:函数帧的 parent 链要能达全局帧的 F。`emitFunction` 时函数帧 parent = 定义时 env(全局帧),`F` 在全局帧 slot。emitIdentifier("F") 在函数体内:函数帧无 → depth 1(沿 parent 到全局帧)→ 读全局帧 slot。**关键**:函数定义是 `let F = (n)->...`,emit 顺序 = 先 emit 闭包盒(store 到全局帧 slot),后 emit 函数体?不 —— emitFunction 需要先 emit 函数体(产生 define),闭包盒在 let 语句处 emit。全局帧 slot 在闭包盒 store 时已含 F。递归调用时读全局帧 slot 得到闭包盒。正确。

但 emitFunction 内部 emit 函数体时,`emitIdentifier("F")` 需 lookupSlot 命中全局帧 —— 作用域模型里函数体作用域的 parent = 全局作用域(含 F)。所以 `let F = ...` 先 defineSlot("F") 再 emitFunction。emit 顺序:emitLetStmt(F 定义)→ defineSlot(F) → emitExpr(Function) → emitFunction 内部 emit 函数体(此时 F 在作用域)。

**Step 5: 测试 + 三端验证**

`aot/tests/t7_factorial.ql`:

```ql
let fact = (n) -> {
  if n == 0 {
    1;
  } else {
    n * fact(n - 1);
  };
};
println(fact(5));      // 120
println(fact(10));     // 3628800
```

`aot/tests/t7_fib.ql`:

```ql
let fib = (n) -> {
  if n < 2 {
    n;
  } else {
    fib(n - 1) + fib(n - 2);
  };
};
println(fib(10));      // 55
```

验证命令同 Task 4,Expected: `120`、`3628800`、`55`。三端一致。

**Step 6: 删除 Task 4 print 特例 + `@ql_print_uint`/`@ql_truthy` 保留**(`@ql_truthy` 仍需;`@ql_print_uint` 删除,print 走 runtime.ql)。确认 `t4_arith.ql` 重新编译仍三端一致(runtime.ql 的 println 已覆盖 print 特例的语义)。

**Commit:**
```bash
git add aot/qlangc.ql aot/tests/t7_factorial.ql aot/tests/t7_fib.ql src/main.rs
git commit -m "feat(aot): qlangc functions/closures/recursion + compile runtime.ql into output (T7 three-way diff green)"
```

---

## Task 8: v1 正式测试集三端 difftest

**Files:**
- Create: `aot/tests/v1_factorial.ql`, `v1_recursion.ql`, `v1_fib.ql`, `v1_primes.ql`, `v1_accum.ql`, `v1_shortcircuit.ql`
- Create: `aot/run_v1_tests.sh`
- Modify: `.gitignore`(补 `.superpowers/` 行,顺带满足"文档不追踪 git"约束的目录隔离)

**Interfaces:**
- Consumes: Task 4-7 全部 emit 能力;Task 7 的 runtime.ql 编译。
- Produces: M1 出口 = v1 测试集 HOST/BOOT/NATIVE 三端逐字节一致。

- [ ] **Step 1: 写六个测试程序**

`aot/tests/v1_factorial.ql`(与 t7_factorial 同构);`v1_recursion.ql`(递归深度计数,如 `let depth = (n)->{ if n==0 {0} else {1+depth(n-1)} }; println(depth(100));` → `100`);`v1_fib.ql`(t7_fib);`v1_primes.ql`:

```ql
let isPrime = (n) -> {
  if n < 2 {
    false;
  } else {
    let i = 2;
    let ok = true;
    while i * i <= n {
      if n % i == 0 {
        ok = false;
      };
      i = i + 1;
    };
    ok;
  };
};
println(isPrime(17));   // true
println(isPrime(100));  // false
```

`v1_accum.ql`(累加和);`v1_shortcircuit.ql`(t6 短路用例)。各文件含 3-6 行 println。

- [ ] **Step 2: 写 `aot/run_v1_tests.sh`**

```bash
#!/usr/bin/env bash
# v1 测试集 HOST/BOOT/NATIVE 三端逐字节一致
# 用法:bash aot/run_v1_tests.sh
set -u
QLANG=${QLANG:-./target/debug/qlang}
cd "$(dirname "$0")/.."
fail=0
for t in aot/tests/v1_*.ql; do
  name=$(basename "$t" .ql)
  # HOST
  $QLANG "$t" > /tmp/v1_${name}.host 2>&1
  # BOOT(剥离 12 行 banner + Execution complete.)
  $QLANG bootstrapped/run_file.ql "$t" > /tmp/v1_${name}.boot_raw 2>&1
  tail -n +13 /tmp/v1_${name}.boot_raw | grep -v '^Execution complete\.' > /tmp/v1_${name}.boot
  # NATIVE
  $QLANG --compile "$t" -o /tmp/v1_${name}.bin >/dev/null 2>&1
  /tmp/v1_${name}.bin > /tmp/v1_${name}.native
  if diff -q /tmp/v1_${name}.host /tmp/v1_${name}.native >/dev/null \
     && diff -q /tmp/v1_${name}.host /tmp/v1_${name}.boot >/dev/null; then
    echo "PASS $name"
  else
    echo "FAIL $name"
    diff /tmp/v1_${name}.host /tmp/v1_${name}.native
    diff /tmp/v1_${name}.host /tmp/v1_${name}.boot
    fail=1
  fi
done
echo "---"
if [ $fail -eq 0 ]; then echo "v1 suite: ALL PASS"; else echo "v1 suite: FAILURES"; exit 1; fi
```

- [ ] **Step 3: 运行全量验证**

```bash
chmod +x aot/run_v1_tests.sh
cargo build --quiet
bash aot/run_v1_tests.sh
# 既有纪律不回退
cargo test --quiet 2>&1 | tail -5
./target/debug/qlang bootstrapped/run_file.ql demo/type_gymnastics.ql | tail -1   # RESULT: 419/419
```
Expected: `v1 suite: ALL PASS`;cargo test 绿;`RESULT: 419/419 asserts passed`。

- [ ] **Step 4: `.gitignore` 补行 + Commit**

`.gitignore` 末尾加 `.superpowers/`(与 `.claude/`/`.vscode/` 同理,隔离未追踪的计划/ledger 目录)。

```bash
git add aot/tests/v1_*.ql aot/run_v1_tests.sh .gitignore
git commit -m "feat(aot): v1 test suite (factorial/recursion/fib/primes/accum/shortcircuit) three-way byte-identical (M1 gate)"
```

---

## Self-review

**Spec coverage:** M0 出口(全盒 ABI/alloc/write/exit/数字→文本)= Task 1-2;M1 v1 语言面(Number/算术/比较/逻辑、let/assign、if/while、函数/闭包/递归、字符串字面量、leaf 调用、runtime.ql 编译进产物)= Task 3-7;M1 出口(v1 测试集三端字节一致)= Task 8。spec 的 leaf 4-5 函数、host 零新 native、LLVM-only 工具链、文档不追踪 git、三端一致纪律均逐条落进 task。柯里化后置(v1 精确匹配 + 多传忽略)在 Task 7 函数调用 emit 中按 arity 只读前 n 参数实现。字符串字面量 emit 未独立成 task —— 归入 Task 4 的"字面量"组(数字已完成,字符串 `.rodata` + STRING 盒按「IR 与值模型约定」实现,print 特例在 BOOL 分派旁加 STRING 直通;若时间紧,字符串字面量验证可延到 M2,因 v1 测试集全数字 —— 在 Task 8 测试集中无字符串,不影响三端 gate)。

**Placeholder scan:** 无 "TBD/TODO"。`@ql_print_uint`/`@ql_truthy` 在 Task 4 Step 3 以"结构 = Task 2 print_uint + BOOL 分派"引用,具体 LLVM 文本由实现按既有 print_uint 逐行展开 —— 不是占位符,是"复用已给模板"。boot AST 语句包装名(ExprStmt)标注了"以实测为准适配分支名",语义不变。

**Type consistency:** 环境帧布局 `[parent][n][slots...]` 在 Task 5/7 一致;`emitExpr → 寄存器名` 一致;`@ql_truthy(i64)→i1` 一致;`@ql_print_uint(i64 %box, i1 %nl)` 在 Task 4 定义、Task 7 删除,调用点随删。`__itoa(n)→{buf,len}` 契约 Task 2 定、Task 7 编译,一致。

**Known risks (执行时裁决,记录进 ledger):**
1. boot `import` 相对路径行为(Step 2 的 runtime.ql import 与 Task 7 拼接)以实测为准。
2. QLang 字符串转义(`\0A`)与 `std.String.fromCodePoint` 可用性以实测为准(有 fallback)。
3. LLVM `phi` 短路合并需正确处理 A 短路返回原值盒(Task 6 已给语义)。
4. 函数体 let 直接写函数帧 slot(Task 7 关键语义点)需与 boot Environment 语义对齐(boot 函数体 let 全在函数帧)。
