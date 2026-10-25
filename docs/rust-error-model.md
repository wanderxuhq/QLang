# Rust 式错误模型:设计口径与落地切片

状态:方向已确认(2026-10-25),分支 `rust-error-model`(从 `error-carried` @ `5d0f4e8` 切出)。
本文件是**实现口径**;它覆盖 `docs/unboxed-values-handoff.md` 里与 Rust 模型冲突的旧口径,
冲突处以本文件为准。

## 1. 目标

把 QLang 的错误处理收敛到 Rust 的骨架:

1. **`Result(T)` / `Option(T)` 是编译器能约束的类型**,不是只靠 `T|Error` / `T|Null` 的运行期谓词;
2. **`?` 只在调用点显式出现**,且只在返回 `Result`/`Option` 的函数里合法;
3. **panic 只给契约违反**;数据失败用 Error/Result;能静态判定的用编译错误;
4. **`?` 不自动出现**:语法(运算符、索引、成员访问)不自动传播;只有显式 `?` 传播;
5. **panic 不可捕获**,语言内没有 try/catch;宿主边界(嵌入)单独处理。

明确不采用:

- 异常/unwinding;
- 构建配置决定行为(Rust 的 debug overflow panic / release wrap 那种);
- 根据“返回类型是不是 Result”偷偷开传播通道——规则必须显式、统一;
- 把 `panic` 当数据失败的通用出口。

## 2. 与旧 handoff 的差异

| 旧口径(handoff) | 新口径(本文件) |
|---|---|
| `语法形式自动传播、函数调用显式` | **全部显式 `?`**;语法不自动传播 |
| `Option(T) ≡ T|Null` 直接当类型 | Option 仍是 `T|Null` 的检查,但**不把 `null` 当 None 的 `?` 传播**;Option 的 `?` 留到后续切片 |
| B4 `/0` 保持 `DivisionByZero` | 暂不改;是否走 IEEE 是独立语义决定,不与 Rust 传播模型捆绑 |
| B2 缺失字段/索引 → Null | 暂不改;先让 Result/`?` 可用,再讨论索引/字段的 panic-vs-Option |
| B1 StackOverflow / B3 arity → 致命 | 暂不改;panic 边界先不动,避免一次改太多 |

## 3. 切片 1(本分支首先落地)

### 3.1 注解检查的“成功值可以是 Error”

现状:`__check_binding` 成功时返回原值;编译器对注解绑定总是 `emitPropagateError(checked)`。
因此 `Result(T)` 的 Err 值(Error)会被当成“检查失败”从函数/顶层传播 ——
`let x: Result(Number) = err;` 不能工作。`Any` 注解接受 Error 也同样不工作。

切片 1 要做的:

- 新增/改成一个**成功判定**:先问“这个值是否通过注解类型”的布尔结果;
- 通过 ⇒ **存原值**(即使它是 Error);
- 不通过 ⇒ 再取 `TypeCheck` 诊断并传播(冷路径);
- 不改变普通 `Number`/`String` 注解失败时的行为。

验收:

```qlang
let z = 0;
let e = 1 / z;

let a: Any = e;                 // Error 是 Any 的值,应存储
println(a.type);                // DivisionByZero

let b: std.Result(Number) = e;  // Err 侧,应存储
println(b.type);                // DivisionByZero

let c: Number = e;              // 检查失败,仍应产生/传播 TypeCheck
```

### 3.2 `std.Option(T)`

在 `stdlib` 增加 `Option(T)`,与 `Result(T)` 同形:

```qlang
let Option = (T) -> {
  check: (v) -> { if isError(v) { false; } else { v == null || T.check(v); } };
};
```

- `Option(Number).check(5)` → true
- `Option(Number).check(null)` → true
- `Option(Number).check("x")` → false
- `Option(Number).check(err)` → false(Error 不是 Option;Err 用 Result)

加入 `stdlib/manifest.json` 的模块/导出;重建 `stdlib/bundle.ql` 并 `--check`。
**不**在本切片实现 `Some/None` 构造器或 Option 的 `?` 传播——那需要先决定 Null 与 None 的区分。

### 3.3 `?` 的上下文约束(渐进式)

规则(切片 1):

- **顶层**:允许 `?`(脚本便利;Error ⇒ stderr + exit 1),这是与 Rust `main -> Result` 的有意偏差。
- **有返回注解的函数**:
  - 注解是 `Result(...)` 或 `Option(...)` ⇒ 允许 `?`;
  - 注解是其他类型(如 `Number`、`String`)⇒ **编译错误**:
    `? requires a Result or Option return type`;
- **没有返回注解的函数**:暂时允许(legacy/动态);这是**迁移期**,不是最终语义。
  后续切片在语料注解完成后,把无注解 + `?` 也改成编译错误。

识别方式(切片 1):**语法级**识别返回注解为 `Result(...)` / `Option(...)` 调用
(允许 `std.Result(...)`/`std.Option(...)`);别名、间接构造暂不支持,遇到时报错并记录为迁移项。
该检查放在共享 parser(`bootstrapped/parser.ql`),让 native 与 boot 同时得到同一诊断。

验收:

```qlang
let ok = (): std.Result(Number) -> { let z = 0; let v = (1 / z)?; v; };   // 允许
let bad = (): Number -> { let z = 0; let v = (1 / z)?; v; };              // CompileError
let legacy = () -> { let z = 0; let v = (1 / z)?; v; };                   // 迁移期允许
```

### 3.4 夹具与套件

- 新增 `aot/tests/t56_result_annotations.ql` + `.expected`:
  - `Any` / `Result(Number)` 存储 Error;
  - `Number` 注解失败产生 `TypeCheck`;
  - `std.Option(Number)` 的 check 三态;
  - `?` 在 `Result` 函数内传播。
- 在 `aot/run_semantic_diagnostic_tests.py` 增加拒绝用例:
  - `: Number` 函数里用 `?`;
  - `: String` 函数里用 `?`;
  - 合法对照:`: Result(Number)` / `: Option(Number)`。
- 跑同源门禁:`semantic` + `interpreter` + `selfhost`;全量基线在切片 1 合并前再跑。

## 3.5 切片 1 落地状态(2026-10-25)

已实现:

- **注解检查的成功协议**:注解可能接受 Error 时(`Result(T)`、`Any`、`Error`、用户/复合类型),
  发射器先走 `__check_value` 的布尔裁决;通过则**存原值**(即使它是 Error),失败才走
  `__check_binding` 的 TypeCheck 冷路径。`Number`/`String` 等拒绝 Error 的注解仍走旧路径。
- **`std.Option(T)`**:加入 `stdlib/result.ql` 与 `manifest.json`,重建 `bundle.ql`;
  `Option(Number).check(5/null/"x")` = true/true/false。
- **`?` 的上下文约束**:共享 parser 记录每个函数的返回注解;若注解存在且不是
  `Result(...)`/`Option(...)`(允许 `std.` 前缀),`?` 是 parse error。
  顶层 `?` 与**无注解函数**仍允许(迁移期)。
- **健全性修复**:`checkIsDead` 不再只看 `staticType`,还要求 `cannotBeError`;
  `runtimeTypeFree` 在 prone 不动点之后刷新 —— 已知类型但可能产出 Error 的写入
  (如 `1 / 变量零`)不再丢检查。
- **boot 库导出修复**:函数/类型/标量导出现在按原值安装;此前 `modules[name].value`
  会把函数导成 `UndefinedField` 错误(`Result`/`Option` 在 boot 上不可用)。
- **Option 的 `?`(切片 2)**:parser 在 `Option(...)` 返回注解的函数里把 `?` 标成内部
  操作符 `?Option`(Result 与无注解仍是 `?`)。native 对 `?Option` 传播 Null(tag 4);
  boot 用现有 Return completion 以 Null 返回,因此不需要新的传播标记。`None` 就是 `null`;
  Option 函数里遇到 Error 不是失败侧,会交给返回边检查报 `TypeCheck`。
  内部操作符不暴露给用户;所有 `?` 语法仍是 `?`。

迁移债(已注明):`stdlib/string.ql` 的 `casing` 与 `aot/runtime.ql` 的
`__s_codepoint` 内层函数原本声明了 `Number`/`String` 却使用 `?`,现在去掉返回注解;
等它们改成 `Result` 再恢复注解。

**实现注意(已经踩过)**:不要把 Option 的 None 做成新的 propagation 类型去扩
`isPropagating` / 在函数边界加转换。试过两种标记,其中一种会让 boot 解释器整体退化
(连 `println(1+2)` 都输出 `not an error`);当前稳定解是 **parser 标内部 `?Option`**,
native 传 Null(tag 4),boot 用现有 Return completion 返回 Null。`isPropagating` 保持
原样(只认 Error)。

当前数字(同源 `/tmp/o_new7`):

| 项 | 基线 `5d0f4e8` | 切片 1 |
|---|---|---|
| `/tmp/t20.ql` IR | 187,738 | **188,301(+563)** |
| `clang -O2` AArch64 指令 | 125,479 | **125,645(+166)** |
| 输出 | 20 | 20 |

+563/+166 是健全性修复 + `Option` 库函数的成本,不是传播模型的收益;后续用
`Result` 注解覆盖与死检查消除再回收。

已通过的定向验收:

- `run_semantic_diagnostic_tests.py`:10/10(新增 `propagate-number` / `propagate-string`);
- `t56_result_annotations`:native 与 boot 都逐行匹配 `.expected`
  (含 `Option` 的 None/Some/Error 三态);
- `run_selfhost_tests.py --compiler /tmp/o_new7`:48 PASS(切片 1 的完整自举套件);
- `run_interpreter_tests.py --compiler /tmp/o_new7 --interpreter /tmp/bp_new2`:57 PASS(切片 1);
- 切片 2(Option `?`):
  - `run_semantic_diagnostic_tests.py`:10/10;
  - `t56_result_annotations`:native/boot 逐行一致(None/Some/Error 三态);
  - `run_interpreter_tests.py --compiler /tmp/o_new10 --interpreter /tmp/bp_new8`:57 PASS;
  - `run_selfhost_tests.py --compiler /tmp/o_new10`:48 PASS;
  - stage2/stage3 IR identical。

## 4. 后续切片(不在本切片)

1. **Result/Option 的命名空间与构造器**:`Ok/Err/Some/None`、`unwrap/expect`。
   当前 `Result` 是函数(类型构造器),不能同时挂字段;要么引入语言级可调用对象,
   要么用 `std.Result.of` + 独立函数,要么给函数加字段表 —— 需要单独决定。
2. **Option 的构造器/辅助函数**:`Some/None`、`Ok/Err`、`unwrap/expect`。
   当前 `Result`/`Option` 是函数(类型构造器),不能同时挂字段;要么引入语言级可调用对象,
   要么用独立函数/命名空间 —— 需要单独决定。`unwrap/expect` 还要接 panic 通道。
3. **消费检查 / must-use**:函数返回 `Result`/`Option` 时,语句位置丢弃要报错/警告;
   依赖调用点返回类型跟踪。
4. **索引/字段的 Rust 化**:`a[i]` 越界 panic + `a.get(i)` Option;`.field` panic +
   `Object.get` Option。与 B2 的 Null 方案二选一。
5. **`/0` 的 IEEE**:若最终选择 Rust f64 语义,需改三方差分预言机与双引擎断言。
6. **panic 面收口**:B1/B3/C、`unwrap/expect`、宿主边界(`runSource` fatal result、独立退出码)。

## 5. 纪律

- 每一片都先报命中数,再报 IR/机器指令;验收必须同源。
- 未注解代码的迁移是**显式**的:每注解一个函数,就少一个动态 `?` 点;不做批量自动改写。
- 不把 `Result` 当“加了名字的 Error”;如果编译器不能约束 `?` 和消费,就不算完成。
