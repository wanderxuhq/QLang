# AGENTS.md — QLang 接手地图

> 给在此仓库工作的 agent 的项目地图。**先读这一页,再读 `docs/unboxed-values-handoff.md`。**
>
> 核对点:2026-10-25,分支 `rust-error-model`(从 `error-carried` @ `5d0f4e8` 切出)。
> 当前待办、IR/机器数、基线状态以 **`docs/unboxed-values-handoff.md`** 为准;
> 语言行为事实以 **`docs/unboxed-values-probes.md`** 为准(不在那份里的,一律视为"未验证");
> **Rust 式错误模型的当前口径以 `docs/rust-error-model.md` 为准**,它与 handoff 冲突时优先。

## 0. 五分钟

- QLang 是动态类型语言。`bootstrapped/` 里的 lexer/parser/AST/interpreter 是**语言核心**,用 QLang 自己写。
- `aot/qlangc.ql` 复用同一前端,把 AST 编成 LLVM IR;`aot/runtime.ql` 是编进产物的运行时;
  `aot/runtime.c` 只是分配/syscall 叶子。
- Rust(`src/`)是**保留的初始 bootstrap 宿主与嵌入层**,不是语义权威;除非阻塞 QLang 工作,否则不要改。
  它的已知差异记录在 `docs/retained-rust-issues.md`,记录而不顺手修。
- 当前主线不是"加功能",而是两条:**编译期信息更足 ⇒ 发射更少指令**,以及**重做错误模型**
  (让声明的类型是真话,使"它会不会是 Error"的检查能系统地消失)。
- 验收看 `clang -O2` 之后的 **AArch64 机器指令数**,不看 IR 行数。
- 最重要的文档:
  - `docs/rust-error-model.md` — **当前分支的实现口径**:Rust 式 `Result`/`?`/panic 设计、切片与状态。
  - `docs/unboxed-values-handoff.md` — 自包含交接:状态、账、待办 A–L、规矩、位置索引。
  - `docs/unboxed-values-probes.md` — **历史行为事实来源**:每条结论带复现命令。
  - `docs/unboxed-values-log.md` — 历史过程;数字多数已过时,只作考古。

## 1. 目录地图

| 路径 | 是什么 |
|---|---|
| `bootstrapped/` | QLang 写的 lexer/parser/AST/interpreter/environment/stdlib/modules。共享前端;纯解释执行的引擎("boot")。 |
| `aot/qlangc.ql` | QLang 写的 LLVM 发射器;读 AST 与分析结论,输出 IR 文本。 |
| `aot/types.ql` | 生成代码**之前**的编译期分析:类型、表示(裸/装箱)、`cannotBeError`、守卫后的收窄。 |
| `aot/runtime.ql` | 编进产物的运行时语义;内存/对象/字符串/错误/库安装。 |
| `aot/runtime.c` | 语言表达不了的 C 叶子:分配、GC、`ql_mem_*`、`ql_write/read`、文件 syscall、`ql_getrandom`、`ql_extension_open`。 |
| `aot/value_abi.ql` | `alwaysinline` 热机制叶子(`ql_empty`/`ql_tag`/`ql_word`/`ql_truthy` 等)。 |
| `stdlib/` | 可移植标准库源码(QLang)、`manifest.json`、打包后的 `bundle.ql`。 |
| `demo/type_gymnastics.ql` | 419 条类型系统断言;两引擎必须输出一致。 |
| `aot/tests/` | 原生夹具(`t*.ql` + `.expected`)、模块/扩展/诊断子目录。 |
| `bootstrapped/tests/` | 前端/AST/源码位置/诊断夹具。 |
| `aot/run_*.py`, `aot/run_v1_tests.sh` | 原生/自举/诊断/模块/赋值/链接等测试驱动。 |
| `stdlib/run_string_tests.py` | String 专用套件 + 独立 Unicode 预言机。 |
| `difftest.py`, `fuzzexpr.py` | 三方差分与随机表达式模糊测试(本机 difftest 不可裁决,见 §2.7)。 |
| `src/` | Rust 保留实现与 bootstrap CLI;`tests/*.rs` 是 Rust 宿主测试。 |
| `docs/` | 交接、证据、路线图、语言契约。入口见 §8。 |

## 2. 构建 / 运行 / 验收

### 2.1 Rust 宿主(只用于 bootstrap/兼容)

```sh
cargo build --release --offline
./target/release/qlang prog.ql                         # Rust 宿主解释执行
./target/release/qlang --compile prog.ql -o /tmp/p     # Rust 便捷驱动:raw clang,不做 ELF 校验
```

- `target/{debug,release}/qlang bootstrapped/run_file.ql ...` **已知会挂起**(2026-10-09 起,
  见 `docs/retained-rust-issues.md`)。不要拿它跑 boot 侧验收,也不要指望 `difftest.py` 的 boot 腿。
- Rust `--compile` 不导出扩展宿主符号;扩展必须走 QLang 编译器 + `aot/native_link.py`。

### 2.2 Native 编译器(发布路径)

```sh
QLANG=./target/release/qlang python3 aot/run_selfhost_tests.py --self --output-dir target/selfhost
# 产出 target/selfhost/stage2;stage2/stage3 的 IR 必须逐字节相同

target/selfhost/stage2 --emit-llvm prog.ql aot/runtime.ql > /tmp/p.ll
python3 aot/native_link.py /tmp/p.ll -o /tmp/p
/tmp/p
```

- `--emit-module` 用于单独编译的 native 扩展。
- **快路径(2026-10 起)**:标准库可以只编一次再链接。
  `aot/stdlib_split.py <compiler>` 产出 `target/stdlib/<hash>/{stdlib.o,symbols.tsv,interface.txt}`;
  `stage2 --emit-llvm-split <源码> <runtime> <symbols.tsv> <interface.txt>` 只发用户模块
  (`{interface}` 传 `-` 则回落到「从源码分析」的对照路径);`native_link.py --stdlib-object`
  或环境变量 `QLANG_STDLIB_OBJECT` 链接对象。单夹具构建 ~22s → ~1.7s。
  两套主门禁会自动构建并启用它。测量见 `docs/unboxed-values-probes.md` §22-§29。
- `native_link.py` 用单线程 LLD,并校验每个静态字符串的 ELF 重定位/字节;不要绕过它直接 clang 链接。
- 改 `aot/qlangc.ql` 之后必须重建编译器。编译器、源码、夹具必须**同源**(同一版本)。

### 2.3 Native 解释器

```sh
python3 aot/run_interpreter_tests.py --compiler target/selfhost/stage2 --output-dir target/native-interpreter
target/native-interpreter/interpreter prog.ql
```

它把 `bootstrapped/run_file.ql` 编成独立可执行;正常输出被 `Interpreting...` 和
`Execution complete.` 包裹。

### 2.4 门禁

```sh
python3 aot/run_selfhost_tests.py --compiler target/selfhost/stage2
python3 aot/run_interpreter_tests.py --compiler target/selfhost/stage2 --interpreter target/native-interpreter/interpreter
python3 aot/run_assignment_tests.py --compiler target/selfhost/stage2 --interpreter target/native-interpreter/interpreter
python3 aot/run_semantic_diagnostic_tests.py --compiler target/selfhost/stage2
cargo test --offline          # 14 tests;钉住 Rust 宿主行为,不等于 QLang 前端行为
```

- 全量基线 = handoff §3.4 列出的套件(约 23 个 python runner + `run_v1_tests.sh`)
  外加 `stdlib/run_string_tests.py`、`cargo test`;清单、耗时、环境缺口以那节为准。
- **验收 = 全量基线 + 本次改动相关套件**。只跑 `interpreter` + `selfhost` 会漏红:
  `probes §11.1` 的两处漂移红恰好被这两套漏掉。
- 基线必须**同源**:同一 commit 的源码 + 编译器 + boot + 夹具。混源只会制造假失败。
- 长套件(interpreter ~731s、selfhost ~1573s)用可跟踪的后台任务跑,不要 `&`/`disown`。
- `run_selfhost_tests.py` / `run_interpreter_tests.py` 支持 `--jobs N` 并行跑独立夹具
  (默认 1)。配合标准库对象,selfhost 全套 ~3 min、interpreter ~6 min;内存是上限
  (单个 `clang -O2` 吃 GB 级),别把 N 开太大。

### 2.5 头条指标

```sh
# /tmp/t20.ql:22 行,输出必须是 20
{ echo 'let x: Number = 0;'; for i in $(seq 20); do echo 'x = x + 1;'; done; echo 'println(x);'; } > /tmp/t20.ql

/tmp/o --emit-llvm /tmp/t20.ql aot/runtime.ql > /tmp/ir.ll
wc -l /tmp/ir.ll                          # IR 行数(参考)
clang -O2 -S /tmp/ir.ll -o /tmp/ir.s     # 先确认 0 error(模块合法)
grep -cE '^\s+[a-z]' /tmp/ir.s           # AArch64 指令行数(机器指令口径)

/tmp/o --emit-llvm /tmp/t20.ql aot/runtime.ql | grep '^;'   # unboxable / located-error / rawABI 计数器
```

- handoff 的账(仅历史对照,不要当当前值):`394e473` IR **188,577** / 机器 **125,473**;
  子片 A 落地后工作树 **187,738** / **125,479**(+6 已解释)。当前 HEAD 含该笔,重测为准。
- IR 行数下降是**可疑信号**:先验证 `clang -O2 -S` 无错,再以机器指令裁决。
  反例:删 `llvm.lifetime` 使 IR −10,444、机器 +3,861 ⇒ 已否决,不要重开。
- `/tmp/t20.ql` 是会话遗留探针;丢了就用上面的命令重建(内容就是 20 次 `x = x + 1`)。

### 2.6 stdlib bundle

```sh
./target/release/qlang stdlib/build_bundle.ql > /tmp/qlang-library-bundle.ql
# 检查/审阅后再发布:
cp /tmp/qlang-library-bundle.ql stdlib/bundle.ql
./target/release/qlang stdlib/build_bundle.ql --check
```

- 改 `stdlib/*.ql` 后**必须**重建 `stdlib/bundle.ql` 并 `--check`;`manifest.json` 管依赖与导出顺序。
- 保持 `core.autocrlf=false`;CRLF 工作区会让 `--check` 假报过期,并悄悄改变编译器解析的源文本。

### 2.7 本机环境

- aarch64 Linux/Android(`aarch64-unknown-linux-android24`),clang 21.1.8 + lld,
  Python 3.13,cargo/rustc 1.97(以实际机器为准)。
- 没有 `package.json`。Python 只是测试/链接/数据生成工具,不是语言运行时。
- `difftest.py` 在本机**不可裁决**(Rust 宿主跑 boot 超时);替代:用 native 编译的 boot 做同样对照。
- `clang` 覆盖 target triple 的 warning 是正常的。

## 3. 语言与语义要点(写代码前必看)

### 3.1 类型是数据(types as data)

- 类型值 = 带可调用 `check` 字段的普通对象;成员测试是 `T.check(v)`。类型**没有名字**,
  `Number`/`String` 等只是全局绑定。
- `let x: T = v` 在声明时检查;参数注解在**完成调用**时检查(部分应用不查);
  重赋值再审;注解是完整表达式,在出现处求值。
- 检查失败产生 `TypeCheck` 错误值,不是崩溃;若 `check` 自身出错,检查**失败**,并把该错误值直接作为绑定值。
- `Array` / `Object` 是**构造器函数**(恰好 1 参),不是类型值:
  `Array(Number)`、`Array(3)`、`Object({name: String})`。
- 联合类型的规范构造子是 `A | B`,用 `std.Type.make` 组合:
  `let Union = (A, B) -> std.Type.make((v) -> A.check(v) || B.check(v));`
  `Result(T) ≡ T | Error`、`Option(T) ≡ T | Null` 已在 `stdlib/result.ql` 实现;
  `?` 只允许在返回注解为 `Result(...)`/`Option(...)` 的函数(无注解/顶层为迁移期例外)。
- `std.Type` 同时是类型值和模块;`std.Type.of` 返回**类型值**;内建类型对象的
  `check`/`raise`/`of`/`make` 受保护。`Error.raise(msg[, cause])` 构造错误值(不再是 `Error("msg")`)。

### 3.2 错误是值(errors as data)

- 没有 throw/catch。错误是普通值,用 `isError`、后缀 `?`(传播)、`??`(错误回退)处理。
- `?`:函数内立即返回该错误;顶层打印诊断到 stderr 并 **exit 1**。
- `??` 只接 **Error**,不接 `null`:`null ?? 7` 仍是 `null`;`(1/0) ?? 7` 是 `7`。
- `assert(condition, message)` 是**契约检查**而非错误处理:成功返回 `null`,失败打印
  `AssertionFailed: <message>` 到 stderr 并 **exit 1**;失败不是 Error 值,不能被 `?`/`??`/`isError` 捕获。
- 错误值只在三处合法:传播;读取自身字段(`.type/.message/.cause/.line/.col`)/打印;
  其余(算术、比较、索引、成员访问、序列化、**作为函数实参**)会产生新的链式 Error。
- `Error` 值是 truthy,`!err` 是 `false`(已知不对称,两引擎一致)。
- 常见 kind:`TypeMismatch`、`IndexOutOfBounds`、`UndefinedField`、`UndefinedVariable`、
  `Uninitialized`、`DivisionByZero`、`StackOverflow`、`ArityMismatch`、`NotCallable`、`TypeCheck`、用户 `Error`。
- 未处理错误/顶层 `?` ⇒ exit 1;`runSource` API 则返回结果记录(嵌入用)。

### 3.3 确定赋值(definite assignment)

- `let x;` 只建立绑定;在**同一作用域直接读**它,前端报编译错误
  `reading uninitialized variable: NAME`。
- `if`/`else` 汇合取合取;循环体内赋值永不构成确定;`return` 终止可达性。
- 跨函数/闭包、经别名或原生调用的读取,保留运行期 `Uninitialized` 错误值(对捕获做保守过近似)。
- `let x;` 仍建立词法作用域并遮蔽外层绑定;`null` 是已初始化的值,不是未初始化状态。

### 3.4 语法/求值

- 语句只在 `;` 结束(或块语句的 `}`);**换行不是终止符**。块尾的 `;` 可省。
- `if`/`while`/裸块在 `}` 结束;`if c { ... };` 的 `;` 是空语句。
- 链式赋值 `a = b = 1` 是语法错误;`return` 只允许在词法函数体内(顶层/模块顶层 return 是语法错误)。
- 没有 `undefined`;`{key: value}`(JSON5)、`{name}` 简写;`{}` 是空对象,不是 null。
- 数字全为 f64;除以精确 0 ⇒ `DivisionByZero`;IEEE 溢出保留 inf;`+` 类型严格(无隐式转换);
  `==` 类型严格,数组/对象按引用比较;负索引 wrap 到 `len + i`。
- 真值:`0`/`-0`/`""`/**空数组**/`false`/`null` 为假;非空字符串/数组、对象、函数、Error 为真。
  (README 的"数组恒真"是旧说法;以 `aot/value_abi.ql` 的 `ql_truthy` 与实测为准。)
- 函数:参数不足是**合法部分应用**;字面量函数超参是编译错误;经变量/原生调用超参是运行期
  `ArityMismatch`;`Math.max/min` 是变参原生。闭包按身份比较;递归深度上限 300(今天 `StackOverflow`
  是运行期值,待办 B1 计划改成致命)。
- import:字面量路径相对**定义它的源文件**;每次 import 执行新模块;静态循环允许,
  重入初始化 = `ImportCycle`;计算式 `import (expr)` 加载单独编译的 native 扩展;没有运行期源码编译器/JIT。
  未执行分支/未调用函数里的 import 不会初始化。
- export:导出表属于定义它的模块;初始化失败不合并导出,不覆盖调用方已有绑定/注解。
- `std` 算法必须在 `stdlib/*.ql`;**runtime 只提供机制**,不得把库算法塞进 `std`;
  普通对象/标量没有特权,类型值/`.check`/`.length` 等真正的语言级契约才可例外。

### 3.5 写 QLang 源码

- 没有 `for`/`match`/try-catch;用 `while`/`if`;每句 `;`。
- 用 `isError(x)` 守卫;不要用 `"x" + number` 当探针(它本身是 `TypeMismatch`,会污染观测)。

- **数值热路径的函数值得写参数 + 返回注解**(`(a: Number, b: Number): Number`):实测同一
  5M 循环,带注解 5.7ns/次、无注解 601.6ns/次(105×,probes §36)。字符串/对象搬运型函数
  加了反而负收益(参数检查照付、String 没有裸表示),等 String 裸 ABI 再说。
- 构造错误用 `std.Error.raise`;不要让 Error 作为普通实参。
- 只消费分析结论,不在发射器里二次推断;新增机制先看 §4 的四条通道。

## 4. 编译器架构

```text
source.ql
  └─ bootstrapped/lexer.ql → parser.ql → ast.ql        (共享前端;语法糖在此归一)
       ├─ bootstrapped/interpreter.ql + environment.ql (纯解释执行)
       └─ aot/types.ql                                 (生成前分析:类型/表示/cannotBeError/收窄)
            └─ aot/qlangc.ql                           (只消费结论,发 LLVM IR)
                 ├─ aot/runtime.ql                     (编进产物)
                 ├─ aot/value_abi.ql                   (alwaysinline 热机制)
                 └─ aot/runtime.c                      (13 个 syscall/alloc 叶子)
                      └─ clang + lld (aot/native_link.py) → ELF
```

- **分析算,发射器只消费**;发射器不做类型推断,不维护与发射顺序耦合的状态。
- **表示属于值,装箱属于使用点**:一个值的表示由分析决定一次;需要盒的消费者在自己那一处付账。
- **每个节点一条发射路径**,由盖在该节点上的编译期事实选择。
- 机制只有四条通道,不要发明第五条:
  1. C 宿主原语(`aot/runtime.c`,仅 `inRuntime` 可写);
  2. `aot/value_abi.ql` 的 `alwaysinline` 热叶子;
  3. 编译器自己发的固定名冷助手(先例 `@__cold_located_error`;子片 A 的 `@__panic_exit` 照它);
  4. 程序可见的 `std` 面(`aot/runtime.ql` 的 `std` 字面量 + `__install_library`)。
- 自举:stage2/stage3 的 IR 逐字节一致;native 编译器能重建自身,不依赖 Rust。
- Rust 只是 bootstrap/嵌入;`src/` 的差异记录在 `docs/retained-rust-issues.md`。

## 5. 当前状态(2026-10-17)

- **2026-10-25 更新**:新分支 `rust-error-model`(从 `5d0f4e8` 切出)开始落地 Rust 式错误模型;
  口径与切片见 **`docs/rust-error-model.md`**。它与 `unboxed-values-handoff.md` 冲突时,以新文件为准。
  当前切片已做:注解检查成功协议、`std.Option(T)`、`?` 只允许在 `Result`/`Option` 注解函数(无注解仍允许,迁移期)、
  Option 的 `?`（parser 内部标成 `?Option`,native 传 Null,boot 用 Return completion）、
  `cannotBeError` 健全性门、boot 库函数导出修复、用户级 `assert`(契约违反 ⇒ fatal,两引擎同一实现)。
- **2026-10-26**:P0 直接调用/纯 Number 内联落地(不可变 leaf 绑定的直接 boxed 调用;
  单调用点纯 Number 函数 raw 内联)。判别 `t58_direct_calls` / `t59_inline_pure`。
- **2026-10-26**:P1 多调用点 raw 直接函数落地(无 value use 的注解 Number leaf:
  不生成闭包盒/annotations/boxed 入口,绑定槽存定义环境指针)。判别 `t60_raw_direct`;
  设计/边界见 `docs/direct-call-optimization.md`。
- **2026-10-26**:P2 裸返回 + known-safe 传播(proven Number 的函数 `ret double`;
  纯参数单调用点调用证明不可能 Error,累加器不再 prone,无新增运行期检查)。
  判别 `t61_known_safe`;5M 累加器 9.6s→0.011s。放宽 leaf 未做。
- **2026-10-26**:P3 放宽 leaf(raw 函数体允许调用;排除自递归/后定义/Import,
  允许局部函数与源序在前的函数)。判别 `t62_leaf_calls`;5M 组合调用 9.07s→0.039s。
- 原分支 `error-carried` @ `5d0f4e8`(已推 `origin`);从 `unboxed-values` 的 `394e473` 切出。
- `unboxed-values` 已推 `origin`,**未合并**;合并前需作者明确同意。
- `backup/nan-removal-stage1` = "去 NaN/∞"回滚现场;`error-carried` 合并后可删。
- `/tmp/wt_head` 是 `394e473` 的 worktree;用完 `git worktree remove`。
- 最近两笔:
  - `77b806a` 错误模型:契约违反(运行期绑定缺失)⇒ 致命 —— 机制 + 两引擎实测。
  - `5d0f4e8` 夹具漂移修复 + handoff/probes 文档(含两处 HEAD 上的真红)。
- 账:见 handoff §3.1;头条 IR/机器数 + 输出 `20`。子片 A 落地 **IR −839 / 机器 +6**(已解释:
  `std.__panic` 让 `__panic` 的闭包盒变为可达)。
- 待办(完整定义见 handoff §4;按依赖排序):
  - **A(优先)**:子片 A 收尾 —— ①关键套件重跑绿 ②提交/push(已做)③补"运行期缺失绑定 ⇒ 致命"
    的拒绝用例(现有 interpreter harness 是单文件用例,这条需要模块,先看能否加多文件支持)。
  - **B**:统一"判不了的运行期路径"判据 —— 有值形态的答案 ⇒ Error 值(总函数化);
    没有值形态 ⇒ 致命;能静态判定的 ⇒ 编译错误。
    - B1 `StackOverflow` ⇒ 致命(3 站点:`runtime.ql:2040`、`interpreter.ql:1141-1143`、`src/interpreter.rs:765-768`;
      夹具 `t24` + `difftest` e21/r28;文档 `README:1045/1072/1100`)。半径最小,建议先做。
    - B2 缺失字段/索引 ⇒ `Null`(站点 `runtime.ql:128/202/344/349`、`:287/304`;
      boot `interpreter.ql:505/832`;夹具 t20/t21/t28/t29/t30/t32/t37/t38/t39/t49/t51 等)。
    - B3 运行期 arity ⇒ 致命(仅"经变量/原生函数调用"时触发;字面量超参已是编译错误,
      参数不足是合法部分应用)。站点 `runtime.ql:1941`;`interpreter.ql:1046/1097/1120`。
    - B4 `/0` 保持 `DivisionByZero` Error 值 —— 改成 IEEE 的候选已评估,要动三方差分预言机与双引擎断言,
      代价不抵,**已定不动**(不要重开)。
  - **C**:用户级 `assert` **已落地**(runtime 定义、`__native` 注册、boot 装同一实现;
    夹具 `t57_assert` + 两驱动 fatal 用例)。`expect` 仍未做,与 Result/Option 辅助函数一起设计。
    见 `docs/rust-error-model.md` §3.6。
  - **D**:cause 链 provenance 真 bug(probes §12):`chained.cause.line` 给读取所在的绑定行,
    而不是来源行。先逐语句 bisect 证实/证伪,再修 **`runtime.ql:97-120`** 的守卫。
    验收 `t38:38` 转绿。**不要改那条断言**,它在正确抓 bug。
  - **E**:错误载体的类型面:`Result(T) ≡ T|Error`、`Option(T) ≡ T|Null`;`Result(T,E)` 的
    `E` 是 Error 家族的收窄,不是第二载体;载荷 schema 与穷尽性一起暂缓。
  - **F**:std 注解(作者要求零收益也要写):返回注解免费;参数注解 = 每调用点一次内联检查
    (实参类型已证才免费);对象/数组返回今天净负(+164),缓。改完重建 bundle。
  - **G**:原始 ABI(P0/P1 已做直接调用、纯 Number 内联、多调用点注解 Number 参数;
    余:裸返回、放宽 leaf/同名 import、prone 实参)。
  - **H**:std 整链(280 个函数中 189 个只能经闭包码指针到达;只有真惰性/按需实例化能删)。
  - **I**:穷尽性/消费点确认(无 `match`;可枚举联合可做成员级;谓词型只能"确认";
    落在 `types.ql` + `compileDiagnostic`;验收 IR/机器逐字节不变)。
  - **J**:既有未完成:注解分批规则、非零字面量除数、②c 错误边计数器、builder 卫生。
  - **K**:基线卫生/仓库:module 环境缺口、extension 先于本次红、platform 需 release;
    4 项未纳入基线;difftest 不可裁决;清理 `_b.ql`/`_df_*`/worktree/backup。
  - **L**:未验证隔离区(不许当结论用)。
- 已知红(最后一次记录;重跑确认):`runtime_diag` 的 cause-provenance(`t38:38`)是真 bug;
  `module` 是环境缺口(需 debug 宿主;宿主跑 boot 太慢/超时);`extension` 在 HEAD 上也红。
  `assignment`/`runtime_diag` 的夹具漂移已在 `5d0f4e8` 修(assignment 应绿;runtime_diag 仍因 D 红)。

## 6. 工作纪律(硬规则)

1. **分析算,发射器只消费**;不二次猜测。
2. **表示属于值,装箱属于使用点**;一个值的表示只由分析决定一次。
3. **每个节点一条发射路径**,由节点上的编译期事实选择。
4. **普通对象无特权**;runtime 只提供机制,绝不把辅助函数塞进 `std`。
5. **编译期事实 > 运行期检查 > 错误地沉默**;能静态判定的违反 ⇒ 编译错误。
6. **不动你没读过的代码**;改语义前先问作者。
7. 每步先报**命中数**,再报行数/指令数;**无收益不背复杂度**(回滚并记录)。
8. **探针必须带对照组**;观测手段不能是会改变语义的操作。
9. **验收 = 全量基线 + 相关套件**;**基线必须同源**。
10. 不凭表面语法评判类型系统能力;先查 `README.md` 类型系统一节与 `tests/type_system.rs`。
11. 不确定就不下结论,写进 probes §10 隔离区;下结论前先查 probes。
12. 长任务必须可跟踪(后台任务,不 `&`/`disown`);不隐藏 stderr;网关输出不 `| tail`。
13. 提交按主题拆;信息写清 IR/机器数 + 验收结果;完成后 push。
14. 不改 `docs/*/taste*` 等自动管理文件;不擅自提交别人未跟踪的文件。
15. 文档:交接自包含;证据/过程放 log/probes;作者要双语文档时加 `.zh.md` sibling。

**作者偏好(从仓库 taste/提交习惯归纳)**:中文、简洁、自主推进(少问"要不要");
先测量再改(以 `-O2` 机器指令为准);新语言特性/公开能力先确认,既有行为修复可直接做;
不要为历史兼容背包袱;反对特判/"看人下菜",要统一规则;`std` 必须 QLang;长任务可见;
完成后 commit + push。

## 7. 陷阱(按血泪排序)

1. **`staticType` ≠ 运行期类型**:`&&`/`||` 被盖章 Boolean 却返回**操作数**;会失败的调用可能返回 Error。
   信任 `staticType` 的优化必须带 `cannotBeError` 护栏;凡触碰值语义必须跑差分套件。
   ⑩-3(直读 Boolean payload)已整笔回滚 —— 数字好看但打红差分套件。
2. **`?Error` 有三种来源**:打印 Error 值(渲染)、对普通值取不存在的域、异类相加的错误被打印。
   **它不是"类型缺失"。**
3. **混源基线** = 假失败:拿 A 版编译器跑 B 版源码/夹具。
4. **验收过窄**:只跑 `interpreter`+`selfhost` 会漏红;它们恰好对 `probes §11.1` 的漂移红都绿。
5. **行号敏感夹具**:`t38` 等按行号断言;改动必须等量替换(2 行换 2 行)。
6. **`check(true, ...)` / 可证真条件会被省略**:计数会下降,不是丢覆盖。
7. **探针污染**:`"x" + 数字` 在 QLang 里是 `TypeMismatch`;别拿它观测。
8. **运行期 `std` 过滤**:boot 把 `std.__*` 从用户面滤掉;新宿主通道照此办理。
9. **AST 不要挂节点引用**:发射器遍历所有属性,会成环卡死;用数值 id + 编译器内部表。
10. **unbox 按 `s.bindId`,不按名字**;按名字会把所有 std 注解悄悄废掉。
11. **Error 作为调用实参被拒**:`check(可能出错的调用, ...)` 会静默不计数;用 `isError`/`.type` 就地判断。
12. **IR 骤降先验模块合法性**(`clang -O2 -S` 0 error);机器指令才是指挥棒。
13. **`llvm.lifetime` 删除**:IR −10,444 / 机器 +3,861,已否决,不要再谈。
14. **shell 细节**:`/bin/sh` 无 `PIPESTATUS`;`ls -d /tmp/x* | tail -1` 会选错目录;
   不要 `>/dev/null` 藏链接错误(它会藏掉唯一线索)。
15. **`native_link.py`** 单线程 LLD + 静态字符串校验;失败会保留旧二进制,别以为链接成功。
16. **Rust 宿主跑 boot 会挂**;`difftest.py` 本机不可裁决;用 native boot 替代。
17. **CRLF**:保持 `core.autocrlf=false`;否则 bundle `--check` 假报。
18. **stdlib 改动必须重建 bundle**,否则运行时用的是旧库。

## 8. 改哪里 / 看哪里

| 想改 | 文件 |
|---|---|
| 语法/词法/解析/语法糖 | `bootstrapped/lexer.ql`, `parser.ql`, `ast.ql` |
| 解释执行语义 | `bootstrapped/interpreter.ql`, `environment.ql`;`aot/runtime.ql` |
| 编译期分析(类型/表示/收窄) | `aot/types.ql` |
| 代码发射 | `aot/qlangc.ql`;直接调用/raw ABI/纯 Number 内联见 `docs/direct-call-optimization.md` |
| 热机制/ABI 叶子 | `aot/value_abi.ql`;`aot/runtime.c` |
| stdlib 算法 | `stdlib/*.ql` + `manifest.json` + 重建 `bundle.ql` |
| 夹具/金文件 | `aot/tests/*.ql` / `.expected`;`bootstrapped/tests/*` |
| 测试驱动 | `aot/run_*.py`;`stdlib/run_string_tests.py`;`difftest.py`;`fuzzexpr.py` |
| 语言规范/类型系统 | `README.md`(类型系统在 767–970 行左右) |
| 模块语义 | `docs/module-semantics.md` |
| 诊断/源码位置 | `docs/source-diagnostics.md` |
| std 能力边界 | `docs/stdlib-capability-gaps.md` |
| Rust 差异 | `docs/retained-rust-issues.md` |
| 数组/对象/数字契约 | `docs/array-semantics.md`, `object-semantics.md`, `numeric-semantics.md` |
| 路线图 | `docs/compiler-next-steps.md`(+ 未跟踪的 `.zh.md` 译本) |
| Rust 式错误模型(当前分支) | `docs/rust-error-model.md` |

位置索引(handoff §7,以 `5d0f4e8` 为准;行号会漂):

- 冷助手先例:`aot/qlangc.ql:1701` 定义 / `main` 里 splice / 调用点手写符号调用。
- 子片 A 助手:`aot/qlangc.ql:1731` 旗标、`:1732-1760` 助手、`:964-967` 调用点。
- 静态/运行期两通道边界:`aot/qlangc.ql:814-846`(`emitIdentifier`;`:832` 的 `sameBody`)。
- `?` / `??` 发射:`aot/qlangc.ql:643` / `:552-553`;boot `interpreter.ql:713`;parser `parser.ql:825`。
- 契约违反的致命原语:`aot/runtime.ql:511`(`__panic`);`std` 字面量 `:1870`;boot 过滤 `interpreter.ql:44`。
- 用户级契约检查:`runtime.ql:787`(`assert`,同 `__panic` 通道);`qlangc.ql:25` 的
  `moduleGlobalNames` 负责让模块/函数解析到该槽;boot 直接装 runtime 的 `assert`(`interpreter.ql:105`)。
- provenance 记录:`aot/runtime.ql:96-129`。
- 类型值/派生类型:`aot/runtime.ql:1352-1362`;`README.md:809/827/867-872`;`tests/type_system.rs`。

## 9. 常用命令速查

```sh
# 编译一次(慢;自举 + 固定点)
QLANG=./target/release/qlang python3 aot/run_selfhost_tests.py --self --output-dir target/selfhost

# 快循环:用已有 stage2 编一个程序
target/selfhost/stage2 --emit-llvm aot/tests/t20_native_bridge.ql aot/runtime.ql > /tmp/x.ll
python3 aot/native_link.py /tmp/x.ll -o /tmp/x && /tmp/x
diff <(/tmp/x) aot/tests/t20_native_bridge.expected

# 门禁
python3 aot/run_selfhost_tests.py --compiler target/selfhost/stage2
python3 aot/run_interpreter_tests.py --compiler target/selfhost/stage2 --interpreter target/native-interpreter/interpreter
python3 aot/run_assignment_tests.py --compiler target/selfhost/stage2 --interpreter target/native-interpreter/interpreter
python3 aot/run_semantic_diagnostic_tests.py --compiler target/selfhost/stage2
cargo test --offline

# stdlib bundle
./target/release/qlang stdlib/build_bundle.ql --check

# 状态
git status --short; git branch -vv; git worktree list
```

## 10. 维护本文件

- 只放稳定地图:架构、命令、铁律、入口。易漂的数字(IR/机器/基线/待办状态)写到 handoff/probes。
- 目标长度 < ~25 KB;宁可指路,不要复制整份 handoff。
- 新增/修改后若要入库,按 `docs:` 主题单独一笔。
