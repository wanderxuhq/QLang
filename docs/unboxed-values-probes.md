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

代价:每个启用点约 +20 条 IR(含冷回落块),整程序净 +200 条指令;夹具输出不变,
`stage2/stage3` IR 固定点成立。


## 22. IR 分块写出 + 预编译 stdlib 前缀的可行性(2026-10-26)

**分块写出**:188k 行原来逐行 `println`,即 188k 次 `write`。改成按 4,096 行用
`std.String.join` 拼成一块、`print` 一次(约 50 次 syscall)。

| 版本 | 空程序用户态 CPU(4 次最小) |
|---|---:|
| 逐行 println | 9.97s |
| 分块写出 | **9.75s(−2.2%)** |

输出**逐字节相同**(空程序 + t20/t19/t30/t61/t62 五个夹具全 `cmp` 通过)⇒ 产物
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


## 26. 标准库对象化:一次编译,按哈希缓存,逐夹具链接(2026-10-27)

前两节把 runtime/stdlib 的文本变成了与程序无关的固定前缀;这一节把它**编译一次**:

- `aot/stdlib_split.py`:用编译器编一个空程序,把模块拆成「preamble + 助手 + 库函数体 +
  字符串 + `@__stdlib_init`」,编译成 `target/stdlib/<key>/stdlib.o`(key = 编译器二进制
  + `runtime.ql` + `stdlib/bundle.ql` 的哈希),并落一份 `symbols.json`(声明文本);
- `aot/native_link.py`:新增 `--stdlib-object` / `QLANG_STDLIB_OBJECT`。开启时把用户 IR
  里属于 stdlib 的 `define`/全局删掉、只给被引用的补 `declare`,然后和 `stdlib.o` 一起链接;
- 两套门禁自动构建并启用它(带缓存,失败则自动回落到单模块链接)。

关键取舍:**`internal alwaysinline` 的 value-ABI 叶子(`ql_tag`/`ql_empty`/`ql_word`/
`ql_byte`/`ql_truthy`)两个模块各留一份**。它们不跨对象边界,调用点仍然内联;否则每个
tag 检查都会变成一次真调用(+1,038 条指令/程序)。

| 度量 | 单模块 | 拆开 + 链接 |
|---|---:|---:|
| 单夹具链接(clang -O2 + lld) | 12.3s | **1.5s** |
| t20 二进制机器指令数 | 126,635 | **126,599**(−36) |
| selfhost 全套(`--jobs 3`) | ~20 min | **6.3 min** |
| interpreter 全套(`--jobs 3`) | ~8 min | **6.2 min** |
| stdlib 对象 | — | 280 函数 + 1,573 全局 |

夹具输出逐条不变(6 个夹具逐字节比对 + 两套门禁全绿)。IR 仍是逐字节相同的单模块文本
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
| 单夹具前端 | 9.7s CPU / 188k 行 IR | **5.7s / 1.7k 行** |
| 单夹具总构建(前端+链接) | ~22s | **~7s** |
| t20 二进制机器指令 | 126,635 | 126,599 |
| selfhost 全套(`--jobs 3`) | 6.3 min | 6.5 min |
| interpreter 全套(`--jobs 3`) | 6.2 min | 8.2 min |

两套门禁全绿;自举固定点在 split 模式下逐字节成立(用 native 编译器手工验证:
`stage2 → IR_a → link → stage3 → IR_b`,`IR_a == IR_b`)。

**注**:对「用户代码本身就很大」的程序(例如编译器自己,830k 行),拆分不减小 IR —— 库的
那部分本来就不是大头;收益主要体现在小程序与套件迭代上。


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
| 单夹具前端(t20) | 9.7s | **0.45s(17×)** |
| 单夹具整条构建(前端+链接) | ~22s | **~1.7s(13×)** |
| selfhost 全套(`--jobs 3`) | 2h(串行)/ 6.3min | **2.3min** |
| interpreter 全套(`--jobs 3`) | — | **5.6min** |

**等价性验证**:同一编译器、同一输入,`-`(从源码分析)与接口缓存两条路径发出的代码,
把局部名字(`%tN`/`bbN`/`ql_fnN`/`.strN`)归一化之后**逐行相同**;两套门禁全绿;
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

t20 二进制机器指令数不变(126,713);selfhost / interpreter 两套门禁全绿;固定点成立。
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
产物机器指令净 −0.5%。门禁:selfhost / interpreter 全绿(各 ~10min / ~8min,当轮宿主较慢),
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

b_chars 用户模块不变(126,015,用户代码不直接调这些 C 叶子);selfhost / interpreter 两套门禁
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
| 12 个夹具机器指令合计 | 1,610,839 | 1,610,809(−30) |

**结论:无收益,已回滚。** 机器指令只在噪声范围里动,输出逐字节一致(13 个夹具 A/B)。

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

验收:自举固定点逐字节成立;scoped_module / lazy_module 两套门禁全绿;7 个带 `.expected`
的夹具输出一致。

下一笔同性质的合并:`collectAssignedNames`(赋值/导出/重声明)与 `collectImportedNames`
(import 绑定的名字)也是对同一棵树的两趟,可以并成一次。


## 34. 前端:名字事实两趟遍历合成一趟(2026-10-27)

`collectAssignedNames`(赋值/导出/重声明)与 `collectImportedNames`(静态 import 绑定的名字)
是同一棵树上的两趟全树遍历,收集的是**互不依赖**的名字事实。合并进 `collectAssignedNames`
的 Import 分支,删掉独立的 walker。

**合并时踩到的坑(值得记)**:`buildInlineCandidates` 开头有一句 `importedNames = {};`
再自己扫一遍。删掉扫描后,这句清空把 `main` 里刚扫好的表清掉了,于是"import 覆盖同名槽"
的判据丢失 —— `t60_raw_direct` 的 `shadow` 被错当成 raw 目标,输出从 102 变成 3。
自举门禁抓到;修法是删掉那句清空并注释原因。

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
| 验收 | 自举固定点逐字节成立;selfhost 绿;t58/t59/t60/t61/t62 等 10 个夹具输出一致 |

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
- 小夹具(t20):6,936 量级

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
在收窄前必须先查夹具里有没有反例。


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
2. 收窄前先扫夹具反例:`let x = import "p";` 这类"语句位置看起来、其实是表达式"的构造。

验收:42 个夹具里 41 个输出一致,`t37_extensions` 输出与改动前**逐字相同**(Android dlopen
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
| 门禁 | `run_selfhost_tests.py` 在标准库对象存在时优先用 `target/tools/link` |

| 度量 | Python 链接 | QLang 链接 + 校验 |
|---|---:|---:|
| 单次链接(小 IR) | ~1.1s | ~2.4s |
| **selfhost 门禁全套(40+ 夹具,--jobs 3)** | 212–616s(随机器负载) | **295s** |

**代价与取舍**:校验器每次链接要重新解析 ELF(符号表 + 重定位,约 0.5s)+ 逐条比对,
所以单次构建从 ~1.0s 变成 ~2.4s。但**它把 Python 从构建路径里彻底移除**,而且门禁总耗时仍
在合理区间(295s)。如果以后要恢复单次速度,方向是:校验按需(CI 默认开、本地 `--no-verify`),
或者把符号/重定位解析做成 C 叶子。

踩到的坑:校验器最初读对象的 `stdlib.ll`(7.3MB)来取期望值 —— 每次链接多花十几秒
(门禁 1245s)。现在对象构建时顺手写一份 `strings.tsv`(`.strboxN<TAB>hex`),校验器读它,
门禁回到 295s。

### 45.1 让所有 runner 都走 QLang 链接器(2026-10-27)

`native_link.link()` 现在**委托**给 `target/tools/link`:只要标准库对象存在、`opt==2`、
并且 IR 带 `; split-stdlib` 标记,就用 QLang 链路;否则回落到 Python(单模块 IR 需要
`split_file`,那是 Python 侧的职责)。

踩到的坑:第一版没有检查 split 标记,gc 套件用的是**单模块 IR**(自带 runtime),再叠
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
| selfhost 门禁(用 QLang 对象) | `run_selfhost_tests.py --jobs 3` | **206s 全绿** |
| interpreter 门禁(用 QLang 对象) | `run_interpreter_tests.py --jobs 3` | 全绿(该轮机器很吵:1698s) |
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

扩展套件的**构建段全过**:`PASS compiled hosts before extensions existed`、
`PASS independent extension: plugin / second / failure / cycle`(含故意坏 ABI、缺入口的变体)。

**运行**:在本机必然失败 —— Android linker namespace 不允许 `dlopen` `/tmp/*.so`
(`library ".../plugin-O0.so" ... is not accessible for the namespace`)。这是环境限制,
与构建无关;套件里那 6 条 FAIL 全是 dlopen 失败导致的。

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

**A/B**:同一夹具开关两版 IR 逐字节相同(只多一行 `; staticcall:`);扫描开销 10.48s → 10.62s(+1.4%);
stage2/stage3 固定点成立。

**命中数**(HEAD 的 stage2 就是旧源产物,先按「旧编译器 + 去掉新叶子的临时 runtime」两段式重建):

| 程序 | 调用点 | 可静态(绑定) | 可静态(对象字段) | 拒绝 |
|---|---|---|---|---|
| 夹具 t28_objects | 129 | 13 | 0 | chain=49 shape=67 |
| 夹具 t49_raw_object_index | 32 | 15 | 0 | chain=6 shape=8 notfn=3 |
| 夹具 t16_functions | 31 | 11 | 0 | shape=17 notfn=2 partial=1 |
| stdlib 库自身 | 393 | **285** | 0 | shape=48 chain=35 notobj=12 notfn=10 escaped=3 |

**结论**:库里 285/393(73%)的调用点是「同程序不可变函数绑定」,而今天的直调只对**用户程序**开着
(`qlangc.ql:3248` 的 `allowDirectUserCalls` 只在用户程序发射期间为真)—— 库内直调今天一个都没有。
用户侧的收益主要不在对象字面量(夹具里 field=0),而在 `std.X.Y` 链(chain)和绑定直调。

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
`stage2/stage3` IR 固定点成立;selfhost 套件 ALL PASS。`TypedArray(Number)` /
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

验收:stage2/stage3 固定点成立;demo/type_gymnastics 419/419;selfhost 套件 ALL PASS。

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

验收:stage2/stage3 固定点成立;demo/type_gymnastics 419/419;selfhost 套件 ALL PASS。

## 56. interpreter 套件的「重复定义」是接线 bug,不是代码生成问题(2026-10-28)

§53 记录的红:链接 `interpreter.ll` 时报 `duplicate symbol: __panic_exit / __cold_located_error /
.strbox7`。根因不在发射器:**`run_interpreter_tests._use_stdlib_object` 只导出了
`QLANG_STDLIB_OBJECT`,没导出 `QLANG_STDLIB_SYMBOLS` / `QLANG_STDLIB_INTERFACE`**,
于是 `emit()` 退回 `--emit-llvm`(单模块、含整个 runtime+库),再和 `stdlib.o` 一起链接 ——
两边的符号当然重复。`run_selfhost_tests` 的同名函数导出三个变量,所以夹具一直是绿的。

修法:补齐三个环境变量(和 selfhost 驱动一致),发射器走 `--emit-llvm-split`。

**验收**:`run_interpreter_tests.py --compiler <新编译器> --jobs 2` → **ALL CHECKS PASS**
(含 419 条类型断言的 type_gymnastics、argument 套件、解释器夹具)。

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

验收:demo/type_gymnastics 419/419;stage2/stage3 固定点成立;selfhost 套件 ALL PASS;
interpreter 套件 ALL CHECKS PASS。

## 58. 内联 lambda 成员也有符号了,但链的下一道墙是「实参证明」(2026-10-28)

`std.String.length` 这类成员是**内联 lambda**(不是标识符绑定),之前没有名字也就没有可调符号。
现在发射期递归收「模块对象绑定名 -> 成员 -> ql_fnN/元数」,以及导出表「模块名 -> 对象绑定名」,
链目标表把这类成员也登记上。

| 夹具 | 之前(v16,仅标识符成员) | 之后(v17) |
|---|---|---|
| t30_strings | 155,483 | **155,363(−120)** |
| t41_math_library | 136,925 | 136,925(该夹具的 sqrt/pow 本来就命中) |

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

三个夹具各 −5 条,等于没有。原因也很清楚:**装箱直调要求「形参没有注解」**(分派器负责的检查
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

验收:输出逐字节相同;demo 419/419;固定点成立;selfhost 与 interpreter 套件全过。

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
验收:输出逐字节相同;demo 419/419;固定点成立;两个套件全过。

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

验收:输出一致;demo 419/419;固定点成立;selfhost 与 interpreter 套件全过。
收益不大,但它是纯减法(体积也降),而且清掉的是每次调用都付的固定成本。

## 67. 门禁的标准库对象改用 QLang 构建器(2026-10-29)

`run_selfhost_tests._use_stdlib_object` 原来直接 `from stdlib_split import build_stdlib`
(Python)。现在:

1. 先确保 `target/tools/{stdlib,build,link,verify}` 存在(`aot/bootstrap.sh`,shell + clang);
2. 优先跑 `target/tools/stdlib --compiler <c>`(QLang 构建器,产物与 Python 版逐字节相同,
   布局一致:`stdlib.o / stdlib.ll / symbols.tsv / strings.tsv / interface.txt / symbols.json`);
3. 工具不可用时才回落 Python 的 `build_stdlib`(保留,供没有工具链的检出)。

`run_interpreter_tests` 里那份重复的 `_use_stdlib_object` 删掉,直接从 `run_selfhost_tests` 导入。
验收:selfhost 与 interpreter 套件都 ALL PASS;`QLANG_STDLIB_OBJECT/SYMBOLS/INTERFACE` 指向
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

1m49s 产出 `target/tools/{build,link,stdlib,verify}` 四个可执行;随后 selfhost 套件用这套
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

所以门禁用 split 是对的(只验行为,不验速度),但**发布构建不应该用 split**——除非把库对象
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
| 夹具 t30(91 行) | 150ms | **7320ms** | 120ms | 3700ms |
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
- 所以三条路各有用途:门禁/行为验证用 `.o`(0.45s/夹具),发布用 `--lto`(2.4× 更快、运行持平),
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
| 夹具 t30 前端 | 11.2s | **0.81s** |
| 产物 IR 行数 | ~180k | 25,901(仅用户模块) |

配合 `native_link.py --lto`(ThinLTO)已能端到端:b_chars 前端 0.8s + 链接 15.1s(默认 `--opt 2`)
≈ **15.9s**,单模块 23.6s;运行 CPU 0.764s vs 0.596s。

**注意**:手动用 `-O1 -flto=thin` 时链接只有 9.6s、CPU 0.556s —— 对这个 bench 而言 `-O1` LTO
比 `-O2` LTO **又快又稳**。下一轮把 LTO 的默认优化级别定为 O1(`--lto` 时),再用 bench 套件复测。

## 76. LTO 默认优化级别定为 O1(2026-10-29)

`--lto` 现在单独走自己的优化级别(`--lto-opt`,默认 **1**),不再复用 `--opt`:

| 配置 | 链接 | b_chars 运行 CPU |
|---|---|---|
| `-O2 -flto=thin` | 15.1s | 0.764s |
| **`-O1 -flto=thin`(新默认)** | **10.6s** | **0.653s** |

整条 bench 套件在 `--split --lto` 下的前端时间:**0.14–0.44s/个**(单模块是 8–16s),
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
| 同上,t16 夹具 | — | 3 3 8 ✓ | — |

简单夹具(t16)是对的,b_chars 差 **28,000**(多算了空格) —— 说明这条管线**不等价**于
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
