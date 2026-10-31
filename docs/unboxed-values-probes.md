# Probe facts — measured, not remembered

> **2026-10-31:Python 已全部移除。** 本文中的 `python3` / `*.py` 命令是历史记录;
> 当前构建、测试、生成器见 [`docs/python-removal.md`](python-removal.md)(同目录文档用相对链接)。


**用途**:本文件是**唯一**的事实来源。任何结论(含 roadmap 决策)若要引用行为,
必须能追到本文件里**带复现命令**的条目;不在本文件里的,一律视为「未验证」。
目的:消灭「断言 → 下一轮被实测推翻」的循环。

- 分支:`error-carried`(工作树;**本文件描述的行为在 HEAD `394e473` 上复现**)
- native 引擎 = 由工作树的 `aot/qlangc.ql` 构出的编译器:`/tmp/o3`
- boot 引擎 = **HEAD 干净副本**(`git worktree add /tmp/wt_head HEAD`)构出的 boot:`/tmp/bp_head`
  - 为什么用 HEAD 副本:**工作树里 boot 现在编不出来**(见 §5 第 3 条)。
- 三引擎中的第三个(Rust 宿主)未逐条跑;已知其 `src/interpreter.rs` 与 native 行为对齐的部分见 §2 出处列。

## 0. 探针纪律(这轮用血换来的两条)

1. **每个探针必须带对照组。** 只观测被测表达式、不观测一个已知良好的同类表达式,
   就会把**探针自己触发的错误**当成被测对象的性质(本会话发生 2 次)。
2. **观测手段不能是「会被改变语义的操作」。** 例:`"x" + r` 在 QLang 里是
   **类型严格**的 ⇒ 异类相加**本身**就是 `TypeMismatch` 错误,于是任何 `?Error`
   都可能是观测手段造的;必须用 `println(r)` / `println(r.type)` 这类中性手段。

复现模板(下文所有 `N` / `B` 两列都由此产生):

```sh
printf 'let z = 0; let a = 1 / z; println(a.type);\n' > /tmp/p.ql
# native:
/tmp/o3 --emit-llvm /tmp/p.ql aot/runtime.ql > /tmp/p.ll && \
  python3 aot/native_link.py /tmp/p.ll -o /tmp/p.bin && /tmp/p.bin
# boot:
/tmp/bp_head /tmp/p.ql
```

## 1. 已实测:错误 kind 与值/静态的边界

| # | 探针(源码) | native | boot | 结论 |
|---|---|---|---|---|
| 1.1 | `let z = 0; let a = 1/z; println(a.type);` | `DivisionByZero` | `DivisionByZero` | 运行期**值** |
| 1.2 | `let o = {a:1}; let r = o.b; println(r.type);` | `UndefinedField` | `UndefinedField` | 运行期**值** |
| 1.3 | `let ar=[1,2]; let r = ar[9]; println(r.type);` | `IndexOutOfBounds` | `IndexOutOfBounds` | 运行期**值** |
| 1.4 | `let f=(n)->f(n+1); let r=f(0); println(r.type);` | `StackOverflow` | `StackOverflow` | 运行期**值**(深度 300) |
| 1.5 | `let x; let r = x; println(r.type);` | **编译错误** | **ParseError** | **静态拒绝**(两侧一致) |
| 1.6 | `let x; let f=()->x; let r=f(); println(r.type);` | `Uninitialized` | `Uninitialized` | **跨函数 ⇒ 运行期值** |
| 1.7 | `let x; if false { x=1; }; let r=x;` | **编译错误** | **ParseError** | 定值分析 ⇒ 静态拒绝 |

**⇒ 判据(实测得到,非推断)**:同一操作**直接写在原作用域** ⇒ 静态拒绝;
**跨函数/闭包边界**(或经别名、经原生调用,见 §3) ⇒ 运行期 Error 值。
两条通道**同时存在**,由「静态可判定性」选择。

## 2. 已实测:`??`、`+`、`==` 的语义

| # | 探针 | native | boot | 结论 |
|---|---|---|---|---|
| 2.1 | `println(null ?? 7);` | `null` | `null` | **`??` 不是 null 合并** |
| 2.2 | `let z=0; println((1/z) ?? 7);` | `7` | `7` | `??` **接住 Error** |
| 2.3 | `let z=0; let e=1/z; println(e ?? 7);` | `7` | `7` | 对已绑定的 Error 也接住 |
| 2.4 | `let o={a:1}; println(o.b ?? 7);` | `7` | `7` | 缺失字段的 Error 也接住 |
| 2.5 | `let r = "x" + 1; println(r.type);` | `TypeMismatch` | `TypeMismatch` | **`+` 类型严格,无隐式转换** |
| 2.6 | `let r = "x" + true; println(r.type);` | `TypeMismatch` | `TypeMismatch` | 同上 |
| 2.7 | `let r = 7; println(r.type);` | `?Error` | `?Error` | 普通值取不存在的域 ⇒ **本身是 Error** |
| 2.8 | `let z=0; let a=1/z; println(a);` | `?Error` | `?Error` | **打印 Error 值的渲染就是 `?Error`** |

⇒ **`?Error` 的三种来源必须分清**:①打印一个 Error 值(2.8);②对普通值取不存在的域(2.7);
③异类相加(2.5/2.6 的 `TypeMismatch` 被打印时)。**它绝不是「类型缺失」**。

## 3. 已实测:arity / 部分应用

| # | 探针 | native | boot | 结论 |
|---|---|---|---|---|
| 3.1 | `let f=(a,b)->a+b; f(1,2,3);` | **编译错误** `Arity mismatch: expected 2 arguments, got 3` | **ParseError**,同一消息 | 字面量超参 ⇒ **静态拒绝** |
| 3.2 | `let f=(a,b)->a+b; println(f(1)(2));` | `3` | `3` | **参数不足 = 合法部分应用** |
| 3.3 | `let f=(a,b)->a+b; let g=f; let r=g(1,2,3); println(isError(r));` | `true` | `true` | **经变量调用 ⇒ 运行期值** |
| 3.4 | `let r = std.JSON.stringify(1,2); println(isError(r));` | `true` | `true` | **原生函数 ⇒ 运行期值** |

出处:`aot/README.md:69`(原生函数参数不符返回 `ArityMismatch`;用户函数支持部分应用);
`aot/README.md:601`。实现:`aot/runtime.ql:1940`(`__arity_error`);
boot `bootstrapped/interpreter.ql:1046/1097/1120`。

## 4. 已实测:`??` 与 `?` 的实现出处

- `?`(后缀传播)**已存在**:lexer `bootstrapped/lexer.ql:317`(另有 `??` ⇒ `:318`);
  parser `bootstrapped/parser.ql:825`(`UnaryOpExpr("?", expr)`);emitter `aot/qlangc.ql:643-646`
  ⇒ `emitPropagateError`;boot `bootstrapped/interpreter.ql:713`。
- `??` 的发射:`aot/qlangc.ql:552-553` ⇒ `emitCoalesce(node)`。
- **`?` 的传播语义(实测,两引擎一致)**:
  | 探针 | native | boot |
  |---|---|---|
  | 顶层 `let z=0; let a=(1/z)?; println("REACHED-TOP");` | `…:1:21: DivisionByZero: division by zero`,**rc=1**,"REACHED" 未打印 | 同消息 |
  | 函数内 `let f=()->{let a=(1/z)?; println("REACHED-FN"); a+1;}; let r=f(); isError(r)` | **true**;`r.type` = `DivisionByZero`;"REACHED-FN" 未打印 | 一致 |
  | `?` 遇好值(`10/2`) | `6` | `6` |
  实现:`aot/qlangc.ql:619-635`(`emitPropagateError`):tag==8 ⇒ **顶层 `__exit_error` + `unreachable`**;
  **函数内 store 进 `curRetv` + 跳 `curEpiLbl`**。与 `docs/result-type-proposal.md:22-25` 描述逐字吻合。
- **§1 那条「静态拒绝 / 运行期值」边界的实现坐标**:`aot/qlangc.ql:814-846`(`emitIdentifier`)——
  `:824` 未绑定 ⇒ `addCompileError("undeclared name")`;
  `:832` **`sameBody`(同体 && 非 optional)⇒ 裸加载,注释明说 null/`ql_empty` 检查是死码**;
  否则进菱形 ⇒ `:838` `__err("UndefinedVariable")`、`:846` `ql_empty` ⇒ `Uninitialized`。
  ⇒ 实测判据(§1.5/§1.6/§1.7)与代码里的 `sameBody` + 前端定值检查**一一对应**。
- **静态未绑定名已是编译错误**:`aot/qlangc.ql:824`(`undeclared name`)、`:941`
  (`assignment to undeclared name`);专门测试套件 `aot/run_semantic_diagnostic_tests.py:19-21`
  (断言到行列);`aot/README.md:235`。

## 5. 已实测:工具链与工程事实

1. **`⑪` 计数器(重测,旧记数字已漂移)**
   ```sh
   /tmp/o3 --emit-llvm /tmp/t20.ql aot/runtime.ql | grep '^;'
   ```
   ```
   ; rawABI: funcs total=274 allparams=13 allraw=0 anyparam=13 rawparams=13 retnum=6 |
     calls total=2622 known=515 arity=515 rawable=0 retfuel=188 |
     numparams=13 writable=13 retany=251 numargs=320
   ; rawABI order: usercalls=309 emitted=285 notyet=24 retraw=18
   ```
   ⇒ **`rawable=0`**:当前**没有任何调用点**能吃裸签名 ⇒ `⑪` 的性质是「先造调用点」,
   不是「按 251/320 去赚」。旧记 `retfuel=170` 已过时(实测 188)。
2. **`difftest` 在本机不可作裁决**:`cargo build` 已热(0.12s)而
   `cargo run --quiet -- _df_boot.ql` **120 秒超时** ⇒ 卡的不是构建,是
   「Rust 宿主解释执行 boot、boot 再跑测试套件」。替代:用 native 编译的 boot(`/tmp/bp_head`)。
   difftest 会在仓库根留下 `_df_boot.ql`(需清理)。
3. **工作树的 boot 编不出来**:`CompileError: …: undeclared name: __panic`
   (`bootstrapped/environment.ql:74`)⇒ 子片 A 的机制尚未落地。
   HEAD 副本(`/tmp/wt_head`)可编(`rc=0`,631 030 行 IR)。
4. **机制的四条通道(读码所得,已在 IR 里验证过第 2、3 条)**
   - C 侧宿主原语:`aot/runtime.c`(258 行,`ql_mem_*`/`ql_write`/`ql_read`/`ql_exit`/`ql_getrandom`/`ql_extension_open`),
     仅 `inRuntime` 时可写(`aot/qlangc.ql:1466` 的 leaf 清单 + `:1552+` 签名表 + `:1886+` declare)。
   - 热机制(内联叶子):`aot/value_abi.ql`(`ql_empty`/`ql_tag`/`ql_word`/`ql_byte`/`ql_truthy` 的
     `define internal … alwaysinline`),由编译器整块发出。
   - 冷机制(跨模块可调):编译器**自己发**固定名函数 —— 唯一先例
     `@__cold_located_error`(`aot/qlangc.ql:1699-1727` 发 define,`:1741` 手写调用)。
   - 程序可见面:`std`(`aot/runtime.ql:1861` 字面量 + `:1884` `__install_library`),
     纪律见 `:1882-1883`(「only value/namespace plumbing, never library algorithms」)。
   - runtime 的 174 个顶层 `let` **无符号、不导出**(`export` 语句数 = 0)。
5. **发射出的 IR 里的机制清单(实测:`/tmp/o3 --emit-llvm /tmp/t20.ql aot/runtime.ql` 后统计符号)**
   - `define` 281 / `declare` **18**;
   - **宿主原语面(全部 `declare` 的非-llvm 项)**:`ql_alloc` `ql_mem_get` `ql_mem_get_ptr`
     `ql_mem_store` `ql_mem_store_ptr` `ql_write` `ql_read` `ql_openat` `ql_close` `ql_readlinkat`
     `ql_getrandom` `ql_exit` `ql_extension_open`;
   - **内联叶子不在 `declare` 里**(它们是 `value_abi.ql` 的 `alwaysinline` define):
     调用次数 `@ql_tag` **2767**、`@ql_truthy` **977**、`@ql_empty` **777**、`@ql_word` **171**;
   - 冷机制 `@__cold_located_error` **1463** 次(= 错误边的可见代价);
   - `@llvm.lifetime.start/end` 各 **5221**。
   ⇒ ⑩ 族(⑩-2/⑩-3)打的就是 `@ql_tag`/`@ql_truthy`/`@ql_empty` 这几处 ✓。
6. **Rust 宿主(第三引擎)的探针结果**:`div0`⇒`DivisionByZero`、`missfield`⇒`UndefinedField`、
   `f(1)`⇒`false|<native fn <curried>>`(部分应用,与另两引擎一致);
   **渲染不同**:宿主把错误打印成
   `TypeMismatch: cannot apply addition to String and Number (at line 0, c…`,
   native/boot 则渲染 `?Error` —— 这正是 `difftest.py:13-14` 说的「两种实现不同的渲染,
   由 `norm_err()` 规范化」。宿主这句也是 `+` 类型严格(§2.5)的**权威措辞**。
   宿主二进制:`target/debug/qlang`。

## 6. 站点级落点(每 kind)

| kind | 引擎落点 |
|---|---|
| `DivisionByZero` | `runtime.ql:503`;`qlangc.ql:461`;`bootstrapped/parser.ql:229`(字面零 ⇒ 编译期);`src/error.rs:117` |
| `UndefinedField` | `runtime.ql:128,202,344,349` |
| `ArityMismatch` | `runtime.ql:1941`;`interpreter.ql:1046,1097,1120` |
| `StackOverflow` | `runtime.ql:2040`(深度 300);`interpreter.ql:1141-1143`;`src/interpreter.rs:765-768`;`src/error.rs:173` |
| `Uninitialized` | `qlangc.ql:846`(运行期那条);`environment.ql:49`;`parser.ql:141`(静态那条);`src/environment.rs:34` |
| `IndexOutOfBounds` | `runtime.ql:287,304`;`interpreter.ql:505,832` |

## 7. 测试用例/预言机清单(改动会波及谁)

| kind | 测试用例 / 金文件 / 预言机 |
|---|---|
| `DivisionByZero` | `aot/tests/{t14_interpolation,t25_numeric,t36_lazy_modules}.ql`;**`aot/run_module_tests.py:53,58`(native 与 boot 都断言 rc=1 + stderr)**;**`fuzzexpr.py:14-17,44-45`(三方预言机)** |
| `UndefinedField` | `t20_native_bridge.expected`,`t21_assignments.expected`,`t28`,`t37`,`t38`,`t39`,`t49`,`t51`;`bootstrapped/tests/native_source_bridge.ql`;`stdlib/object.ql`,`stdlib/bundle.ql` |
| `ArityMismatch` | `t24_call_buffers.expected`,`t27`,`t28`,`t29`,`t30`,`t37`,`t41`,`t43`,`t45`,`t54` |
| `StackOverflow` | `t24_call_buffers.expected`;`difftest.py` e21(:166)/r28(:470) |
| `Uninitialized` | `t14`,`t33_builtin_bindings`,`t35`;`tests/uninitialized.rs`;`difftest.py` u2(:273)/u28(:301)/w02(:337)/w03(:338)/w05(:340);`aot/run_interpreter_tests.py:96-104` |
| `IndexOutOfBounds` | `t21_assignments.expected`,`t29`,`t30`,`t32`,`t38`;`stdlib/string.ql`;`stdlib/run_string_tests.py`;`stdlib/bundle.ql` |

## 8. 文档行(需改/需补精确)

- `README.md:911`,`:1100` —— 说「读未初始化 ⇒ 值」,**不完整**:直接读被**静态拒绝**,
  仅跨函数/不可判定时才得到值(§1.5 vs §1.6)。
- 除零 `:943`,`:1071-1075`,`:1097`;缺失字段 `:1050`,`:1070`,`:1095`;
  越界 `:1070`,`:1092`,`:1094`;栈 `:1045`,`:1072`,`:1100` —— 与 §1 实测**一致**。
- `README.md:1133-1134` —— `??` 「catches the wrapped error」**与实测一致**(§2.2-2.4)。
- `aot/README.md:69`,`:601` —— 与 §3 实测一致(部分应用 + 原生函数参数不符)。
- `README.md:1209` —— `==` 类型严格(与 §2 方向一致)。

## 9. 已撤回的结论(不要再重新提出来)

以下都曾被我当作结论,均被实测推翻;**如需复活,必须先给出带对照组的复现**。

1. ~~「`??` 没能接住除零,与 README 不符」~~ —— 探针用异类相加当观测手段,污染了结果。
2. ~~「`??` 接住的值仍带传播状态,是个 bug」~~ —— 同上;真正的规则是 `+` 类型严格(§2.5)。
3. ~~「arity 是另一条通道、`?Error` 是形态可疑」~~ —— 参数不足是**合法部分应用**;
   `?Error` 只是打印 Error 的渲染(§3.2、§2.8)。
4. ~~「两台引擎在错误行为上有分歧」~~ —— 已测的 20+ 条全部一致(§1-§3);
   差别只在错误**类别名**(native `CompileError` vs boot `ParseError`)。
5. ~~「runtime 导出」是可选方案~~ —— runtime 的 `export` 语句数是 0,该机制不存在;
   机制的既有通道是 §5.4 的四条。
6. ~~「我们丢掉了 Rust「任意错误类型」的灵活性」~~ —— `Error` 是普通类型值 +
   `std.Type.make` ⇒ 派生错误类型可表达(`aot/runtime.ql:1352-1362`)。
7. ~~「我们没有泛型」~~ —— `Array(x)`/`Object(x)` 是类型构造器,`Union(A,B)` 是规范写法
   (`README.md:809`,`:867-872`);缺的只是**值层签名的类型参数推断/实例化**
   (`aot/types.ql:987` `typeParamsUnknown` 是其保守回退)。
8. ~~「`?` 的形态没定」~~ —— 后缀 `?` 早已实现(§4)。
9. ~~「静态可判 ⇒ 编译错误还没做」~~ —— 未绑定名已做且有专门测试套件(§4)。
10. ~~「仓库根的 `_b.ql` 是项目文件」~~ —— 是 difftest 之类工具留下的临时文件(§5.2)。

## 10. 明确未验证(隔离区,不许当结论用)

- Rust 的**栈耗尽**是否官方保证 abort(本轮只核到分配失败 `handle_alloc_error` 默认 abort)。
- `⑥` 的「已注解函数数」:本轮按正则计得 stdlib 14 处 / runtime 6 处;
  按「函数」精确计数**口径未定**。
- Rust 宿主(`src/`)对 §1-§3 各条的逐条行为:已补测 §5.6(div0/missfield/arity + 渲染差异)。
- `@ql_tag`/`@ql_truthy` 之外的内联叶子清单未逐个数(已知它们在 `aot/value_abi.ql`,不在 IR 的 `declare` 里)。

## 11. 基线(同源 HEAD —— 唯一有效口径)

**跑法必须同源**:HEAD 源码 + HEAD 编译器 + HEAD boot,且 **cwd = HEAD 工作树**:

```sh
git worktree add -f /tmp/wt_head HEAD
# /tmp/o3 = 工作树编译器;下面两条用「工作树编译器」编「HEAD 源码」——是杂交体,见 §11.2
( cd /tmp/wt_head && /tmp/o3 --emit-llvm aot/qlangc.ql aot/runtime.ql )      -> /tmp/o_head
( cd /tmp/wt_head && /tmp/o3 --emit-llvm bootstrapped/run_file.ql aot/runtime.ql ) -> /tmp/bp_head
cd /tmp/wt_head && python3 aot/run_<suite>.py --compiler /tmp/o_head --interpreter /tmp/bp_head
```

日志 `/tmp/sweep3/`。**注**:第一遍(`/tmp/sweep2`)把 HEAD 编译器与**工作树**测试用例混着跑,
产生的失败全部是假的(`/tmp/o_head` 编不动工作树里带 `__panic` 的 boot)⇒ **混源会造假失败**。

| 测试套件 | rc | 耗时 | 测试套件 | rc | 耗时 |
|---|---|---|---|---|---|
| array | 0 | 107s | module | **1** | 1s(缺 Rust 二进制) |
| assignment | **1** | 41s | numeric | 0 | 226s |
| call | 0 | 214s | object | 0 | 83s |
| diagnostic | 0 | 34s | scoped_module | 0 | 94s |
| gc | 0 | 43s | semantic | 0 | 45s |
| interpreter | 0 | 731s | source_context | 0 | 169s |
| lazy_module | 0 | 120s | strings | 0 | 217s |
| lifetime | 0 | 106s | bundle | 0 | 0s |
| link | 0 | 3s | runtime_diag | **1** | 17s |
| selfhost | 0 | 1573s | | | |

外加 `cargo test` **14 passed**;`platform` 需 `target/release/qlang`(本次未建 ⇒ 环境缺口);
`run_v1_tests.sh`、`verify_bootstrap.ql`、`run_argument_tests.py`、`run_extension*.py` 本次未纳入。

### 11.1 两处在 HEAD 上真实变红(不是环境)

- `assignment`:`CompileError: …/exits.ql:1:46: reading uninitialized variable: x`
  —— 测试套件**生成的**测试用例仍按「未初始化是运行期值」写,而编译器已**静态拒绝**(§1.5、§4)。
- `runtime_diag`:`CompileError: aot/tests/t38_runtime_diagnostics.ql:22:30: type mismatch:
  value of type String does not match the annotated type Number`
  —— 测试用例停留在「注解不强制」的时代,而编译器已强制。

⇒ 二者与 §9 的「漂移的断言」同源:**编译器变严了,测试用例没跟上**。长期未暴露,是因为常规测试
只有 `interpreter` + `selfhost`(两者都绿)⇒ **验收口径过窄**。

### 11.2 两条口径(由本节产生)

1. **验收 = 全量基线 + 与该改动相关的测试套件**;只跑两套会漏掉 §11.1 这类红。
2. **基线必须同源**(编译器与源码同一版本);跨版本混跑只会制造假失败(sweep2 的教训)。

## 12. 已实测:**cause 链的位置不持久**(与 runtime 自己的注释矛盾)

探针(逐项读,带 `isError` 守卫 —— 拼接会污染观测,见 §0.2):

```qlang
let zero = 0;                      // 1
let direct = 1 / zero;             // 2
let chained = direct + 1;          // 3
let show = (l, v) -> { if isError(v) { println(l + "=ERR"); } else { println(l + "=" + std.Number.toString(v)); }; };
let a = chained.cause.line;        // 9
let b = chained.cause.line;        // 11
let d = chained.cause.line;        // 15
```

实测输出:

```
direct.line(1st)=2   ✓   direct.line(2nd)=2   ✓   ← 直接错误:自身位置持久
cause.line(1st)=9    ✗   cause.line(2nd)=11   ✗   cause.line(3rd)=15  ✗
```

⇒ **直接错误的 `.line` 正确且稳定;但 `chained.cause.line` 给出的是「读取它时所在的绑定行」
(9/11/15),而不是 cause 的来源行(2)** ⇒ cause 链的位置**不持久**。

**与实现自己的说法矛盾** ✗:`aot/runtime.ql:97-98` 的注释写着
「Error provenance is **persistent**: reusing a stored Error **never changes its original
location** or previous call paths. Only failure edges allocate.」—— 而 `:99-106`
的 `__err_at`/`__err_record` 里已有 `located` 守卫 ⇒ **cause 那一路没被守卫护住** ⇒ 修点即此处。

**后果(已实测)**:`aot/tests/t38_runtime_diagnostics.ql:38` 的
`check(first.line == 7 && chained.cause.line == 3, "provenance survives allocations")`
在 :21 通过、在 :38(其后有多次造错与 3 万次分配)**失败** ⇒ 这就是 §11.1 里
`runtime_diag` 修掉注解编译错误后露出的**第二层红** —— 它不是本次改动造成的,
而是被第一次真正执行到。**它属于错误模型本体**(provenance 语义),不是测试用例笔误。

## 13. 子片 A(契约违反 ⇒ 致命)的机制与实测数字

**机制**(两条通道,**都不新增全局面、都不动 `std` 的用户面**):

- **生成代码侧**:编译器**自己发**一个固定名冷助手
  `define void @__panic_exit(ptr %env, %ql_value %kind, %ql_value %msg)`
  —— 逐条照 `@__cold_located_error` 同法:`aot/qlangc.ql:1731` 旗标 `needColdPanic`、
  `:1732-1760` 助手(体内把 `curScope` 切到 `runtimeScope`、`curEnv = "%env"`,再
  `emitCallRegs("__panic", …)`)、`main` 里 `needColdPanic` 的 splice(与 located 助手并列);
  调用点是**手写符号调用** `call void @__panic_exit(...)` + `unreachable`(`:964-967`)。
  ⇒ 因此**不需要**给源码绑定任何名字,也不需要改模块/作用域机制。
- **boot 源码侧**:走 **`std.__panic`** —— 依据是实测事实:boot 唯一的宿主能力通道就是 `std.__*`
  (`interpreter.ql:27` `std.__diagnostics`、`:29` `std.__extensions`),且 boot 会把这类名字
  **从用户 std 滤掉**(`:44`);新项已加入该过滤名单 ⇒ **不进用户面**。
- **runtime**:`std` 字面量加一项(`runtime.ql:1861`);`__panic` 早已存在(`:511`,= `__exit_error(__err(…))`)。

**实测**(工作树编译器 `/tmp/o6` + 工作树 boot `/tmp/bp_wt`,即同源):

| 项 | 结果 |
|---|---|
| 编译器自举 | rc=0 ✓ |
| 工作树 boot | **首次编得出**(此前是 `CompileError: undeclared name: __panic`)✓ |
| 判别测试用例(模块条件导出 ⇒ 运行期缺失赋值) | native:rc=1 + `UndefinedVariable: Undefined variable: absent` ✓;boot:rc=1 + 带源位置的同一消息 ✓ |
| t20 四步 | 探针 528/92 ✓、`clang` 0 error ✓、输出 `20` ✓、动态除数 `DivisionByZero` ✓ |
| 数字 | IR 188 577 → **187 738(−839)**;机器 125 473 → **125 479(+6)** |

**关于 +6**(已知同族,非回归):`std.__panic` 这一项让 `__panic` 的闭包盒**变为可达** ⇒ 被发出;
与 log ㉑ 记过的「一个**未被调用**的运行期函数」代价同族(那次数值 +105 IR / +41 机器)。

## 14. 已实测:Result/Option 注解、Option 的 `?`、用户级 `assert`(2026-10-25)

同源:`target/selfhost/stage2`(当前 `aot/qlangc.ql` + `aot/runtime.ql`)与
`target/native-interpreter/interpreter`(同一编译器构建)。

### 14.1 注解成功协议(Err 是值)

```qlang
let z = 0; let e = 1 / z;
let a: Any = e;                    println(a.type);              // DivisionByZero
let b: std.Result(Number) = e;     println(b.type);              // DivisionByZero
let fail = () -> { let c: Number = e; c; };
println(isError(fail()));                                        // true
```

⇒ `Any`/`Result(Number)` 存原 Error;`Number` 仍失败(在函数内是可观察的 `TypeCheck` 值;
顶层绑定失败则按顶层未处理错误 exit 1)。测试用例 `t56_result_annotations` 逐行匹配两引擎。

### 14.2 Option 的类型与 `?`

```qlang
println(std.Option(Number).check(5));     // true
println(std.Option(Number).check(null));  // true
println(std.Option(Number).check("x"));   // false
let none = (): std.Option(Number) -> { let v = null; let x = v?; 99; };
println(none());                          // null
```

⇒ `None` = `null`;Option 函数里的 `?` 传播 `null`;Error 不是 Option(交返回边报 `TypeCheck`)。
测试用例 `t56` 的 None/Some/Error 三态在 native/boot 上一致。

### 14.3 `?` 上下文约束

```qlang
let bad = (): Number -> { let z = 0; let v = (1 / z)?; v; };
```

native:`CompileError: …:1:51: ? requires a Result or Option return type`;boot:同一
`ParseError` 位置与消息。`Result(Number)`/`Option(Number)`/无注解函数是合法对照
(`run_semantic_diagnostic_tests.py` 的 `propagate-number`/`propagate-string` + `t56`)。

### 14.4 用户级 `assert`

```qlang
println("before");
assert(false, "boom");
println("after");
```

| 引擎 | 实测 |
|---|---|
| native | rc=1,stdout=`before\n`,stderr=`AssertionFailed: boom` |
| boot | rc=1,stdout 到 `before` 为止,stderr=`AssertionFailed: boom` |

成功侧:`assert(true, "ok")` 返回 `null`;字符串/数组 truthy、对象消息均可用
(测试用例 `t57_assert`)。实现是 runtime 的 `assert`,通过 `__native(assert, "assert", false)`
让 boot 直接调用同一份实现;`assert` 已进 `moduleGlobalNames`,导入模块/函数内可见。

## 15. 已实测:直接调用与纯 Number 内联(2026-10-26)

同源 `target/selfhost/stage2` 形态;判别测试用例 `t58_direct_calls` / `t59_inline_pure`。

```qlang
// direct: 不可变 leaf,无参数注解,实参均 cannotBeError
let add = (a, b) -> a + b;
let i = 0; let s = 0;
while i < 5 { s = add(i, 1); i = i + 1; };

// raw inline: 单调用点、无 value use、参数/返回 Number、body 纯 + 且无自由变量
let pure = (a: Number, b: Number): Number -> a + b;
let j = 0; let t = 0;
while j < 5 { t = pure(j, 1); j = j + 1; };
```

| 形状 | 机器指令 |
|---|---:|
| 空文件 | 125,673 |
| 直接调用判别 | **125,870** |
| 同上走后门 `f = add; f(i,1)` | 125,889 |
| 纯 Number 内联判别 | **125,744** |
| 同上走后门 `f = pure; f(j,1)` | 125,939 |

⇒ 直接调用静态 **−19**,但循环体不再进入 771 条静态指令的通用分派体;纯 Number
内联 **−195**,函数体/闭包被删掉,循环体成为 raw `fadd`。20M 次微基准本机用户态:
内联约 **0.05–0.08s**,通用分派约 **36s**(后台测试套件争用,仅量级参考)。

**失效条件(已加判别)**:赋值、重声明、export、value use(别名)、参数注解、
参数不足/超参、实参可能为 Error、body 有调用、body 有自由变量、非 Number 运算。
`t59` 覆盖重声明、赋值、value use、捕获自由变量;`t58` 覆盖别名、部分应用、
Error 实参、注解参数、返回注解、leaf 内赋值与 body Error。
同源 p0f:`stage2/stage3` IR 相同;interpreter 59 PASS;selfhost ALL CHECKS PASS;
call/array/object/numeric/assignment/diagnostic ALL CHECKS PASS。

## 16. 已实测:多调用点 raw 直接函数(P1,2026-10-26)

判别测试用例 `t60_raw_direct`。形状:注解 `Number` 参数、无参数写入、leaf、绑定无 value
use/重声明/赋值/export,且**每个**调用点 arity 精确、每个实参 `staticType == Number`
且 `cannotBeError == true`。

```qlang
// 5 个调用点:closure/annotations/boxed 入口都不再发出,绑定槽存定义环境指针
let add = (a: Number, b: Number): Number -> a + b;
let v1 = add(1, 2); let v2 = add(3, 4); let v3 = add(5, 6);
let v4 = add(7, 8); let v5 = add(9, 10);
println(v1 + v2 + v3 + v4 + v5);
```

| 形状 | 机器指令(旧 → P1) |
|---|---:|
| 空文件 | 125,673 |
| t20 | 125,735(不变) |
| 5 调用点注解函数 | 126,120 → **125,766**(−354) |
| 非内联体 `max2`/`sq` 共 6 调用点 | 126,284 → **125,819**(−465) |

上述两例的 `rawcalls`/`rawfuncs` 分别为 5/1、6/2。

⇒ raw 入口 `%ql_value @ql_fnN(ptr %env, double %p0, ...)`;调用点把实参读成 double,
不再构造 16 字节实参缓冲;函数体只发一份,调用点越多越划算。

5M 次 `max2(i, i+1)` 微基准(同一编译器;raw 直接调用 vs `let f = max2` 强制通用
路径):用户态 **0.059s vs 8.473s**,输出相同;静态 125,759 vs 125,993(−234)。

**失效条件(已加判别)**:value use、部分应用、参数写入、任一实参可能为 Error、
零参函数、非 leaf(含递归)、绑定注解、重声明/赋值/export、定义前调用、同名静态
import(import 会覆盖同名槽)。`t60` 覆盖 5 调用点、全局读/写、逐帧 env(逃逸闭包)、
value use、部分应用、参数写、循环内定义、零参、递归、Error-prone 实参、同名 import
覆盖。native/boot 输出一致。


## 17. 已实测:裸返回与 known-safe 传播(P2,2026-10-26)

测试用例 `t61_known_safe`。核心形状:

```qlang
let add = (a: Number, b: Number): Number -> a + b;
let i = 0; let s = 0;
while i < 5000000 { s = add(s, i); i = i + 1; };
```

| 形状 | 机器指令 | 用户态(5M) |
|---|---:|---:|
| 旧:累加器 prone ⇒ 通用分派 | 125,937 | 9.606s |
| known-safe:累加器不再 prone ⇒ inline | **125,757** | **0.011s** |

裸返回判别(5 次 raw 调用):125,766 → **125,762**(−4,`rawretcalls=5`)。
小函数被 `clang -O2` 内联,box/unbox 本来就会被折叠;裸返回的主要作用是
让「调用不可能 Error」可传播。空文件/t20 不变(125,673 / 125,735)。

**失效条件(已加判别)**:多调用点、value use/export/import/重声明/赋值、
参数被写、带注解的 Let/Assign、body 有调用、`?`、除法、返回注解不是 Number。
`t61` 覆盖单调用点累加器、裸返回用于算术/条件/`!`、除法(不证明)、多调用点、
别名、参数写入。native/boot 输出一致。

**独立发现**:`moduleCache` 包含入口程序,旧 compiler 在 userProgram 之后又把
入口当模块分析一遍;第二遍 `inferExpr` 会重置 `cannotBeError`/`returnsNumberSafe`
等分析结论。P2 跳过入口路径后 known-safe 修正才生效;模块仍各分析一次。


## 18. 已实测:放宽 leaf(P3,2026-10-26)

测试用例 `t62_leaf_calls`。规则:自调用/后定义函数排除;body 内局部函数、源序在前的
函数允许;`Import` 仍禁止。

| 形状 | 机器指令 | 用户态 |
|---|---:|---:|
| `compose` 测试用例(含自别名/互递归;P2) | 128,016 | — |
| 同上(P3;最终测试用例) | **127,881** | — |
| 5M 次 `s = s + compose(1,i)` 旧 | 125,951 | 9.074s |
| 同上(P3) | **125,762** | **0.039s** |

判别覆盖:组合函数、局部闭包、自递归(排除)、自别名(`let g=selfAlias`)排除、
后定义调用(排除)、互递归(`a` 排除/`b` 可 raw)。native/boot 输出一致。


## 19. 已实测:累加器安全证明的顺序问题(2026-10-26)

判别:注解 Number 累加器 `acc = add(acc, i)`(2M 次)。旧编译器把实参 `acc` 判成
不安全,于是没有 inline/raw,每轮走通用调用。

| 版本 | 整程序机器指令 | 用户态(交替跑 3 次) |
|---|---:|---:|
| 旧(Identifier 只读 `safe[bid]`) | 126,064 | 5.56 / 6.43 / 5.10s |
| 新(未访问的 bid 就地 DFS) | **125,772** | **0.28 / 0.27 / 0.25s** |

`safemarked` 3 → 5。复现:`aot/bench/run_bench.py --compiler <stage2> --only b_calls`。
注意整程序指令数只差 292 条 —— 固定 runtime/stdlib 占满 126k,热循环改动要靠
`run(s)` 而不是 `insns` 裁决(见 §3.4 的同一现象)。


## 20. 已否决:热助手 `alwaysinline`(2026-10-26)

设想:把 `__norm_idx` / `__isError` / `__str_eq` / `__s_len` / `__utf8_width` /
`__s_pos` / `__hash` / `__obj_find` 打上 `alwaysinline`,让 LLVM 在调用点看到
tag/长度判断,把循环不变部分提出去,并省掉调用与实参缓冲。

实测(同源编译器,`aot/bench`):

| 版本 | b_build | b_calls | b_chars | 用户态 |
|---|---:|---:|---:|---|
| 基线 | 126,019 | 125,772 | 126,315 | b_chars 3.45/3.94/4.02s |
| alwaysinline | **129,088** | **128,841** | **129,384** | b_chars 3.43/3.17/4.02s |

- 代码尺寸:**每个程序固定 +3,069 条机器指令(+2.4%)** —— 这 8 个助手在 runtime、
  stdlib、用户代码的每个调用点都被展开。
- 运行时:交错跑三对,b_chars 的差值落在自身噪声(±15%)里,**测不出收益**;
  b_calls / b_build 持平。
- 前端与 clang 耗时不变。

结论:**否决并回滚**。+2.4% 的全局代码膨胀换一个测不出来的收益,不符合"无收益不背
复杂度"。要再试的话,必须先把"热循环单条语句的指令数"做成可复现的稳定量度
(现在的整程序 insns 与 ±15% 的运行噪声都不够),再单独收窄名单(比如只放
`__norm_idx`)。


## 21. 已实测:数组取元素的内联快路径(2026-10-26)

判别:`let chars: AnyArray = …; while … { if chars[i] == " " { … }; i = i + 1; }`
(500 轮 × 72,751 元素 = 3,640 万次取元素)。

规则:接收者静态类型已知是 `Array`/`AnyArray`、下标静态类型 `Number` 且
`cannotBeError` ⇒ 发射端内联「tag==5 + 无符号界 + 整数性」检查,读
`els[idx*16]`;任何一项不成立(负下标回绕、小数、越界、tag 不符)落回通用
`__get_index`,由它按原语义给出错误值。**保留 tag 检查**:staticType 不是运行期
类型(陷阱 #1),它只决定值不值得快,不成立时必须安全降级。

| 版本 | 用户态 CPU(5 次最小) | 整程序机器指令 |
|---|---:|---:|
| 通用 `__get_index` | 2.920s | 126,358 |
| 内联快路径 | **2.474s(−15.3%)** | 126,558(+200) |

自举前端(编译 `aot/qlangc.ql`,lexer/parser 为主):**46.62s → 42.97s CPU(−7.8%)**。
计数器:`; index-fast: N`(空程序 31 —— 全是 stdlib 的取元素点;自举时更多)。

代价:每个启用点约 +20 条 IR(含冷回落块),整程序净 +200 条指令;测试用例输出不变,
`stage2/stage3` IR 固定点成立。


## 22. IR 分块写出 + 预编译 stdlib 前缀的可行性(2026-10-26)

**分块写出**:188k 行原来逐行 `println`,即 188k 次 `write`。改成按 4,096 行用
`std.String.join` 拼成一块、`print` 一次(约 50 次 syscall)。

| 版本 | 空程序用户态 CPU(4 次最小) |
|---|---:|
| 逐行 println | 9.97s |
| 分块写出 | **9.75s(−2.2%)** |

输出**逐字节相同**(空程序 + t20/t19/t30/t61/t62 五个测试用例全 `cmp` 通过)⇒ 产物
完全不变,只是 syscall 数量变了。

**预编译 stdlib 前缀(S-3)可行性**:比较 `define i32 @main(` 之前的全部代码,
空程序 vs t20 vs t62 —— **除了冷助手里的 temp 编号,完全一致**:

- `@__panic_exit` / `@__cold_located_error` 是编译尾声才拼接进去的,它们的 `%tNNN`
  用的是全局计数器(随程序变化);`%env` 偏移(如 2704)跨程序相同,因为
  runtime/stdlib 的槽先分配、入口程序的槽在后。
- `;` 计数注释(unboxable bindings 等)按程序变化,本来就不属于代码前缀。
- 字符串声明:`@.strN` 前缀跨程序**共享**(空程序 1,572 条 ⊂ t62 的 1,590 条)。

⇒ 只要给冷助手一个独立计数器,「prelude + runtime/stdlib 函数体 + 库字符串声明」
就是一个与用户程序无关的固定前缀;每条编译只需发「注释计数 + 用户函数 + main +
用户字符串」,并从前缀尾部恢复 `tmpN/lblN/funcCounter/strCounter` 与字符串驻留表。
这能把前端里 parse(5.1s)+分析(1.1s)+发射(~3.3s)的固定部分整体拿掉。


## 23. S-3 第一步:冷助手独立命名空间,S-3 定下来(2026-10-26)

上一节发现:「prelude + 冷助手」里唯一的程序相关物是冷助手的 `%tNNN` 编号(它们是编译
尾声才发射的)。现在给冷助手一套独立命名空间(`%hN` / `hLN`),并把拼接点从「计数注释
之后」移到 **prelude 之后**。于是:

- `define i32 @main(` 之前的第一段(**prelude + 两个冷助手,161 行**)在
  空程序 / t20 / t62 下**逐字节相同**;
- 机器指令数不变(t20 125,923;t62 128,069)——纯改名 + 重排,不动生成的代码;
- 自举固定点仍然成立。

下一步(S-3 消费端)要注意的三件事,已记录:
1. `@main` 的前导(alloca/memset 大小)按程序变化 ⇒ 前缀只能是
   「prelude + 助手 + 库函数体 + 库字符串声明」,main 里的 runtime/stdlib 初始化序列
   要单独成块,不能与前缀拼在一起;
2. 用户字符串若与库字符串相同,一次性模式会复用库的 `@.strboxN` ⇒ 消费端需要库的
   驻留表(约 1,572 条)才能逐字节一致;
3. 计数注释(`; unboxable bindings` 等)按程序变化,放在前缀之后。


## 24. S-3 第二步:库区独立命名空间,库函数体变成固定文本(2026-10-26)

命名空间分三段:冷助手 `%hN`/`hLN`、**runtime+stdlib 区 `%rN`/`rLN`**、按程序区
`%tN`/`bbN`。分区之后:

| 输入 | 共享函数数 | 文本不同的函数 |
|---|---:|---|
| 空程序 vs `t15_modules`(带 import) | 285 | **1(`@main`)** |
| 空程序 vs `t62_leaf_calls`(带用户函数) | 285 | **1(`@main`)** |

即 284 个 runtime/stdlib 函数体逐字节相同——之前它们随用户程序的 import 数量漂移
(模块加载初始化占用的 `%tN` 编号在库函数体之前)。机器指令数不变(t20 125,923),
自举固定点成立。

**这条性质是把 stdlib 预编译(文本前缀或独立目标文件)的前提**:库函数体不再依赖
用户程序,只有 `@main` 里的初始化序列按程序变化。


## 25. S-3 第三步:runtime/stdlib 初始化提成 @__stdlib_init(2026-10-27)

`@main` 里原来内联着 runtime/stdlib 的初始化(建闭包、装 std、装 args)。现在这段
整体提成一个独立函数 `@__stdlib_init(ptr %env, i32 %argc, ptr %argv)`,`@main` 只剩
一句调用 + 按程序变化的部分。

这一步不改任何语义:初始化里的错误路径仍按"顶层"处理(`__exit_error` + `unreachable`),
所以函数内把 `isTopLevel` 显式设成 true —— 与原来在 `@main` 顶层逐条相同。

代价与验证:

| 度量 | 结果 |
|---|---|
| t20 机器指令 | 125,923 → **125,946**(+23,调用边界) |
| selfhost 全套(`--jobs 3`) | **ALL PASS** |
| native interpreter 全套(`--jobs 3`) | **ALL CHECKS PASS** |
| 自举固定点 | stage2/stage3 IR 逐字节相同 |

踩到的两个状态泄漏(都已修,记下来):
1. `emitStdlibInit` 忘了恢复 `curSink` —— 调用点之后的行被追加到刚 push 进 `fnBlocks`
   的那个函数体尾部,IR 结构直接坏掉;
2. 初始化函数内部借用 `inRuntime = true`,返回后必须由 `@main` 显式置回 false,否则
   用户程序的直接调用判定全部失效(`directCallTarget` 在 `inRuntime` 下返回 null),
   表现为 `internal: proven-safe call is not directly dispatched`。


## 26. 标准库对象化:一次编译,按哈希缓存,逐测试用例链接(2026-10-27)

前两节把 runtime/stdlib 的文本变成了与程序无关的固定前缀;这一节把它**编译一次**:

- `aot/stdlib_split.py`:用编译器编一个空程序,把模块拆成「preamble + 助手 + 库函数体 +
  字符串 + `@__stdlib_init`」,编译成 `target/stdlib/<key>/stdlib.o`(key = 编译器二进制
  + `runtime.ql` + `stdlib/bundle.ql` 的哈希),并落一份 `symbols.json`(声明文本);
- `aot/native_link.py`:新增 `--stdlib-object` / `QLANG_STDLIB_OBJECT`。开启时把用户 IR
  里属于 stdlib 的 `define`/全局删掉、只给被引用的补 `declare`,然后和 `stdlib.o` 一起链接;
- 两套测试自动构建并启用它(带缓存,失败则自动回落到单模块链接)。

关键取舍:**`internal alwaysinline` 的 value-ABI 叶子(`ql_tag`/`ql_empty`/`ql_word`/
`ql_byte`/`ql_truthy`)两个模块各留一份**。它们不跨对象边界,调用点仍然内联;否则每个
tag 检查都会变成一次真调用(+1,038 条指令/程序)。

| 度量 | 单模块 | 拆开 + 链接 |
|---|---:|---:|
| 单测试用例链接(clang -O2 + lld) | 12.3s | **1.5s** |
| t20 二进制机器指令数 | 126,635 | **126,599**(−36) |
| selfhost 全套(`--jobs 3`) | ~20 min | **6.3 min** |
| interpreter 全套(`--jobs 3`) | ~8 min | **6.2 min** |
| stdlib 对象 | — | 280 函数 + 1,573 全局 |

测试用例输出逐条不变(6 个测试用例逐字节比对 + 两套测试全绿)。IR 仍是逐字节相同的单模块文本
——编译器一行没改,只有链接路径变了,所以自举固定点不受影响。


## 27. 前端也跳过库:编译器 `--emit-llvm-split`(2026-10-27)

上一节让链接跳过库,但前端仍要把 180k 行库 IR 发射出来。这一节让**编译器自己**只发
用户部分:

- 发射函数时多写一行注释 `; ql-symbol <名字> <ql_fnN>`(不进代码);
- `aot/stdlib_split.py` 构建对象时把这张表落成 `symbols.tsv`;
- `stage2 --emit-llvm-split <源码> <runtime> <symbols.tsv>`:
  - 只发 `declare`(冷助手、`@__stdlib_init`、表里每个符号),不发库函数体/库字符串/助手;
  - 仍然 `reserveModuleBindings` runtime/stdlib(槽表不变),再把绑定标成 active、
    登记 `runtimeFnIr` 与直接调用目标(与单模块模式 `emitLetStmt` 做的事一致);
  - `funcCounter` 从表里最大编号之后开始、用户字符串从 `.str1000000` 起,避免与对象撞名。
- `native_link.py`:识别 `; split-stdlib` 标记(编译器已拆好),仍然链接对象;字符串校验
  改成同时按「用户 IR + 对象自己的 IR」核对,不放过任何一个静态字符串。

| 度量 | 单模块 | 前端也拆 |
|---|---:|---:|
| 单测试用例前端 | 9.7s CPU / 188k 行 IR | **5.7s / 1.7k 行** |
| 单测试用例总构建(前端+链接) | ~22s | **~7s** |
| t20 二进制机器指令 | 126,635 | 126,599 |
| selfhost 全套(`--jobs 3`) | 6.3 min | 6.5 min |
| interpreter 全套(`--jobs 3`) | 6.2 min | 8.2 min |

两套测试全绿;自举固定点在 split 模式下逐字节成立(用 native 编译器手工验证:
`stage2 → IR_a → link → stage3 → IR_b`,`IR_a == IR_b`)。

**注**:对「用户代码本身就很大」的程序(例如编译器自己,830k 行),拆分不减小 IR —— 库的
那部分本来就不是大头;收益主要体现在小程序与测试套件迭代上。


## 28. 分析接口缓存:连 parse/分析也不做了(2026-10-27)

上一节让前端只发用户 IR,但仍要每次 lex/parse/分析 runtime+stdlib(≈5s)。用户程序的分析
其实只读很少几样东西,把这几样缓存下来就够了:

- 槽顺序(`SLOT`)、运行期函数名集合(`RFN`)、运行期被赋值的名字(`ASG`);
- 顶层的「名字 + 元数」(`DFN`,直接调用目标用);
- `std.<模块>` 三张索引(`MT` 值类型 / `MV` 成员值 / `MC` 成员函数返回类型)。

`stage2 --emit-stdlib-interface runtime.ql` 打印这 378 行;`stdlib_split.py` 把它和对象放在
一起缓存。`--emit-llvm-split <源码> <runtime> <symbols.tsv> <interface.txt>` 装载接口后
**完全跳过** runtime/stdlib 的 parse+分析;第 5 个参数传 `-` 则走「从源码分析」的对照路径
(用于 A/B 验证)。

| 度量 | 单模块 | 对象 + 接口 |
|---|---:|---:|
| 单测试用例前端(t20) | 9.7s | **0.45s(17×)** |
| 单测试用例整条构建(前端+链接) | ~22s | **~1.7s(13×)** |
| selfhost 全套(`--jobs 3`) | 2h(串行)/ 6.3min | **2.3min** |
| interpreter 全套(`--jobs 3`) | — | **5.6min** |

**等价性验证**:同一编译器、同一输入,`-`(从源码分析)与接口缓存两条路径发出的代码,
把局部名字(`%tN`/`bbN`/`ql_fnN`/`.strN`)归一化之后**逐行相同**;两套测试全绿;
自举固定点在缓存模式下逐字节成立。


## 29. 字符堆对象:ASCII 单字符共享盒(2026-10-27)

`s[i]` / `split("")` 每取一个字符都新建一个 STRING 盒。128 个 ASCII 字符的盒子是常量,
所以在 runtime 模块初始化末尾预建一份共享盒(模块级数组 ⇒ 从运行期作用域可达 ⇒ GC 根,
不需要改 C 侧根集),`__s_at` 单字节 ASCII 直接返回共享盒。

**关键细节**:共享表必须用**叶子读**(`ql_value_get(ql_mem_get_ptr(table, 8), byte*16)`),
不能写 `__asciiChars[byte]` —— 后者走 `__get_index`(下标有限/整数/回绕规整),比它省下的
分配还贵。第一版就是栽在这里:实测比不优化**慢 19%**;换成叶子读之后才转正。

| 版本 | 14.5M 次 `s[i]` + 比较(用户态 CPU) |
|---|---:|
| 每个字符新分配 | 2.168s |
| 共享盒 + `__get_index` 读表 | 3.030s(**更慢,已否决**) |
| 共享盒 + 叶子读表 | **1.800s(−17%)** |

t20 二进制机器指令数不变(126,713);selfhost / interpreter 两套测试全绿;固定点成立。
判别基准 `aot/bench/b_strat.ql`。


## 30. 直接调用改寄存器实参 ABI(2026-10-27,已落地)

动机:每次调用都把实参写进栈缓冲(`alloca` + N 次 `store` + 两个 `lifetime` + 传 `argc`/
从闭包盒 `load` `annotations`),被调者再读回来。stdlib 里 4,114 个调用点。

实现(宽度可控):**≤3 参且无参数注解**的函数额外发一个寄存器入口
`@ql_fnN_f(ptr %env, %ql_value %p0…)`,函数体直接从寄存器取参;闭包盒仍指向通用入口
(包装函数:从缓冲取参 → 转调 `_f`),所以间接调用/部分应用行为不变。285 个函数里
267 个符合条件,4,114 个调用点里 4,112 个 argc ≤ 3。

| 度量 | 通用 ABI | 寄存器 ABI |
|---|---:|---:|
| stdlib IR | 188,129 行 / 8.8MB | **154,832 行 / 7.13MB(−19%)** |
| `clang -O2` 编 stdlib.o | 13,272ms | **10,036ms(−24%)** |
| stdlib 机器指令 | 125,713 | **125,041(−0.5%)** |
| 5M 次无注解调用(用户态 CPU,同对象、8 次最小) | 0.424s | **0.355s(−16%)** |
| t16 用户模块 IR / 前端 / clang | 3,224 行 / 500ms / 467ms | 3,238 行 / 317ms / 470ms |
| 自举编译自身 IR | 849,220 行 | 907,007 行(+7%,用户函数多 ⇒ 包装多) |

**测量的教训(重要)**:第一次评估时我用「4 次运行 + 两边各用自己那份 stdlib.o」,得出
「5M 调用 0.475s → 0.504s,反而变慢」,据此否决。实际是**噪声 + 对象不匹配**(一份带包装、
一份不带);改成同一份对象、8 次最小值后是 **−16%**。凡比较"用户代码的调用形状",
必须链接**同一个** stdlib 对象,否则量的是库的差异。

代价:每个符合条件的函数多一个包装入口(用户函数多的程序 IR 会涨,编译器自身 +7%);
产物机器指令净 −0.5%。测试:selfhost / interpreter 全绿(各 ~10min / ~8min,当轮宿主较慢),
自举固定点逐字节成立。


## 31. 别名/内存效果注解(D 项,2026-10-27)

想法:每条语句都从 env 帧重新 `load` 绑定,LLVM 不敢跨 store 提升。做法(全部是**声明**,
不改代码):

- `declare noalias ptr @ql_alloc(i64)` —— 分配器返回的存储不与任何已有对象重叠;
- 内存叶子声明精确效果:`ql_mem_get`/`ql_mem_get_ptr`/`ql_write` → `memory(argmem: read)`,
  `ql_mem_store`/`ql_mem_store_ptr`/`ql_read`/`ql_getrandom` → `memory(argmem: write)`。

| stdlib 机器指令 | 值 |
|---|---:|
| 无注解 | 125,041 |
| 只加 `ql_alloc noalias` | 124,528(−513) |
| 再加内存效果 | **124,505(−536,−0.43%)** |

b_chars 用户模块不变(126,015,用户代码不直接调这些 C 叶子);selfhost / interpreter 两套测试
全绿;固定点成立。

**结论**:小但免费(两处声明、零 IR 增长),留下。但"重复 env load 提出循环"的期待不成立 ——
LLVM 的 BasicAA 本来就能用同帧固定偏移区分不同绑定,SROA 也把局部往返消掉了;`noalias`
真正帮到的是"堆帧 vs 其它分配"这一层。要再往下压,只能是算法级(见 §32 的功能分组)
或惰性 std(C 项)。


## 32. 放宽 `directLeaf` = 无收益;动态调用到底卡在哪(2026-10-27)

背景:静态分派登记直接调用目标时要求 `node.directLeaf = functionBodyIsLeaf(body)`,即函数体里
不能有任何调用。真实代码里几乎所有函数都会调用别的东西,于是编译器自身 98% 的调用点是
`blr`。假设:去掉 leaf 约束能大幅提高静态分派比例。

做法:把登记条件收窄为「符号已发出 + 无参数注解 + 绑定不可变 + 完整应用 + 实参已证非 Error」,
去掉 leaf 要求;同时给 `directCallTarget` 加拒绝计数器(`; directreject:`)。

| 度量(编译器自身编译) | 放宽前 | 放宽后 |
|---|---:|---:|
| 静态调用点 | 481 | 892 |
| 动态调用点 | 24,079 | 24,431 |
| 动态占比 | 98.0% | 96.5% |
| 12 个测试用例机器指令合计 | 1,610,839 | 1,610,809(−30) |

**结论:无收益,已回滚。** 机器指令只在噪声范围里动,输出逐字节一致(13 个测试用例 A/B)。

**真正的诊断(这是这一节的收获)**:`directCallTarget` 的拒绝分布(放宽 leaf 后):

```
noinfo=2776  args=1492  notable=180  成功 direct=529
```

即本地函数调用里"没登记成直接目标"远多于"实参不安全"。但更关键的是**分母**:24k 个动态调用点里
约 **19k 根本不进这条路径** —— 它们是 `std.<模块>.<成员>(…)` 和"参数是高阶函数"的调用,连
`lookupSlot` 都到不了。所以静态分派的下一刀不是放宽 leaf,而是:

**给 `std.<模块>.<成员>` 建「成员 → 符号」映射并静态分派。** 难点:库的模块对象是
`makeStringLibrary(...)` 里返回的对象字面量,成员是**匿名闭包**,`symbols.tsv` 里的
`名字 → ql_fnN` 覆盖不到它们。需要在发射对象字面量时记录 `模块名.成员 → ql_fnN`,
再让分析与发射共用这张表。


## 33. 前端:模块事实一趟扫完(2026-10-27)

`loadModuleProgram` 原本在新解析出的 AST 上走**两趟**:`collectModuleExports`(找导出名)和
`loadModuleNode`(找 Import 并递归加载)。第二趟还带着一个从头到尾没被用过的 `names` 参数。
导出名与 import 列表是**互不依赖的信息**,没有理由拆成两趟。

合并成 `scanModuleFacts`(一次深搜同时收集 导出名 + Import 节点,文档序),解析仍然放在
`resolveModuleImports` 之后做(它要递归进别的模块,属于不同关注点,不是"多一顿遍历")。
注意 `module` 字段要跳过:它是解析阶段回填的别的模块的 AST。

| 度量(交错跑两轮,机器当时较慢,看比例) | 旧 | 新 |
|---|---:|---:|
| 自举(编译 qlangc.ql) | 64,024 / 64,202 ms | **62,130 / 59,557 ms** |
| 中位数 | 64.1s | 60.8s(−5.2%) |

验收:自举固定点逐字节成立;scoped_module / lazy_module 两套测试全绿;7 个带 `.expected`
的测试用例输出一致。

下一笔同性质的合并:`collectAssignedNames`(赋值/导出/重声明)与 `collectImportedNames`
(import 绑定的名字)也是对同一棵树的两趟,可以并成一次。


## 34. 前端:名字事实两趟遍历合成一趟(2026-10-27)

`collectAssignedNames`(赋值/导出/重声明)与 `collectImportedNames`(静态 import 绑定的名字)
是同一棵树上的两趟全树遍历,收集的是**互不依赖**的名字事实。合并进 `collectAssignedNames`
的 Import 分支,删掉独立的 walker。

**合并时踩到的坑(值得记)**:`buildInlineCandidates` 开头有一句 `importedNames = {};`
再自己扫一遍。删掉扫描后,这句清空把 `main` 里刚扫好的表清掉了,于是"import 覆盖同名槽"
的判据丢失 —— `t60_raw_direct` 的 `shadow` 被错当成 raw 目标,输出从 102 变成 3。
自举测试抓到;修法是删掉那句清空并注释原因。

| 度量 | 结果 |
|---|---|
| 墙钟(交错两轮) | ds1 33.2/46.8s,n3 42.6/41.2s —— **在本机噪声内,测不出差异** |
| 确定性收益 | 少一趟全树遍历、少一个 walker 函数 |
| 验收 | 自举固定点逐字节成立;scoped_module / lazy_module / selfhost 全绿;t60 输出恢复 102 |

同性质的候选(下一轮):`reserveModuleBindings`(建立槽)与 `collectBodyLetNames`;
`types.ql` 里 `typeBodyIsClean` / `typeReturnsPure` / `typeReturnsAreSafe` 对同一函数体的三趟。


## 35. 分析:函数体三个判据合成一趟(2026-10-27)

`typeFunctionReturnsPure` 与 `typeFunctionReturnsNumberSafe` 各自需要函数体的三个布尔事实:

- `clean`:函数体没有 调用/import/`?`/带注解的 Let·Assign;
- `pure`:每个 `return` 的值都是纯 Number(依赖参数 bindId);
- `safe`:每个 `return` 的值都是安全 Number(依赖第二遍的 `cannotBeError`)。

原来是三个独立 walker,`clean` 被两个判据各走一遍 ⇒ 干净函数体最多走 **4 遍全树**,含调用的
函数体走 **2 遍**。合并成 `typeBodyFactsOf`:一趟收集三个事实,按 `typeProgram` 缓存
(第二遍分析要重算 `safe`)。

**关键细节**:提前退出必须放在函数入口。第一版把它放在对象分支里,语句列表仍会走完整棵树,
实测**反而慢 26%**(CPU 39.5s vs 31.3s,同机重复 3 次)。挪到入口后,dirty 函数体只走 1 趟。

| 度量 | 结果 |
|---|---|
| 结构 | 3 个 walker → 1 个;干净函数体 4 遍 → 1 遍,dirty 2 遍 → 1 遍 |
| 墙钟/CPU | 本机噪声 ±30%(同一二进制两次量到 30.7s / 39.5s),**测不出差异** |
| 验收 | 自举固定点逐字节成立;selfhost 绿;t58/t59/t60/t61/t62 等 10 个测试用例输出一致 |

教训:遍历合并必须保留原来的**提前退出位置**;把"少走一趟"换成"每趟走得更全"是负收益。


## 36. 注解的真实收益:算术型 105×,String 型负收益(2026-10-27)

同一个 5M 次循环,只改被调函数有没有 Number 注解(`/tmp/B_ann.ql` vs `/tmp/B_unann.ql`):

```qlang
let add = (a: Number, b: Number): Number -> a + b;   // 与下行的差别只有注解
let add = (a, b) -> a + b;
let run = (n: Number): Number -> {
  let acc: Number = 0; let i: Number = 0;
  while i < n { acc = add(acc, i); i = i + 1; };
  acc;
};
println(run(5000000));
```

| 版本 | 用户态 CPU | 每次调用 | 产物机器指令 |
|---|---:|---:|---:|
| 带注解 | **0.029s** | **5.7 ns** | 125,427 |
| 无注解 | **3.008s** | **601.6 ns** | 125,640 |

**105×**,输出都是 `12499997500000`。机制:注解版满足 P1/P2(全部参数注解 Number、无 value
use、单调用点)⇒ raw 直接调用 + 内联,循环体里只剩 `fadd`;无注解版每轮走
`__call_borrowed`(栈上建实参数组 + 通用分发)+ 被调者里 `a + b` 还要走 `__op_add` 类型分派。

**但 String 型函数加注解是负收益**:给 13 个 emit 助手(temp/lbl/emitPack/…/internString)
加"返回 + 参数"注解,编译器二进制 **+558 条指令**(参数检查在实参类型未被证明时照付),
只留返回注解 + `f64lit(x: Number)` 是 −91(噪声)。原因:String 既没有裸 ABI、也没有
known-safe 证明,返回值拿到 `String` 静态类型也消不掉调用点的 Error 边。

**写法约定**:数值热路径的函数(算术、累加、索引运算)值得写参数+返回注解;字符串/对象
搬运型函数不值得(等 String 的裸表示/安全性做完再说)。

## 37. 字符串的成本模型(2026-10-27)

用户态 CPU,100 万次循环,基线是空循环 26 ns/次(`/tmp/lenbench.ql`、`/tmp/sA.ql` 等):

| 操作 | 每次 | 备注 |
|---|---:|---|
| 空循环 | 26 ns | 基线 |
| `s.length` | 38 ns | 净 +12 ns,很便宜 |
| 单值插值 `` `${i}` `` | **680 ns** | 走 `__interpolate` |
| `std.String.toString(i)` | **1,450 ns** | 插值 + **成员查找 + `__call_borrowed` 分发**(≈770 ns) |
| 拼一行(5 段 `+`) | **420 ns/行** | 20 万行 85 ms |

结论:拼接不是大头,**数字转文本**才是;而 `toString` 有一半价钱花在"成员调用"上(见 §32 的
动态调用形状)。编译器里有 131 个 `std.String.toString(...)` 调用点,128 个在 `line(...)` 拼装里,
按 188k 行/50 万次以上算,一次 stdlib 构建就是 0.7s 以上。

注意:`std.String.toString(x)` 与 `` `${x}` `` 语义完全等价(后者省掉成员分发),但**不要**用
"把源码里的调用改写成插值"来规避 —— 那是掩盖问题;根因是成员调用没有静态分派。


## 38. 确定性指标:walker 访问的 AST 节点数(2026-10-27)

本机墙钟与用户态 CPU 都能差 ±30%(§35),<5% 的改动量不出来。所以在 IR 头里加了一个
**确定性**计数器:

```
; astvisits: walkers=1418787
```

含义:编译这一份源码时,q langc 的五个通用 walker(`scanModuleFacts` / `reserveModuleBindings` /
`collectAssignedNames` / `functionBodyIsLeaf` / `collectBodyLetNames`)一共访问了多少个 AST 节点。
同一输入重复跑,数字完全相同;改动遍历后应看到它下降。

- 自举(编译 qlangc.ql,含 15 个 import 模块):**1,418,787**
- 小测试用例(t20):6,936 量级

分析侧(types.ql)也加了同样的计数器,但它在多模块程序上统计不稳(同一程序时而为 0),
所以**没有**打进报告行,只在 `typeVisitReport()` 里留着;要用的话先查清为什么。

## 39. 已排除:把 bundle import 挪进函数(2026-10-27)

原本设想:`library.ql` 静态 import 了 `stdlib/bundle.ql`(97KB),而 interface 模式下
`parseStandardLibrary()` 不被调用,把 import 挪进函数体就能省掉那 97KB 的解析。

**不成立。** 实测(`/tmp/lazy3.ql`):

```qlang
let f = () -> { import /tmp/lazymod/m.ql; 1; };
println(0);          // f 从未调用
```

产物里仍然有 `; ql-symbol helper ql_fn279` —— import 是**编译期静态解析**的,
"未调用不初始化"只影响运行期初始化。要真省掉,必须让 `stdlib/bundle.ql` 从编译器的 import
图里消失(例如生成纯文本 `stdlib/bundle.txt` + 独立 origins 表,需要时再读)。


## 40. 遍历成本分项;`reserveModuleBindings` 收窄未落地(2026-10-27)

`; astvisits` 现在带分项(自举一次,编译 qlangc.ql):

```
walkers=1423101  module=495300  slots=575005  names=300305  leaf=52491  bodylets=0
```

`slots`(`reserveModuleBindings`)最大:它对**每个语句列表**深度遍历整层表达式,只为找
`Let`/`Import`。理论上 `Let`/`Import` 是语句、只能出现在语句列表这一层(块内的声明归那个
Block 自己处理),所以试着收窄成"只扫语句层 + 下探 Let/Export 的值"。

结果:**访问数 −33%(slots 575,005 → 108,298)**,但**产物变了** —— 运行时帧多了 1 个槽
(后续槽位偏移 +64),169 个函数的 IR 变化,`typeRep` 计数也变(raw lit 574→578)。
原因没查清(推测旧版会额外登记某些名字,多出来的槽是"历史行为"),所以**按纪律回滚**,
只留下分项计数器。

顺带:第一版收窄太狠,漏了 `let imported = import ./modules/extrema.ql;`(import 作为
Let 的**值**),`t26_extrema` 直接抓红 —— 这类"看起来是语句、其实也能是表达式"的构造,
在收窄前必须先查测试用例里有没有反例。


## 41. `reserveModuleBindings` 收窄到语句层(2026-10-27,已落地)

`slots`(`reserveModuleBindings`)是最大的一笔遍历开销:它对**每个语句列表**都把整层
表达式深走一遍,只为找 `Let`/`Import`。而 `Let`/`Import` 是语句,只能出现在语句列表这一层
(块内的声明由那个 Block 自己的调用处理)。

改成:语句层只扫本层语句;`Let`/`Export` 的**值**仍按剪枝逻辑下探 —— 因为存在
`let imported = import ./modules/extrema.ql;` 这种"import 在值里"的形态(`t26_extrema` 抓到过)。

| `; astvisits`(自举) | 收窄前 | 收窄后 |
|---|---:|---:|
| 合计 | 1,423,101 | **859,210(−40%)** |
| slots | 575,005 | **8,707(−98.5%)** |

**两个教训**:

1. **不能拿"两份不同源码"的 IR 做相等比较**。第一版收窄时我加了缓存/新函数,产物自然不同
   (运行时帧多一个槽、偏移 +64、169 个函数变化);我把这当成"原因不明"回滚了一次。真正
   定位靠的是**登记名字轨迹**对照:多出来的三个名字正是新源码自己的 `kind`/`stmt`/
   `reserveBindingsInValue`。编译器编译自己时,"源码变了 ⇒ 产物变"是必然的。
2. 收窄前先扫测试用例反例:`let x = import "p";` 这类"语句位置看起来、其实是表达式"的构造。

验收:42 个测试用例里 41 个输出一致,`t37_extensions` 输出与改动前**逐字相同**(Android dlopen
环境缺口,非本次引入);selfhost / interpreter 全绿;自举固定点逐字节成立。


## 42. `std.process.run`(公开能力)+ QLang 链接器(2026-10-27)

**动机**:构建路径中间夹着 `aot/native_link.py`(Python)。它做三件事:拼 clang 命令、
跑静态字符串校验、把产物原子地替换上去。要把它换成 QLang,前提是 **QLang 能起子进程**。

### 机制(四道门都过了)

| 位置 | 变更 |
|---|---|
| `aot/runtime.c` | `ql_getpid()`、`ql_spawn(argbuf, nargs, out, err)`(fork/execvp/waitpid,stdout、stderr 落临时文件,避免 poll 管道)、`ql_unlink(path)` |
| `aot/qlangc.ql` | prelude 的 `declare`、叶子白名单、叶子签名表 |
| `aot/runtime.ql` | `__spawnRaw`(argv 以 NUL 分隔塞进缓冲)、`__procRun`(读回 stdout/stderr、清理临时文件)、`std.process = { run }` |
| 用户面 | **`std.process.run(args)` → `{status, stdout, stderr}`** |

**自举顺序(踩过)**:新叶子是"编译器自己的知识",所以不能直接用旧编译器编带新叶子的
runtime.ql。做法两步:①先用旧编译器 + **不含 process 的 runtime.ql** 产出 stage2c(它已认识
新叶子);②再用 stage2c 编完整 runtime.ql 得到 stage2d。

### QLang 链接器 `aot/link.ql`

`opt -O2`(IR 优化)→ `llc -O2 -filetype=obj`(代码生成)→ `ld.lld`(链接,模板来自
`aot/toolchain/aarch64-android24.cfg`,由 `clang -###` 抓取的一次性事实)。`clang` 只剩
"编译 runtime.c"一处,且结果按平台缓存在 `/tmp/.qlang-runtime-aarch64.o`。

| 度量(同一个 IR) | Python 路径 | QLang 路径 |
|---|---:|---:|
| 链接耗时(3 次最小) | 1.109s | **0.868s(−22%)** |
| 产物大小 | 711,080 | 711,008 |
| 行为 | `argc=2 / one / two` | 相同 |

段差异只有几十字节(`.text` +80、`.symtab` −96),是 lld 参数细节,不影响行为。

**还没做**:①把 runner 切到 `aot/link.ql`;②把 native_link.py 的**静态字符串校验**搬进
link.ql(现在 QLang 版还没校验);③runtime.o 按发行版预编译(现在首次构建用 clang 编一次);
④boot 解释器侧的 `std.process.run` 一致性(否则两引擎会分叉)。


## 43. `std.Bytes`(公开能力,2026-10-27)

ELF 校验需要**按字节**读文件,而 `std` 原来只有文本读(`readFileText` 还会做 UTF-8 校验,
二进制直接报 `invalid UTF-8`),`s[i]` 又是按字符(UTF-8 解码)而不是字节。

新增公开面 `std.Bytes`(Bytes 值就是按字节存放的字符串):

| 函数 | 说明 |
|---|---|
| `std.Bytes.read(path)` | 读文件全部字节;失败返回 Error |
| `std.Bytes.length(b)` | **字节**长度(读字符串头的声明长度,不是 `__s_len` 的 UTF-8 字符数) |
| `std.Bytes.byteAt(b, i)` | 0..255 |
| `std.Bytes.u32(b, i)` / `u64(b, i)` | 小端读 |
| `std.Bytes.hex(b, off, n)` | 小写十六进制串,一次分配(逐字节写缓冲) |

**踩到的两个坑**:

1. QLang 的 `/` 是浮点除法。十六进制取高半字节写成 `v / 16` 得到 7.9375,截断成 '7' 之后
   低半字节算成 0 ⇒ 0x7f 输出 "70"。必须 `let low = v % 16; let high = (v - low) / 16;`。
2. 字节长度不能复用 `__s_len`(它按 UTF-8 字符计数,对二进制是错的);字符串头 +16 才是
   声明长度。一个 711,008 字节的 ELF 用 `__s_len` 会量出 462,045。

验收:读 `/tmp/q_out`(711,008 字节的 ELF)得到 length=711008、byteAt(0)=127、
hex(0,4)="7f454c46"、u32(0)=1179403647(与 `readelf -h` 的 Magic 一致);
selfhost 全绿;自举固定点逐字节成立。


## 44. QLang 版 ELF 静态字符串校验(2026-10-27)

`aot/verify.ql`:`verify <elf> <ir> [<extra-ir> ...]`,纯 QLang,不依赖 `readelf`/Python。
它和 `native_link.py` 的 `validate` 同口径:每个 `.strbox<N>` 必须在 ELF 里有符号、header 是
`{tag=2, 长度}`、buffer 指针由 `R_AARCH64_RELATIVE` 的 addend 给出、buffer 字节等于 IR 里的
`c"..."` 字面量。

验收(813 个字符串):

| 用例 | 结果 |
|---|---|
| 好产物 | `verify: 813 static strings ok`,退出 0 |
| 篡改 buffer 里一个字节 | 退出 1,`linked bytes do not match IR` |
| 篡改盒子的长度字段 | 退出 1,`string size does not match IR` |

**踩到的四个坑**(都是"EFL/ELF 细节",值得记):

1. `e_shentsize`/`e_shnum`/`e_phentsize`/`e_phnum` 是 **2 字节**字段;用 `u64` 读会把相邻字段
   吞进来 —— `shnum` 变成 25,771,311,129,循环无界分配直接 `OutOfMemory`。用 `u32 % 65536`。
2. `.strbox` 是 **7** 个字符;从索引 8 取数字会把 `".strbox1000000"` 解析成 `"000000"` = 0,
   于是查到对象里的 `.strbox0`,报出莫名其妙的长度不符。
3. IR 的 `c"\61\72..."` 是十六进制转义:逐字节 `toString` 得到十进制;而整段 `hex` 再去掉
   `5c` 会误伤数据里真的是 0x5c 的字节。正解:用 `std.Bytes.slice` 取字面量区文本,再
   `replace("\\")("")`。
4. 大小写:IR 字面量保留原样(`3D`),`std.Bytes.hex` 输出小写(`3d`)——先统一小写。


## 45. QLang 工具链接管构建路径(2026-10-27)

链路:`stage2 --emit-llvm-split` → **`target/tools/link`(QLang)** → `opt` → `llc` → `ld.lld`
→ **`target/tools/verify`(QLang)** → 发布。构建路径上不再有 `python3 aot/native_link.py`。

| 环节 | 现状 |
|---|---|
| 链接器 | `aot/link.ql`,QLang 驱动 opt/llc/ld.lld;clang 只用于一次性编译 runtime.c(缓存) |
| 校验器 | `aot/verify.ql`,纯 QLang 解析 ELF;失败则不发布(保留旧产物) |
| 工具构建 | `aot/toolchain_build.py`(Python,**只做引导**:用当前编译器 + native_link.py 产出 `target/tools/*`) |
| 测试 | `run_selfhost_tests.py` 在标准库对象存在时优先用 `target/tools/link` |

| 度量 | Python 链接 | QLang 链接 + 校验 |
|---|---:|---:|
| 单次链接(小 IR) | ~1.1s | ~2.4s |
| **selfhost 测试全套(40+ 测试用例,--jobs 3)** | 212–616s(随机器负载) | **295s** |

**代价与取舍**:校验器每次链接要重新解析 ELF(符号表 + 重定位,约 0.5s)+ 逐条比对,
所以单次构建从 ~1.0s 变成 ~2.4s。但**它把 Python 从构建路径里彻底移除**,而且测试总耗时仍
在合理区间(295s)。如果以后要恢复单次速度,方向是:校验按需(CI 默认开、本地 `--no-verify`),
或者把符号/重定位解析做成 C 叶子。

踩到的坑:校验器最初读对象的 `stdlib.ll`(7.3MB)来取期望值 —— 每次链接多花十几秒
(测试 1245s)。现在对象构建时顺手写一份 `strings.tsv`(`.strboxN<TAB>hex`),校验器读它,
测试回到 295s。

### 45.1 让所有 runner 都走 QLang 链接器(2026-10-27)

`native_link.link()` 现在**委托**给 `target/tools/link`:只要标准库对象存在、`opt==2`、
并且 IR 带 `; split-stdlib` 标记,就用 QLang 链路;否则回落到 Python(单模块 IR 需要
`split_file`,那是 Python 侧的职责)。

踩到的坑:第一版没有检查 split 标记,gc 测试套件用的是**单模块 IR**(自带 runtime),再叠
`runtime.o` 就 `duplicate symbol: __panic_exit / __cold_located_error / .strbox7`。
加上标记检查后 gc/array/object 全绿(各 ~20s)。

自此:构建路径 = `emit → target/tools/link(QLang → opt/llc/ld.lld)→ target/tools/verify(QLang)`;
Python 只剩 ①工具引导 ②单模块/扩展等回落路径 ③`--check-only` 参照实现。


## 46. 工具链去 Python:写文件 + QLang 构建驱动(2026-10-27)

**`std.fs.writeText(path, text)`**(机制叶子 `ql_write_file`):构建驱动必须把编译器输出(IR)
落盘,而 `std.fs` 原来只有读。

**`aot/build.ql`**:一条命令完成 `emit --emit-llvm-split`(捕获 stdout)→ 写临时 IR →
`target/tools/link`(opt/llc/ld.lld + 校验)→ 发布。全程 QLang,不调用 Python:

```
target/tools/build aot/tests/t20_native_bridge.ql -o /tmp/t20_ql \
  --compiler /tmp/stage2_w2 --stdlib-object <obj> --symbols <tsv> \
  --interface <txt> --stdlib-strings <tsv>
```

实测:t20 构建 exit 0,输出与 `.expected` 一致。

自举顺序(老规矩):新叶子 `ql_write_file` 先让编译器认识 —— 先用旧编译器 + **不含写文件
的 runtime** 产出认识新叶子的编译器,再用它编完整 runtime。

剩下唯一还在工具链里的 Python:`aot/stdlib_split.py`(标准库对象构建/缓存/拆分/接口)。
下一步把它也用 QLang 重写,并提供 `target/tools/stdlib` 供 `build` 自动取对象。


## 47. 标准库对象构建也用 QLang(2026-10-27)

`aot/stdlib_build.ql` 取代 `stdlib_split.py` 的 `build_stdlib`:缓存键、IR 切分、符号表、
strings 表、分析接口、目标文件,全部 QLang(shell 只用 `sha256sum`/`mkdir`/`llc`)。

**验收方式**:用**同一个编译器**分别跑 Python 版和 QLang 版,逐个产物 `cmp`:

| 产物 | 结果 |
|---|---|
| `stdlib.ll` | **逐字节相同** |
| `symbols.tsv` | **逐字节相同** |
| `strings.tsv` | **逐字节相同** |
| `interface.txt` | **逐字节相同** |
| `stdlib.o` | 大小不同(QLang 用 `llc -O2`、Python 用 `clang -O2 -c`,多出的只是 `.comment` 等元数据);用它构建的 t20 输出与 `.expected` 一致 |

对齐过程中修掉的五个差异(都是"文本细节"):

1. `define hidden ` + 原文会把 `define` 叠两遍;而且**冷助手**(`@__panic_exit`/`@__cold_located_error`/
   `@__stdlib_init`)没有 `internal`,不能改成 `hidden`(改了用户模块就链接不上);
2. preamble 与 ABI 声明之间多一个空行;
3. `strings.tsv` 的名字多了 `@` 前缀;
4. `symbols.tsv` 要按**字节序**排序(QLang 的字符串 `<` 顺序和 Python `sorted()` 不同);
5. 同名符号以**最后**一次为准(Python 是 dict 覆盖)。


## 48. 工具链去 Python:验收(2026-10-27)

工具链四个工具全部是 QLang:`target/tools/{stdlib,build,link,verify}`(由
`aot/{stdlib_build,build,link,verify}.ql` 编译而来;`aot/toolchain_build.py` 只负责**引导**
编译它们,之后不再参与)。

**没有 Python 参与的验收**(编译器 `/tmp/stage2_w2`,对象由 QLang 版构建器产出):

| 动作 | 命令 | 结果 |
|---|---|---|
| 标准库对象构建 | `target/tools/stdlib --compiler … --cache-root …` | 67s,四个产物与 Python 版**逐字节相同** |
| t20 构建 | `target/tools/build aot/tests/t20_native_bridge.ql -o …` | 输出与 `.expected` 一致 |
| **重建编译器** | `target/tools/build aot/qlangc.ql -o /tmp/stage2_pure …` | **3m53s**,产物可用(能正常发 IR) |
| selfhost 测试(用 QLang 对象) | `run_selfhost_tests.py --jobs 3` | **206s 全绿** |
| interpreter 测试(用 QLang 对象) | `run_interpreter_tests.py --jobs 3` | 全绿(该轮机器很吵:1698s) |
| 自举固定点 | stage2 → tools/link → stage3 | **IR 逐字节相同** |

**仍然用 Python 的地方**(都是"引导/回落",不是工具链路径):`toolchain_build.py` 首次构建
工具;`native_link.py` 处理单模块 IR 与扩展、以及 `--check-only` 参照校验;测试驱动本身。


## 49. 引导不再需要 Python;单模块回落基本消失(2026-10-28)

**引导**:`aot/bootstrap.sh` 用 `clang` 直接链接工具的 IR(和原先 Python 版做的事一样),
不经过 Python。工具存在之后 `aot/bootstrap.sh --self` 用 **`target/tools/link`** 重建四个工具
(verify/link/build/stdlib),即工具链自举。`run_selfhost_tests.py` 现在调这个脚本,不再
调用 Python 的 `toolchain_build.py`(已删除)。

**单模块回落**:`run_gc_tests.py` 原来自己用 `--emit-llvm`(单模块 IR),所以只能走 Python 的
`split_file`。现在有标准库对象时它发 `--emit-llvm-split`,于是 -O2 那条走 QLang 链接器
(9s,-O0 仍走 Python,因为委托目前只接管 -O2)。

**踩到的坑(值得记)**:`link.ql` 选模板时取的是 cfg 里**最后一条**非注释行。我给扩展加的
"共享库模板"是第二条,于是所有链接都用了 10 个 token 的共享库模板 —— 产物里对象根本没链进去
(`nm | grep -c strbox` 从 838 掉到 26),校验器报 `missing ELF symbol`。删掉第二条模板后恢复。
教训:配置文件的"多条模板"必须有显式选择规则,不能依赖"最后一条"。

**仍走 Python 的两处**:扩展(`--shared`,QLang 链接器尚未支持;本机本来也因 Android
dlopen 限制不可裁决)、以及非 -O2 的委托(可后续按需扩展)。`--check-only` 参照实现保留在
`native_link.py`(测试侧对照用)。


## 50. native 扩展:构建已全 QLang,运行受 Android 限制(2026-10-28)

**native 扩展是什么**:用 `--emit-module` 把一份 QLang 源码编成独立 `.so`(没有 `@main`、
不带自己的 runtime),宿主在运行期用 `import (路径)` 动态加载:`dlopen` → 校验
`qlang_extension_abi_v1` 字符串 → 调 `qlang_extension_init_v1` 把导出装进当前程序。
它是"预编译模块/插件"的机制。

**构建**:`link.ql --shared`(PIC + 共享库模板,不链 runtime.o)已实现并验证:

```
target/tools/link plugin.ll -o plugin-O2.so --shared      # 17,800 字节
nm -D plugin-O2.so | grep qlang_extension
  0000000000000760 R qlang_extension_abi_v1
  0000000000011f10 T qlang_extension_init_v1
```

扩展测试套件的**构建段全过**:`PASS compiled hosts before extensions existed`、
`PASS independent extension: plugin / second / failure / cycle`(含故意坏 ABI、缺入口的变体)。

**运行**:在本机必然失败 —— Android linker namespace 不允许 `dlopen` `/tmp/*.so`
(`library ".../plugin-O0.so" ... is not accessible for the namespace`)。这是环境限制,
与构建无关;测试套件里那 6 条 FAIL 全是 dlopen 失败导致的。

**配置文件的教训(第二次)**:模板选择必须显式。现在 cfg 用 `exe ` / `shared ` 前缀区分,
`link.ql` 按前缀取,不再依赖"最后一条非注释行"——上一版就是因为多了一条共享库模板,
所有链接都用了它,产物里对象根本没链进去(probes §49)。

**symbols.json**:Python 侧的 `split_file` 回落路径需要它;QLang 构建器现在也生成
(567 函数 / 1,625 全局,键是**不带 @** 的名字 —— 和 Python 的 `GLOBAL` 正则一致)。


## 51. 校验提速:解析搬进 runtime(方案 B,2026-10-28)

**问题**:`verify.ql` 逐字段调用 `std.Bytes.u64/byteAt`,每次约 **2.9 微秒**(成员访问 → 通用分发
→ tag/边界检查 → 逐字节叶子调用 → 装箱)。13,000 次字段读取 ≈ 0.4 秒,整次校验 0.62 秒;
Python 的 `struct.unpack` 同一件事只要 0.5 毫秒。

**做法**:把 ELF 解析与逐条比对写成 **runtime.ql 里的函数** `__verify_elf_strings`,
通过 `std.Bytes.verifyStrings(elf, strings, ir)` 只做**一次**跨边界调用。runtime 内部的调用是
直接调用,不再走成员分派。`verify.ql` 从 266 行缩到 15 行(只剩参数解析和打印)。

| 度量 | 之前(逐字段 QLang) | 现在(runtime 内一次跑完) |
|---|---:|---:|
| 校验(841 条,含用户 IR) | 0.62s | **0.088s(7×)** |
| 链接里校验的增量 | +0.60s | **+0.07s** |

**同等重要的修正**:对象旁的 `strings.tsv` 只覆盖**库侧**字符串;第一版只读它,等于不检查用户
模块的字符串(旧的 `verify.ql` 会读 IR)。现在 `verify` 额外接收 IR 路径,把 `@.str`/`@.strbox`
也解析进来一起核对 —— 841 条 = 828(库)+ 13(用户)。

**验收**:好产物 `841 static strings ok` 退出 0;把用户字符串 `.strbox1000001` 的长度字段改成 999
→ 退出 1,`size does not match`。

**坑**:ELF 前 8 字节是 `7f 45 4c 46 02 01 01 00`(含 class/data/version),`readU64` 读 8 字节得到
28,258,425,767,667 —— 判 magic 要取低 32 位(`% 4294967296`),或者干脆只比前 4 字节。

## 52. 静态派发的事实层:先统计(2026-10-28)

**规则**(充分条件,不是必要条件;全成立才允许走静态,否则回落 `__call`):
调用点的被调者是(1)本程序不可变绑定、值是函数字面量,或(2)「已知对象字面量绑定」的字段、
字段值是函数字面量且该绑定未被赋值/未逃逸/该字段未写过;并且实参个数等于形参个数。
绑定是函数值时「被当值用」不破坏证明(同一个函数值),对象绑定逃逸才破坏(别人可能写它的字段)。

**实现**:`aot/known_values.ql`,开关 `--static-scan`(默认关)。两遍遍历:第一遍收绑定形状、
写入、逃逸;第二遍给每个调用点定性。本切片只统计,不改发射。

**A/B**:同一测试用例开关两版 IR 逐字节相同(只多一行 `; staticcall:`);扫描开销 10.48s → 10.62s(+1.4%);
stage2/stage3 固定点成立。

**命中数**(HEAD 的 stage2 就是旧源产物,先按「旧编译器 + 去掉新叶子的临时 runtime」两段式重建):

| 程序 | 调用点 | 可静态(绑定) | 可静态(对象字段) | 拒绝 |
|---|---|---|---|---|
| 测试用例 t28_objects | 129 | 13 | 0 | chain=49 shape=67 |
| 测试用例 t49_raw_object_index | 32 | 15 | 0 | chain=6 shape=8 notfn=3 |
| 测试用例 t16_functions | 31 | 11 | 0 | shape=17 notfn=2 partial=1 |
| stdlib 库自身 | 393 | **285** | 0 | shape=48 chain=35 notobj=12 notfn=10 escaped=3 |

**结论**:库里 285/393(73%)的调用点是「同程序不可变函数绑定」,而今天的直调只对**用户程序**开着
(`qlangc.ql:3248` 的 `allowDirectUserCalls` 只在用户程序发射期间为真)—— 库内直调今天一个都没有。
用户侧的收益主要不在对象字面量(测试用例里 field=0),而在 `std.X.Y` 链(chain)和绑定直调。

**坑/注意**:`knownScan` 对空 statements 直接返回(对象化模式下库程序是空壳,否则会打印
`sites=0` 的假条目);计数按 label 累加,跨程序保留,绑定表每个程序开头清空。

## 53. 数组类型族与 boot 的多参数调用(2026-10-28)

**类型面**:`Array` 不再是构造器,只留一个空占位名(可当命名空间);数组类型按"元素 × 长度"
排列成四个独立名字,外加元组:

| | 长度任意 | 长度恰好 n |
|---|---|---|
| 元素任意 | `AnyArray` | `SizedArray(n)` |
| 元素都是 T | `TypedArray(T)` | `TypedSizedArray(n, T)` |

`Tuple([T1, T2, ...])`:每个位置一个类型。旧的 `Array(3)`/`Array(T)`/`Array([...])`/
`Array({length, element})` 全部删除(最后一种和 `TypedSizedArray` 重合)。元素参数接受类型值
或普通描述符对象(与 `Object({...})` 一致,`Shape` 因此不用改)。

**boot 的多参数调用**:原实现把「宿主 QLang 函数」(stdlib.ql 里的类型库/构造器)当 1 参桥接,
`args.length != 1` 直接 ArityMismatch —— 于是 `TypedSizedArray(3, Number)` 在 boot 里根本调不了
(用新加的 2 参全局 `ZZTest` 复现)。改成只拒绝 0 参,其余交给宿主派发器(`std.__callNative`)处理
arity/部分应用;这与 "hosting runtime 的派发器拥有 arity 与 Error 策略" 的既有约定一致。

**验收**:`demo/type_gymnastics.ql` 在两个引擎都是 **419/419**(迁移约 20 处类型拼写);
`stage2/stage3` IR 固定点成立;selfhost 测试套件 ALL PASS。`TypedArray(Number)` /
`SizedArray(3)` / `TypedSizedArray(3, Number)` / `Tuple([Number, String])` 的正反例在两引擎一致。

**顺带发现(先于本切片,未修)**:`run_interpreter_tests.py` 在 HEAD 上因链接重复符号失败
(`__panic_exit`/`__cold_located_error`/`.strboxN` 同时出现在用户模块与 `stdlib.o`)——
对象化(split)模式下冷助手与字符串没有被抑制在库侧。与本次类型改动无关,单列一条待办。

## 54. 库内直调:285 个机会,现有机制只吃下 20 个(2026-10-28)

**命中数**:给 `--static-scan` 加「定义序号 < 调用点序号」后,库内 285 个绑定调用点
**全部**满足「定义先于调用」(标准库是自底向上写的,没有前向调用),所以 285 是真实上限,
不是被发射顺序折掉的数。

**但打开库内直调后**(库语句发射前重建候选表 + `allowDirectUserCalls`),
现有机制只接受:`direct=17 inline=1 rawcalls=2 rawfuncs=1` —— 因为它的判据比扫描强
(要求绑定从未被当值用、元数/注解满足 raw ABI 等)。

| 指标 | 之前 | 之后 |
|---|---|---|
| 库对象 IR 字节 | 7,964,680 | 7,934,189 |
| `clang -O2` 后 AArch64 指令 | 131,889 | **131,084(−805,−0.6%)** |

验收:stage2/stage3 固定点成立;demo/type_gymnastics 419/419;selfhost 测试套件 ALL PASS。

**剩下 ~265 个点需要新的发射形态**:已知绑定 ⇒ 直接调它的**装箱入口**(省掉 `__call` 的
元数与部分应用分派、闭包解盒),而不是复用 raw/inline 候选那套判据。这是下一片。

## 55. 库内装箱直调:28 个点,卡在「实参不可能为 Error」(2026-10-28)

把直调目标的注册条件从「leaf + 无形参注解」放宽成**「无形参注解」**(leaf 是 raw ABI 的判据,
装箱直调不需要),库对象的直调点 20 → **28**;`__call` 的分派检查由静态条件替代:元数精确、
形参无注解(分派器那步检查本来就不存在)、实参已证不可能为 Error。

| 指标 | 基线 | 片 1(库内直调) | 片 2(放宽注册) |
|---|---|---|---|
| 库对象 `clang -O2` 指令 | 131,889 | 131,084 | **130,792(−1,097,−0.83%)** |

**上限在哪**:放宽后 `directreject` 是 `noinfo=50 args=478 notable=20` —— 绝大多数调用点卡在
`callArgsCannotBeError`(实参可能是 Error 值)。这条规则不能跳:QLang 里「Error 作为实参」必须
在调用点变成 TypeMismatch,直调会把它原样传进去。所以继续提高只能靠把「实参不可能为 Error」
的事实真正算到库代码上(对库程序打开 safe-call 分析实测**没有任何变化**,说明事实没产生),
或者改成直调 + 显式检查(省下的就只剩参数数组与分派开销)。

**语义注意**:直调绕过 `__call` 的递归深度守卫(与既有 raw/direct 路径一致);形参注解检查因为
目标无注解而不存在;元数与 Error 实参由静态条件保证。

验收:stage2/stage3 固定点成立;demo/type_gymnastics 419/419;selfhost 测试套件 ALL PASS。

## 56. interpreter 测试套件的「重复定义」是接线 bug,不是代码生成问题(2026-10-28)

§53 记录的红:链接 `interpreter.ll` 时报 `duplicate symbol: __panic_exit / __cold_located_error /
.strbox7`。根因不在发射器:**`run_interpreter_tests._use_stdlib_object` 只导出了
`QLANG_STDLIB_OBJECT`,没导出 `QLANG_STDLIB_SYMBOLS` / `QLANG_STDLIB_INTERFACE`**,
于是 `emit()` 退回 `--emit-llvm`(单模块、含整个 runtime+库),再和 `stdlib.o` 一起链接 ——
两边的符号当然重复。`run_selfhost_tests` 的同名函数导出三个变量,所以测试用例一直是绿的。

修法:补齐三个环境变量(和 selfhost 驱动一致),发射器走 `--emit-llvm-split`。

**验收**:`run_interpreter_tests.py --compiler <新编译器> --jobs 2` → **ALL CHECKS PASS**
(含 419 条类型断言的 type_gymnastics、argument 测试套件、解释器测试用例)。

教训:对象化(split)模式有两个前提 —— 链接给对象,**编译也要给接口**;只给一半,症状会伪装成
「代码生成发出了重复符号」。

## 57. `std.<模块>.<成员>` 链直调(2026-10-28)

**做法**:分析期把「模块 → 成员 → 源绑定名」收下来(库的导出表在包的包装函数
`let __build_standard_library = (std) -> { ...; {String: StringLibrary, Math: MathLibrary, ...}; }`
的尾值里,必须递归进函数体才看得到);发射期把它和「源绑定名 → 符号/元数」拼成目标表,
`std.M.f(...)` 命中就用库函数的装箱入口直调 —— 签名正好是 `(ptr env, ptr args, i64 n, %ql_value ann)`,
与对象化模式 `declare %ql_value @ql_fnN(ptr, ptr, i64, %ql_value)` 一致。

**门槛**(全成立才发):链根必须是模块级 `std`(没被遮蔽)、该路径没被cfg写、实参个数等于元数、
实参已证不可能为 Error。计数器 `; stdchain: hits= nokey= arity= args= written=`。

**命中数**:`std.Math.sqrt` / `std.Math.pow` 这类「成员是标识符绑定」的命中;
`std.Object.keys`、`std.String.length` 这类**成员是内联 lambda** 的仍是 `nokey`(它们没有名字,
也就没有可调的符号 —— 这是下一片:让对象构建时给匿名函数也发符号)。

| 指标 | 之前 | 之后 |
|---|---|---|
| `t41_math_library` 机器指令 | 138,002 | **136,925(−1,077,−0.78%)** |

验收:demo/type_gymnastics 419/419;stage2/stage3 固定点成立;selfhost 测试套件 ALL PASS;
interpreter 测试套件 ALL CHECKS PASS。

## 58. 内联 lambda 成员也有符号了,但链的下一道墙是「实参证明」(2026-10-28)

`std.String.length` 这类成员是**内联 lambda**(不是标识符绑定),之前没有名字也就没有可调符号。
现在发射期递归收「模块对象绑定名 -> 成员 -> ql_fnN/元数」,以及导出表「模块名 -> 对象绑定名」,
链目标表把这类成员也登记上。

| 测试用例 | 之前(v16,仅标识符成员) | 之后(v17) |
|---|---|---|
| t30_strings | 155,483 | **155,363(−120)** |
| t41_math_library | 136,925 | 136,925(该测试用例的 sqrt/pow 本来就命中) |

**为什么只有 −120**:t30 的计数是 `hits=8 nokey=1 args=62` —— 71 个链调用点里 62 个被
「实参可能是 Error」挡住,只有 8 个拿到直调。也就是说链的收益已经撞上同一堵墙:
roadmap 的「库调用图的 known-safe 证明」(handoff 待办 M)。

还剩下的 `nokey`:`std.Object.keys` / `std.JSON.*` 的模块对象是**工厂调用产物**
(`ObjectLibrary = makeObjectAlgorithms(...)`),不是字面量,静态收不到成员表 —— 要么内联工厂,
要么让工厂自己登记(不在这一片)。

验收:demo 419/419;固定点成立;selfhost ALL PASS;interpreter ALL CHECKS PASS。

## 59. std 注解(Number 参数/返回)试过:几乎是平的,不加(2026-10-28)

给 `stdlib/math.ql` 与 `stdlib/number.ql` 的 Number 出入参补上注解(`absolute`/`truncate`/
`finiteNumber`/`roundValue`/`squareRoot`/`parseDecimal` 等 13 个),重建 bundle 后测:

| 指标 | 之前 | 之后 |
|---|---|---|
| 库对象 `directreject` | `noinfo=50 args=478` | `noinfo=96 args=450` |
| 库对象直调点 | 28 | **18** |
| 裸返回候选 | 18 | 60 |
| t41 / t30 / t43 机器指令 | 136,925 / 155,363 / 139,623 | 136,920 / 155,358 / 139,618(−5) |

三个测试用例各 −5 条,等于没有。原因也很清楚:**装箱直调要求「形参没有注解」**(分派器负责的检查
不能跳),所以补注解把 46 个目标从「可直调」推到 `noinfo`,换来的只是裸返回候选;
而裸返回这条路径今天没接上收益。

结论:按「无收益不背复杂度」,这批注解没有保留。F 项的真正价值要等
「补注解 ⇒ 实参证明铺开 ⇒ 直调/裸返回接上」这条链打通;单独补注解是平的。

`?` 传播那条也测过(`typeProneOf` 把 `UnaryOp "?"` 当可能出错),语义上该改,但对
`args` 计数没有任何影响,同样没保留(见 §58 之后的讨论)。

## 60. 带注解的函数也能直调(只要实参类型证明了那次检查)(2026-10-28)

原来的规则是「形参没有注解才能装箱直调」——因为绕过 `__call` 就跳过了参数检查。这条规则让
注解和直调互斥:§59 里补注解反而把目标推出可直调集合(`noinfo` 50→96,直调 28→18)。

新规则:仍然允许直调,但**每个带注解的形参**要求实参的静态类型恰好是那个内建类型
(分派器那次检查必然通过),否则回落 `__call`。注解不是内建名字、或实参是 `&&`/`||`
(静态类型被盖成 Boolean 但实际返回操作数,AGENTS §7.1)时一律回落。

| 指标 | 之前 | 之后 |
|---|---|---|
| 库对象直调点 | 28 | **38** |
| 库对象 `noinfo` | 50 | 18 |
| 库对象机器指令 | 130,792 | **130,648(−144)** |
| t41 / t30 机器指令 | 136,925 / 155,363 | 136,781 / 155,219(各 −144) |

计数器新增 `ann=<n>`(因注解不匹配而回落)。验收:demo 419/419;固定点成立;
selfhost ALL PASS;interpreter ALL CHECKS PASS。

注:`typeBuiltins` 现在从 `types.ql` 导出(qlangc 需要判断注解是不是内建类型名)。

## 61. 成员闭包缓存:一次 load 代替两次哈希查找(2026-10-28)

`std.M.f(...)` 的调用点原来每次要 `__get_field(std,"M")`、`__get_field(mod,"f")` 两次哈希查找。
现在在模块初始化时**每个用到的路径只查一次**,把闭包存进隐藏槽(`$stdcacheN`),调用点一次 load:

- 有直接目标且实参可证 ⇒ 直调(省两次查找 + `__call`);
- 没有目标或实参不可证 ⇒ 仍走 `__call`,但省掉两次查找。

前提:程序里没写过 `std` 的成员(`stdWriteScan`);导入模块有独立帧,看不到这些槽,所以只有主模块用。

| 指标 | 直调(§60) | 加缓存 |
|---|---|---|
| t41_math_library | 136,781 | **136,393(−388)** |
| t30_strings | 155,219 | **151,256(−3,963,−2.55%)** |
| t28_objects | 148,362 | **146,026(−2,336,−1.57%)** |

**运行时**(1M 次 `std.Math.abs`,用户态中位数):

| 构建 | 时间 |
|---|---|
| HEAD(无直调) | ~1.90s |
| 只做直调(§60) | ~0.69s |
| 直调 + 闭包缓存 | **~0.31s(比 HEAD 快 6×)** |

验收:demo 419/419;stage2/stage3 固定点成立;selfhost ALL PASS;interpreter ALL CHECKS PASS。
计数器 `; stdchain: hits= cached= nokey= arity= args= written=`,`cached` = 走缓存的调用点数。

## 62. 调用点 Error 守卫:直调点从 38 涨到 278,但代码 +3.4%(回滚)(2026-10-28)

想法:实参不可证「不可能是 Error」时不再回落 `__call`,而是在调用点内联 tag 检查,
任一实参是 Error 就走慢路径(慢路径**就是** `__call`,消息与行为完全一致),否则直调。

结果(库对象):

| 指标 | 之前 | 之后 |
|---|---|---|
| 直调点 | 38 | **278**(guarded=312) |
| `args` 拒绝 | 490 | 0 |
| 库对象机器指令 | 130,648 | **135,091(+4,443,+3.4%)** |
| t41 / t30 / t28 | 136,393 / 151,256 / 146,026 | 141,197 / 156,863 / 151,301(各 +4,800 左右) |

**为什么变差**:每个被守卫的点都自带一份慢路径(`__call` 的实参数组 + 分派),而慢路径本来就
在程序里;守卫只是把它复制到每个调用点。慢路径几乎不执行,却要按点付代码体积。

**正确的做法**(下一步,如果还要做):慢路径放进**一个共享的冷助手**
(`@__cold_guarded_call(fn, argsBox)` → `__call_borrowed`),并且实参数组只构造一次
(快路径传元素指针,慢路径传 box 指针)。那样每点只多一条分支 + 一次调用,体积增量应该
在几百条以内而不是 4,800。回滚,不做半成品。

**补充(同一天,链路径 + 快速入口都加上守卫之后)**:体积进一步恶化 —— 库对象
130,869→**137,048(+6,179)**,t30 **+10,171**,t28 **+8,480**。原因是快速寄存器入口的守卫
必须在**冷分支里**构造实参数组(寄存器入口没有可共享的数组形态),而那是每个调用点一份。
结论:在“指令数”这个验收口径下,守卫式直调不划算,链路径与快速入口都不加;这一片到此为止。

## 63. 架构修正:检查从「调用点」下沉到「共享入口」(2026-10-28)

§62 的教训是:调用点补检查 = 按点复制分派器,体积 +3.4%~+5%。根因在调用约定:**一套通用
分派器承担了所有检查**,而编译器只能在调用点特化 —— 特化就得复制那份共享代码。

修法不是“不检查”,而是**把检查放到一个共享入口**:

```
@__direct_checked(fn, box)   // Error 实参 + 形参注解 + 递归深度,然后 __invoke
```

- 实参可证的直调点:仍然直接调函数体(什么都不查);
- 实参不可证的直调点:调 `__direct_checked`(一次调用,代码全程序共享一份);
- 被调者不是普通用户函数:入口自己退回 `__call_borrowed`,行为不变。

这样直调点不再自带分支/回落/数组复制,体积反而下降;而且**递归深度守卫回到直调路径**
(之前直调绕过它,是个正确性缺口)。

| 指标 | 之前(只有可证实参能直调) | 之后 |
|---|---|---|
| 库对象 | 130,975 | **130,495(−480)** |
| t41 / t30 / t28 | 136,720 / 151,583 / 146,353 | **136,208 / 150,869 / 145,779** |
| 不可证实参的链调用 1M 次 | ~0.23s | ~0.21s |

验收:demo 419/419;Error 实参语义逐字节一致(`f(e)` / `std.String.length(e)` → TypeMismatch);
固定点成立;selfhost ALL PASS;interpreter ALL CHECKS PASS。

**架构结论**:体积爆炸的根因不是“检查本身”,而是“检查写在了会被复制的位置”。凡是每个调用点
都要干的事,必须是共享的一份代码;调用点只该留“调用哪份代码”这一个选择。

**同日的收尾测量**:寄存器入口 `_f` 的适用范围(原来只对「无注解且 ≤3 参数」的函数生成)
试过放开 ≤3 限制:库对象 130,495 → 130,519(+24),等于没有。也就是说,能吃到寄存器入口
（免构造实参数组）的点已经吃到了,剩下的点收益不大于每个函数多出来的包装函数。
直调优化到此收尾。

## 64. 数组读为什么这么慢:快路径的 tag 取错了(已修,4.8–11.7×)(2026-10-28)

形状:lexer 的循环 `while i < n { if chars[i] == " " { total = total + 1; }; i = i + 1; }`。
实测(`aot/bench/b_chars`,runtime.ql 切成 91,352 个字符):空转 **3.4ns/次**,加一次
`chars[i]` 读取 **~74ns/次**,真实 bench ~83ns/字符。

已确认:
- 内联快路径**确实被发射**(`index-fast` 计数 +1,IR 里是 tag/整数/界检查 + 直接 load);
- 但**运行时几乎总走慢路径**:把慢路径的返回值换成 null 常量后 b_chars 输出 **0**
  (正常 10,487,500);把守卫 `br i1 canRead` 强制成 true 后输出**正确**且明显更快。
  两者合起来说明:快路径本身正确,**守卫在运行期判假**。

守卫的三个合取项(IR):包 tag==5、下标是整数(fptosi/sitofp/fcmp)、`0 <= at < len`。
**根因(已修)**:守卫比较错了 tag。`%ql_value` 是 `{内层 tag, payload}`,指针值的**内层 tag 是 0**;
而语言 tag(array=5) 要通过 `ql_word` / `readU64(v,0)` 读**对象头**。快路径写的是

    %tag = extractvalue %ql_value %v, 0      ; 恒为 0(指针值)
    %isArray = icmp eq i64 %tag, 5           ; 恒假 ⇒ 永远走慢路径

于是「index-fast」这条内联优化从落地起就是**死代码**,所有数组读都在付 `__get_index`
的完整 QLang 调用代价。

修法:语言 tag 用 `@ql_word(%ql_value v, 0)`,长度用 `@ql_word(%ql_value v, 16)`
(与 runtime 的 `readU64(c,0)/readU64(c,16)` 同一口径,对非数组值也安全;快分支仍然先判
tag==5 才解引用 `payload+8` 取数据指针)。

| 指标 | 修复前 | 修复后 |
|---|---|---|
| `b_chars`(~83ns/字符) | 5.36s | **1.11s(4.8×)** |
| `b_index` | 5.53s | **1.09s(5.1×)** |
| 单次 `chars[i]` 循环(18.3M 次) | 1.83s | **0.156s(11.7×)** |

验收:输出逐字节相同;demo 419/419;固定点成立;selfhost 与 interpreter 测试套件全过。

**教训**:优化「已落地」不等于「已生效」。这条快路径有 32 个发射点、计数器也在涨,
但守卫恒假,运行期一次都没走到 —— 只有把「命中数」和「运行期真的走了哪条路」分开量,
才能发现这类死代码。

顺带测过的一个方向:把读检查从「深度 0」放宽到「同一函数内且非 optional」时跳过
(1.81s→1.70s,约 −6%),不是主因;因为要连带改语义口径,未保留,先记在这里。

## 65. 字符串相等少一层调用(`==` 的 String 快路径)(2026-10-29)

`chars[i] == " "` 那种比较发射成 `__op_eq(a, b)` → `__str_eq(a, b)`,**两层 QLang 调用**,
每次调用都要建帧。分析已经证明「一侧静态是 String」,所以另一侧运行时若是 String(tag 2),
通用派发的唯一结果就是 `__str_eq` —— 内联一次 `ql_tag` 判断,命中就直接调 `__str_eq`,
否则回落 `__op_eq`(Error/Null/数组/对象的语义不变)。

| 指标 | 之前 | 之后 |
|---|---|---|
| b_chars 运行 | 1.11s | **0.86s(−22%)** |
| b_chars 机器指令 | 131,296 | 131,819(+523,+0.4%) |
| b_index 运行 | 1.066s | 0.994s |

体积 +0.4% 换运行 −22%,这个取舍取运行(体积仍在 131.8k,噪声量级)。
验收:输出逐字节相同;demo 419/419;固定点成立;两个测试套件全过。

**下一步**:剩下的每字符成本是「QLang 小函数的调用帧开销」本身(每次调用 memset 局部区 +
绑定槽)。要么把小热函数(如 `__str_eq`)在 IR 层做成 `alwaysinline` 的叶子形态,要么给
小函数一个「无帧」变体。这是比单个操作符更大的题目。

## 66. 栈帧清零只在需要时做(2026-10-29)

每个函数/块栈帧的入口都 `memset(16+64*slot)` 一次,用来让「未初始化读」能被 `ql_empty` 认出来。
但绝大多数作用域里所有 `let` 都有初值、也没有嵌套函数字面量(可能捕获本帧),清零是纯开销 ——
小热助手(如 `__str_eq`)每次调用都要抹几百字节。

现在只在三种情况下清零:有没初值的 `let`、有函数字面量(可能捕获)、有 import(optional 绑定)。
判定在 AST 上做(`frameNeedsZero`),堆帧(模块/闭包环境)仍然一律清零。

| 指标 | 之前 | 之后 |
|---|---|---|
| b_chars 运行 | 0.701s | **0.663s(−5%)** |
| b_chars 机器指令 | 131,819 | **131,745(−74)** |

验收:输出一致;demo 419/419;固定点成立;selfhost 与 interpreter 测试套件全过。
收益不大,但它是纯减法(体积也降),而且清掉的是每次调用都付的固定成本。

## 67. 测试的标准库对象改用 QLang 构建器(2026-10-29)

`run_selfhost_tests._use_stdlib_object` 原来直接 `from stdlib_split import build_stdlib`
(Python)。现在:

1. 先确保 `target/tools/{stdlib,build,link,verify}` 存在(`aot/bootstrap.sh`,shell + clang);
2. 优先跑 `target/tools/stdlib --compiler <c>`(QLang 构建器,产物与 Python 版逐字节相同,
   布局一致:`stdlib.o / stdlib.ll / symbols.tsv / strings.tsv / interface.txt / symbols.json`);
3. 工具不可用时才回落 Python 的 `build_stdlib`(保留,供没有工具链的检出)。

`run_interpreter_tests` 里那份重复的 `_use_stdlib_object` 删掉,直接从 `run_selfhost_tests` 导入。
验收:selfhost 与 interpreter 测试套件都 ALL PASS;`QLANG_STDLIB_OBJECT/SYMBOLS/INTERFACE` 指向
`target/stdlib/<key>/`。至此**构建路径上不再有 Python**,Python 只剩测试驱动与两个回落分支。

## 68. t38「provenance survives allocations」= staticType 被当成运行期类型(已修)(2026-10-29)

`run_runtime_diagnostic_tests` 的 `t38:38` 仍红。最小复现(不依赖 t38 的其它断言):

```qlang
let zero = 0;
let direct = 1 / zero;          // Error,line 3
let chained = direct + 1;       // 链式 Error
println(isError(chained));      // false  ← 不是 Error?
println(chained.type);          // 一个 Error(UndefinedField)
println(chained.cause.line);    // 7(应是 3)
let i = 0; while i < 30000 { let garbage = [i, {n: i}]; i = i + 1; };
println(chained.cause.line);    // 11  ← 又变了
```

三个现象:
1. `isError(chained)` 是 **false**,但 `chained.cause` 存在 —— 链式错误的对象**没有被认成 Error**
   (`ql_tag`/tag 8 那条路)。
2. `chained.cause.line` 一开始是 **7**(不是来源行 3),经过 3 万次分配后变成 **11** ——
   cause 的定位字段会被**后续读取所在的行**改写,不是「分配导致丢 provenance」。
3. `chained.type` 是 UndefinedField —— 它没有 Error 的字段布局。

**根因**:不是 provenance 守卫,而是 `isStaticNumber` 只查 `staticType == "Number"` ——
发射端据此**省掉 tag 测试**走裸数值路径。但「静态类型 Number」的运行期值还可能是 Error
(除零、可能出错的调用),于是 `direct + 1` 直接对 Error 的载荷做了一次 double 加法,
得到的是一个**垃圾 Number**,链式错误根本没被构造。

**修法**:`isStaticNumber` 同时要求 `cannotBeError == true`(与 AGENTS §7.1「staticType ≠
运行期类型」一致)。分析已经为「两个操作数都不可能出错 + 该运算本身不产生错误」的节点盖上
`cannotBeError`,所以安全表达式仍然走裸数值路径。

| 指标 | 修复前 | 修复后 |
|---|---|---|
| t38 运行时诊断 | 16/17(1 FAIL) | **17/17 全过** |
| `direct + 1` | 垃圾 Number,`isError` 为 false | `TypeMismatch` Error,cause 定位正确 |
| t41 / t30 / b_chars 机器指令 | 136,865 / 151,774 / 131,745 | 147,257 / 162,851 / 141,958(**+7.6%**) |
| b_chars 运行 | 0.64s | 0.66s |

**代价是 +7.6% 体积**:凡是「静态 Number 但没被证明不可能出错」的表达式(主要是运行时/库里
那些**没有参数注解**的助手)现在都要发 tag 菱形。这是正确性换来的;要收回去只能靠给热助手
补注解(handoff F),让 `cannotBeError` 成立。

## 69. 数值 tag 测试改读内层 kind(−0.35%)(2026-10-29)

§68 修完之后,+7.6% 的体积主要来自数值派发菱形里的两次 `@ql_tag`。Number 是标量,内层 kind
就是 1,而对象 kind 恒为 0(语言 tag 在对象头里),所以「是不是 Number」可以直接
`extractvalue %ql_value %v, 0 == 1`,不必走 `@ql_tag` 的分支。

| 指标 | 之前(v43) | 之后(v45) |
|---|---|---|
| t41 / t30 / b_chars 指令 | 147,257 / 162,851 / 141,958 | 146,741 / 162,340 / 141,457 |
| b_chars 运行 | 0.69s | 0.66s |

**但 String 不能这么判**:字符串是堆对象(kind 0、对象头 tag 2),`==` 的 String 快路径必须继续
用 `@ql_tag == 2`。我先误改成 kind==2,直接把字符串快路径变成死代码(b_chars 0.67→0.83s),
发现后立刻改回 —— 这也再次说明「内层 kind」和「语言 tag」是两套东西。

验收:demo 419/419;固定点成立;selfhost、interpreter、runtime-diagnostic 全过。
剩下的 ~7% 只能靠给热助手补注解/加强 known-safe(handoff F/M)把裸数值路径赢回来。

## 70. 工具链两条验收(2026-10-29)

**① 链接路径在四个优化级别都通**(之前非 `-O2` 的委托刚放开,没回归):

```
stage2 --emit-llvm-split t16_functions.ql runtime.ql symbols.tsv interface.txt
tools/link <ir> -o <bin> --opt {0,1,2,3} --stdlib-object stdlib.o --stdlib-ir strings.tsv
```

四个级别都链接成功、运行退出 0、输出与 `t16_functions.expected` 逐字节相同。

**② 工具链能从零重建**(证明构建路径不依赖 Python):

```
rm -rf target/tools && aot/bootstrap.sh --compiler target/selfhost/stage2
```

1m49s 产出 `target/tools/{build,link,stdlib,verify}` 四个可执行;随后 selfhost 测试套件用这套
新工具跑 **ALL REQUESTED CHECKS PASS**。

**③ 安全分析扩到运行时/库:仍然没有新事实**。把 `typeSetCallSafety(true)` 包在
runtime/library 的 `inferTypes` 外面,`t41/b_chars` 的指令数**一模一样**
(146,741 / 141,457) —— 和 §59 的结论一致:库里的绑定过不了安全证明,所以那 ~7% 的
tag 菱形靠「开分析开关」收不回来;要收只能靠**注解**(让参数/返回带类型)或改判据本身。

## 71. 定点注解收不回 tag 菱形(2026-10-29,回滚)

§68 的 +7% 体积来自 1379 个数值派发菱形(§70 测的分布)。试了两个最集中的函数:
`runtime.ql` 的 `fileOffset`(184 个菱形)和 `stdlib/math.ql` 的 `reduceAngle`(55 个),
给参数补 `: Number`:

| 指标 | v45(无注解) | v48(两处注解) |
|---|---|---|
| t41 / b_chars / t30 指令 | 146,741 / 141,457 / 162,340 | 146,760 / 141,476 / 162,359 |

**+19 条,反而更差**。原因:菱形是「至少一侧不是静态 Number」时发的;注解把参数变成静态
Number **并且**加上调用点检查,但函数体内真正发菱形的地方多来自数组元素(`parts[0]` 之类,
静态类型仍是未知),注解碰不到它们。净效果 = 多出的检查 > 去掉的菱形。

结论:注解不是收这部分体积的手段,除非把**元素/调用结果**的类型也证明出来(known-safe 扩展)。
这 7% 就作为「staticType 不再冒充运行期类型」的既定代价;回滚,不再追。

## 72. 库对象化:编译快了 50×,但热路径慢了 3.7×(需要 LTO)(2026-10-29)

给 bench harness 加了 `--split`(走库对象,只发用户模块),默认仍是单模块(指令数口径可比)。

同一份 b_chars、同一个编译器(`/tmp/v45`):

| 模式 | 指令数 | 前端 | clang | 运行(CPU) |
|---|---|---|---|---|
| 单模块(默认) | 141,457 | 11.23s | 12.35s | **0.634s** |
| split(库对象) | 789(只算用户模块,不可比) | **0.15s** | **0.30s** | **2.309s** |

两条结论:

1. **编译时间**:11.23+12.35 ≈ 23.6s → 0.45s,**约 50×**。这就是「库只编一次」的价值。
2. **运行时间**:同样输出(1048,750,0 错误),**CPU 慢 3.7×**。原因是跨模块:库里的小热函数
   (`__str_eq` 等)在单模块时会被 clang 内联进用户循环,split 后变成**外部调用**,
   每次迭代多一次真调用。

所以测试用 split 是对的(只验行为,不验速度),但**发布构建不应该用 split**——除非把库对象
做成 **LLVM bitcode + LTO 链接**:编译仍然只做一次(对象缓存),链接时再做跨模块内联。
这是下一步(item 2b),判据就是 b_chars 的 CPU 时间能不能回到 0.6s 量级。

`--split` 的指令数只覆盖用户模块,**不要**拿它和历史数字比。

## 73. `--timing`:编译各阶段耗时探针(2026-10-29)

本机 `/proc/uptime` **是冻结的**(同一进程里连读两次都是 `124.08 932.80`),所以时钟改用
`/proc/self/stat` 的 `utime + stime`(100Hz,10ms 粒度;编译是单线程,CPU 时间就是阶段耗时)。

`stage2 --emit-llvm <src> <runtime> --timing` 会在 IR 末尾多打一行注释(默认关闭,固定点不受影响):

```
; phase: parse=<用户源码解析>ms lib=<runtime+库解析>ms analyze=<分析>ms emit=<发射>ms
```

实测:

| 输入 | parse | lib | analyze | emit |
|---|---|---|---|---|
| 空程序 | 0ms | 6290ms | 0ms | 3150ms |
| 测试用例 t30(91 行) | 150ms | **7320ms** | 120ms | 3700ms |
| 编译器自身(6.4k 行) | 12740ms | 8710ms | 3360ms | **19340ms** |

小程序的编译时间约 65% 在**重新解析运行库 + 标准库**:这正是 §72「库只编一次」要消掉的部分。

## 74. 库 bitcode + ThinLTO:编译仍快,运行回到单模块水平(2026-10-29)

§72 的 split 省编译但热路径慢 3.7×,原因是跨模块调用不能内联。把库对象额外产出一份
**LLVM bitcode**(`stdlib.bc`,由 `stdlib.ll` 用 `clang -O1 -emit-llvm -c` 生成,按时间戳缓存),
链接时用 `-flto=thin` 做跨模块内联(`native_link.py --lto`,或 bench `--split --lto`)。

b_chars、同编译器:

| 模式 | 前端 | 链接/优化 | 运行 CPU |
|---|---|---|---|
| 单模块 | 11.23s | 12.35s | 0.596–0.634s |
| split(.o) | 0.15s | 0.30s | **2.309s** |
| split + ThinLTO(O1) | 0.18s | **~9.6s** | **0.556–0.577s** |

- 编译总时间:23.6s → **~9.8s(2.4×)**;
- 运行时间:**回到单模块水平**(甚至略快);
- 所以三条路各有用途:测试/行为验证用 `.o`(0.45s/测试用例),发布用 `--lto`(2.4× 更快、运行持平),
  单模块留作基准与 A/B。

**LTO 下字符串校验要放宽**:LTO 会做常量合并与 GC,ELF 里的字符串符号不再与 IR 1:1。
`validate` 在 `lto` 时改成「ELF 不能出现预期集合之外的字符串符号」+ 逐个校验仍存在的符号,
缺的那些视作被合并/DCE。

**注意**:`stdlib.bc` 目前由 `native_link.py --lto` 按需生成并缓存;`tools/link`(QLang 链接器)
还不支持 `--lto`,所以带 `--lto` 的路径暂时走 Python 链接器。

## 75. 一个开关切到「库只编一次」:`--stdlib-object <dir>`(2026-10-29)

`tools/stdlib` 的产物目录里已有 `symbols.tsv` / `interface.txt`,所以编译器接受一个目录参数即可:

```
stage2 --emit-llvm --stdlib-object target/stdlib/<key> prog.ql runtime.ql > prog.ll
```

内部等价于 `--emit-llvm-split <src> <runtime> <dir>/symbols.tsv <dir>/interface.txt`。

| 输入 | 单模块 | `--stdlib-object` |
|---|---|---|
| 测试用例 t30 前端 | 11.2s | **0.81s** |
| 产物 IR 行数 | ~180k | 25,901(仅用户模块) |

配合 `native_link.py --lto`(ThinLTO)已能端到端:b_chars 前端 0.8s + 链接 15.1s(默认 `--opt 2`)
≈ **15.9s**,单模块 23.6s;运行 CPU 0.764s vs 0.596s。

**注意**:手动用 `-O1 -flto=thin` 时链接只有 9.6s、CPU 0.556s —— 对这个 bench 而言 `-O1` LTO
比 `-O2` LTO **又快又稳**。下一轮把 LTO 的默认优化级别定为 O1(`--lto` 时),再用 bench 测试套件复测。

## 76. LTO 默认优化级别定为 O1(2026-10-29)

`--lto` 现在单独走自己的优化级别(`--lto-opt`,默认 **1**),不再复用 `--opt`:

| 配置 | 链接 | b_chars 运行 CPU |
|---|---|---|
| `-O2 -flto=thin` | 15.1s | 0.764s |
| **`-O1 -flto=thin`(新默认)** | **10.6s** | **0.653s** |

整条 bench 测试套件在 `--split --lto` 下的前端时间:**0.14–0.44s/个**(单模块是 8–16s),
运行 CPU 与单模块持平(b_chars 0.588–0.653 vs 0.596–0.634)。

注意:bench 表里的 `clang(s)` 列是**指令计数**用的 `clang -O2 -S`(只扫用户模块),
不是 LTO 链接时间;端到端要额外加 ~10.6s 的链接。

## 77. [已更正,见 §78] 手搓 llvm-link LTO 管线"输出错误"的误判(2026-10-29)

想让 QLang 链接器(`tools/link`)也支持 `--lto`,按经典管线实现:
`llvm-link user.ll stdlib.bc → opt -O1 → llc -filetype=obj → ld.lld`(库不再单独进 ld)。

结果(同一份 split IR、同一个库对象):

| 链接方式 | 链接时间 | b_chars 输出 | CPU |
|---|---|---|---|
| `clang -O1 -flto=thin`(Python 路径,已验收) | 10.6s | **10,487,500** ✓ | 0.653s |
| `llvm-link + opt -O1 + llc + ld.lld` | 6.9s | **10,515,500** ✗ | 0.503s |
| 同上,t16 测试用例 | — | 3 3 8 ✓ | — |

简单测试用例(t16)是对的,b_chars 差 **28,000**(多算了空格) —— 说明这条管线**不等价**于
clang 的 LTO 驱动(它在 internal 化/字符串全局/目标文件组织上有额外处理),不能拿去发布。

**结论当时写错了,§78 更正**:差异来自 b_chars 读取的 `aot/runtime.ql` 在两次测量之间被我编辑过
(每次多算的空格数 = 文件里多出来的空格数),不是 LTO 管线的问题。

## 78. 更正 §77:手搓 LTO 管线是对的;QLang 链接器现在支持 `--lto`(2026-10-29)

§77 那个「b_chars 多算 28,000」的真因:**b_chars 读的是 `aot/runtime.ql` 这份源码文件**,
而我在两次测量之间编辑过它(给校验器加 relaxed 参数)。HEAD 的 runtime.ql 有 **20,975** 个空格
(= 正确输出 10,487,500 / 500 轮);补丁版多 48–56 个空格/轮,正好对上差值。

**教训**:凡是读源文件当输入的 benchmark,基线必须**同源同时测**——历史数字会随文件内容漂移。
这次就是拿旧数字对比新文件,误判成 LTO 错了。

更正后的测量(同一份源码、同一份 split IR):

| 链接方式 | 链接时间 | 运行 CPU | 输出 |
|---|---|---|---|
| 单模块(同源对照) | — | 0.551s | 10,515,500 |
| `clang -O1 -flto=thin`(Python) | 10.6s | 0.653s | 10,515,500 ✓ |
| `tools/link --lto --lto-opt 2`(QLang:llvm-link→opt→llc→ld) | 11.2s | 0.621s | 10,515,500 ✓ |
| `tools/link --lto --lto-opt 1` | 17.9s | 1.020s | 10,515,500 ✓(但 llc -O1 的码更慢) |

所以:
- QLang 链接器 `--lto` **可用**,默认 `--lto-opt 2`(llc -O1 虽然链接慢一点、运行反而更慢);
- `tools/stdlib` 现在**同时产出 `stdlib.bc`**(缓存命中时也会补),`--lto` 不再依赖 Python 生成;
- 校验器加了 relaxed 模式(LTO 会常量合并/GC,`verify <elf> <strings> <ir> --lto` 只要求
  「ELF 里没有预期外的字符串符号」)。

## 79. 静态派发收尾:剩余拒绝面只有 0.2% 的量级(2026-10-29)

当前计数器(t30 + runtime):

```
; directreject: nohit=0 notable=20 noinfo=30 assigned=0 arity=0 args=0 ann=10
; stdchain: hits=70 cached=1 nokey=0 arity=0 args=0 written=0
```

- `args=0` 已经清零(共享入口 `__direct_checked` 之后不再需要)；
- 剩下 60 个点:`notable`(作用域名解析到没有 directFns 表的绑定)、`noinfo`(表里没有该名字:
  定义晚于调用、或被赋值/导出)、`ann`(实参静态类型不等于形参注解)。
- 覆盖率按早先的账(278 个直调点)算约 82%;按每个直调点省 ~5.8 条指令(§63 的实测)折算,
  这 60 个点约 **350 条指令 ≈ 0.2%**。
- 真要吃掉它们需要「预扫所有顶层函数、预分配符号名」的前置 pass(处理前向引用),
  改动面大、收益固定且很小。

**结论:静态派发的剩余面到此关闭**,不再投入;`ns-unresolved` 那 30 个是**类型索引**的缺口
(`Error.raise`/`String.fromCodePoint` 等),影响的是 `.check`/收窄的信息量,不是直调覆盖率。

## 80. 工具链:bench 也走 QLang 链接器;`--shared` 链接验证(2026-10-29)

- `aot/bench/run_bench.py --split` 现在优先用 `target/tools/link`(带 `--lto` 时也一样),
  工具不存在才回落 Python 的 `native_link.py`。也就是说**度量与测试的构建路径都不再依赖 Python**。
- `--shared`(native 扩展)链接验证:`stage2 --emit-module` 出 IR →
  `tools/link <ir> -o ext.so --shared` 成功,产物是 ELF 共享对象(导出 `__cold_located_error`/
  `__panic_exit`,未定义 `memcpy`)。本机无法 dlopen 运行扩展(环境缺口),这里只验到链接层。
- 从零重建工具链已在 §70 验过(`rm -rf target/tools` → `bootstrap.sh` 1m49s)。

## 81. 错误模型第 5 项收口:E 已验证;B1/B3 按口径暂不改(2026-10-29)

- **E(类型面)**:`std.Result(T) ≡ T|Error`、`std.Option(T) ≡ T|Null` 已在 `stdlib/result.ql` 实现,
  `?` 只在 `Result(...)`/`Option(...)` 注解函数里允许。用库对象路径复跑两个判别测试用例:
  `t53_return_boundaries`、`t56_result_annotations` 输出与 `.expected` 逐字节一致。
- **B1(StackOverflow)/B3(运行期 arity)**:以 `docs/rust-error-model.md` 为准 ——
  **「暂不改;panic 边界先不动,避免一次改太多」**。所以这两项不是待办,是**作者已决定的延后**,
  不再列为缺口。
- B2(缺失字段/索引 ⇒ Null)与 B4(`/0` 保持 Error)同属已定口径,不动。

结论:第 5 项到此关闭 —— 没有遗留的可执行工作。

## 82. 第 6 项:仓库卫生清扫 + 驱动 QLang 化的判断(2026-10-29)

**清扫**:删掉两个陈旧 worktree(`/tmp/wt_head` = 394e473、`/tmp/wt_p0` = 2c800e8)和两个
difftest 遗留文件(`_df_boot.ql`、`_df_host.ql`,10-15 的产物,本来也在 .gitignore 里)。
现在 `git worktree list` 只剩主工作树,`git status` 干净。

**驱动 QLang 化的判断**:22 个 Python runner(48–143 行/个)是**编排**:
建临时目录、按模式拼编译器命令行、clang 链接、跑二进制、和 `.expected` 比对、报告 fatal 用例。
这些是测试基础设施,不是语言运行时——AGENTS §2.7 明确「Python 只是测试/链接/数据生成工具」。
真正有意义的那一半(**构建路径**不依赖 Python)已经在第 2/4 项做完:
测试与 bench 的标准库对象走 `target/tools/stdlib`,链接走 `target/tools/link`,
Python 只剩「没有工具链时的回落」和测试编排。

**结论:不做驱动 QLang 化。** 移植 22 个 runner 会把「测试怎么跑」从成熟工具链搬到自研进程
编排上,收益是零(用户跑不到这些脚本),风险是测试不稳。这一项到此关闭,记在这里避免以后重开。

## 83. 全测试套件对照:`.o` / QLang-LTO / clang-LTO 的运行代价(2026-10-29)

同源(/tmp/vf 由当前源码构建)、同机、顺序跑(避免争抢)。harness 对每个 bench 取 5 次最小值。

| bench | 单模块 CPU | split+`.o` | split+QLang `--lto` |
|---|---|---|---|
| b_build | 4.159 | — | 4.392(+6%) |
| b_calls | 0.019 | — | 0.068 |
| b_chars | **0.461** | **2.309(5.0×)** | **0.788(+71%)** |
| b_index | 0.614 | — | 0.769(+25%) |
| b_strat | 1.957 | — | 2.208(+13%) |
| b_untyped_calls | 0.352 | — | 0.507(+44%) |

单独再测 **clang 驱动**的 LTO(`native_link.py --lto`,`-flto=thin -O1`,取 3 次最小值):

| bench | 单模块 | clang-LTO |
|---|---|---|
| b_chars | 0.461 | 0.489–0.561 |
| b_index | 0.614 | 0.474 |
| b_untyped_calls | 0.352 | 0.291 |
| b_build | 4.159 | 5.010 |
| b_strat | 1.957 | 1.992 |

结论:
1. **`.o` 路径只配给测试**:热路径慢 5×(2.309 vs 0.461)。
2. **QLang 链接器的 `--lto` 稳定偏慢(+6%…+71%)**:`llvm-link` 不做 clang LTO 的
   internalize/globaldce,跨模块优化不如 clang 的驱动。**发布构建暂时别用它**。
3. **clang 驱动的 LTO 与单模块大致持平**(−23%…+22%,机器噪声主导,方向不一致)。要发布又想省
   编译时间,走 `native_link.py --lto`。
4. 之前的「`--lto` 运行与单模块持平」只在 b_chars 上测过、且是不同负载下的数;全测试套件不支持
   「QLang 链接器路径持平」这个说法,已在 README 更正。

## 84. 把 QLang 链接器的 LTO 修成 clang 同款管线:运行回到 ±12%(2026-10-29)

§83 的「QLang `--lto` 慢 6%–71%」有两个原因,现在都处理了:

1. **漏了 internalize + globaldce**:库函数在 stdlib.ll 里是 `hidden`(跨模块可见性需要),
   而 clang 的 LTO 会先把它们 internalize 再删没人用的;不做这一步,代码里留下 612 个文本符号
   (单模块 426),内联/DCE 都保守。
2. **跑的是 `opt -O2` 通用管线**,不是 LTO 专用的 `lto<O>` 管线。

修法(`tools/link --lto`,exe 模式):

```
opt -passes="internalize,globaldce,lto<O2>" -internalize-public-api-list=main merged.bc
llc -O2 -filetype=obj
```

(shared 模式不做 internalize,否则扩展导出的符号会被删。校验器在 `--lto` 下也放宽了用户 IR
字符串的「必须存在」——globaldce 会删掉只出现在死代码里的字符串。)

同源、顺序跑、harness 取 5 次最小值:

| bench | 单模块 CPU | split+LTO CPU | 差 |
|---|---|---|---|
| b_build | 4.141 | 4.004 | −3% |
| b_calls | 0.014 | 0.021 | — |
| b_chars | 0.605 | 0.622 | +3% |
| b_index | 0.466 | 0.524 | +12% |
| b_strat | 1.987 | 1.999 | +1% |
| b_untyped_calls | 0.282 | 0.284 | +1% |

6 个 bench 输出**全部一致**;编译前端 10.7–11.0s → 0.15–0.21s。文本符号 421(单模块 426)。

**教训**:这台机器的 run-to-run 噪声能到 ±20%(同一个二进制先后测出 0.578 与 0.72),任何
「A 比 B 快多少」的结论都必须在**同一次运行里交替**测,或者用 harness 的 5 次最小值。

## 85. 两个"大件"的编译时间:std 库对象 vs 编译器自身(2026-10-29)

单机顺序测量(避免并行争抢):

| 任务 | 前端+发射 | 后端 | 合计 |
|---|---|---|---|
| `tools/stdlib` 冷缓存(建 `stdlib.o`+`stdlib.bc`+接口) | ~11s(空程序全量 IR) | llc + clang | **88.7s** |
| 编译器自身(单模块,`qlangc.ql`+`runtime.ql`,96 万行 IR) | **49.6s** | clang -O2 -c **67.6s** | **~120s** |

**用库对象 + LTO 编编译器反而更慢**:前端 38.9s(只省下库解析那 10.7s——编译器的前端主要花在
自己 3,821 行的解析/分析上)+ LTO 链接 **114.5s** = **153s** > 120s。产物 IR 与单模块**逐字节相同**
(`cmp` 通过),所以是纯耗时问题,不是正确性问题。

结论:
- **小程序**:`--stdlib-object` + `--lto` ≈ 0.2s 前端 + 11s 链接;只验行为走 `.o` 0.45s。
- **编译器/大程序**:单模块仍然最快(clang 的 -O2 比我们的 LTO 管线便宜),不要换成 LTO。
- **库对象只建一次**(89s),所有后续小程序共享。

## 86. 三条路径的全测试套件运行代价,以及「可内联库体」能收回多少(2026-10-29)

同源、顺序跑、harness 5 次最小值(CPU 秒):

| bench | 单模块 | split `.o`(无内联) | split+LTO |
|---|---|---|---|
| b_build | 4.141 | 12.261(3.0×) | 4.004 |
| b_calls | 0.014 | 0.018(1.3×) | 0.021 |
| b_chars | 0.605 | 2.467(4.1×) | 0.622 |
| b_index | 0.466 | 2.446(5.2×) | 0.524 |
| b_strat | 1.987 | 6.784(3.4×) | 1.999 |
| b_untyped_calls | 0.282 | 0.986(3.5×) | 0.284 |

**结论**:不做跨模块内联统一慢 **3–5×**;LTO 能 100% 收回,但链接 11.2s。

**「可内联库体」(Go export-data 式)的估计**:慢的根源是**少数几个跨模块热函数**
(`__str_eq`/`__op_add`/`__op_eq`/`__call_borrowed`),不是均匀摊在库上——LTO 的收益集中在这里。
所以只把这些小函数的内联体随接口导出、链接时按预算内联,预期能收回 **70–90%** 的差距:
b_chars 2.47 → ~0.7–0.9s、b_strat 6.78 → ~2.4–2.9s、b_build 12.3 → ~4.5–5.5s,
而链接仍停在 **0.3–0.6s**(不做全程序优化)。

**验证成本最低的原型**:编译器发射时,按白名单把 3–5 个小热函数的 IR 体复制进用户模块并标
`alwaysinline`,量同样 6 个 bench。判据:运行时进到单模块的 1.2× 以内、链接 < 1s。
这是估算,不是结论——要先做这个原型才能确认。

## 87. 原型否掉了「导出几个热函数的内联体」这个估计(2026-10-29)

按白名单把库函数体粘进用户模块并标 `alwaysinline`,前提是**用户模块能按符号引用到它们**。
实测不成立:b_chars 的 split 用户 IR 里**没有任何 `@ql_fnN` 引用**(`grep -c "@ql_fn" = 0`),
只有 28 处 `call %ql_value %tN(...)` —— 对**闭包 code 指针的间接调用**;库函数的闭包盒在对象里,
用户模块看不到被调者是谁。所以「粘几个热函数体」无从下手。

真正的差距来源因此更正为两条:
1. **间接调用**:`std.*`/运行时助手的调用在 split 模式下退化为「闭包间接调用 + 派发」,
   单模块模式下它们是对 `@ql_fnN` 的**直接调用**;
2. 跨模块不能内联(这条之前就知道)。

LTO 之所以能把 3–5× 收回,靠的是把两个模块合并、闭包盒变成已知常量,从而**去虚化 + 内联**;
单纯"导出内联体"做不到这一点。

**修正后的判断**:想让 split 路径接近单模块,必须让 split 模式能**直接调用库函数**
(接口里带上 符号 + env + anns,省掉闭包间接),而不是导出内联体。
那是比"白名单原型"大一档的工作;在此之前,发布构建继续用 `--lto`(11s)或单模块。

## 88. split 模式一直在静默丢失直接调用(symbols.tsv 列数不匹配)(2026-10-29)

编译器解析 `symbols.tsv` 时要求**两列**,而构建器写的是**三列**(`名字<TAB>ql_fnN<TAB>fastArity`)。
于是 `stdlibSymbolMap` 全空 → 接口里的 `DFN` 行解析不出符号 → **split 模式下所有直接调用
静默退化成闭包间接调用**(包括 `__op_eq`/`__str_eq` 这些每次比较都要走的运行时助手)。

修一行(接受 2 或 3 列)后:

| 指标 | 修复前 | 修复后 |
|---|---|---|
| t30 split IR 里引用的 `@ql_fn` 符号数 | **3**(只有用户自己的函数) | **231** |

**但对 b_chars 的运行时间没有可测影响**(split 2.47 → 2.55s,单模块 0.70s)。说明剩下的
3–5× 不是"间接调用",而是**不能内联**:`__op_eq`/`__str_eq` 的调用开销在体内(建帧、参数槽),
直接调用省掉的只是一次间接跳转。

**这条修复的价值在另一处**:它让"导出热函数内联体"这条路第一次**可行**——之前用户模块里
根本没有 `@ql_fn` 引用,无体可粘;现在有了这 231 个引用,可以按引用集合导出对应的 `_f` 体、
标 `alwaysinline`,这才是能把 3–5× 收回来的做法。

## 89. 用户函数与库内部函数会撞号(接口缺 MAX)(2026-10-29)

做「内联库体」原型时撞到:用户模块的第一个函数编号取的是 **symbols.tsv 里最大导出符号 + 1**,
而库里还有**未导出**的函数用了更大的编号(实测库最大 = 300,导出最大 = 299)。于是用户
`ql_fn300` 和库内部 `ql_fn300` 同名 —— 单模块不会碰到,但任何"把两个模块的体合到一起"的操作
(LTO、内联体粘贴)都会「重复定义」。

修法:接口末尾加一行 `MAX <n>`(库函数**总**最大编号,含未导出),编译器加载接口时
`funcCounter = max(符号最大 + 1, MAX + 1)`。

| 项 | 修前 | 修后 |
|---|---|---|
| 库最大函数编号 | — | 300(`MAX 300`) |
| 用户函数起始编号 | 300(与库内部撞号) | **301** |

顺带说明:这条也是 §88 那个 symbols.tsv 列数 bug 的同族问题 —— split 模式的"事实表"要么缺列、
要么缺项,而且**都是静默的**:不给诊断,只是悄悄退化或埋下撞号。

## 90. std 内联体原型:直调型 bench 追平单模块,闭包型没救(2026-10-29)

做法(原型脚本,未入库):从用户 IR 里出现的 `@ql_fnN` 符号出发、取传递闭包、按体大小 ≤400 行
筛选、总预算 20k 行;把这些库函数的 `_f` 体粘进用户模块、标 `alwaysinline`(改名 `__inl_*`、
补 `.strbox` 外部声明、未粘贴的被调者补 `declare`),然后 `clang -O2` 一次编完,仍然链 `stdlib.o`。

| bench | 单模块 | 纯 `.o` | 内联体(20k) |
|---|---|---|---|
| b_chars | 0.603 | 2.58 | **0.633** ✓ |
| b_index | 0.562 | 2.45 | **0.556** ✓ |
| b_untyped_calls | 0.221 | 0.99 | 0.935 ✗ |
| b_strat | 1.759 | 6.78 | 6.385 ✗ |
| b_build | 4.49 | 12.26 | 14.07 ✗ |

编译时间:内联体版本 `clang -O2` **2.0–4.3s**(单模块 ~12s,LTO 链接 ~11s),6 个 bench 输出全部一致。

**结论**:内联体只在"热路径是对 `@ql_fnN` 的直接调用"时有效(b_chars/b_index 完全追平)。
b_strat/b_build/b_untyped_calls 的热路径走的是 **std 对象的闭包**(`std.X.Y(...)` 在 split 下
是间接调用 + 缓存闭包),粘体救不了——它们的前置条件是把 std 链在 split 下变成**直接调用**
(接口里 `MEM` + `DFN` + 符号已经齐了,只差成员的元数)。所以顺序必须是:
**先 std 链直调 → 再内联体**,和作者说的优先级一致。

## 91. std 链直调进 split:接口现在带 MEM 元数,但成员符号还拿不到(2026-10-29)

按"先 std 链直调、再内联体"的顺序做第一步:

- 接口的 `DFN` 行顺带填 `stdMonoArity`;`MEM` 行追加第 4 列(成员绑定的元数);
- `loadStdlibInterface` 遇到 `MEM` 时,用 `symbols.tsv` 的符号 + 元数建 `stdChainTargets`;
- `--emit-stdlib-interface` 之前**不跑分析**,导出表几乎是空的;现在先跑 runtime+库的分析再 dump。

**但只拿到 3 条 MEM**(`Number.parseFloat`、`Math.sqrt`、`Math.pow`),而且元数是 `-1`,
`stdchain` 计数变成 `hits=0 cached=71 arity=4` —— 全部因为元数未知被拒。

根因:库的导出表是 `{Math: MathLibrary, ...}`,而 `MathLibrary` 的成员是**内联 lambda**
(`{sqrt: (x) -> ...}`),没有源绑定名。单模块模式下这些 lambda 在**发射**时被登记进
`stdMemberIr`(得 `ql_fnN`),接口 dump 只做分析、不发射,所以拿不到它们的符号。

**结论**:要让 split 模式的 std 链直调成立,接口生成必须包含"成员 lambda 的符号",也就是
dump 时要**发射一遍库**(或由构建器从它自己的发射过程里导出这张表)。成本:对象构建多付
一次发射(~12s,89s → ~100s),一次性。

## 92. split 的 std 链直调成立(66 个点),但只有"直调型"bench 追平(2026-10-29)

接口现在带 `SYM <模块> <成员> <ql_fnN> <元数>` 行(由**发射那一趟**导出:`stdMemberIr` 只在
发射时才有内联 lambda 的符号),编译器在 split 模式下据此建 `stdChainTargets`。

| 指标 | 之前 | 之后 |
|---|---|---|
| split t30 的 `stdchain` | hits=0 cached=71 arity=4 | **hits=66 cached=5** |
| 接口 `SYM` 行数 | 0 | 36 |

再叠内联体(20k 预算)后的运行时间(同源交替):

| bench | 单模块 | split+链直调+内联 |
|---|---|---|
| b_chars | 0.467 | **0.471** ✓ |
| b_untyped_calls | 0.212 | 0.802 ✗ |
| b_strat | 2.145 | 6.303 ✗ |
| b_build | 5.308 | 12.668 ✗ |

**剩余差距的原因**:这三个 bench 的热路径调用的是**大函数**(`std.String.split`/`join`、
`__call_borrowed` 等,体动辄上千行),超出内联预算(≤400 行)粘不进来;它们的开销不是"间接跳转",
而是 QLang 的**调用 ABI**(建帧、参数槽、返回值装箱)。单模块能追平是因为 clang 把这些大函数
也内联进调用点了。

所以下一步不是继续加内联预算(大函数强行 alwaysinline 会膨胀),而是**降低调用本身的成本**
(更瘦的调用约定 / 参数不落槽),或者对"大函数 + 热调用"做专门的多版本化。

## 93. mod.ql 的形态与语义(设计定稿;编译器接线待做)(2026-10-29)

作者定了三条:

1. **mod 是配置,不是"另一门语言"**:用 JSON(QLang 字面量的子集)写成 `mod.ql`,由**专门的
   逻辑**读配置并处理语义(校验、可见白名单、链式成员解析)——不把 mod 丢给语言 parser 去执行。
2. **mod 可选**:有 mod 听 mod;没有就沿用旧行为(现在的 `interface.txt` 路径)。以后第三方包
   也可以用同一套 mod,不是 std 专属。
3. **有 mod 时按白名单**:mod 没声明的值/函数/成员,即使库里存在也不能用(分析阶段就当作
   不存在 → `undeclared name`),而不是运行期才失败。
4. 生成方式:QLang 还没有 codegen SDK,先**字符串拼接**产出 mod.ql。

原型(未入库):`aot/stdlib_interface.ql` 用 `std.JSON.parse` 读配置 + 校验(version/maxFn 必需,
缺就报 `InterfaceError`),编译器在 split 路径上认 JSON(以 `{` 开头)并填同一批表。用
Python 手工从 `interface.txt` 生成了一份 mod.ql 与旧路径对比:**计数完全一致**
(`stdchain hits=66 cached=5`、`directreject` 相同)。

**但接线后 selfhost 测试套件红了**:某个测试用例链接失败(`numeric.ll`),原因是手工生成的 mod.ql
漏了函数条目 —— 白名单一旦不全,生成代码引用的符号就链接不上。所以 mod.ql **必须由发射那一趟
的事实生成**(和 `SYM` 同源),不能手工维护;这也是下一步要做的:构建器在写对象时一并产出
mod.ql,并把"白名单完整性"作为验收(与 `MAX`/符号表交叉核对)。

**补充(同日的进一步定稿)**:

- **格式**:不必是严格 JSON——QLang 兼容 JSON5、自带 `std.JSON`,所以 mod.ql 用 QLang/JSON5
  字面量写、用现成的 `std.JSON.parse` 读,**不另写解析器**。
- **类型**:mod 里每个成员/函数**能推导出类型就标推导出的类型,推导不出写 `Any`**;接口因此
  兼作"类型面",消费方读 mod 就知道 `std.String.length` 的类型,而不是一律未知。
  ```json
  { "version": 1,
    "modules": {
      "String": {
        "length":  { "symbol": "ql_fn180", "arity": 1, "type": "Any" },
        "replace": { "symbol": "ql_fn183", "arity": 2, "type": "Function" }
      }
    },
    "maxFn": 300 }
  ```

**再补充**:mod.ql **不经过 JSON 解析**——它就是一个 QLang 对象字面量(`let mod = { ... };`),
读取方用**自己的 QLang parser** 把它当对象拿到(JSON5 是 QLang 的子集,所以两种写法都接受),
不引入 `std.JSON` 这一层。构建器现在直接写 `let mod = {...};`。

## 94. split 路径切到 mod.ql(接口是 QLang 值),并修掉 SYM 成员的未声明符号(2026-10-29)

上一节的接线失败过一次(手工生成的 mod.ql 漏条目 → `numeric.ll` 链接失败),这次的结论是
**不是格式的问题,而是"手工生成"的问题**:接口必须由发射那一趟的数据长出来。

### 94.1 mod.ql 的最终形态

构建器(`aot/stdlib_build.ql`)从一个 `interface.txt` 的生成过程里同时拼出 `mod.ql`,
它是 **QLang 对象字面量** `let mod = { ... };`,字段是 interface.txt 的无损映射:

| 字段 | 来源 | 实测条数 |
|---|---|---|
| `slots` | `SLOT` | 205 |
| `functions` | `DFN`(源顶层函数)+ 符号表 | 158 |
| `runtime` | `RFN` | 158 |
| `modules` | `MEM` / `SYM`(成员 → `{symbol, arity[, bind]}`) | 4 模块 / 39 成员 |
| `mt` | `MT` | 26 |
| `values` | `MV` | 4 模块 |
| `calls` | `MC` | 7 模块 |
| `maxFn` | `MAX` | 300 |

两个坑:
- `MEM` 的元数必须取 MEM 行带过来的**源绑定参数个数**(`cells[4]`),不是 symbols.tsv 的
  fast 寄存器元数;两者语义不同(`-1` vs 1..3),直调按前者判。
- `MEM` 的 `bind`(源绑定名)不能丢:成员身份是绑定名,符号是查出来的;`SYM`(内联 lambda)
  没有绑定名,符号只存在于接口里。`std->成员` 两条链因此形状不同。
- `functions` 只放 DFN(直接调用目标),不放模块成员的符号 —— 后者走 `modules`;符号表里另有
  一批"库内部函数"的符号,split 模式只声明不使用,不需要归属。

### 94.2 消费端:一个 QLang 值,一个词法器

编译器的 `loadStdlibInterface` 按内容分派:以 `{` / `let mod` 开头走 mod.ql,否则走旧的行格式。
mod.ql 用**共享词法器**(`Lexer(text).tokenize()`)读,再按字面量文法递归下降成 QLang 值
(`modLiteralAt`,返回 `{value, next}` 把游标带出来):

- 只接受纯字面量(`String/Number/true/false/null/Array/Object`,以及 `-1` 这种 `Minus`+`Number`);
  出现别的 token 就报 `CompileError` —— 配置里藏代码是隐性语义。
- 不引入第二套 JSON 读取器(上一版试过 `std.JSON.parse`,等于多一层而且要走第二套校验)。
- 校验 version / slots / functions / runtime / modules 缺失,缺就报错,不静默。

**为什么不用完整 parser**:第一版用 `parseModule` + AST 遍历,读接口比 `interface.txt` 慢
0.14–0.31s(同一测试用例多次取最小值:t20 `0.34` vs `0.20`,t30 `1.45` vs `1.14`)。探针把成本
分到两段(10 次,整程序计时):

```
tokenize mod.ql × 10 = 0.64s     → 词法 ~0.06s/次
parseModule      × 10 = 2.68s    → 完整解析 ~0.20s/次(建 AST + 每个节点带 span)
```

接口是数据,不需要 AST 也不需要位置,所以换成词法级读取。改后同一测量:

```
t20  mod 0.243s / txt 0.180s   (10 次最小值;均值 0.323 / 0.292)
t30  mod 1.231s / txt 1.194s
```

即开销从 0.14–0.31s 降到 **0.03–0.06s**(本机噪声就有 ±0.03s),前端没有可感知的退化;
`parseModule` 仍然是用户源码那条路用的(它需要 AST)。

### 94.3 等价性:mod.ql 与 interface.txt 的 IR 逐字节相同

同一编译器、同一份 symbols.tsv,只换第 5 个参数:

```
same=69  diff=0  fail=4
```

四个 `fail` 是 `t8_comp / t8_leaf / t8_obj / t9_error` —— 它们直接引用运行期内部名
(`allocBox`/`ql_alloc`/`__obj_new`/`__err`),本来就只能走单模块路径;**两条路径的报错完全相同**,
不是本次改动引入的。`t58_direct_calls`、`t30_strings`、`t61_known_safe` 等代表测试用例逐字节相同。

### 94.4 顺带修掉:SYM 成员的符号没有声明 → `opt: use of undefined value`

整套测试第一次跑,`t25_numeric` 链接失败:

```
opt: numeric.ll:13373:27: error: use of undefined value '@ql_fn250'
  %t8344 = call %ql_value @ql_fn250(...)
```

`std.Math.abs` 是 `SYM` 成员(库里的内联 lambda),符号 `ql_fn250` 只在接口里出现,`symbols.tsv`
的键是**绑定名**(`absolute` → 另一个符号),所以 split 模式的声明循环(只遍历 symbols.tsv)
永远不会声明它。

**这不是本次改动引入的**:用 HEAD 的编译器(`git show HEAD:aot/qlangc.ql` 重建)跑同一测试用例,
同样产生 1 处 `call @ql_fn250` / 0 处 `declare`。是 §91/§92 加 SYM 直调时留下的缺口 —— 那之后
没有再跑过全量测试套件。修法:split 模式声明完符号表后,再遍历 `stdChainTargets`,把不在表里的
符号补一条通用入口声明(36 条 SYM 里只有被真正用到的会进 IR,其余由 `opt` 清掉)。

补声明按**字节序**排(不能用成员表的书写顺序:mod.ql 的模块成员顺序来自对象,行式文本来自
文件行序)。不排序时两条路径的声明顺序不同 → IR 文本不同(语义相同),等价性断言就没法
逐字节比。排序后回到 `same=69 diff=0`;声明顺序本身不影响机器码:同一 t20 用排序前/后的
编译器各发一遍,IR 逐字节相同(IR 185,619 / 机器 141,116,输出 `20`)。

## 95. 链接的 debug / release 分档(2026-10-30)

`tools/link` 的 release 链是 `opt -O2 用户 IR → llc -O2 → ld.lld → 校验 ELF 字符串`。既然
`opt` 那一趟是唯一可以整段省掉的(其余都是必须跑的),就把它做成档:

```
tools/link <ir> -o <out> --stdlib-object <o>           # release(默认,行为不变)
tools/link <ir> -o <out> --stdlib-object <o> --debug   # llc 直接吃 IR(-O1),跳过 opt
```

**契约:两种档位发射的 IR 完全相同,只有后端优化等级不同** —— 前端/分析/直调决策不分档,
所以不存在"debug 下能跑、release 下语义不同"的风险面。

实测(同机、3 次取最小):

| | release | debug |
|---|---|---|
| 链接 loop.ql(100M 累加) | 1426ms | **1134ms** |
| 链接空程序 | 1479ms | **1098ms** |
| 运行 100M f64 累加 | 216ms | **459ms**(2.1×) |

省的是 `opt` 这一趟(~0.3s,含 0.12s 进程启动),运行慢是因为没有 IR 级内联/合并。
debug 剩下的 1.1s 基本是地板:`llc` 0.28 + `ld.lld` 0.26 + 校验 0.13 + QLang 链接器自身 0.09
+ 若干子进程;要再往下只能减少进程数或换实现语言(见 §94.2 同类分析)。

正确性对照:6 个测试用例(`t20/t30/t43/t54/t58/t61`)两种档位的输出与 `.expected` 逐字节相同。
`--no-verify` 仍可叠加(再省 0.13s),但默认开着——它是"不发布错二进制"的门,与优化等级无关。

## 96. debug / release 两档:debug 不消费分析的优化结论(2026-10-30)

作者定的分档口径:**debug 走保守路线(所有值走通用路径),release 能删的删、能静态的静态**。
所以分档点不是"分析跑不跑",而是**发射器是否消费分析结论**——分析两档都照跑,诊断因此完全一致
(同一份源码两档都合法或都不合法)。

| 档位 | 编译器 | 链接器 |
|---|---|---|
| release(默认) | 消费全部结论:直调/内联/raw ABI/闭包省略/死函数删除/unbox 裸槽/可证检查省略 | `opt -O2 → llc -O2 → ld.lld → 校验` |
| debug | 一条都不用:所有值装箱、所有调用走通用路径、检查全留 | `llc -O1` 直接吃 IR(§95) |

实现是**一个开关 + 若干消费点**,没有第二套发射器:

```
conservativeMode（--debug）:
  buildInlineCandidates + allowDirectUserCalls   → 不跑（库那趟与入口那趟都关）
  curScope.unbox / node.unboxType                → 不标记（绑定与形参都不裸）
  deadCheck / 返回类型的 proven                   → 不成立（注解检查与返回检查全发）
  `; proven-safe call is not directly dispatched` → 不检查（保守路径走通用调用同样正确）
```

最后一条是**踩到的真问题**:那条 internal 不变量原本假定"分析证明不可能出错的调用一定已被
内联/直调",debug 下必然触发,`t55/t59/t61` 三个测试用例直接编译失败。它说明"分析结论"曾被
当成"发射器不变量"——分档正好把这类隐性耦合暴露出来。

**差分测试套件** `aot/run_debug_diff_tests.py`:每个测试用例两档各编一次,判据是**两档输出逐字节相同**
(顺带与 `.expected` 比)。它有两个用途:①优化不健全会表现为"debug 对、release 错";②语言调试
时所有值都走通用路径,没有裸槽/直调/闭包省略这些特例。实测 42 个测试用例:41 个两档一致且正确,
`t37_extensions` 两档**同样**红(需要 extension 宿主,与档位无关,已列入 SKIP)。

不变量与体积(同源):

| | t20(单模块 IR) | t30(用户模块 IR) |
|---|---|---|
| release | 185,619 行(与 HEAD 基线**逐字节相同**,只多一行 `; conservative: off`) | 24,512 行 |
| debug | 187,334 行 | 24,719 行 |

debug 的 `; rawABI order` 计数:`direct=0 inline=0 rawcalls=0 rawfuncs=0 rawretcalls=0`,
即确实一条优化都没用。

## 97. 死函数删除:两条实现路径都会把发射出的 IR 弄坏(2026-10-30,未落地)

目标是把"完全没人引用的顶层函数"整块删掉(2000 函数程序里 1999 个属于这类)。作用域必须先收窄:
**只对入口程序**,因为编译器自己会按名字直调库函数(`emitCallRegs("__build_standard_library")`、
`__install_library`、`__process_args` …),那些调用边不在 AST 里;第一版没管这条,**t20 直接段错误**
(把仍在被调的库函数删了)。库函数只经导出表被用户看到,值用途都写在 AST 里,所以"入口程序"是安全边界。

判据(可证明无观察者):`value == 0`(没有任何值位置读取)、`callee == 0`(没有任何调用)、
非 moduleBody、无注解、未被赋值/重声明/导出/import。

**两条发射路径都试过,都在"很多死函数"的程序上产生非法 IR**(`clang -O2 -S` / `opt` 报
`use of undefined value`):

| 做法 | 结果 |
|---|---|
| 不发射函数体与闭包,绑定照常建槽并写 `null` | 2000 函数程序:`; deadfns: dropped=1999`,mono IR 29569 行,但 IR 非法(`use of undefined value '%r241'`) |
| 连整条 `let` 语句一起跳过 | IR 更小(13577 行 / 用户模块 751 行),同样非法(`'%t200'` / `'%t8196'`) |

两条路坏的位置都像**"某条指令落进了已被丢弃的汇点"**:失败点总是某个分支条件或临时量
"用了没定义的中间值",而不是语义错误。在小程序(t20)上删 0 个死函数时一切正常,说明问题出在
"最后一条语句/块收尾"与"该语句没有产出值"的组合上 —— 发射器的块/汇点记账要求每条语句走完
正常路径(包括 `emitBindingStore` 之后的收尾),跳过后面的指令会写进过期的汇点。

**结论**:这条优化需要先给发射器加一个"空语句/空值语句"的正规出口(或让块/汇点记账与语句
产出解耦),再重做;当前 HEAD 不含该优化。测量准备(2000 函数程序):单模块 `--emit-llvm`
原始 308,792 行 / 前端 16.2s / 链接 22.5s;删除后预计单模块 13.6k 行、用户模块 751 行。

## 98. 死函数删除落地(只对入口程序)(2026-10-30)

§97 的两条实现路径都被否掉了,原因不是判据,而是**发射器的记账**:把整条 `let` 语句跳过会让后续
指令落进已丢弃的汇点(IR 里出现"用了没定义的临时量")。可行的做法是**只跳过函数体与闭包,
绑定照常建槽并写 `null`** —— 每条语句仍走完正常路径。

作用域边界(§97 记录的那个坑):**只对入口程序**。编译器自己会按名字直调库函数
(`emitCallRegs("__build_standard_library")` / `__install_library` / `__process_args` …),
那些边不在 AST 里;第一版没管,把仍在被调的库函数删了,t20 直接段错误。库函数只经导出表被
用户看到,值用途都写在 AST 里,所以"入口程序"是安全边界。

判据(可证明无观察者):`value == 0`、`callee == 0`、非 moduleBody、无注解、未被赋值/重声明/导出/import。
debug 档(`--debug`)不跑这条(保守路线保留一切)。

实测(2000 个函数的程序,最后一行调用其中一个):

| | 原始 | 删除后 |
|---|---|---|
| `; deadfns: dropped=` | — | **1999**(保留被调的那个) |
| 单模块 IR | 452,799 行 | **200,926 行** |
| split 用户模块 IR | 16,940 行(实测未变,见下) | 16,940 行 |
| 前端(split) | 16,196ms | **12,640ms** |
| 链接 | 22,474ms | **12,483ms** |
| 输出 | 2014 | 2014(一致) |

用户模块 IR 没跟着降,是因为那 2000 条 `let` 仍各自发了一条"建槽 + 写 null"的语句(约 8 行/条);
真正降到 751 行需要"整条语句跳过",而那条路会破坏 IR(§97)。所以下一步的杠杆是**给发射器加
一个正规的"空值语句"出口**,让块/汇点记账与语句产出解耦 —— 那之后这 16,940 行才会消失,
前端和链接也才会再降一个量级。

## 99. 死函数删除:判据看着对,但引用计数漏边 —— 测试判死(2026-10-30)

§98 的实现(只跳过函数体与闭包)能跑通 2000 函数程序的度量,但**全量测试否掉了它**:

| 测试 | 结果 |
|---|---|
| debug/release 差分 | **5 个测试用例两档输出不同**(含 `t62_leaf_calls`) |
| selfhost | `inline-values` **段错误**(exit -11) |
| interpreter | 未跑完(自举先红) |

说明 `collectDirectRefs` 的"引用计数"漏掉了真实的引用边。已知它的口径:
- 只数 `Identifier` 读(`value`)与 `Call` 的 Identifier 被调者(`callee`);
- `Import` 子树整棵跳过;
- 泛型递归遍历所有 AST 属性。

可能漏掉的边(待逐个证实,不要猜):
1. `t59_inline_pure` / `t62_leaf_calls` 那类**被内联进调用点**的函数:调用点被 `inlineCandidates`
   替换后,原来的"被调"边在发射期才消失,删掉函数体后内联替换仍引用它的符号;
2. `inline-values` 段错误指向**闭包捕获/槽共享**:函数体没发射,但某个仍在发射的闭包捕获了它
   (捕获是 `Identifier` 读,理论上会被计数 —— 所以更像是"捕获发生在另一个同样被删的函数里,
   计数把它算作 `value`,于是两个函数互相保活失败/或都不计数");
3. `prepareStdCache` / 模块表这类**发射期构造的名字表**:它们按名字引用绑定,不走 AST 计数。

**结论:先别删函数体**。要重做的话,判据不能只靠 AST 标识符计数,应该改成"**该 bindId 在整棵
AST 里除自己的 Let 外没有任何出现**"(把 `callee` 也算出现,不再区分 value/callee)——保守但
不会漏边;或者等 §97 那条"空值语句出口"做好后,用发射期的使用表(而不是 AST)来判定。
当前 HEAD 不含该优化。

**更正(2026-10-30)**:上一节的"回滚"没有真正生效 —— `git checkout -- aot/qlangc.ql` 恢复的是**当时
的 HEAD**(`75ef9ba`,里面已经提交了这条优化),所以那次提交只回滚了文档与测试驱动,编译器仍带着
不健全的判据。现在用 `git checkout cbcd3f8 -- aot/qlangc.ql` 真正回滚,并以
`git diff cbcd3f8 HEAD -- aot/qlangc.ql` 为空作为判据(已核对)。教训:**回滚要指定基线提交,
不能只写 `checkout -- <file>`**(它默认回 HEAD)。

### 99.1 漏边到底漏在哪(实测,2026-10-30)

给判据加上"删了就打印名字"的探针后,直接看到它误删了**仍在使用的**函数:

| 测试用例 | 误删 | 实际情况 |
|---|---|---|
| `t23_inline_values` | `id` | `id` 被放进数组字面量 `[..., id, ...]` 后调用 |
| `t62_leaf_calls` | `late`、`b` | `late` 被**前面**定义的 `early` 调用;`b` 与 `a` 互递归 |
| `t59_inline_pure` | `callm` | 被调用 |

共同点:`late`/`b` 是"**先被调用、后定义**",`id`/`callm` 是"**作为值出现在容器/实参**"。
判据读的是 `collectDirectRefs` 给的 `value`/`callee` 计数,而这四种情形下计数都是 0 —— 说明扫描
漏的不是"次数",而是这些**位置**:后定义的调用点、容器字面量里的值、互递归边。

下一步(下一轮做):不依赖这两个计数器,而是**在扫描里显式记录"这个 bindId 在 AST 里出现过几次"**
(任何位置的出现都算,包括 Call 的被调者、容器元素、函数体内部),并要求出现次数 == 0 才允许删。

### 99.2 改用"出现次数"也救不了:根因是 bindId 不可靠(2026-10-30)

按 99.1 的结论换成"该 bindId 在整棵 AST 里除自己的 Let 外一次都没出现"的判据(逐节点数 `bindId`),
误删**没有消失**:`t62_leaf_calls` 仍删 2 个(`late`/`b`)、`t23_inline_values` 删 1 个(`id`)、
`t59_inline_pure` 删 1 个(`callm`)。说明这些引用点的 `Identifier.bindId` **根本不是被引用函数的
bindId**(多半是 -1 或另一个 id)——计数再严格也数不到边。

所以真正的根因不是"判据口径",而是:**AST 上的 bindId 在扫描阶段对"先调用后定义 / 容器里的值 /
互递归"这些位置还没有正确解析**。要用 AST 做引用分析,得先把绑定解析做成一个独立、完整的一趟
(给每个 Identifier 盖上唯一的 bindId),而不是依赖发射期按需解析。

在做到那一步之前,死函数删除不落地(连续三次尝试都被测试否掉)。当前 HEAD 的编译器与 `cbcd3f8`
逐字相同(`git diff cbcd3f8 HEAD -- aot/qlangc.ql` 为空)。

### 99.3 证据:前向引用在分析期就是 `bindId = -1`(2026-10-30)

给编译器加 `--dump-ids`(打印每个 `Let`/`Identifier` 的 `bindId`),对

```qlang
let a = (x) -> late(x) + 1;
let late = (x) -> x * 2;
println(a(3));
```

的输出是:

```
DUMP Let a bid=1
DUMP Identifier x bid=0
DUMP Identifier late bid=-1     ← 前向引用拿不到 id
DUMP Let late bid=3
DUMP Identifier a bid=1
DUMP Identifier println bid=-1
```

原因在 `types.ql:899`:`node.bindId = typeBindLookup(node.name)` —— **分析按位置解析词法作用域**,
`a` 的函数体里 `late` 还没进作用域,于是 -1;而 `types.ql:1249` 只有在 `typeCollectWrites` 时
才给 `Let` 分配 id,后续 pass 复用。**发射器不受影响**:它有一趟 `reserveModuleGlobals` 预先把
模块级名字全部占槽,所以运行期能正确解析——这也解释了为什么"程序能跑,但 AST 引用分析数不到边"。

所以要做 AST 级引用分析,必须新增一趟**模块级名字解析**(像发射器那样先把整个模块的 `let` 名字收齐,
再把所有 `Identifier` 解析到唯一 id,盖在**新字段**(例如 `refId`)上,不要动现有 `bindId` ——
后者被表示分析/unbox 依赖,改动会波及全部分析结论)。

在这之前,死函数删除不落地(三次尝试都被测试否掉,证据 §99/99.1/99.2/99.3)。

### 99.4 语义陷阱:形参注解在**闭包创建时**求值,所以"没人引用的函数"也可能有可观察行为(2026-10-30)

改用"按名字数模块级引用"(过近似,参数/局部同名也算)后,测试用例扫描 40/42 通过,只剩
`t37_extensions`(环境缺口)和 **`t53_return_boundaries`**。t53 的失败点是:

```
AssertionFailed: annotation slot propagates return   (t53:7:19)
```

被删掉的是 `annotationCase` 里的嵌套函数:

```qlang
let annotationCase = () -> {
  let identity = (value: if true { return Number; } else { Number; }) -> value;
  99;
};
check(annotationCase() == Number, "annotation slot propagates return")?;
```

`identity` 确实没人调用,但**形参注解是闭包创建时求值的表达式**,里面的 `return` 会让
`annotationCase` 当场返回 `Number`。删掉闭包创建这一步,`annotationCase()` 就返回 `99` —— 断言失败。

**语言事实**(值得单独记住):函数字面量的注解数组在**创建闭包时**求值一次,不是调用时。
所以任何"删掉没人引用的函数"的优化都必须排除**带形参注解**的函数;同理,`.annotations` 的
求值顺序也是可观察的(错误、副作用、`return`)。

本轮给该判据加上了"有形参注解就不删",但在 `collectDeadFunctions` 里没有生效(仍删了 `identity`),
原因待查(疑似 `fn.parameters` 在该节点上是 Error,导致检查被静默跳过)。**代码回滚到 `cbcd3f8`**,
四条证据留在 §99–§99.4。

### 99.5 第 5 次:extension 宿主段错误 —— 仍是"编译器按名字直连"这一类(2026-10-30)

按名字计数 + 排除带形参注解后,`t53/t62/t59/t23` 四个测试用例全部通过(`dropped=0`,输出正确),
差分测试套件 41 个测试用例全绿,selfhost(含固定点)、interpreter、assignment、gc、semantic 全绿;
但 **extension 测试套件段错误**(`host-O0` returncode=-11)。

与 §98 的库函数那次同源:extension 宿主里也有**编译器自己按固定名字直连**的东西(扩展桥
`__extension_bridge_*`、`__native` 注册回调等),那些边不在 AST 里,名字计数看不见。
所以判据还得再收一层:**排除编译器/运行时按名字使用的接口名**(或者干脆只在没有 extension 的
普通程序上启用,但这等于给优化加白名单,不是好规则)。

代码回滚到 `cbcd3f8`。五条证据(§97、99、99.1–99.5)已经足够说明:这条路要么做成"发射期使用表",
要么就必须把"编译器按名字直连的名字"完整列出来 —— 后者是白名单思路,和仓库"反对特判"的规矩冲突。

### 99.6 extension 那次到底是哪条边:被删的是 `path`,而它的名字在 AST 里从不出现(2026-10-30)

按名字计数 + 排除带注解形参后跑 extension 宿主,`; ql-symbol` 对比显示被删的是:

```
< ; ql-symbol path ql_fn302 0      ← 被删
< ; ql-symbol nested ql_fn304 0
> ; ql-symbol nested ql_fn303 0   ← 编号顺移
```

`path` 的定义是 `let path = () -> { pathCalls = pathCalls + 1; args[0]; };`,宿主里**没有任何
Identifier 叫 `path`**(所以 AST 计数=0);再加一趟发射期使用探针(`--dump-uses`,记录所有
`lookupSlot(name)`),`path` **也不在**"发射期用过但 AST 说 0"的名单里 —— 也就是说发射器自己
也从不按名字找它。

那两个可能都得留着验证:
1. **删它本身破坏了什么**(例如扩展桥按函数编号/符号顺序对齐);
2. **槽布局顺移**(`path` 少占一个槽,后面对齐全变)才是元凶 —— 证据:`nested` 的 `ql_fn` 编号
   从 304 变 303,说明删除会影响后续所有编号/槽号;而 extension ABI 里有 `__extension_args_slot`
   这类"把宿主槽位告诉插件"的机制。

**下一轮的决定性实验(便宜)**:不改判据,只在宿主里加一个**与扩展无关**的空函数
(`let unusedDummy = (x) -> x;`),让它被删、而 `path` 保留 —— 如果宿主仍段错误,就是"槽/编号顺移"
而不是"删了 path"。

本轮同样回滚到 `cbcd3f8`(判据:`git diff cbcd3f8 HEAD -- aot/qlangc.ql` 为空)。

## 100. 死函数删除落地:漏掉的边是"动态 import 的路径表达式"(2026-10-30)

§99.5 的 extension 段错误,经过两级实验定位到**一行扫描逻辑**:

1. 加一个与扩展无关的空函数让它被删(宿主照样段错误)—— 说明不是"槽/编号顺移";
2. 保留 `path`、只删空函数 —— **28 条契约全绿** —— 说明问题就是"删了 `path`"。

而 `path` 在宿主里的唯一调用点是:

```qlang
let p = import (path());          // 动态 import:路径表达式里调用 path
```

`countModuleRefs` 沿用了 `collectDirectRefs` 的 `if type == "Import" return null` —— **整棵 Import
子树被跳过**,于是动态 import 的路径表达式里的引用一条都数不到。去掉这条跳过后:
宿主 `dropped=0`(path 被正确保活),extension 测试套件 **ALL PASS**。

判据最终形态(只对入口程序):

```
value==0 且 callee==0                        ← 不再依赖(改成按名字数,见 §99.2/§99.3)
+ 名字在整个 AST 里除自己的 Let 外一次都没出现(含 Import 子树、容器元素、被调者)
+ 非 moduleBody、无 let 注解、**无形参注解**(注解在闭包创建时求值,§99.4)
+ 未被赋值/重声明/导出/import
```

实测(2000 函数程序,最后一行调用其中一个):

| | 原始 | 现在 |
|---|---|---|
| `; deadfns: dropped=` | — | **1999**(保留被调的那个) |
| 单模块 IR | 452,799 行 | **200,926 行** |
| 输出 | 2014 | 2014(一致) |
| t20 | — | dropped=0,输出 20 |
| extension 宿主 | — | dropped=0,28 契约全绿 |

debug 档(`--debug`)不跑这条(保守路线保留一切)。

## 101. 最终决定:不做编译期删除(2026-10-30,作者)

作者评估后决定:**不落地编译期删除**(死函数 / 闭包盒),理由是"太危险"——这条判断有实测支撑:

- 判据要覆盖的东西太多:动态 `import (expr)` 的路径表达式(§100)、形参注解在闭包创建时求值(§99.4)、
  编译器/扩展桥按名字直连的边(§98/§99.5)、`bindId` 对前向引用是 -1(§99.3);
- 任何一条漏掉,表现都是**段错误或两档输出不同**,而不是报错 —— 这类错误的代价远高于它省下的编译时间;
- 收益也有限:2000 函数程序单模块 IR 452,799 → 200,926 行、前端 −22%、链接 −44%,而**用户模块 IR
  仍有 16,940 行**(那 2000 条"建槽 + 写 null"的语句还在,要再降需要 §97 的"空值语句出口")。

因此 HEAD **不含**这条优化(`git diff cbcd3f8 HEAD -- aot/qlangc.ql` 为空),相关代码全部回滚。
如果将来还要做,前置条件按顺序是:

1. **发射期使用表**(谁被读过/被调用,由发射器自己记录,而不是 AST 计数);
2. 模块级名字解析(`refId`,独立一趟,不动 `bindId`);
3. 明确的"接口清单"(扩展桥、`__native` 注册这类按名字直连的边);
4. 差分测试套件 + 全量测试作为常规门(`run_debug_diff_tests.py` 已经在基线上)。

在此之前,`--debug`(保守发射)与 `release`(静态优化)两档的分工保持不变;编译速度的收益走
`mod.ql` 接口、标准库对象、`link --debug` 这些**不改变语义**的路子。

## 102. `--debug` 档的两个 IR bug(release 不受影响)+ 当前 debug/release 与系统语言的对比(2026-10-30)

**bug 1:`store %ql_value null`(非法 IR)**。`--debug` 会把 release 下被省略的注解检查发出来,而这些
路径里发射器用内部占位串 `"null"` 表示"没有这个值",它被原样写进了 `store`:

```
store %ql_value null, ptr %t195      ; llc: null must be a pointer type
```

正确零值是 `zeroinitializer`。三处 `store %ql_value`(绑定存储、注解数组、调用参数缓冲)都要过一遍
映射。release 不踩是因为这些检查多半被"可证不会失败"省略了 —— 这正是 debug 档存在的价值:它把
只在冷路径上的发射器 bug 变成必现。

**bug 2:修掉占位串后仍段错误**。保守路径发出来的程序跑到 100M 循环时 SIGSEGV(539ms 后崩),
说明还有一处"release 永远不会走、debug 必走"的发射路径是错的(候选:装箱直调/raw 之外的分派
兜底、`__call` 的被调者读取)。修完 bug 1 后仍崩,所以**当前 debug 档还不能用于测速**。

两个 bug 都只在 `--debug` 下出现,release 产物不变(判据:`git diff cbcd3f8 HEAD -- aot/qlangc.ql` 为空)。

### 102.1 当前能测到的数(release,本机 min-of-5)

构建 hello(编译+链接):

| | 时间 |
|---|---|
| clang -O2 | 750ms |
| rustc -O | 1025ms |
| **QLang release(前端 + `tools/link`)** | **1916ms** |

运行 100M 次 f64 累加(依赖链,同类型对照):

| | 时间 |
|---|---|
| Go(注:int64 求和,不是同类型) | 71ms |
| Rust f64 -O | 80ms |
| C f64 -O2 | 121ms |
| **QLang release** | **174ms** |

即 release 档:构建约为 clang 的 2.5×、rustc 的 1.9×;运行约为 C 的 1.4×、Rust 的 2.2×。
debug 档的数字**暂缺**(上面两个 bug),但方向明确:它是"全装箱 + 全间接调用 + 无 IR 优化",
运行会慢一个量级,编译只快 0.3s(链接档的 `opt` 那一趟)。

### 102.2 debug 档的确切症状(缩小到一条发射路径)

修掉 `store %ql_value null` 之后,debug 档能编译能链接,但**结果错在"表达式直接当实参"这条路径**上:

| 程序 | release | debug |
|---|---|---|
| `println(3);` | 3 | 3 ✅ |
| `let a = 1 + 2; println(a);` | 3 | 3 ✅ |
| `println(1 + 2);` | 3 | **0** ❌ |
| 100M 累加循环 | 174ms | **SIGSEGV** |

也就是"值先落绑定再打印"是对的,"表达式直接进实参缓冲"就错 —— 保守路径下 `println(...)` 走的是
通用 `__call`/`emitBorrowedCall`,实参缓冲那一段在 debug 下没有被正确填(ref 语义/写回不同)。
release 不踩是因为它把这些调用直接内联/直调掉了。

**结论**:debug 档目前不可用(结果错 + 段错误),但症状被缩到一条路径上,下轮修这一条即可。
代码回滚到 `cbcd3f8`(release 完全不受影响)。

### 102.3 `println(1 + 2)` 为什么变成 0:debug 走了"跨帧读取"那条慢路

同一份 `println(1 + 2)`,两档的 IR 在最外层语句上就分叉了:

```llvm
; release:直接从帧槽取实参
%t254 = getelementptr i8, ptr %t206, i64 16
%t255 = load %ql_value, ptr %t254

; debug:先取父帧,再对绑定指针做 absent(== null) 检查,分两支
%t254 = load ptr, ptr %t206
%t255 = getelementptr i8, ptr %t254, i64 208
%t256 = icmp eq ptr %t255, null
br i1 %t256, label %bb2, label %bb3
```

也就是说保守档把被调者/实参的读取从"同体直取"退化成"跨帧 + 缺失检查"的通用路径
(`emitIdentifier` 的 `!sameBody` 分支),而那条路在没有闭包/没有捕获的场景下取到的不是同一个槽。
release 不走它是因为调用被直调/内联掉了。

**下一步(修法方向)**:保守档不该改变*读取路径*的选择 —— 它只该决定"值怎么表示、调用怎么分派"。
即 `emitIdentifier` / `emitCallRegs` 里 `sameBody`/`depth` 这些"取哪个槽"的判断必须与 `conservativeMode`
无关;正在分派的那一层(直调 vs `__call`)才该受档位影响。这一条改完,`println(1 + 2)` 与 100M 循环
都应该恢复正确。

### 102.4 分叉点在**调用路径的选择**上,不在"槽定位"上(2026-10-30)

§102.3 的 IR 证据再追一层:两处代码都在**同一个函数** `@ql_fn301`(入口 `main`)里,但

| | 实参/被调者的读取 |
|---|---|
| release | `gep i8, ptr %t206, i64 16` → 直接读**当前帧**槽 1 |
| debug | `load ptr, ptr %t206` → 取**父帧**,再 `gep i8, ptr %t254, i64 208` → 父帧槽 13 |

`+16` vs `+208` 差 12 个槽,说明 release 走的不是"按名字查 `println`"这条路,而是**直调/受信任**
那条(它把实参放在当前帧的固定位置);debug 没直调,于是回到"把 `println` 当普通绑定读"的通用
`__call` 路径 —— 而在模块顶层,`println` 是**全局绑定**(父帧槽 13),那条通用路径读到的环境和
release 完全不同,拿到的是 0/null。

**所以修法要改的是 `emitBorrowedCall` 在顶层对"被调者标识符"的求值**(它应该直接按全局槽读,
和 `emitIdentifier` 对全局名的既有解析一致),而不是去动 `sameBody`/`depth` 这些判断 ——
§102.3 里"槽定位与档位解耦"的说法要修正为"**通用调用路径对全局被调者的求值**是错的"。

### 102.5 试了"接口直调目标穿透保守档",无效 —— 反证出真正的问题(2026-10-30)

按 §102.4 的推断做了第一个修法:给 `loadStdlibInterfaceMod` 播种的直调目标打 `fromStdlib`,
让它在 debug 档也生效(理由:那是 split 模式调库函数的**约定**,不是用户代码优化);并把
"同名声明让旧目标失效"提到档位之外。结果:

| 程序 | debug |
|---|---|
| `println(3)` | 3 ✅ |
| `let a = 1 + 2; println(a)` | 3 ✅ |
| `println(1 + 2)` | **仍然 0** ❌ |

但这次的**计数器**给了决定性线索:

```
release: ; directreject: nohit=0 notable=0 noinfo=2 assigned=0 arity=0 args=0 ann=2
debug  : ; directreject: nohit=0 notable=0 noinfo=4 assigned=0 ……
```

`noinfo` 表示"表存在、但里面没有这个名字"。也就是说 debug 档查的**不是同一张表**:
`lookupSlot("println")` 在 debug 下落到**更深的那一层作用域**(全局作用域,深度 1),那层的
`directFns` 没有库接口的条目 —— 这与 §102.4 的 IR 证据(`load ptr, ptr %frame` 取父帧、
再读父帧槽 13)完全吻合。

**所以:
- 顶层 `println` 在 release 下解析到**模块作用域**(深度 0),debug 下解析到**全局作用域**(深度 1);
- 根因不在"调用分派",而在**同一份程序两档的作用域/槽解析结果不同** —— 也就是 §102.3 的原判断
  ("取哪个槽的决策不该随档位变化")方向是对的,只是没找到是哪一处让 `lookupSlot` 少了一层。

下一轮查:两档的 `curScope` 链在入口程序发射时是否相同(`emitFrame`/`reserveModuleGlobals`/
`emitModuleStd` 里有没有随 `allowDirectUserCalls` 变化的分支),以及 `lookupSlot` 的
`publicRuntimeNames` 过滤是否在两档给出不同结果。

### 102.6 `--dump-lookup` 探针:两档都先 depth=1、后 depth=0,但次数不同(2026-10-30)

给 `lookupSlot` 加探针(`--dump-lookup` 打印 `名字 depth=... module=...`)后,`println` 的序列是:

```
release: depth=1, depth=0, depth=0, depth=0
debug  : depth=1, depth=0
```

也就是:两档都在"模块 std 初始化"阶段先命中全局(depth=1),随后**各有 depth=0 的命中**;
差别是 release 有 3 次、debug 只有 1 次。所以 debug 的调用点并没有完全"落到全局",
更可能是**调用点之前的某一步**(std 缓存槽的建立/读取)少走了两次模块作用域查询,
于是调用点读到的帧/槽与 release 不同源。

下一步的探针要能**归属到具体语句**:在 `emitExpr`/`emitCall` 入口打一条 `STMT <行号>:<类型>` 标记,
再和 `LOOKUP` 交错看,就能确定 debug 那次 `println` 调用读的是哪个槽。这是纯观测,不改语义。

本轮结论:修法仍未落地;确认"两档作用域解析不同"是根因方向,且需要语句级归属的探针才能定位。
代码回滚到 cbcd3f8(release 不受影响)。

### 102.7 关键观察:`%t206` 是模块帧,debug 却从**父帧**读 `println`(2026-10-30)

把 §102.6 的 IR 再对一遍定义:

```llvm
%t206 = alloca i8, i64 272          ; 模块帧(272B = 17 个槽)
...
%t254 = load ptr, ptr %t206          ; ← 帧偏移 0 = 父帧指针
%t255 = getelementptr i8, ptr %t254, i64 208   ; 父帧(全局帧)槽 13
```

`reserveModuleGlobals()` 会把 `$exports`(0)、`std`(1) 和 `moduleGlobalNames` 全部
`defineSlot` 进**模块作用域**(里面就有 `println`),所以 `lookupSlot("println")` 本该 depth=0;
debug 却拿到了 depth=1。两种可能:
1. 进入发射时 `curScope` **不是**模块作用域(而是全局作用域),`reserveModuleGlobals` 没生效;
2. `reserveModuleGlobals` 生效了,但**条目被后来的 `defineSlot`/invalidate 覆盖**。

**关键的下一步(1 个探针 + 1 个修法)**:
- 探针:发射第一条语句前,打印 `curScope.moduleRoot` 与 `curScope.slots["println"]`,
  以及 `curScope.parent` 上是否有同名槽 —— 一次就能分辨是 1 还是 2;
- 修法:无论哪条,方向都是"入口程序的 `curScope` 建立/全局保留"必须与档位无关
  (`emitModule` 的入口段里不该有随 `allowDirectUserCalls` 走的分支)。

本轮没再改代码(避免又改错地方):HEAD 与 `cbcd3f8` 的编译器逐字相同,release 不受影响。

### 102.8 探针结果:入口处两档作用域**完全相同**(own=20 / parent=55),分叉发生在发射过程中(2026-10-30)

在 `reserveModuleGlobals()` 之后打印作用域状态:

```
mode=[release] SCOPE moduleRoot=true own=20 parent=55 isRuntime=false
mode=[--debug ] SCOPE moduleRoot=true own=20 parent=55 isRuntime=false
```

两档一模一样:`println` 在**当前作用域是槽 20**,全局(父)作用域另有一个槽 55。所以：

- 不是"`curScope` 不是模块作用域"(§102.7 的解释 1 排除);
- 也不是"条目被覆盖"(解释 2 排除);
- 那 debug IR 里读的**父帧 + 208(=槽 13)** 其实**不是 `println`** —— 它读的是别的东西
  (槽 13 在模块作用域是另一个名字),只是位置恰好出现在 `println(1+2)` 附近。

所以分叉发生在**发射语句的过程中**:某个 helper(大概率是"检查用的注解/参数缓冲"那段,debug 档
才会走到)在**另一个 `curScope` 上下文**里发了读取,而它读到的槽位是按那个上下文的编号算的。

**下一步(一个小探针就能收口)**:在 `emitIdentifier` 里打印 `(名字, depth, curScope==模块作用域?, 槽号)`,
只在该名字是 `println` 或槽号 > 200 时打印;同时给 `emitCall` 打 `STMT` 标记。两者交错就能看出
debug 那次 `+208` 的读取是**哪条语句、哪个作用域**发的。

本轮无代码改动(探针已回滚):编译器与 `cbcd3f8` 逐字相同。

## 103. debug 档修好了:分水岭是"没有注解 ≠ 检查 null"(2026-10-30)

前六轮追查的结论收敛成一处语义误解。`emitAnnotatedCheck` 收到的是 `ty`/`text` 两个**可能是内部
占位串 `"null"`** 的值(表示没有注解/没有文本)。原来的写法把占位串直接当 `%ql_value` 写进 IR:

```llvm
store %ql_value null, ptr %t195     ; llc: null must be a pointer type
```

正确语义不是"对 null 做检查",而是"**没有注解就没有检查**":

```qlang
if ty == "null" { return value; };        // 无注解 ⇒ 不发检查
if text == "null" { text = emitNull(); }; // 有类型但没有文本 ⇒ 文本用真正的 null
```

这两个占位串只在 release 下被省略检查时躲过去了,debug 档必走 —— 所以它一露头就是非法 IR 或段错误。
(中途我试过"把所有 `null` 映射成 `zeroinitializer`,更错:t20 立刻报 `TypeCheck: type annotation is
not a type value`,因为那等于"用一个 null 类型值去做检查"。)

### 103.1 验收(全部同源)

- `println(1 + 2)` → **3**;t20 → **20**;t30 → `string checks: 193`;100M f64 累加 → `4999999950000000`
- `run_debug_diff_tests.py`:**41 个测试用例两档输出逐字节相同**
- selfhost(含 stage2/stage3 IR 固定点)、interpreter:**ALL PASS**
- release 不回退:t20 的 `--emit-llvm` IR 与基线**逐字节相同**;IR 行数 release 184,842 / debug 186,523(+0.9%)

### 103.2 debug vs release 实测(本机 min-of-3)

| | release | debug |
|---|---|---|
| 构建 hello(前端 + 链接) | 2813ms | **2527ms**(−10%) |
| 运行 100M f64 累加 | 414ms | **709ms**(+71%) |
| 用户模块 IR 行数 | 184,842 | 186,523 |

同机对照:C `-O2` 100M = 336ms、Rust `-O` = 183ms。即 **release ≈ C 的 1.23×、Rust 的 2.3×;
debug ≈ C 的 2.1×、Rust 的 3.9×**。debug 只快 10%(省的是 `opt` 那一趟 + 少量发射),
因为它**只关掉优化、不省前端**;运行慢 71%,因为直调/装箱/检查全是通用路径。

## 104. module 测试套件脱离 Rust:改用 stage2 + tools/link + native 解释器(2026-10-30)

`aot/run_module_tests.py` 原本两条腿都依赖 Rust 宿主(`target/debug/qlang`):
`--compile` 编程序、跑 `bootstrapped/run_file.ql` 当 boot 参照。而 AGENTS §2.1 记录"Rust 宿主跑 boot
会挂",这测试套件因此在基线上一直是**环境缺口**(180s 超时)。

改成纯 QLang 工具链:

| 用途 | 原来 | 现在 |
|---|---|---|
| 编程序 | `qlang --compile` | `stage2 --emit-llvm` + `target/tools/link` |
| boot 参照 | `qlang bootstrapped/run_file.ql` | **native 解释器**(stage2 编 `run_file.ql` + tools/link,缺则自动构建) |
| Rust 对照腿 | `QLANG_CHECK_RUST=1` | 删除 |

顺带修正两处**与语言契约不符的断言**:

1. `boot_output` 原来要求退出码 0;t15 最后一条语句把 String 赋给 Number 注解会产生未处理 Error
   ⇒ 契约是 **exit 1**。现在只取"程序自身输出"(截到 `Execution complete.` 之前),退出码单独断言。
2. native 腿同样放宽到 `(0,1)`,但输出必须与解释器逐字节相同。

**结果:`Module suite: ALL PASS`**(BOOT/NATIVE、输入删除后执行、3 类 cycle、6 类拒绝用例)。
这测试套件现在只依赖 QLang 自己的编译器/链接器/解释器,不再需要 Rust。

## 105. LTO 档的实测:在这类代码上不划算(2026-10-30)

`--lto` 的链接链是 `llvm-link(用户 IR + stdlib.bc) → opt lto<On> → llc → ld.lld`。拿 100M f64 累加
测三档:

| | 链接 | 运行 |
|---|---|---|
| 非 LTO(`--stdlib-object`) | **2308ms** | **347ms** |
| LTO `--lto-opt 0` | 5581ms | 883ms |
| LTO `--lto-opt 1` | 10196ms | 532ms |
| LTO `--lto-opt 2`(发布默认) | 11654ms | 378ms |

结论:**数值型代码根本不需要 LTO** —— 非 LTO 已经最快(347ms)且链接只要 2.3s;LTO 只是把链接时间放大
2.4–5×。LTO 的价值在**闭包搬运型** benchmark(probes §22–§29 记录过 b_chars:`.o` 2.31s → `--lto` 0.62s),
那类代码靠跨模块内联把库函数体塞进用户循环。

所以:
- **不改默认**(发布仍是 `--lto-opt 2`,给闭包型负载用);
- 数值型/命令行工具类程序的推荐档是**非 LTO**;
- 文档里"发布一律 --lto"的说法要按负载分,不能一刀切。

## 106. `--check`:只报诊断、不产出,并把结论缓存成 sidecar(2026-10-30)

作者选的方案 B:**走完整的 parse/分析/发射,但不落地**。理由:用户诊断有一部分是**发射期**产生的
(`addCompileError`),如果"停在分析之后",check 与 build 就有两条诊断路径,迟早出现"check 绿、build 红"。

实现(三处钩子,全在 `aot/qlangc.ql`):

1. `--check` 开 `checkMode`;
2. `emitLine` 顶部短路 —— 发射照常跑(所以诊断与真编译一模一样),只是不写 stdout;
3. `checkMode` 成功时写 sidecar `<src>.qcheck`;入口处若 sidecar 与当前"源码 hash + 环境"一致,**直接返回**。

sidecar 格式(行式,不引入 JSON):

```
v1
source=<sha256(源文件) 全文>
env=<stdlib 目录名>          # 它本身就是 (编译器字节 + runtime + bundle) 的哈希 ⇒ 换编译器/换库自动失效
verdict=ok
```

**只缓存 `ok`**:有错一律不缓存(错误要每次重报)。所以最坏情况是"少用缓存",不会给出错误结论。

### 106.1 实测(t30)

| | 时间 |
|---|---|
| 完整构建(前端 + 链接) | 4575ms |
| `--check` 首次 | **993ms**(4.6× 更快) |
| `--check` 缓存命中 | **176ms**(26×) |
| 改一行源码后 | 1363ms(正确失效、重新检查) |

正确性:`println(missing);` 在 `--check` 下与 build **报同一句诊断**、同样 exit 1、stdout 为空;
release 的 `--emit-llvm` IR 与基线**逐字节相同**(checkMode 默认关)。

## 107. L2:`--ir-cache` 把发射产物也缓存起来(opt-in)(2026-10-30)

L1(诊断结论)已经在 `--check` 里落地(§106)。L2 缓存的是**用户模块 IR 本身**:
`<src>.qir` = 头(`v1 / source=<sha256> / env=<stdlib 目录名>`) + `---` + IR 正文。

命中时**直接回放文件**,跳过 parse/分析/发射,只剩链接。实现仍是三处钩子:

1. `--ir-cache` 开头(`irCacheOn`);
2. `emitLine` 顺手把 IR 收进内存数组;
3. 入口比对头 → 命中就 `print` 正文并 return;成功发射后把正文写回(上限 40 万行)。

### 为什么必须 opt-in

固定点测试里 stage2 与 stage3 **共用同一个 stdlib 目录**(它按 stage1 字节做键),所以 env 相同;
如果默认开缓存,stage3 就会直接回放 stage2 的 IR —— 固定点断言会变成空断言。所以默认关,
只有显式 `--ir-cache` 才启用;测试与固定点永远不传这个开关。

### 实测(t30,机器当时负载偏高,看比值)

| | 时间 |
|---|---|
| emit 冷 | 1552ms |
| emit 命中(回放) | **323ms** |
| 完整构建(命中 + 链接) | 25715ms |
| 完整构建(不走缓存) | 85283ms |

**正确性**:缓存回放的 IR 与正常发射**逐字节相同**,产物输出 `string checks: 193` 正确。

剩下的空间:链接仍是瓶颈(见 §95/§105:`opt`+`llc`+`ld.lld` 各有进程启动成本)。
L2 把"发射"这段消掉之后,下一个可做的才是把编译产物(`.o`)也缓存,做到"源码没变 → 连链接都跳过"。

## 108. 测试驱动也能不依赖 Python:`aot/run_tests.ql`(2026-10-30)

工具链早就没有 Rust 也没有 Python(`aot/build.ql` 写在文件头:"全程 QLang,不调用 Python"),但**测试驱动**
还是 27 个 `aot/run_*.py`。现在有了 QLang 版:

```
stage2 --emit-llvm aot/run_tests.ql aot/runtime.ql > /tmp/rt.ll
tools/link /tmp/rt.ll -o /tmp/rt
/tmp/rt target/stdlib/<key>            # 或 run_tests --compiler <c> <stdlib-dir>
```

它按 `aot/tests/manifest.txt`(一行一个用例名)逐个:发用户模块 IR → `tools/link` 链接 → 跑 → 与
`.expected` 逐字节比对;没有 `.expected` 的用例只要求能编能跑。**全程只调 QLang 自己的二进制。**

结果:**57 通过 / 0 失败**。唯一没纳入的是 `t37_extensions` —— 它要现建 `.so` 并传一串路径,
属于 extension 专属测试(见 §104 与 `run_extension_tests.py --tmp`),单独跑。

为什么用显式清单而不是扫目录:QLang 没有目录列举原语(`std.fs` 只有读写),所以清单是显式文件;
漏登记的用例不会被跑到,改夹具时要记得加一行。

## 109. 连 `bundle.ql` 的重建也不需要 Rust 了:把构建脚本编成原生工具(2026-10-30)

`stdlib/bundle.ql` 一直是用 **Rust 宿主**跑的:`./target/release/qlang stdlib/build_bundle.ql`。
两条路都试过:

| 做法 | 结果 |
|---|---|
| native **解释器**跑 `build_bundle.ql` | **600s 超时**(只出了 12 行输出)——解释执行跑这种"读一堆文件再拼接"的脚本太慢 |
| **先把它编成原生二进制**再跑 | **秒级完成,产物与 Rust 宿主逐字节相同** |

后者就是 QLang 自己的路:

```
stage2 --emit-llvm stdlib/build_bundle.ql aot/runtime.ql > /tmp/bb.ll
tools/link /tmp/bb.ll -o /tmp/bb
/tmp/bb > stdlib/bundle.ql          # 重建
/tmp/bb --check                     # 校验(exit 0 = 未过期)
```

实测:`/tmp/bb` 的输出与 `stdlib/bundle.ql` **逐字节一致**,`--check` 通过。

**结论**:工具链、标准库对象、bundle 重建、原生测试用例,现在全部可以只用 QLang 二进制完成;
Rust 只剩"初始 bootstrap"(第一次把编译器带上路)这一件事。

## 110. QLang 测试驱动现在也能跑解释器套件(2026-10-30)

`aot/run_tests.ql` 加了 `--interpreter`:

```
/tmp/rt2 <stdlib-dir>              # 原生用例:发 IR → 链接 → 跑 → 比对   57 通过 / 0 失败
/tmp/rt2 <stdlib-dir> --interpreter # 解释器用例:编 boot → 跑 → 比对     40 通过 / 0 失败
```

解释器模式先确保 `target/native-interpreter/interpreter` 存在(缺则 `stage2` 编
`bootstrapped/run_file.ql` + `tools/link`),然后按 `aot/tests/interpreter.txt` 逐个跑,
把输出剥掉 `Interpreting...` / `Execution complete.` 外壳再与 `.expected` 比对。

用例清单仍是显式文件(QLang 没有目录列举原语):`aot/tests/manifest.txt`(原生 57 个)、
`aot/tests/interpreter.txt`(解释器 40 个),都从原 Python 驱动的列表导出。

至此原生与解释器两类主测试都能只靠 QLang 二进制跑;剩下仍要 Python 的是 selfhost(固定点 +
并行)、extension(现建 `.so`)、module(多文件)、String(Unicode 预言机)、bench 与时序探针。

## 111. `std.process.spawn/wait`:QLang 终于能并行起子进程(2026-10-30)

探针先确认了限制:两次 `std.process.run(["sleep","0.3"])` = **810ms**(串行),因为
`runtime.c` 的 `ql_spawn` 在 `fork`/`execvp` 之后直接 `while (waitpid(...))` —— 叶子自己会阻塞。

补上的机制(四通道里的 1 号:C 宿主原语 + 4 号:程序可见的 std 面):

| 层 | 新增 |
|---|---|
| `aot/runtime.c` | `ql_spawn_async(argbuf, nargs, out, err)`(同样重定向,不 wait,返回 pid)、`ql_wait(pid)`(状态编码与 `ql_spawn` 相同) |
| `aot/runtime.ql` | `std.process.spawn(args) -> { pid, out, err }`、`std.process.wait(h) -> { status, stdout, stderr }`;`std.process` 变成 `{ run, spawn, wait }` |
| `aot/qlangc.ql` | 叶子白名单、调用签名表、前置声明三处登记 |

**引导顺序是个坑**:新叶子要先被"知道",但旧编译器不认识 `ql_spawn_async`,直接用它编新
`runtime.ql` 会报 `undeclared name`。正确顺序是两步:

```
旧编译器 + 旧 runtime.ql → C1(知道新叶子,但装着旧 runtime)
C1 + 新 runtime.ql       → C2(知道新叶子,装着新 runtime)
```

实测(两个 `sleep 0.3`):

| 写法 | 墙钟 |
|---|---|
| `run` 两次(串行) | 810ms |
| `spawn` 两次再 `wait` | **538ms** |

并行确实生效(差值就是省下的 300ms;剩下的是两次 fork/exec 的启动成本)。判据用例
`aot/tests/t63_async_process.ql`:并发起两个子进程再收输出(`ab`),并验证 `wait` 拿到
退出码(`exit 3` → `3`)。

## 112. 自举测试驱动也 QLang 化了:并行跑用例 + 固定点(2026-10-30)

有了 `std.process.spawn/wait`(§111),就能写 `aot/run_selfhost.ql`:

```
run_selfhost <stdlib-dir> [--compiler <c>] [--jobs <n>] [--no-fixed-point]
```

- **并行**:每个用例交给 `sh -c` 子进程做"发 IR → 链接 → 跑",驱动只调度与比对;
  用 `--jobs N` 控制同时在跑的个数(默认 4)。
- **固定点**:驱动自己发一份编译器 IR 并链接成 stage2',再让 stage2' 发一份,两份**逐字节比较**。
- **清单**:`aot/tests/selfhost.txt`(55 个)。比原生清单少三个多文件 import 用例
  (t13/t14/t15)—— 它们在 split 模式下要模块图,不属于自举要验的东西(那三条由 module 测试覆盖)。

实测:`--jobs 6` → **56 通过 / 0 失败**(55 个用例 + 1 个固定点),总耗时约 8 分钟
(其中固定点本身要两次编译编译器 + 一次链接)。

注意:它用的是 `stdlib-dir` 里的对象,所以**新增宿主叶子后要先重建标准库对象**
(否则新 API 在旧对象里不存在,用例会在 `(cmd)` 上失败 —— t63 就是这么被抓到的)。

## 113. debug/release 差分驱动也 QLang 化了(2026-10-30)

`aot/run_diff.ql`:

```
run_diff <stdlib-dir> [--compiler <c>] [--jobs <n>]
```

每个用例由 `sh -c` 子进程编两档(release / `--debug`)并各跑一次,驱动用 `spawn/wait` 调度、
比对两份输出(有 `.expected` 时再比一次)。判据仍是"两档逐字节相同"。

清单统一成 `aot/tests/split.txt`(55 个):比原生清单少 t13/t14/t15 三个**多文件 import** 用例 ——
它们在 split 模式下需要模块图,不是这两套测试要验的东西(由 module 测试覆盖)。原来自举用的
`selfhost.txt` 并进这个文件,两个驱动共用一个清单。

实测 `--jobs 6`:55 通过 / 0 失败;`--jobs 4` 时 79 秒(110 次编译 + 110 次链接)。

坑:`tools/link` 的 `-o` 若指向一个**已存在的目录**(我的探针里 `/tmp/rd` 正好是个目录),
会在 shell 里报 `Permission denied` 而不是"输出路径非法"。换名字即可。

## 114. 基准驱动也 QLang 化了(2026-10-30)

`aot/run_bench.ql`:

```
run_bench <stdlib-dir> [--compiler <c>] [--runs <n>]
```

按 `aot/bench/benches.txt`(6 个 bench)逐个测**构建耗时**(单模块 / 标准库对象)与**运行耗时**
(各跑 n 遍取平均,顺便比对两者输出是否一致)。全程只用 QLang 二进制。

计时用 `date +%s%N` 子进程:本机 `/proc/uptime` 是冻结的,`/proc/self/stat` 只反映本进程 CPU,
量不了子进程墙钟;运行耗时用"一次测量跑 n 遍"摊掉子进程开销(~25ms)。

一次实测(`--runs 3`,机器当时负载很高,只看比值):

| bench | 单模块构建 | 对象构建 | 单模块运行 | 对象运行 |
|---|---|---|---|---|
| b_build | 41.6s | **2.4s** | 5.1s | 12.9s |
| b_calls | 55.2s | **2.7s** | 300ms | 308ms |
| b_chars | 41.7s | **3.2s** | 895ms | 3.2s |
| b_index | 42.9s | **2.7s** | 945ms | 3.0s |
| b_strat | 42.3s | **2.9s** | 2.6s | 6.8s |
| b_untyped_calls | 39.5s | **1.8s** | 398ms | 1.1s |

结论与 §22–§29 一致:**构建快 12–20 倍**,运行则闭包/字符串密集型的慢 1.5–5×
(要走 LTO 才追平,§105 记了 LTO 的代价)。六项输出全部一致。

注意:这台机器负载波动极大(同一命令在不同时刻能差 5–10 倍),绝对值只作同一次运行内的相对比较。

## 115. `tools/link --root <repo>`:从任意 cwd 都能链接(2026-10-30)

之前链接器有三处**仓库相对路径**(`aot/runtime.c`、`aot/toolchain/<target>.cfg`、默认的
`target/tools/verify`),所以调用方必须先 `cd` 到仓库根 —— QLang 写的驱动因此都得在 `sh -c` 里
`cd` 过去,再拼绝对产物路径,很容易写错(extension 驱动就是卡在这上)。

加了 `--root <dir>`:三处都按它解析,加了 `--root` 后从 `/tmp` 链接 t20 验证通过(输出 `20`)。
默认空 = 保持原行为(相对 cwd)。

用法:

```
tools/link <ir> -o <out> --root <repo> --stdlib-object <obj> ...
```

这样驱动可以只拼绝对路径,不必再 `cd`,也顺手消掉了"必须在仓库根跑链接"这个隐性约束。

## 116. 扩展(native .so)测试驱动也 QLang 化了(2026-10-30)

`aot/run_extension.ql`:

```
run_extension <tmp-dir> --root <repo> [--compiler <c>]
```

完整的 28 契约,全程 QLang 二进制:

1. **宿主先编**:扩展还不存在时就发 IR 并链接成 `host-O0`/`host-O2`(证明扩展是运行期加载);
2. **四个独立扩展** `plugin`/`second`/`failure`/`cycle`:`--emit-module` 出 IR,再 `--shared` 链接成 `.so`(两档优化);
3. **三个负例**:`wrong-abi`(把 IR 里 ABI 字符串 `\71\6C…\76\31` 改成 `…\76\39`)、
   `no-entry`(把 `@qlang_extension_init_v1(` 改成 `@not_the_entry(`)、
   `not-native`(直接写一个文本文件当 `.so`);
4. **删掉源码**再跑宿主,与 `.expected` 逐字节比对。

实测:**2 通过 / 0 失败**(宿主 O0/O2 各跑一次,各 28 契约)。

三个容易踩的点(都在这轮踩到了):
- `tmp-dir` 必须是 **dlopen 允许的路径**(Android 上 `/tmp` 会被 linker 拒绝);
- 链接必须带 `--root <repo>`(§115),否则从别处链接读不到 `aot/runtime.c` 与 toolchain 模板;
- `cycle.so` 必须**拷到 `<work>/source/cycle.so` 并按那个路径传**:宿主是用 `import(路径)` 触发重入来
  验证 `ImportCycle` 的,传 `cycle-O0.so` 会让这条检查失败(计数仍是 28,但有一条 FAIL)。

## 117. String 套件:预言机那一段**故意**留在 Python(2026-10-30)

其余套件都 QLang 化了(§108–§116),这一个我建议**不搬**,理由是它和别的驱动不同:

`stdlib/run_string_tests.py` 有两条腿:

1. **夹具腿**:跑 `t30_strings.ql`(原生 + boot),与 `.expected` 比对 —— 这条**已经在 QLang 驱动里**
   (`aot/tests/manifest.txt`、`interpreter.txt`、`split.txt` 都含 t30,一直输出 `string checks: 193`);
2. **独立预言机腿**:用 **Python 的 `unicodedata`(钉住 15.1.0)** 遍历全部 Unicode 标量,
   挑出 `upper`/`lower` 有非恒等映射的字符,生成一个 QLang 程序并算出期望输出,
   再与两引擎的实际输出逐字节比对。

第 2 条的价值恰恰在于**它不复用 QLang 自己的表**(`stdlib/unicode_data.ql`)。把它改写成 QLang,
就变成"用 QLang 的 UCD 表去验证 QLang 的 UCD 表"——**循环论证**,测试会恒绿,再也不会发现表错。
所以这里保留 Python 是**设计决定,不是欠债**;真要脱离 Python,得引入**第三方**的 Unicode 数据
(比如另一份 UCD 快照、或 ICU 的产物),那才保持独立性。

结论:不要"顺手把它也 QLang 化"。要动就动数据来源,不动驱动语言。

## 118. Unicode 权威数据已入库;QLang 参照实现首次尝试段错误(2026-10-30)

作者的要求:**参照实现不许依赖一点 Python**。golden file 与"Python 生成的表"都达不到这条线,
所以只有一条路 —— 读 **UCD 原始文本**(由 Unicode Consortium 发布的一手数据)。

已入库 `third_party/ucd/15.1.0/{UnicodeData,SpecialCasing,PropList}.txt`(共 2.0 MB),
`README.md` 记了官方 URL、版本、下载日期与三个 SHA-256。这是**权威数据**,不是我们的记录。

随后写了 `aot/unicode_oracle.ql`(读 UCD → 与运行时的表驱动实现逐码点比对),
编译通过,但**首次运行即段错误**(exit 139,无输出)。当前怀疑点:

- `std.String.fromCodePoint` 在边界值上的行为(代理区 `0xD800..0xDFFF`、或 0/越界);
- `std.String.codePointAt` 的索引语义(它按码点还是按字节?)用在 ASCII 十六进制串上时;

排查方式(下一轮):把语料切成"前 N 行"二分,先定位是**哪一条 UCD 记录**触发崩溃,
再判断是 `fromCodePoint` 的 bug 还是我用错了 API —— 两种都要记进本文件。

半成品已删除(不留未验证代码);数据与本文保留。

### 118.1 运行时解析 UCD 太慢(2026-10-30)

把范围缩到 U+0020..U+2FFF 再跑(`aot/unicode_oracle.ql` v2):不再段错误,但**跑不完** ——
10 分钟没有输出,只能杀掉。也就是说"每次测试都现读 1.9 MB `UnicodeData.txt` 并逐行 split"这条路
在 QLang 里不可行(35k 行 × `split(";")` + `trim` + `fromCodePoint` 的分配量远超预期)。

这也解释了 §118 的段错误与它无关:那是**另一件事**(很可能 `fromCodePoint(0)` 构造含 NUL 的字符串)。

结论:**参照实现不要现读完整 UCD**。可行做法是入库一份**预筛子集**(只含目标范围内的映射,
约 3k 行、几十 KB),生成它用 POSIX 工具(`awk`/`sed`,**不是 Python**),并把命令与源文件
SHA-256 记在子集的头部注释里 —— 这样权威性仍然追溯到 UCD 原文,而运行时只做小文件解析。

半成品已删除;数据与本节保留。

## 119. Unicode 参照实现跑通了:2450 条主流映射 0 处不一致(2026-10-30)

按"先做主要的"收敛之后,参照实现成立了:

- 数据:`third_party/ucd/15.1.0/case-common.txt`(2450 行,U+0020..U+2FFF 里有大小写映射的码点),
  由 §118 入库的 UCD 原文用 **POSIX awk** 派生(命令写在同目录 README 里,**不用 Python**);
- 参照:QLang 程序直接读这个子集,与运行时(`unicode_data.ql` 表)逐码点比对;
- 结果:**upper 1205 / lower 1249 → 0 处不一致**。

### 踩到的两个 API 事实

1. `std.String.codePointAt(s, i)` 在这条路径上返回 `?Error`(签名/语义与直觉不符)⇒
   解析十六进制改用 `std.String.at` 查表。这也解释了 §118 的"段错误/无输出"很可能不是崩溃,
   而是同一处调用链拿到了错误值后走了别的分支。
2. `std.String.toLowerCase("İ")`(U+0130)给 `i + U+0307`,而 `UnicodeData` 的**简单**映射是 `i` ——
   因为 QLang 实现的是**完整大小写映射**(`SpecialCasing.txt` 的口径)。所以参照实现要先排除
   `SpecialCasing` 里出现过的 112 个码点;否则会把"我们做对了"报成"不一致"。

### 还缺什么(冷门,先不做)

- `SpecialCasing` 的完整/上下文映射(尾 sigma、`ß→SS`、土耳其语)没有独立参照;
- 辅助平面(>U+FFFF)与代理区未覆盖;
- `White_Space`/`trim` 的参照没并入这一版(PropList 已入库,随时可加)。

## 120. Unicode 参照加上 White_Space/trim:25 个成员全对(2026-10-30)

数据 `third_party/ucd/15.1.0/whitespace.txt`(25 个码点,从 `PropList.txt` 用 awk 派生,命令在 README)。
检查三条:

1. 每个成员 `trim(ch) == ""`;
2. **首尾**:`trim(ch + "a") == "a"` 且 `trim("a" + ch) == "a"`;
3. **中间不该被删**:`trim("a" + ch + "a") == "a" + ch + "a"`(第一版我把这条写成了 `== "aa"`,
   于是把"做对了"报成不一致 —— trim 只处理首尾,这是它的定义)。

结果:`upper 1205 / lower 1249 / White_Space 25 → 0 处不一致`。

顺带一个 awk 的坑:`split(s, arr, "..")` 的第三个参数是**正则**,`..` 会匹配任意两个字符 ——
解析 `0009..000D` 这种范围必须用 `index()` 找分隔符,否则切出来全是垃圾(我第一次就这样得到 11 行 "0000")。

## 121. 复核:cause 链 provenance 不再复现(2026-10-30)

handoff §4 D 把 `chained.cause.line` 记成真 bug(`t38:38`)。这次按主线回来复核,**已经绿了**:

```
/tmp/t38                                       → runtime source checks: 17,exit 0
python3 aot/run_runtime_diagnostic_tests.py    → Runtime diagnostic suite: ALL CHECKS PASS
```

即 `first.line == 7 && chained.cause.line == 3`(那条 30000 次分配之后的 provenance 断言)通过。
具体是哪次改动修好的没有被单独记录(很可能随错误模型切片一起变的),所以只记"不复现",
不再声称了解成因;若将来重现,按原假设重开 bisect:cause 槽里放的是**未定位**错误对象 ⇒
`__err_record` 的「已定位不被重记」守卫不生效。

顺带纠正 handoff §5 的三条"已知红":`runtime_diag`(本条)、`module`(§104)、`extension`(§116)
现在都不红了 —— 这三条都是文档滞后,不是代码状态。

## 122. 2026-10-31 审查修复:错值/崩溃/门禁静默失真(2026-10-31)

对 `rust-error-model` @ `dc8af53` 做完整审查后的一批修复。每条都带最小双引擎回归,
下面只记**判决性测量**与口径变化;细节在提交信息里。

**错值类**

- 裸槽(unboxable)判定加入 `prone`(`types.ql`)。反例 `let x = 1/z; println(x + 1);`
  修复前 native 打印 `1`(解释器 `?Error`)。
- 收窄事实改按 `bindId` 记,嵌套块赋值作废(`types.ql`);同类反例修复前 native `1` / boot `?Error`。
- String `==` 快路径要求 String 一侧 `cannotBeError`(否则 Error 被当"不等")。
- `?Option` 失败边补返回检查,与 boot 的 Return completion 对齐。
- `fastArityOf` 改按**符号**记(`fastArityBySymbol`):同名带注解用户函数不再发未定义的 `@ql_fnN_f`。
- std 链缓存/直调的失效判据加入别名污点(`let m = std.Math; m.abs = ...`)与 import 模块写入。
- boot `TypedArray`/`TypedSizedArray` 对成员错误加 `isError` 守卫(此前 boot 接受 `TypedArray(5)`)。
- parser 返回表补 `setReturnContext`:插值 `${(1/z)?}` 不再绕过 Result/Option 规则。

**崩溃/挂死**

- `std.process.*` argv 用字符串头字节长(非 ASCII 不再截断);参数/`fs.writeText` 先验
  `tag==2`,`std.process.run(["echo",42])` 与 `writeText(path,42)` 从段错误变为 `TypeMismatch`。
- `ql_wait` 只在 `EINTR` 重试、`pid<=0` 直接报错;重复 wait 从死循环变为 `IOError`。
- GC 阈值从 `live/2` 改为 `live`(GC 成本由 live 扫描主导)。实测:
  解释器 `println(1)` 8.2s → 3.3s;`t43_number_library` >600s(超时)→ **242s**;
  `t43` 前缀后单次 `parseFloat` 74s → 13.7s。

- 未初始化读的另一条路径:`let x; println("${x}")` 修复前 native **段错误**(引导器 `?Error`):
  `emitIdentifier` 的 sameBody 快捷路径假设前端已证初始化,但插值内的读不被"直接读"判据拦。
  现在 `let x;` 的绑定保留 `ql_empty` 检查,直到第一次赋值。

**门禁/工具**

- `--ir-cache`/`--check` 的 key 升 v2:入口 + runtime + 每个 import 模块 + symbols/mod + 选项;
  改 import 后不再命中旧 IR/旧结论,`--debug --ir-cache` 不再回放 release IR。
- `tools/link` 真正消费 `--opt`(此前 opt 0/2 产物逐字节相同);runtime.o 缓存键 = 优化级 + 源码哈希,
  且用 `Bytes.read` 判存在(文本读 ELF 必 IOError ⇒ 每次重编)。
- `verify` 不再对 0 条比对报绿;link 默认从对象旁取 `strings.tsv`,缺失则失败(除非 `--no-verify`)。
- 测试驱动:缺 `.expected` 一律失败(此前 16 个用例静默 pass,其中 native 分支根本不执行);
  `run_diff` 比较退出码;`run_debug_diff_tests.py` emit 失败不再跳过;`run_bench` 失败返回非零。
- split 模式补上 symbols.tsv 第三列 → 库的寄存器入口终于被使用(t30 风格程序:11 个 `_f` 调用、233 条声明)。

**头条(单模块 t20,`clang -O2`)**:IR **188,630** / 机器 **145,187**;
修复前同源编译器 187,736 / 142,367 ⇒ **+894 / +2,820**。原因可解释:
`unboxable bindings` 667 → **506**(少 161 个绑定不再被错误解箱),`located-error elided` 92 → 111。
这是正确性代价,不是新优化;不要拿它当性能回归去回滚。

**验收(同源)**:selfhost(59)/interpreter(41,含 t43/t64)/assignment/semantic(含插值与 `Array(...)` 诊断)/
runtime_diag/module/debug-diff/String 套件全绿;QLang 驱动 `run_tests` 59/0;`bundle --check` 通过;
stage2→stage3 IR 逐字节相同(1,020,735 行)。新增 `t64_array_types`(三张清单);
`t13`/`t14` 的静态已知不匹配改用动态值/允许 exit 1(运行期检查的覆盖不变)。
`run_selfhost_tests.py --self` 现在优先复用已有 stage2 作 stage1,并真正比较
「stage2 发的 IR」与「stage3 发的 IR」;实测 ALL PASS。

## 123. 第二轮审查:修复本身引入/遗漏的问题(2026-10-31)

对 §122 那批修复再做一轮审查,发现并修掉:

- **Critical**:收窄事实按 bindId 改成每程序一张表后,函数体内建立的收窄会泄漏到之后分析的
  另一个函数(`let x=1/z; let f=()->{if !Number.check(x){return;} ...}; let g=()->{println(x+1)};`
  native 打印 `1`,boot `?Error`)。现在事实按**深度**分层 + 函数 floor:函数体只看到体内事实,
  `typePop` 丢弃,写入清所有深度。两条双引擎回归(Number.check / isError 守卫)。
- **High**:`maybeEmpty` 在 `emitStoreByName` 的清标记把 `if false { x=1; }` / `while false {...}`
  后的读又变回段错误(块不 push 编译期 scope,depth 仍是 0)。现在 `let x;` 的读永久保留
  `ql_empty` 检查(代价只在极少数无初始化绑定上)。
- **High**:std 污点按名字判定,参数与同名 let 碰撞可逃逸(`let p=0; (p)->{p.abs=...}; f(std.Math)`)
  → native 5 / boot 99。现在写扫描同时看参数表,参数名一律按可能写 std 处理。
- **Medium**:缓存命中后 `.qir` 正文被替换的测试证明带 import 永远 miss;**现在读时只校验
  header 里记录的 deps**(entry hash 覆盖 import 集合),实测二次 check 不再重写 sidecar,
  改 import/transitive 依赖/选项都会正确失效。sha256sum 按 50 个路径分批(ql_spawn <64 argv)。
- **Medium**:sha256 失败时会把 Error 文本写进 header。现在任一 hash 缺失就不写缓存文件
  (`PATH=/nonexistent` 实测不产生 `.qir`)。
- **Medium**:两列 symbols.tsv 仍会声明 233 个签名错误的 `_f`(0 参);现在只对 `fastArity >= 0` 声明。
- **Low**:`std.process.run([])`/≥64 参数把机制码当退出码;现在负状态映射为 `IOError`。
- **Low**:GC 阈值 `live` 加 64MB 上限(峰值堆 ~1.5× live,避免紧内存设备 OOM)。
- **Low**:`tools/link -o <已有目录>` 曾被 `mv` 当成"把文件移进目录"而成功;现在显式拒绝。
- smoke 用例的可执行性收紧:`run_tests` 按 `aot/tests/smoke_status.txt` 要求退出码
  (默认 0,t14/t15 为 1);`run_diff`/`run_bench` 拒绝崩溃(>1)被当通过。
- `run_module_tests` 的陈旧解释器判据补 `runtime.c`/`value_abi.ql`/编译器本身;
  QLang `run_selfhost.ql` 的固定点改为与 Python 版相同的 stage2/stage3 三次发射。

已核实非问题:t14 的 `includes("Uninitialized")` 实际为 true(插值把 Uninitialized 渲染成
`kind: message`);t13 的尾部在旧版也因 `nullable = 1` 提前退出,不是本批回归。

**头条变化**:第二轮修复后 t20 单模块 IR **189 275** / 机器 **146 238**
(第一轮 188 630 / 145 187;修复前 187 736 / 142 367)。+645/+1 051 来自收窄事实不再跨函数、
`let x;` 永久保留 empty 检查:`located-error elided` 111 → 102;**正确性代价**,不是优化回退。

## 124. 第三轮审查:收窄清除/floor、未初始化裸算术、参数别名污点(2026-10-31)

对 §122–§123 的修复再做一轮审查,发现并修掉:

- **Critical**:Assign 分支的 `typeNarrowMark(s.target.bindId, false)` 是 no-op —— Assign 的目标
  Identifier 从不经过 `inferExpr`,bindId 未设置。守卫事实在写入后仍生效,导致下面的注解检查被省略:
  `if !Number.check(x){...}; x = 1/z; let y: Number = x;` 修复前 native 绑定 `y` 为 Error
  并打印其 type(rc=0),boot 是 TypeCheck(rc=1)。现在 Assign 先 `typeBindLookup` 再清除;
  双引擎回归(循环内守卫+写入+注解)通过。
- **High**:`typeFloorStack` off-by-one(`typePush` 之后存 `typeDepth`,但函数体表索引是 `typeDepth-1`),
  函数体自身的收窄事实永远不可见。修正为 `typeDepth - 1`;`located-error elided` 102 → 111。
- **High(既有,本轮暴露)**:`let x: Number;` 没有初始化器,但被当成"类型已知的稳定绑定"
  → 解箱/raw 算术把 Uninitialized Error 的 payload 当 double(`${x+1}` native 打印 `1`,
  boot 是 TypeCheck 链)。现在 `base` 对无初始化声明置为 prone(可能 Error):不解箱、
  `cannotBeError` 为假、raw 路径退回装箱派发。回归:插值/闭包/比较/乘法五条双引擎一致。
- **High**:std 污点可经「参数 → let 别名」逃逸:
  `(p) -> { let q2 = p; q2.abs = (x) -> 99; }; f(std.Math)` native 5 / boot 99。
  `stdContainsRef` 现在把参数名也视为可能持 std;模块参数名也在 taint 扫描前收集。
- **Medium**:`build.ql` 曾在编译前删 `-o`,源文件/不存在路径/`-o == 源` 会毁数据。
  现在先编译(IR 用唯一临时名),emit 成功后才删旧产物;并拒绝 `-o` 与各输入同名。
- **Medium**:显式 `--stdlib-ir <x>.ll/.bc` 会静默跳过库字符串校验;现在向 `/dev/stderr`
  打 warning(用户 IR 仍校验),真正缺清单仍失败。
- **Low**:`--timing` 现在进缓存 flags(带 timing 的缓存不再被无 timing 的运行回放);
  `run_extension` 要求宿主 exit 0;`stdlib_build` 的 `full.ll/stdlib.ll/symbols.json` 也原子写;
  `run_module_tests` 过滤不存在的源;`smoke_status` 非法行直接失败;t14 补 `.expected`(34 行两引擎一致)。

**头条**:t20 单模块 IR **188 738** / 机器 **145 279**(第二轮 189 275 / 146 238;修复前 187 736 / 142 367
⇒ 两轮审查净增 +1 002 / +2 912,其中 floor 修正把第二轮多出的 537/959 收回)。
验收:selfhost(59)/interpreter(41)/assignment/semantic/runtime_diag/module/debug-diff(44)/String 全绿;
QLang run_tests 59-0、run_diff 56-0、run_selfhost 57-0;固定点逐字节相同(1 027 195 行)。
