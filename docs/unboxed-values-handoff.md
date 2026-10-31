# 交接:QLang 编译期削减 + 错误模型 —— 从零接手

**先读这份;它是自包含的。** 证据与实测细节在同目录的 **`docs/unboxed-values-probes.md`**
(标了 § 编号的引用都指它);本文件是**地图**,那份是**档案**。旧的长篇过程记录在
`docs/unboxed-values-log.md`(仅作历史,数字多已过时)。

---

## 0. 五分钟接手

| | |
|---|---|
| 当前分支 | **`rust-error-model`**(从 `error-carried` @ `5d0f4e8` 切出;含 2026-10-31 审查修复) |
| `unboxed-values` | 已推到 `origin`(`394e473`);**未合并**,合并前需作者明确同意 |
| 备份分支 | `backup/nan-removal-stage1`(「去 NaN/∞」那次回滚的现场,合并后即可删) |
| 头条指标 | `/tmp/t20.ql` 的 IR 行数 + `clang -O2` 后的 AArch64 **机器指令数**;**程序输出必须始终是 `20`** |
| 当前 HEAD(2026-10-31 三轮审查修复后) | IR **188 738** / 机器 **145 279**(相对修复前 187 736 / 142 367:+1 002 / +2 912;见 probes §122–§124) |
| 历史基线(`394e473`,口径不同) | IR **188 577** / 机器 **125 473** |
| 本会话历史区间 | 相对起点 `2cbc2e5`(194 640 / 129 040):**IR −4 752(−2.4 %)/ 机器 −3 440(−2.67 %)** |
| 2026-10-31 修复前同源编译器 | IR **187 736** / 机器 **142 367** |
| 第一轮修复后(中间值) | IR **188 630** / 机器 **145 187** |
| 第二轮修复后(中间值) | IR **189 275** / 机器 **146 238** |

```bash
# 1) 构建被测编译器(自举)
/tmp/nk --emit-llvm aot/qlangc.ql aot/runtime.ql > /tmp/o.ll && python3 aot/native_link.py /tmp/o.ll -o /tmp/o
# 2) 头条指标 + 探针
/tmp/o --emit-llvm /tmp/t20.ql aot/runtime.ql > /tmp/ir.ll
grep -E '^; (unboxable|located-error elided|rawABI)' /tmp/ir.ll   # 528 / 92 / …
# 3) 验收(见 §3.4:必须全量 + 同源)
python3 aot/run_interpreter_tests.py --compiler /tmp/o --interpreter <native 编译出的 boot>
python3 aot/run_selfhost_tests.py   --compiler /tmp/o
```

**同源规则(硬)**:编译器与源码必须**同一版本**;拿 A 版编译器去跑 B 版源码/测试用例,只会得到**假失败**
(本会话为此白跑一整轮,§11.2)。

## 1. 这是在做什么

QLang 自举,双引擎:**native AOT 发射器**(`aot/qlangc.ql`,运行时 `aot/runtime.ql`)与
**纯语言解释器**(`bootstrapped/*.ql`,即 boot),外加一个仓库内 Rust 兼容宿主(`src/`)。

两条并行的目标:

1. **让编译期信息更足,从而发射更少指令** —— 每次改动的形状都是:分析(`aot/types.ql`,在生成代码
   **之前**)算出**类型与表示**并盖在 AST 上;发射器只读这些结论;凡分析证明是死的,就直接不发。
2. **重做错误模型**(见 §4-B/§4-D):让**声明的类型是真话** ⇒ 各处「它会不会是 Error」的检查才可能
   **系统地**消失(实测:错误边全假时机器指令 130 505 → 90 167)。

## 2. 不可谈判的规矩

1. **分析算,发射器只消费**;发射器不做推断、不二次猜测。
2. **表示属于值,装箱属于使用点**;一个值的表示只由分析决定一次,需要盒的消费者在自己这一处付账。
3. **每个节点一条发射路径**,由盖在该节点上的编译期事实选择。
4. **普通对象没有特权**;runtime 只提供**机制**,绝不把辅助函数塞进 `std`。
5. **编译期事实 > 运行期检查 > 错误地沉默**;能在编译期判定的违反就报编译错误。
6. **不动你没读过的代码**;改语义前先问作者。
7. 每步先报**命中数**,再报行数;**无收益不背复杂度**(无收益的改动要回滚并记录)。
8. **探针必须带对照组**;观测手段不能是会改变语义的操作(异类相加、取不存在的域都会污染结果)。
9. **验收 = 全量基线 + 与该改动相关的测试套件**(只跑两套会漏红;§3.4);**基线必须同源**。
10. **不凭表面语法评判类型系统能力**:先查 `README` 的类型系统一节与 `tests/type_system.rs` 有无实例。
11. **不确定就不下结论**,写进 `probes.md` §10 的隔离区;下结论前先在 `probes.md` 找条目。
12. **长任务必须可跟踪**(`monitor_command` / `run_in_background`,**不带 `&`/`disown`**);
    **不隐藏 stderr**;**网关输出不许 `| tail`**。
13. 提交按主题拆开;提交信息写清账(IR/机器数 + 验收结果)。
14. 不改 `docs/*/taste*` 之类自动管理的文件;不擅自提交别人未跟踪的文件。

## 3. 账(全部可复现)

### 3.1 头条

| | 会话起点 `2cbc2e5` | HEAD `394e473` | 工作树(在飞) |
|---|---|---|---|
| IR(行) | 194 640 | 188 577 | **187 738** |
| 机器指令(`-O2` AArch64) | 129 040 | 125 473 | **125 479** |

本区间**已提交**的改动(`2cbc2e5..394e473`):`__panic` 原语、⑩-2(一侧已证 Number 的 `+` 派发)、
⑩-4(一侧已证 String 的 `+` 直通)、⑩-5(一侧 String 的 `==`/`!=` 直通)。
**⑩-3(直读 Boolean payload)已整笔回滚** —— 它把差分测试套件打红(见 §5.1)。

### 3.2 机制面(从发射出的 IR 数出来,§5.5)

- `define` 281 / `declare` **18**;宿主原语**只有 13 个**:`ql_alloc` `ql_mem_get` `ql_mem_get_ptr`
  `ql_mem_store` `ql_mem_store_ptr` `ql_write` `ql_read` `ql_openat` `ql_close` `ql_readlinkat`
  `ql_getrandom` `ql_exit` `ql_extension_open`。
- 内联叶子(`aot/value_abi.ql` 的 `alwaysinline`,**不在 declare 里**):`@ql_tag` **2767**、
  `@ql_truthy` **977**、`@ql_empty` **777**、`@ql_word` **171**。
- 冷机制 `@__cold_located_error` **1463** 次(= 错误边的可见代价)。

**机制的四条通道(新增机制时照这个选,别发明第五条)**:
(a) C 侧宿主原语 —— 仅 `inRuntime` 可写(`qlangc.ql:1466` leaf 清单 + `:1552+` 签名表 + `:1886+` declare);
(b) 热机制 —— `aot/value_abi.ql` 的 `alwaysinline` 叶子,编译器整块发出;
(c) 冷机制、要跨模块复用 —— **编译器自己发一个固定名函数**:唯一先例 `@__cold_located_error`
    (`qlangc.ql:1701` 定义、`main` 里 splice、调用点手写符号调用),**子片 A 的 `@__panic_exit` 照此**(§4-A);
(d) 程序可见面 —— `std`(`runtime.ql:1861` 字面量 + `:1884` `__install_library`),纪律见 `:1882-1883`。

runtime 的 174 个顶层 `let` **无符号、不导出**(`export` 语句数 = 0)。

### 3.3 ⑪ ABI 计数器(重测,旧记已漂移)

```bash
/tmp/o --emit-llvm /tmp/t20.ql aot/runtime.ql | grep '^;'
# ; rawABI: … calls total=2622 known=515 arity=515 rawable=0 retfuel=188 | … retany=251 numargs=320
# ; rawABI order: usercalls=309 emitted=285 notyet=24 retraw=18
```
⇒ **`rawable=0`**:今天**没有任何调用点**能吃裸签名 ⇒ ⑪ 的性质是「先造调用点」,不是「按 251/320 去赚」。

### 3.4 全量基线(必须同源,§11)

跑法:`git worktree add /tmp/wt_head HEAD`,用**同一版本**的编译器与 boot,逐测试套件跑。
测试套件共 **23 个 python + 1 shell + 12 个 Rust 测试文件 + `verify_bootstrap.ql`**;多数强制 `--compiler`,
部分还要 `--interpreter`(native 编译出的 boot)。

HEAD 基线(`/tmp/sweep3/`):**17 绿**,含 `interpreter`(731s)、`selfhost`(1573s)、`strings`(217s)、
`numeric`(226s)、`call`(214s)、`cargo test`(**14 passed**)。

**HEAD 上真实变红的两处(非环境,修法见 §4-K)**:
- `assignment`:`CompileError … exits.ql:1:46: reading uninitialized variable: x`(测试套件生成的测试用例仍按
  「未初始化为运行期值」写,而编译器已**静态拒绝**);
- `runtime_diag`:`t38:22:30: type mismatch: value of type String does not match the annotated type Number`
  (测试用例停留在「注解不强制」的时代)。

**环境缺口(不是失败)**:`module` 需 `target/debug/qlang`;`platform` 需 `target/release/qlang`;
`difftest` 在本机**不可裁决**(它的 boot 侧走 `cargo run`,120 秒超时;`cargo build` 已热只需 0.12s)
⇒ 替代:用 native 编译的 boot 做同样对照。

### 3.11 遍历合并(2026-10-27)

原则:多次遍历要留给"确实需要上一轮结论"的优化;**纯信息收集不拆成多趟**。已合并三处:

| 提交 | 合并 | 度量 |
|---|---|---|
| `4fd83d2` | 模块导出名 + import 节点(一次深搜) | **−5.2% 自举**(可测) |
| `4594045` | 赋值/导出/重声明 + import 绑定名 | 噪声内 |
| `c63bc39` | 函数体 clean/pure/safe 三判据(按 pass 缓存) | 噪声内,4→1 / 2→1 遍 |

教训(probes §35):合并时**提前退出的位置**是语义的一部分;挪到函数入口才行,放在对象分支里
会让语句列表仍走完整棵树,实测反而慢 26%。同类的"清空/初始化"也是(§34 的 `importedNames`)。

### 3.12 本机测量噪声(2026-10-27)

同一二进制连续跑,墙钟与用户态 CPU 都可能差 ±30%(probes §35 记录到 30.7s/39.5s)。
**<5% 的改动在这台机器上量不出来**:要么交错多轮取最小值,要么用确定性计数器
(`; dynshape` / `; directreject` 是先例;AST 节点访问次数计数器待做)。

### 3.10 寄存器实参 ABI(2026-10-27)

≤3 参且无注解的函数多一个寄存器入口 `@ql_fnN_f`,函数体从寄存器取参;闭包盒仍指通用入口
(包装函数)。stdlib IR **−19%**、`clang -O2` 编 stdlib.o **−24%**、机器指令 −0.5%、
5M 次无注解调用 **−16%**;用户函数多的程序 IR 会涨(自举自身 +7%)。

**测量陷阱**:比较"用户代码的调用形状"必须链接**同一个** stdlib 对象 —— 用两份不同的
对象 + 4 次运行,得出的是相反结论(probes §30)。

### 3.9 字符堆对象(2026-10-27)

ASCII 单字符改成共享盒(runtime 初始化时预建 128 个,模块级数组即 GC 根),`__s_at` 命中
直接返回。共享表必须用叶子读(`ql_value_get`),走 `__get_index` 会**更慢**(下标规整比分配
还贵,实测 +19%)。14.5M 次 `s[i]` 2.168s → **1.800s(−17%)**;t20 指令数不变、测试全绿、
固定点成立。

### 3.8 分析接口缓存(2026-10-27)

`--emit-stdlib-interface` 把用户分析真正要读的那点东西导出(槽顺序、运行期函数/赋值名字、
顶层「名字+元数」、`std.<模块>` 三张索引),和 `stdlib.o` 一起缓存;`--emit-llvm-split`
的第 5 个参数装载它,**完全跳过** runtime/stdlib 的 parse+分析。第 5 个参数传 `-` 是从源码
分析的对照路径。

> **2026-10-29 更新:接口换成了 `mod.ql`(QLang 对象字面量 `let mod = {...};`)。**
> 同一份事实现在两种落盘形式:构建器写 `mod.ql`(split 路径默认读它)与 `interface.txt`
> (行式文本,保留兼容;第 5 个参数按内容分派)。读取用**共享前端**把字面量解成 QLang 值,
> 只接受纯字面量、不引入第二套 JSON 读取器。字段:`slots / functions(DFN) / runtime(RFN) /
> modules(MEM/SYM,带源绑定名 `bind`) / mt / values(MV) / calls(MC) / maxFn`。
> **等价性**:69 个测试用例的 IR 与 `interface.txt` 路径逐字节相同(4 个 runtime-internal 测试用例
> 两条路径报同一个错,本来就只能单模块)。细节与踩坑:probes §94。

单测试用例前端 9.7s → **0.45s**,整条构建 ~22s → **~1.7s**;selfhost 全套 **2.3 min**。
两条路径的代码归一化后逐行相同;测试全绿;固定点成立。测试的 `emit()` 已自动使用它。

### 3.7 前端也跳过库(2026-10-27)

编译器加了 `--emit-llvm-split <源码> <runtime> <symbols.tsv>`:只发用户部分,库函数按
`symbols.tsv` 里的 `名字 → ql_fnN` 表发 `declare`(表由 `stdlib_split.py` 从发射器写的
`; ql-symbol` 注释里抽出来)。单测试用例前端 9.7s / 188k 行 → **5.7s / 1.7k 行**,
整条构建 ~22s → **~7s**。两套测试全绿、split 模式下自举固定点逐字节成立。

### 3.6 标准库对象化(2026-10-27)

`aot/stdlib_split.py` 把「preamble + 助手 + runtime/stdlib 函数体 + 字符串 + `@__stdlib_init`」
编成一份 `target/stdlib/<key>/stdlib.o`(key = 编译器 + runtime.ql + bundle.ql 的哈希),
`aot/native_link.py` 用 `--stdlib-object` / `QLANG_STDLIB_OBJECT` 拆掉用户模块里的库定义、
补 `declare` 后链接;两套测试自动构建并启用(失败回落单模块)。

单测试用例链接 12.3s → **1.5s**;二进制指令数 126,635 → 126,599;
> **2026-10-29 收尾**:`tools/stdlib` 现在同时产出 `stdlib.bc`;`tools/link` 支持 `--lto`
> (llvm-link → opt → llc → ld.lld,默认 `--lto-opt 2`);编译器加了 `--stdlib-object <dir>`
> 一键切 split、`--timing` 阶段探针。三条路径实测:t30 前端单模块 11.2s / `--stdlib-object`
> **0.8s**;b_chars 链接 .o 0.45s(运行 2.31s)、`--lto` 11.2s(运行 0.621s,单模块 0.551s)。
selfhost 全套
**6.3 min**、interpreter **6.2 min**(`--jobs 3`)。`internal alwaysinline` 的 value-ABI
叶子在两个模块各留一份,避免把 tag 检查变成真调用(+1,038 条)。

### 3.5 测试并行(2026-10-27)

`run_selfhost_tests.py` / `run_interpreter_tests.py` 加 `--jobs N`(默认 1,行为不变)。
测试用例彼此独立(各自的 `<name>.ll` / `<name>` 在 work 目录里,`native_link` 本来就往私有临时
目录链接),所以可以并行。实测 `--jobs 3` 跑完整 selfhost 测试套件约 20 分钟(此前宿主争抢时
要 2 小时);机器内存有限,`clang -O2` 吃内存,别再往上加。

### 3.5 2026-10-26 新增切片(同源全绿)

- `96cfcde` **lexer 字符分类改查表**:空程序前端 17.27/17.21s → 14.82/14.79s(−14%);
  13 个测试用例 + 自举 99 万行 IR 逐字节相同。
- `6dce4a7` **known-safe 绑定证明按需求值**(`typeSafeBindingHook`):2M 次注解 Number
  调用 5.56/6.43/5.10s → 0.28/0.27/0.25s(≈20×);`safemarked` 3→5。
- **数组取元素内联快路径**(本笔):接收者已证是 Array + 下标已证 Number 时内联
  「tag/界/整数性」检查,失败落回 `__get_index`。3,640 万次取元素 2.920s → 2.474s
  用户态 CPU(−15.3%);自举前端 46.62s → 42.97s(−7.8%);计数器 `; index-fast: N`
  (空程序 31、自举 139);整程序 +200 条机器指令。测试用例输出不变、固定点成立。
- **IR 分块写出**:188k 行从 188k 次 `write` 降到 ~50 次,空程序用户态 CPU
  9.97s → 9.75s(−2.2%),输出逐字节相同(空程序 + 5 测试用例 `cmp` 通过)。
- **S-3 第三步已落**:runtime/stdlib 初始化提成 `@__stdlib_init(ptr %env, i32 %argc,
  ptr %argv)`,`@main` 只剩调用 + 按程序变化的部分;t20 机器指令 +23(调用边界),两套
  测试全绿(用 `--jobs 3`),固定点成立。这是"stdlib 独立目标文件"的前提。
- **S-3 第二步已落**:命名空间分三段(冷助手 `%hN` / 库区 `%rN` / 按程序 `%tN`),
  284 个 runtime/stdlib 函数体在空程序、带 import 的 t15、带用户函数的 t62 下**逐字节
  相同**,只差 `@main`。机器指令数不变、固定点成立。
- **S-3 第一步已落**:冷助手用独立命名空间(`%hN`)并紧贴 prelude 拼接,
  「prelude + 助手」161 行在空/t20/t62 下逐字节相同;机器指令数不变、固定点成立。
- **S-3 预编译 stdlib 前缀可行性已验证**(probes §22):`@main` 之前的代码跨程序
  一致,只差冷助手的 temp 编号(给它独立计数器即可)与 `;` 计数注释;字符串声明
  前缀共享。下一轮按此实施。
- **否决**:热助手 `alwaysinline`(+3,069 条指令/程序,+2.4%,无收益)见 probes §20。

账的口径补充:整程序机器指令数被固定 runtime/stdlib 占满(126k 里程序自身几百条),
热循环改动要看 `aot/bench` 的 **CPU 时间**(`run(s)`/`cpu(s)`,5 次最小值);墙钟在
本机有 ±15% 抖动。

### 3.13 2026-10-30 本轮收敛(供接手)

- **debug / release 两档落地并可用了**:`--debug`(编译器保守发射 + 链接跳过 opt)与 release 语义一致、
  产物只差优化;差分测试套件 `aot/run_debug_diff_tests.py`(41 测试用例两档逐字节相同)是常规门。
  修的关键是"**没有注解 ≠ 检查 null**"(`emitAnnotatedCheck` 的占位串 `"null"`),见 probes §103。
- **module 测试套件脱离 Rust 并转绿**:改为 stage2 + `tools/link` + native 解释器,删掉 Rust 对照腿;
  顺带修正"t15 末句未处理 Error ⇒ exit 1"的断言,见 probes §104。基线里它不再是环境缺口。
- **extension 测试套件的假红查清**:Android 的 `/tmp` 不在 dlopen 允许命名空间内,加 `--tmp <dir>` 即可,
  28 条契约全绿(probes §96 附近 + `run_extension_tests.py --tmp`)。
- **编译期删除(死函数/闭包盒)已评估并否决**(作者:太危险):五次尝试的具体失败点、
  2000 函数程序的收益(单模块 IR −56%、前端 −22%、链接 −44%)与将来若要做的前置条件
  (发射期使用表 → 模块级 refId 解析 → 显式接口清单)都在 probes §97–§101。
- **LTO 不划算(数值型负载)**:非 LTO 链接 2.3s/运行 347ms;LTO O2 链接 11.7s/运行 378ms —— 见 probes §105。
  LTO 只对闭包搬运型负载有价值,文档里不要再写"发布一律 --lto"。

## 4. 待办(全部,按依赖排序)

每条给:做什么 / 落在哪 / 验收 / 半径与依赖。

### A. **子片 A 收尾(在飞,优先)**
- 内容:契约违反 ⇒ **致命**(运行期绑定缺失)。**机制已落地并两引擎实测通过**(§13):
  生成代码走编译器自发冷助手 `@__panic_exit`;boot 源码走 `std.__panic`(boot 唯一宿主通道,并把
  该名从**用户 std 过滤名单**里排除);runtime 加一项 `std.__panic`。
- 数字:IR **−839**、机器 **+6**(可解释:新管线项让 `__panic` 闭包盒变为可达,与 log ㉑ 同族)。
- 收尾三步:①关键测试套件重跑绿(`interpreter`/`selfhost`/`scoped_module`/`assignment`/`semantic`);
  ②**两次提交并 push**(子片 A 一次;测试用例/测试套件漂移修复 + `probes.md` 一次);
  ③把「运行期缺失绑定 ⇒ 致命」补成**拒绝用例**(现有 `aot/run_interpreter_tests.py` 的列表是单文件用例,
  本条需要模块 ⇒ 先看 harness 是否支持多文件再补)。
- 半径(已量):t35 一处测试用例(已按范式修好,计数保持 22)。

### B. **② 统一「判不了的运行期路径」**(已定的判据)
判据:**有值形态的答案 ⇒ Error 值(总函数化);没有值形态的答案 ⇒ 致命;能静态判定的 ⇒ 编译错误**。
- **B1 `StackOverflow` ⇒ 致命**。站点 3 处(`runtime.ql:2040` 深度 300 / `interpreter.ql:1141-1143` /
  `src/interpreter.rs:765-768`);测试用例 `aot/tests/t24_call_buffers.expected` + `difftest.py` e21/r28;
  文档 `README:1045/1072/1100`。**半径最小,建议先做**。
- **B2 缺失(字段/索引)⇒ `Null`**。站点 `runtime.ql:128/202/344/349`(字段)、`:287/304`(索引)+
  boot `interpreter.ql:505/832`;测试用例 `t20.expected`/`t21.expected`/`t28`/`t29`/`t30`/`t32`/`t37`/`t38`/`t39`/`t49`/`t51`
  + `stdlib/{object,string,bundle}.ql`;可检查对照形式**现成**(`hasOwn`/`Object.get`)⇒ 符合 R1。
- **B3 运行期 arity ⇒ 致命**。注意:**字面量超参已是编译错误**(两引擎一致),参数不足是**合法的部分应用**;
  运行期那条只在「经变量/原生函数调用」时触发。站点 `runtime.ql:1941` + boot `interpreter.ql:1046/1097/1120`;
  测试用例多(`t24`/`t27`…`t54`)。
- **B4 `/0` ⇒ IEEE:已定不动**。理由是代价:它要改三方差分预言机(`fuzzexpr.py` 明写「三方」)与
  `run_module_tests.py` 的双引擎断言,收益不抵。

### C. **③ 用户级 `assert`/`expect`**(部分落地:2026-10-25)
用户代码今天**没有办法**断言自己的不变量(语言里没有 assert/expect)。Rust 的 `expect("理由")` 正是
干这个的,官方也把「不变量被破」列为该 panic 的三类之一。实现与 `__panic` **同通道**;R1 要求它同时
有可检查对照形式。

**已落地 `assert`**:runtime 的 `assert(condition, message)`(失败
`__panic("AssertionFailed", __str(message))` ⇒ stderr + exit 1,不可捕获;成功返回 null),
runtime 注册为 native、boot 直接装同一实现;测试用例 `t57_assert`,两个驱动各有 fatal 用例。
`assert` 同时在 `qlangc.ql` 的 `moduleGlobalNames` 里,导入模块/函数可见。
同源验收(interpreter 57 PASS、selfhost ALL PASS、stage3/stage4 IR identical)见
`docs/rust-error-model.md` §3.7。`expect` 仍未做,与 Result/Option 的辅助函数一起设计(§3.6/§4)。

### D. ~~cause 链 provenance 真 bug~~ —— **已修,2026-10-30 复核转绿**

原来:`direct.line` 正确,但 `chained.cause.line` 给的是读取所在的绑定行而不是来源行
(`__err_record` 的「已定位不被重记」守卫没生效)。

**2026-10-30 复核:不再是红。** 复现命令:

```sh
stage2 --emit-llvm-split aot/tests/t38_runtime_diagnostics.ql aot/runtime.ql \
  <stdlib>/symbols.tsv <stdlib>/mod.ql > /tmp/t38.ll
tools/link /tmp/t38.ll -o /tmp/t38 --root <repo> --stdlib-object <stdlib>/stdlib.o
/tmp/t38                                  # → "runtime source checks: 17",exit 0
python3 aot/run_runtime_diagnostic_tests.py --compiler target/selfhost/stage2
                                          # → ALL CHECKS PASS
```

`chained.cause.line == 3` 这条断言现在通过。修复应该来自后续的错误模型切片(没有单独一笔),
所以这里只记录"已不复现",不声称了解具体是哪次改动修好的 —— 以后若再出现,按原假设
(cause 槽里放的是**未定位**的错误对象 ⇒ 守卫不生效)重新 bisect。

### E. **错误载体的类型面**(设计已定,实现未做)
- `Result(T) ≡ T | Error`、`Option(T) ≡ T | Null`,**唯一类型构造子是 `A | B`**;
  **`Result(T,E)` 的 `E` = Error 家族的收窄(派生类型)**,不是第二个载体 ⇒ `docs/result-type-proposal.md`
  的开放问题要据此改写;`stdlib/result.ql` 未实现。
- `Error` 是**普通类型值**(`runtime.ql:1352-1362`,可 `std.Type.make` 派生)⇒ 「任意错误类型」这条
  灵活性**已有**;缺的是**载荷 schema 的声明**(让编译器能在守卫后把 `cause` 细化成有类型的形状)。
- **暂缓**:派生错误类型的载荷 schema 与穷尽性一起做(见 I)。

### F. **⑥ std 注解**(作者标准要求:即使零收益也要写)
- 规则(实测):**返回注解是免费的**;参数注解的代价是**每个调用点一次内联检查**,只有当调用点实参类型
  已被证明时才免费;对象/数组返回注解**今天净负**(+164),缓。
- 计数口径未定(我按「注解出现次数」计得 stdlib 14 / runtime 6,旧记的 4 与 5 对不上)。
- 改 `stdlib/*.ql` 后**必须重建 `stdlib/bundle.ql`**(`--build_bundle.ql --check` 校验)。
- 依赖:B 与 E 先定,否则注解的收益被错误模型挡住(派生返回类型已完整时注解 ±0)。

### G. **⑪ 原始 ABI**(P0/P1 已落地,继续)
`rawable=0` ⇒ **第一步是造出能让调用点吃裸签名的条件**(参数注解 + 调用点类型已证),不是先改 ABI。
计数器命令见 §3.3。

**2026-10-26 P0**:不可变 leaf 函数的直接调用(跳过 `__call_borrowed`)已落地;
单调用点、无 value use 的纯 Number 函数进一步 raw 内联,函数体/闭包不再发出。
判别 `t58_direct_calls` / `t59_inline_pure`;机器指令 −19 / −195,20M 微基准内联路径
用户态 ~0.05–0.08s vs 通用分派 ~36s。设计/边界见 `docs/direct-call-optimization.md`。

**2026-10-26 P1**:多调用点、参数注解函数的 raw ABI 已落地(`t60_raw_direct`):
无 value use 的注解 Number leaf 函数不再有闭包盒/annotations/boxed 入口,绑定槽存
定义处环境指针,调用点直接传 double;判别程序机器指令 −354 / −465,5M 次微基准
用户态 0.059s vs 通用 8.473s。自编译实测 **无提速**(编译器源码 raw 命中 0,
同输入 44.76s vs 44.90s,产物机器指令相同)。仍限 leaf、
无 value use、所有调用点实参已证 Number 且非 Error;返回仍 boxed。设计同见上文档。

**2026-10-26 P2**:裸返回 + known-safe 调用结果(`t61_known_safe`):
proven Number 的 raw 函数 `ret double`;分析期证明纯参数单调用点调用不可能 Error,
给 Identifier/Call 盖 `cannotBeError`,累加器不再 prone、走现有 inline,不新增
运行期检查。5M 次 `s = add(s, i)`:机器 125,937→**125,757**,用户态
**9.606s→0.011s**。顺带修掉入口程序被 moduleCache 重复分析、重置分析结论的 bug。
仍限 leaf;放宽 leaf 未做。

**2026-10-26 P3**:放宽 leaf(`t62_leaf_calls`):raw 函数体允许调用,排除自调用、
后定义函数与 Import;局部函数/源序在前的函数允许。5M 次 `compose(1,i)`:
机器 125,951→**125,762**,用户态 **9.074s→0.039s**。融合函数仍不限 value use。

### H. **⑦ std 整链**(特性级,未开工)
280 个函数里 **189 个(67.5 %)** 只能经闭包码指针到达 ⇒ 静态**不可删**;只有真惰性/按需实例化能碰它。

### I. **穷尽性 / 消费点确认**(边界已定)
- 语言**没有 `match`** ⇒ 穷尽性只能是**守卫覆盖 + 消费点确认**;
- **可枚举联合**(`Result(T)`、`Union(A,B)`、`Array(x)`/`Object({…})`)⇒ 可做成员级穷尽;
  **谓词型**(`Type.make(任意谓词)`)⇒ **不可枚举、不可判定** ⇒ 只能要求「确认」;
- 落点:`aot/types.ql`(只读消费声明类型 + 收窄事实,`narrowAfterGuard`/`branchAlwaysExits`)与
  `aot/qlangc.ql:204` 的 `compileDiagnostic`/`addCompileError`;**绝不往 `inferExpr` 加状态**;
- **验收:通过的程序 IR 与机器指令逐字节不变**(只允许「本该报错而没报」变成报错)。

### J. **既有未完成(来自旧 handoff,仍有效)**
- **注解分批规则**:叶链、小批、重建、测 IR 增量,非负留、净负记而弃。
- **族 (a) 剩余候选**:①除数是非零**字面量**时省掉 div0 菱形(**未做**,注意「一侧已证」那三笔已落);
  ②`②c` 调用后错误边的**计数器**(需在发射点加计数,相邻文本匹配不行)。
- **④ builder 卫生**(§5.6):库文本在**编译器构建期**嵌入 ⇒ 陈旧/错构的编译器会产生源码里没有的失败。

### K. **基线卫生与仓库**
- `assignment` / `runtime_diag` 两处漂移测试用例:修法已定(运行期断言搬到**前端诊断测试套件**并按范式保持行数/计数;
  `runtime_diag` 的期望数 17→16 已在测试套件里注明)⇒ **已做,待随第二次提交进仓库**;
- `module`(环境:需 `target/debug/qlang`,且宿主跑 boot 太慢)、`extension`(HEAD 对上同样红,先于本次改动)、
  `platform`(需 `cargo build --release`);
- **未纳入基线**的四项:`run_argument_tests.py`、`run_extension*.py`、`run_v1_tests.sh`、`verify_bootstrap.ql`;
- **difftest** 本机不可裁决(见 §3.4);
- 文档:交接文档**中英双份**、log 单份(避免每次提交维护两份);`docs/compiler-next-steps.zh.md` 归档;
- 清理:仓库根的 `_b.ql`/`_df_boot.ql`(工具残留);`/tmp/wt_head`(worktree)用完 `git worktree remove`;
  `backup/nan-removal-stage1` 在 `error-carried` 合并后删。

### L. **未验证隔离区(不许当结论用,同 `probes.md` §10)**
Rust 的栈耗尽是否官方保证 abort;⑥ 的计数口径;`src/` 宿主对 §1-§3 各条的逐条行为;内联叶子的完整清单。

## 5. 陷阱(都会咬人,按血泪排序)

1. **⑩-3(直读 Boolean payload)**:四步全过、数字 −7 927,但**把差分测试套件打红**(410/419)。
   根因:`staticType` **不等于运行期类型** —— `&&`/`||` 被盖章 Boolean 却返回**操作数**;会失败的调用
   可能返回 Error。加 `cannotBeError` 护栏后收益≈0 ⇒ **整笔回滚**。口径:**信任 `staticType` 的优化必须带
   `cannotBeError` 护栏**,且**凡触碰值语义必须跑差分测试套件**。
2. **探针污染**:`"x" + 数字` 在 QLang 里是 `TypeMismatch`(错误!),拿它当观测手段会把探针自己的错误
   当成被测对象的性质(本会话发生 3 次)。**必须带对照组。**
3. **`?Error` 有三种来源**:打印一个 Error 值(渲染)、对普通值取不存在的域、异类相加的错误被打印。
   **它不是「类型缺失」。**
4. **混源基线**:拿 A 版编译器跑 B 版源码 ⇒ 假失败(一整轮白跑)。
5. **验收过窄**:常规只跑 `interpreter`+`selfhost`,而它们在 §3.4 的两处漂移红上**恰好都绿**。
6. **行数敏感测试用例**:`t38` 类文件用行号断言坐标 ⇒ 改动必须**等量替换**(2 行换 2 行)。
7. **check 会被省略**:可证明为真的 `check(true, …)`/`check(x >= 0, …)` **会被编译器省掉** ⇒ 计数下降。
8. **shell 细节**:`/bin/sh` 无 `PIPESTATUS`;`ls -d /tmp/x* | tail -1` 会选错目录(在本会话都踩过);
   **不要 `>/dev/null` 藏链接错误**(它会藏掉唯一的线索)。
9. **长命令可见性**:网关不许 `| tail`(缓冲会让「卡住」与「慢」不可分)。
10. **`Error` 当调用实参会被拒绝**(`TypeMismatch: attempt to pass error value as argument`)⇒
    `check(<可能出错的调用>, …)` 会**静默不计数**;用 `isError(x)` / `x.type == "…"` 就地判断。
11. **分析必须**先遍历到**那个节点**,规则才可能生效(这是 B8 那 −4 424 行的教训)。
12. **按绑定身份,不按名字**:unbox 决策用 `s.bindId`;「这名字在程序里被赋值过」会悄悄废掉所有 std 注解。
13. **不要把节点引用挂到 AST 节点上**(发射器会遍历所有属性 ⇒ 环 ⇒ 走不完);用数值 id 的内部表。

## 6. 已定 / 已缓 / 已回滚

- **已定**:两条道的判据(§2.5 与 §4-B);唯一错误载体是 `Error`;语法形式**自动传播**、函数调用**显式**;
  panic **固定 abort、不可捕获**;**不跟** Rust 的「构建配置决定行为」;`E` = Error 家族的收窄;`/0` 不动。
- **已缓**:对象/数组返回注解(净负 +164,作者明确不确定把基名等权于最宽具体类型是否安全);
  派生错误类型的载荷 schema(与穷尽性一起)。
- **已回滚**:「去 NaN/∞」(现场在 `backup/nan-removal-stage1`);`llvm.lifetime.start/end` 的删除
  (**IR −10 444 / 机器 +3 861** —— 「IR 赢、机器输」的最干净例证,没有再谈的余地)。
- **已废止**:「B8 = 大规模注解 stdlib」。

## 7. 位置索引

| 想要 | 去哪 |
|---|---|
| 冷助手先例(照它仿) | `aot/qlangc.ql:1701`(定义)/ `main` 里 splice / 调用点手写符号调用 |
| 子片 A 的助手 | `aot/qlangc.ql:1731` 旗标、`:1732-1760` 助手、`:964-967` 调用点 |
| 静态/运行期两通道边界 | `aot/qlangc.ql:814-846`(`emitIdentifier`;`:832` 的 `sameBody`) |
| `?` / `??` 的发射 | `aot/qlangc.ql:643` / `:552-553`;boot:`interpreter.ql:713`;parser:`parser.ql:825` |
| 契约违反的致命原语 | `aot/runtime.ql:511`(`__panic`);`std` 字面量 `:1861`;boot 过滤 `interpreter.ql:44` |
| provenance 记录 | `aot/runtime.ql:96-129`(`__err_cause`/`__err_at`/`__err_record`) |
| 类型值/派生类型 | `aot/runtime.ql:1352-1362`;`README.md:809/827/867-872`;`tests/type_system.rs` |
| 证据与实测 | `docs/unboxed-values-probes.md`(§1 通道、§2 `??`/`+`、§3 arity、§5 机制、§11 基线、§12 bug、§13 子片 A) |

### M. **库调用图的 known-safe 证明**(静态派发的下一步,2026-10-28)

详见 `compiler-next-steps.md` 同名小节 + probes §54/§55。要点:库内 285 个绑定调用点全部
「定义先于调用」,装箱直调已落地 28 个(库对象 −1,097 指令);剩下卡在 `callArgsCannotBeError`
(`args=478`,其中 376 个实参是绑定标识符)。原因:库绑定过不了安全证明(写入里有调用结果),
对库程序打开 `typeSetCallSafety` 无任何变化。要做的是把 P2 的返回值证明扩展到整张库调用图
(`aot/types.ql` 的 `typeCallSafe`/`typeBindingSafe`/`typeComputeSafeBindings`)。
