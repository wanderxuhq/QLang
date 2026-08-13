# Boot 解释期热点定位与裁剪设计(host 调用分派开销为主因,纯 QLang 先落地)

- **日期**:2026-08-13
- **状态**:待评审
- **范围**:解释期热点(interpreting ≈4.9s / total ≈6.1s ≈ 80%);不含 lexing(已优化)与 parsing
- **目标**:定位 boot 解释期耗时根因,给出裁剪方向,预期"明显变快即可";严格保持 host/boot 字节级一致、`demo/type_gymnastics.ql` 419/419、`difftest.py` 三端全绿、`verify_bootstrap` PASS/0 FAIL
- **硬性约束**:零新 native(只复用既有运行时机制);QLang 的数据与语言层函数必须由 QLang 实现("离开 rust 的摇篮");编译器/运行时机制(Rust host)允许优化

## 背景(探针数据,2026-08-13)

阶段耗时(同窗口内交错测量,本机为手机级 proot,详见"验证策略"的消噪要求):

| 阶段 | 耗时 | 占总量 |
|---|---|---|
| LEX(仅词法) | 0.59s | ~10% |
| PARSE(词法+语法) | 1.18–1.22s | ~20% |
| FULL(全流程) | 6.10–6.14s | 100% |
| **解释期(FULL − PARSE)** | **≈4.9s** | **≈80%** |

解释期计数器(挂在临时 `/tmp/bootprobe/*.ql`,与工作树隔离,统计与窗口无关):

| 计数器 | 值 | 含义 |
|---|---|---|
| `__n_eval` | 44,852 | boot `evaluate` 调用次数(每个表达式一次) |
| `__n_prop` | 54,107 | boot `isPropagating` 调用次数 |
| doGet calls | 26,970 | 标识符求值走 `env._get` 的次数 |
| 　↳ hop1 | 17,813 | 其中 95.2% 本层命中(标识符共 18,712 个) |
| 　↳ parent | 9,157 | 父链穿透(≈899 个唯一未命中 × 平均 ~9 层) |
| `callFunctionInner` | 5,964 | boot 侧函数调用(用户函数分支 3,562) |
| boot Environment 创建 | 3,563 | 仅 full-call 时创建(QLang 数据,非瓶颈) |

evaluate 直方图(44,852):Identifier 18,712(**41.7%**)、BinaryOp 6,018、Call 5,773、MemberAccess 5,741、IndexAccess 1,080、其他 7,528。

## 根因

boot 解释器的 `evaluate` 循环运行在 **host 之上**,循环体内每个 helper 调用(`isPropagating`、`doGet`、`isTruthy`、`isErrorVal`、`isWrapped`、`typeTag`、`callFunctionInner`……)都是 host `call_function_inner` 对 boot 闭包的一次 User Function 分派。宿主每分派一次,固定付出(`src/interpreter.rs:687-786`):

1. 错误值参数扫描(`args.iter().find`)
2. 柯里化分支判断(参数不足 → 构造 `<curried>`)
3. 元数校验
4. 参数标注类型检查(循环)
5. 递归深度护栏(计数 + 自增)
6. **`child_env` 分配**:`Rc::new(RefCell::new(Environment::with_parent(...)))` + 新 HashMap
7. **每参数 `define_annotated`**:HashMap insert
8. **`call_stack.push`**:含 `"unknown".to_string()` 的一次 String 堆分配
9. `run_block` 执行函数体
10. `recursion_depth -= 1`、`call_stack.pop()`

且 helper 是**嵌套**的:`isPropagating(v)` → `isErrorVal(v)` → `isWrapped(v)` → `isError(v.type)`(native)。一次"传播检查"实际触发 **3 层 boot 闭包分派 + 1 次 native + 2–3 次包装成员探测**。54,107 次 `isPropagating` ≈ **~16 万次嵌套分派**;加 `evaluate` 44,852、`doGet` 26,970、`callFunctionInner` 5,964 及其余小 helper,解释期总 host User Function 分派量 ≈ **30 万次**。

**关键澄清**:boot Environment 对象(QLang 数据,仅 3,563 个)不是瓶颈;瓶颈是 **host 每次分派的固定机制开销 × 30 万次**。

### 已被否决的方向(证据)

1. **guard 内联进 evaluate**(上期,`probe_op20`):P1 21.5s vs P0 14.8s —— 给最大热循环加活、未减分派数,纯亏。
2. **Identifier 直读 `env._values` 快路径**(本期):语义正确(419/419,doGet 26,970→15,854)但 **5.20s vs 基线 4.82–4.87s** 反而更慢 —— boot 数据是双层包装,直读需 2 层 host Object 索引 + 额外 `isError` 分派,成本 > 省下的 1 次分派。

两条否决共同指向:**代价单位是 host 分派本身**;boot 层用"1 次分派换若干轻操作"必然亏。

## 设计

### 方案 A:host `call_function_inner` 分派开销裁剪(运行时机制,根治)

裁剪 User Function 分支的逐调用固定开销,按权重:

- **`child_env` 分配 + 参数绑定**(最重):热 helper(doGet/isPropagating 等)每次分派都 Rc+RefCell+HashMap+insert。可为小元数闭包换轻量局部绑定,或推迟/合并环境创建(需保持"局部参数优先于父链"的查找语义)。
- **`call_stack` String 分配**:`"unknown".to_string()` 每次分派堆分配,改静态借用/驻留。
- 扫描/柯里化/元数/标注检查相对轻,保留语义不动者。

允许性:属"编译器/运行时本身可以用到 host(Rust)";**零新 native**、零数据层改动、boot 代码不动。触碰 `src/interpreter.rs`(可能 `src/environment.rs`),需严格回归(字节级一致)。

预期:触及全部 ~30 万次分派;幅度取决于逐调用固定开销占比,**需实现后实测**,存在不确定性。

### 方案 B:boot 宏级调用削减(纯 QLang,立即兑现)

合并 evaluate 热路径的 N 层 helper 链。最大一处:**`isPropagating` 三合一**:

```ql
// 现状:3 层分派(isPropagating → isErrorVal → isWrapped)
let isPropagating = (v) -> { isErrorVal(v) && v.propagate == true; };

// 合并后:1 层分派,探测次数同量级,净减 2 次分派 + 冗余探测
let isPropagating = (v) -> {
  v != null && !isError(v.type) && v.type == "Error" && v.propagate == true;
};
```

`isErrorVal` / `isWrapped` 保留定义(其它调用点仍用)。54,107 次 × 省 2 次分派 ≈ **省 ~10.8 万次分派**(解释期总量约 1/3)。这**不是**被否决的"guard 内联"——evaluate 无新增工作、净操作数下降,属"宏级调用削减"(与已提交的 lexer split 重写同风格)。同类审计:evaluate 热路径其它 ≥2 层 helper 链一并合并。

预期:解释期 ~1/3 分派削减 → 明显变快。**零 native、零数据层、只碰 `bootstrapped/interpreter.ql` 少数函数体**,风险最低。

### 方案 C:Mu spine 缓存(类型计算专项,独立立项)

上期实测 Ch.6 提速 2.3×,但 Ch.7 浅递归收益小,且针对类型计算而非通用解释期;不并入本期。

### 为什么 A+B 而非单做其一

B 纯 QLang、零风险、改动极小,可**立即兑现并实测量级**;A 从根上降低每次分派的固定成本,覆盖全部 30 万次分派,但改 host 需严格回归。两者独立可叠加。建议 **B 先行、A 随后**:B 落地即有独立验证点,若 B 已明显达"明显变快",A 可放缓评估。

## 语义等价性验证

- **B**:合并前后 `isPropagating(v)` 对全部输入的真值表一致(Error+propagate / Error 非 propagate / 非 Error / null / 裸 host 值);`isErrorVal`/`isWrapped` 自身不动,其它调用点无感知。合并后代码路径可逐输入对照。
- **A**:host 输出行为不变 —— 错误值、类型检查、递归深度、调用栈语义照旧;用字节级 host/boot 对照 + difftest 三端 + verify_bootstrap 回归。

## 影响面分析

- **B**:仅 `bootstrapped/interpreter.ql` 内 `isPropagating`(及同类合并函数)的函数体;`export` 列表不动;demo/parser/lexer/stdlib 零改动;公开行为不变。
- **A**:`src/interpreter.rs` 的 `call_function_inner` 用户分支(可能含 `src/environment.rs`);不新增 native;boot/demo 零改动。需新增回归用例锁定分派语义。

## 验证策略

1. B 落地后:`./target/release/qlang bootstrapped/run_file.ql demo/type_gymnastics.ql` → host/boot 字节级一致 + `RESULT: 419/419 asserts passed`。
2. `difftest.py` 三端差分全绿;`verify_bootstrap` PASS/0 FAIL。
3. **计时必须配对交错消噪**:本机是手机级 Termux/proot(aarch64,walt 调控),热漂移 ±20%(已实测:同窗口内 INSTR/UNINSTR 交错后无差异,但跨窗口绝对值漂移高达 ~1.3s)。比较只能在**同一窗口内 A/B/A/B 配对**进行,不跨窗口比绝对值。
4. A 落地后重复 1–3,并加计数器回归(解释期分派量不回归)。

## 实测基线(2026-08-13,未改动,同一窗口交错)

| 项 | 值 |
|---|---|
| FULL | 6.10 / 6.10 / 6.14s |
| PARSE | 1.18 / 1.22s |
| LEX | 0.59 / 0.59s |
| 解释期 | ≈4.9s(≈80%) |
| 关键计数 | 见背景表 |

## Step B 实测结果(2026-08-13)

| 项 | 值 |
|---|---|
| A 态(Task 1,未优化,HEAD~2) | A1=4.833 / A2=4.890s,A 组中位数 ≈ 4.862s |
| B 态(Task 3,已优化,HEAD) | B1=4.772 / B2=4.770 / B3=4.820s,B 组中位数 = 4.772s |
| 同窗口交错 | B1→A1→B2→A2→B3,同一窗口内配对;收尾恢复 B 态,工作树 == HEAD |
| Task 3 计数器 | s509=0、s520=1133、s552=3、s821=4885、s822=4884、binop=4885 |
| 决策门结论 | **未达明显** |

**判定(决策门):** 按规则"B 组每值都显著小于 A 组每值(且 B 组中位数 < A 组中位数 × 0.9)"判"明显变快"。实测 B 组每值确实均小于 A 组每值,但 **B 中位数 4.772 < A 中位数 4.862 × 0.9 = 4.375 不成立**(实际 B ≈ A × 0.982,净提速仅 ≈1.8%);最接近的配对 B3=4.820 与 A1=4.833 仅差 0.013s(≈0.27%),完全落在 ±20% 热漂移内。**结论:未达明显** —— Step B 的 ~10.8 万次分派裁剪确实发生了(计数器见上),但此前 toChars/array-length 优化已吃掉了解释期主要瓶颈,剩余分派裁剪对端到端贡献不足 ~2%,被漂移吞噬。后续:**Step A(host `call_function_inner` 裁剪)另行立实现计划**。

## 不做的事(YAGNI)

- 不加 host 原生(零新 native,沿用上期否决)。
- 不改 `Value` / 数据表示(boot 包装语义是既有正确行为)。
- 不做 guard 内联 / Identifier 直读快路径(已证否决)。
- 不做 Mu spine 缓存(独立立项)。
- 不优化 lexing/parsing(已达标)。
