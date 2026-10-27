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
