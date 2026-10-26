# Probe facts — measured, not remembered

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
  (`assignment to undeclared name`);专门套件 `aot/run_semantic_diagnostic_tests.py:19-21`
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
   「Rust 宿主解释执行 boot、boot 再跑套件」。替代:用 native 编译的 boot(`/tmp/bp_head`)。
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

## 7. 夹具/预言机清单(改动会波及谁)

| kind | 夹具 / 金文件 / 预言机 |
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
9. ~~「静态可判 ⇒ 编译错误还没做」~~ —— 未绑定名已做且有专门套件(§4)。
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

日志 `/tmp/sweep3/`。**注**:第一遍(`/tmp/sweep2`)把 HEAD 编译器与**工作树**夹具混着跑,
产生的失败全部是假的(`/tmp/o_head` 编不动工作树里带 `__panic` 的 boot)⇒ **混源会造假失败**。

| 套件 | rc | 耗时 | 套件 | rc | 耗时 |
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
  —— 套件**生成的**夹具仍按「未初始化是运行期值」写,而编译器已**静态拒绝**(§1.5、§4)。
- `runtime_diag`:`CompileError: aot/tests/t38_runtime_diagnostics.ql:22:30: type mismatch:
  value of type String does not match the annotated type Number`
  —— 夹具停留在「注解不强制」的时代,而编译器已强制。

⇒ 二者与 §9 的「漂移的断言」同源:**编译器变严了,夹具没跟上**。长期未暴露,是因为常规门禁
只有 `interpreter` + `selfhost`(两者都绿)⇒ **验收口径过窄**。

### 11.2 两条口径(由本节产生)

1. **验收 = 全量基线 + 与该改动相关的套件**;只跑两套会漏掉 §11.1 这类红。
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
而是被第一次真正执行到。**它属于错误模型本体**(provenance 语义),不是夹具笔误。

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
| 判别夹具(模块条件导出 ⇒ 运行期缺失赋值) | native:rc=1 + `UndefinedVariable: Undefined variable: absent` ✓;boot:rc=1 + 带源位置的同一消息 ✓ |
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
顶层绑定失败则按顶层未处理错误 exit 1)。夹具 `t56_result_annotations` 逐行匹配两引擎。

### 14.2 Option 的类型与 `?`

```qlang
println(std.Option(Number).check(5));     // true
println(std.Option(Number).check(null));  // true
println(std.Option(Number).check("x"));   // false
let none = (): std.Option(Number) -> { let v = null; let x = v?; 99; };
println(none());                          // null
```

⇒ `None` = `null`;Option 函数里的 `?` 传播 `null`;Error 不是 Option(交返回边报 `TypeCheck`)。
夹具 `t56` 的 None/Some/Error 三态在 native/boot 上一致。

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
(夹具 `t57_assert`)。实现是 runtime 的 `assert`,通过 `__native(assert, "assert", false)`
让 boot 直接调用同一份实现;`assert` 已进 `moduleGlobalNames`,导入模块/函数内可见。

## 15. 已实测:直接调用与纯 Number 内联(2026-10-26)

同源 `target/selfhost/stage2` 形态;判别夹具 `t58_direct_calls` / `t59_inline_pure`。

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
内联约 **0.05–0.08s**,通用分派约 **36s**(后台套件争用,仅量级参考)。

**失效条件(已加判别)**:赋值、重声明、export、value use(别名)、参数注解、
参数不足/超参、实参可能为 Error、body 有调用、body 有自由变量、非 Number 运算。
`t59` 覆盖重声明、赋值、value use、捕获自由变量;`t58` 覆盖别名、部分应用、
Error 实参、注解参数、返回注解、leaf 内赋值与 body Error。
同源 p0f:`stage2/stage3` IR 相同;interpreter 59 PASS;selfhost ALL CHECKS PASS;
call/array/object/numeric/assignment/diagnostic ALL CHECKS PASS。

## 16. 已实测:多调用点 raw 直接函数(P1,2026-10-26)

判别夹具 `t60_raw_direct`。形状:注解 `Number` 参数、无参数写入、leaf、绑定无 value
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

夹具 `t61_known_safe`。核心形状:

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

夹具 `t62_leaf_calls`。规则:自调用/后定义函数排除;body 内局部函数、源序在前的
函数允许;`Import` 仍禁止。

| 形状 | 机器指令 | 用户态 |
|---|---:|---:|
| `compose` 夹具(含自别名/互递归;P2) | 128,016 | — |
| 同上(P3;最终夹具) | **127,881** | — |
| 5M 次 `s = s + compose(1,i)` 旧 | 125,951 | 9.074s |
| 同上(P3) | **125,762** | **0.039s** |

判别覆盖:组合函数、局部闭包、自递归(排除)、自别名(`let g=selfAlias`)排除、
后定义调用(排除)、互递归(`a` 排除/`b` 可 raw)。native/boot 输出一致。
