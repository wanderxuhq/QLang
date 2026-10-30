# 直接调用与纯 Number 内联(2026-10-26)

这是 P0/P1 切片(编译器优化,不改语言语义)的落地口径。判别测试用例:
`aot/tests/t58_direct_calls.ql`、`aot/tests/t59_inline_pure.ql`、`aot/tests/t60_raw_direct.ql`。

## 1. 三种形状

### A. 直接调用(boxed ABI)

适用:用户程序里的 `let f = <Function>` 绑定,且:

- 绑定在**用户程序 AST**里从未被赋值、重声明或导出;每次 `let`/赋值都会清掉旧的直接目标;
- 函数体是 **leaf**:自己的 body 没有 `Call` / `Import`(嵌套 `Function` 是值,不算调用);
- **没有参数注解**(参数注解检查由通用 dispatcher 负责;返回注解可以保留,函数体返回边仍检查);
- 调用点 arity 与函数形参**精确相等**(部分应用/超参仍走通用路径);
- 每个实参的 `cannotBeError == true`(通用路径的“Error 不能作实参”规则静态成立);
- 调用点经 `lookupSlot` 命中的就是登记该函数的作用域(遮蔽/重声明会清表)。

发射效果:不再构造 `__call_borrowed` 的借用数组/通用分派,直接
`call %ql_value @ql_fnN(env, args, argc, annotations)`。函数体/闭包仍保留,
所以函数值、别名、动态调用都不受影响。

### B. 纯 Number 内联(raw)

在 A 的基础上再收紧:

- 该绑定在用户程序里**只有这一个 callee 引用**,没有任何 value use(别名、
  export、作为实参等都会使候选失效);重声明也会使候选失效;
- 每个参数 `unboxType == "Number"`(注解 Number 或分析证明);
- body 只有一条表达式,且是 `+ - * & | ^`、一元 `+/-`、Identifier 或 Number 字面量;
- body `staticType == "Number"` 且 `cannotBeError == true`,无 call,并且 body 里的
  Identifier 只能是本函数的参数(捕获自由变量会让 inlining 读错作用域);
- 返回注解缺省或 `Number`;
- 调用实参 `staticType == "Number"` 且 `cannotBeError == true`。

发射效果:**不发出该函数的 ql_fn 与闭包盒**;调用点把实参读成 raw double,
用 inline 替换参数后直接生成 body 的 `fadd`/`fmul` 等,结果再装箱。
单次调用、纯计算、无副作用。

### C. 多调用点 raw 直接函数(P1)

在 A 的前提上,把「无参数注解」换成「每个参数都是内建 `Number` 注解且函数体内
从未被赋值」(`aot/types.ql` 的 `rawAbiAll`),并额外要求:

- 该绑定在用户程序里**没有任何 value use**(`refs.value == 0`);不是 export、
  重声明目标或赋值目标;
- 至少一个直接调用点,且**每个**调用点 arity 精确、每个实参
  `staticType == "Number"` 且 `cannotBeError == true`;
- 所有调用点在源序上都位于定义之后(定义前调用已经被前端报 undeclared);
- 该名字不在任何静态 import 的导出候选集里(import 会覆盖同名槽,直接目标会绕过它);
- 函数体 leaf(无 call/import),绑定本身无注解;零参函数不在本切片。

发射效果:**不生成闭包盒、不生成 annotations 数组、不生成 boxed `@ql_fnN`**;
函数体只发一份 raw 入口 `%ql_value @ql_fnN(ptr %env, double %p0, ...)`。
绑定槽存**定义处环境指针**(不是函数值);调用点从槽取 env,实参经
`emitRawDouble` 直接以 double 传参,结果仍是 boxed `%ql_value` ——
错误边、返回注解检查、body 语义都不变。

通用分派原本负责的四件事被静态消掉:arity、参数 Error 策略、
内建 `Number` 注解检查、栈深度(leaf 无递归)。这是 P1 能直接调 raw 入口的前提。

## 2. 判别数字(同源编译器;下表是判别程序,不是测试用例全文)

| 程序 | 机器指令 |
|---|---:|
| 空文件 | 125,673 |
| t20(20 次 `x = x + 1`) | 125,735(不变) |
| 直接调用判别(5 次 `add(i,1)`) | **125,870** |
| 同上走后门: `f = add; f(i,1)` | 125,889 |
| 纯 Number 内联判别(5 次 `pure(i,1)`) | **125,744** |
| 同上走后门: `f = pure; f(i,1)` | 125,939 |
| 多调用点注解函数(5 次 `add(1,2)`…;P1 前) | 126,120 |
| 同上(P1 后,5 raw calls / 1 raw function) | **125,766**(−354) |
| 非内联体多调用点(`max2`/`sq` 共 6 次;P1 前) | 126,284 |
| 同上(P1 后,6 raw calls / 2 raw functions) | **125,819**(−465) |

- 直接调用:静态 **−19**,但循环体不再进入 771 条静态指令的通用分派体;
- 纯 Number 内联:静态 **−195**,函数体/闭包被删掉,循环体成为 raw `fadd`;
- raw 直接函数:静态收益来自删掉闭包盒/annotations 数组/boxed 入口,
  并把每个实参从 16 字节缓冲改成寄存器 double;函数体只发一份,调用点越多越划算。
- 20M 次微基准(本机、受后台测试套件争用影响,只作量级参考):
  inline 用户态约 **0.05–0.08s**,通用分派路径约 **36s**。
- 5M 次 `max2(i, i+1)`(同源 `target/selfhost/stage2`;raw 直接调用 vs
  `let f = max2` 强制通用路径):用户态 **0.059s vs 8.473s**,输出相同;
  静态 125,759 vs 125,993(**−234**)。

## 3. 同源验收(2026-10-26,最终编译器 `target/selfhost/stage2`)

- `stage2` 自编译 `stage2/stage3` 的 IR **逐字节相同**(`target/selfhost/stage2.ll` / `stage3.ll`);
- `run_selfhost_tests.py --self`:ALL REQUESTED CHECKS PASS(含 `t58`/`t59`/`t60`
  与 stage2/stage3 identical);
- `run_interpreter_tests.py`:ALL CHECKS PASS(含 `t58`/`t59`/`t60`;native/boot 输出一致);
- `run_semantic_diagnostic_tests.py`、`run_assignment_tests.py`、`run_diagnostic_tests.py`、
  `run_call_tests.py`、`run_numeric_tests.py`、`run_array_tests.py`、`run_object_tests.py`、
  `run_json_numeric_tests.py`、`run_scoped_module_tests.py`、`run_lazy_module_tests.py`、
  `run_gc_tests.py`、`run_lifetime_tests.py`:ALL CHECKS PASS(同源 stage2 + native boot);
- `run_bundle_tests.py --bundler target/source-origins-check/bundler`:ALL CHECKS PASS;
  `cargo test --offline`:14 passed;`stdlib/build_bundle.ql --check`:verified;
- 已知红(既有,未触碰):`runtime_diag` 的 `t38:38` cause-provenance;
- `/tmp/t20.ql` 仍是机器 125,735 / 输出 20(普通程序不变;收益只在已证目标/注解函数)。

## 4. 边界与后续

- A 仍保留 boxed 参数缓冲/函数 frame/返回装箱;P1 已让「多调用点 + 参数注解」
  的函数改走 raw 入口,不再经 A。
- B 只覆盖单调用点的纯 Number 表达式;有 value use、重声明、赋值、调用、
  错误边、除零/取模、字符串/数组的函数一律回退到 A 或通用路径。
- C 仍要求 leaf、无 value use、所有调用点实参已证 Number 且非 Error。
  参数 prone(例如累加器来自可能失败的调用)时不能 raw;同名 import 会覆盖绑定槽,
  也一律回退;返回仍是 boxed `%ql_value`(裸返回/裸多返回值是下一片)。
- 判别测试套件:`run_selfhost_tests.py` + `run_interpreter_tests.py`(
  `t58_direct_calls` / `t59_inline_pure` / `t60_raw_direct`);两者 native/boot
  输出必须一致。
- 静态指令数不是动态指令数;本机没有 perf/valgrind,20M 微基准只用于量级判断。

## 5. 自编译实测:P1 对 qlang 编译自己**没有**提速(2026-10-26)

同机、同一输入(当前 `aot/qlangc.ql` + `aot/runtime.ql`),两个编译器都输出到
`/dev/null`,预热后交替跑 3 次:

| 编译器 | 自编译 wall(中位) | user(中位) | 该输入生成的机器指令 |
|---|---:|---:|---:|
| P0(2c800e8 源码,同一 P1 构建) | 44.76s | 43.86s | 736,234 |
| P1(当前源码) | 44.90s | 44.01s | 736,234 |

- **raw 命中为 0**:`qlangc.ql` 里没有 `Number` 参数/返回注解,
  `rawcalls=0 rawfuncs=0`;P0 的 173 个直接调用仍在,但 P1 没有新增可优化的调用点。
- 两份编译器对同一输入生成的机器指令数**完全相同**;P1 仅多了诊断注释。
- P1 约 **+0.15s(+0.3%)**,是新增预扫描的固定开销,不是收益;基本可视为不变。
- P1 编译器源码自身的产物从 **717,013 → 736,234** 机器指令(+19,221,+2.7%),
  来自新增逻辑,不是用户代码生成变差。

原因:raw ABI 只对「注解 Number 参数 + leaf + 无 value use + 所有调用点实参已证
Number」生效;编译器的热路径是 AST 遍历、IR 文本拼接和字符串/对象操作,helper
多数不是 leaf,也没有 Number 注解。要加速自编译,应针对这些热点(IR 输出、分派、
字符串),而不是继续扩大 raw ABI 的适用范围。

## 6. 剩余 raw 边界的收益评估(2026-10-26)

结论:**裸返回对当前热点几乎为 0;放宽 leaf 受注解限制;真正的大头是让
「已知不会返回 Error 的调用」不再把结果标成 prone**,或等价地允许 prone 实参。

- **裸返回**:小/中型 raw 函数会被 `clang -O2` 内联,box/unbox 和调用点的
  `ql_tag` 错误检查一起被折叠。实测 5M 次 `max2` 循环(用户态 0.059s)与
  3M 次 22 条算式的 `mix` 循环(0.059s),汇编里都没有 raw 调用指令。
  只有大到不能内联的 raw 函数才会省下约 3–5 条边界指令/调用;
  若同时证明「所有返回边都不可能 Error」,还能消掉非内联调用点的定位检查。
- **放宽 leaf**:仍以「注解 Number 参数」为前提;`qlangc.ql` 没有 Number 注解,
  自编译依旧 0 命中。对用户代码是覆盖率问题,收益取决于被调 helper,需单独基准。
- **prone 实参**:5M 次 `s = add(s, i)` 当前走通用分派,用户态 **9.606s**
  (静态 125,937);同样循环手写 `s = s + i` 为 **0.034s**(静态 125,752)。
  这是数量级差距,但收益来自「让累加器不再是 prone」。
  更干净的做法:分析期证明某函数所有返回边都不可能 Error(顺带允许裸返回),
  把该事实传播到调用点 ⇒ `s` 不再 prone,现有 raw/内联自动生效,并消掉
  调用点的定位错误检查。直接允许 prone 实参则要在每个调用点复刻 dispatcher
  的 Error 实参策略(消息/cause/位置),复杂度和风险更高。

对自编译:P0/P1 已实测无提速;上述三项都不改变 `qlangc.ql` 无注解这一事实,
所以仍不会有可测提升。目标是用户数值代码时,优先级建议为
「known-safe 调用结果传播」>「放宽 leaf」>「裸返回」。

**口径修正(2026-10-26)**:不把「放宽 prone 实参」当作目标形态。它的本质是在每个
调用点新增逐实参的 Error 检查,违反「编译期事实 > 运行期检查」;相对今天的通用分派
它仍更快,但那是替换更贵路径的副产品,不是我们想要的终态。known-safe 返回传播
**不新增任何运行期检查**:它在分析期证明函数所有退出边(tail/return/`?` 传播)
都不可能 Error,把结论传给调用点;证明成功时 `s` 不再 prone、调用点现有定位检查
可删、并可裸返回;证明失败(除零/取模/未知调用/不稳定绑定等)就**维持今天的路径**,
不为覆盖率补检查。成本是一次性分析,不是每次调用。

## 7. 裸返回 + known-safe 调用结果(P2,2026-10-26)

### A. 裸返回(proven Number)

在 raw 候选之上,若函数满足「所有退出边(尾值、`return`)都是已证的 Number、
不可能 Error,没有 `?`、没有带注解的 Let/Assign、返回注解检查已由推导证明为死
代码」,raw 入口返回 `double` 而不是 `%ql_value`;调用点由 `emitValue` 直接拿到
裸 Number,不再装箱/解箱,也不发调用点定位错误检查。

- 不能证明时(除法、`?`、调用、注解检查、可能 Error 的读)继续返回
  `%ql_value`,语义不变。
- 条件位置的裸 Number(`if f(1)`、`while f(1)`、`!f(1)`)在发射器里补装箱,
  因为条件仍走 `ql_truthy`。
- 小/中型函数会被 `clang -O2` 内联,装箱本来就会被折叠:实测 5 次 raw 调用
  只从 125,766 降到 **125,762(−4)**。裸返回的主要价值是给 known-safe 传播
  提供证明,而不是单独省指令。

### B. known-safe 调用结果(静态,不插运行期检查)

证明一个调用不可能返回 Error:

1. **函数**是纯参数数值函数:参数全是注解 `Number` 且从未被写;body 无
   `Call`/`Import`/`?`/带注解的 Let/Assign;所有退出边只由参数、字面量、
   `+ - * & | ^`、`if`/`while` 构成;返回注解缺省或 `Number` 且推导一致。
2. **绑定**只定义一次、无注解、无 value use、无 export/import/重声明/赋值。
3. **调用点**只有这一处、arity 精确、每个实参也已经被证明是安全 Number。

满足后,分析期直接给实参 Identifier 和 Call 盖 `cannotBeError`(不改 prone
字段,也不加任何运行期检查)。发射器必须把它 inline 或 raw;若走到通用分派,
发射器报编译错误而不是静默跳过检查。

5M 次累加器循环实测:

| | 机器指令 | 用户态(5M) |
|---|---:|---:|
| `s = add(s, i)`(旧,prone ⇒ 通用分派) | 125,937 | 9.606s |
| 同上(known-safe ⇒ 现有 inline 路径) | **125,757** | **0.011s** |

这不是「把编译期时间转嫁到运行期」:没有新增逐实参检查,反而删掉了调用点的
错误检查;证明失败就维持原路径(不优化也不补检查)。判别测试用例 `t61_known_safe`。

### C. 顺带修掉的重复分析

`moduleCache` 也包含入口程序;旧代码在用户程序分析之后又把入口当模块分析了
一遍。第二遍的 `inferExpr` 从 `node.cannotBeError = false` 开始,会把
known-safe 修正(以及 `returnsNumberSafe`)全部重置。现在跳过入口路径,
模块仍各分析一次;这也减少了一整遍用户程序分析。

自编译实测(同一输入 `qlangc.ql` + `runtime.ql`,P1 编译器 vs P2 编译器):
两者用户态在 **42–52s** 区间波动(本机负载噪声大),没有可测收益;新增的
证明/不动点扫描与跳过入口重复分析大致抵消。P2 的目标是**用户数值代码**,
不是自编译。

## 8. 放宽 leaf(P3,2026-10-26)

raw 候选不再要求 body 是 leaf,而是要求 body 里的调用**不会碰到没有闭包的槽**:

- 自调用(递归)以及 body 里对自身名字的任何引用(包括先存到局部别名再调用)
  一律排除(raw 绑定槽存的是 env 指针,不是函数值);
- 调用源序在**后面**的函数、或按名字读取它们,一律排除(发射时直接目标尚未
  登记;若对方是 raw,运行时通用调用会把 env 指针当函数值);
- 调用**本函数体内部**声明的局部函数允许(它们有正常闭包);
- `Import` 仍禁止;调用源序在前的 raw 函数走直接 raw,调用在前的非 raw
  函数/运行期函数走正常闭包。
- 函数体里的递归/前向引用在分析期可能没有 `bindId`,所以按**名字**判定
  (保守:同名遮蔽会少优化,不会多优化)。

判别 `t62_leaf_calls`(组合函数、局部闭包、递归、后定义调用、互递归):

| 程序 | 机器指令 | 用户态 |
|---|---:|---:|
| `compose` 组合函数(旧,非 leaf ⇒ 通用) | 128,016 | — |
| 同上(P3) | **127,881**(−135) | — |
| 5M 次 `s = s + compose(1, i)` | 125,951 | 9.074s |
| 同上(P3) | **125,762**(−189) | **0.039s** |

互递归 `a↔b` 时 `a` 因调用后定义的 `b` 被排除,`b` 调用已存在的 `a`(非 raw
闭包)可以 raw;语义与输出不变。

## 9. known-safe 的绑定证明必须按需求值(2026-10-26)

判别:`let acc: Number = 0; … while … { acc = add(acc, i); i = i + 1; }`(注解
Number 的累加器 + 注解 Number 的两参函数)。

**症状**:这个循环拿不到 inline/raw,每轮走通用调用(2M 次 ≈ 5.7s,≈2.8µs/次)。
`safemarked` 只有 3;`acc` 在安全判定里被判成 unsafe。

**根因(不是证明规则太严,是求值顺序)**:`typeExprSafeNumber` 的 Identifier 分支
只**读** `safe[bid]`,不**算**该绑定。而 `typeComputeSafeBindings` 按 bindId 顺序
遍历;`acc` 的写入引用了表里更靠后的 `i`,于是"还没轮到 i"被当成"i 不安全",
`acc` 被标 3,之后的 `typeApplySafeCalls` 也就不会给实参盖 `cannotBeError`。
`typeBindingSafe` 本身是带 `1=visiting` 的记忆化 DFS,只是入口没接上。

**修法**:Identifier 分支遇到未访问的 bid 就地调一次 `typeBindingSafe`(经
`typeSafeBindingHook` 跳板,因为两个函数互相递归、QLang 不保证前向引用解析)。
环仍然按 `1=visiting` 乐观 —— 环里每一跳都必须过纯调用/纯算术,藏不住 Error 源。

**证据**:

| 形状(2M 次调用) | 机器指令(整程序) | 用户态 |
|---|---:|---:|
| 旧:实参未盖章 ⇒ 通用调用 | 126,064 | 5.56 / 6.43 / 5.10s |
| 新:safe 递归 ⇒ inline/raw | **125,772** | **0.28 / 0.27 / 0.25s** |

`safemarked` 3 → 5。自举固定点成立(stage2/stage3 IR 逐字节一致);selfhost
全套 + interpreter 全套全绿。前端耗时不变(新增的递归与省掉的检查大致抵消)。

**别的教训**:整程序机器指令数对"热循环里每条语句少几条指令"并不敏感(126k 里
程序自身只有几百条),所以这类切片必须看**运行时**,指令数只用来抓代码膨胀。
