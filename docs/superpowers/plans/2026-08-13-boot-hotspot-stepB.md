# Boot 解释期热点 Step B 实现计划(纯 QLang 宏级调用削减)

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 boot 解释期 ≈30 万次 host User Function 分派里最重的一批**净削减**:先合并 `isPropagating` 三层闭包链(≈10.8 万次分派),再按计数器审计并合并 evaluate 热路径其余热 helper 链,验收标准是"明显变快"且 host/boot 字节级一致、419/419、difftest 全绿、verify_bootstrap PASS/0 FAIL。

**Architecture:** 不改 host(Rust)、零新 native、零数据层改动。只改 `bootstrapped/interpreter.ql` 的少量 helper 函数体与热调用点:把 N 层 boot 闭包分派合并成 1 层,探测序列与短路顺序**逐位不变**(纯文本内联,谓词无副作用、不捕获外部),故逐输入真值表等价。改动对 host 输出不可见,靠全量回归锁语义。

**Tech Stack:** QLang(boot 解释器源码)、Python(difftest.py)、Rust host(仅用于运行与计时,不改源码)。

**Spec:** `docs/superpowers/specs/2026-08-13-boot-hotspot-design.md`(方案 B 部分;方案 A host 裁剪与本计划**互斥可选**,见 Task 4 决策门)

## Global Constraints

以下从 spec 逐字摘录,每个 Task 的验收都隐含包含它们:

- **零新 native**:只复用既有运行时机制;QLang 的数据与语言层函数必须由 QLang 实现("离开 rust 的摇篮"——调用原生方法即违反)。
- **字节级一致**:`./target/release/qlang bootstrapped/run_file.ql demo/type_gymnastics.ql` 与 host 直跑输出逐字节一致 + `RESULT: 419/419 asserts passed`;`python3 difftest.py` 三端 `All identical ✔`;`./target/release/qlang verify_bootstrap.ql` `PASS`/0 FAIL。
- **改动面**:只碰 `bootstrapped/interpreter.ql` 少量函数体/调用点 + `difftest.py` 用例列表;`export` 列表不动;demo/parser/lexer/stdlib 零改动。
- **计时纪律**:本机是手机级 Termux/proot,热漂移 ±20%。任何计时结论只能**同一窗口内 A/B/A/B 配对交错**,不跨窗口比绝对值。
- **分支**:只在 `rust` branch 工作;每个 Task 以 commit 收尾,提交前先跑该 Task 的全量验证。

## File Structure

- `difftest.py` — Task 1 在 `RISKY_CASES` 列表(434 行)末尾追加 5 个传播真值表锁定用例 r35–r39。职责:语义回归基线(先测后改)。
- `bootstrapped/interpreter.ql` — Task 2 改 `isPropagating`(88–90)一处函数体;Task 3 改 5 个 `isErrorVal` 热调用点(509/520/552/821/822)。职责:分派削减本体。
- `/tmp/bootprobe2/*.ql` — Task 3 计数器探针副本(临时,不提交,与工作树隔离)。
- `docs/superpowers/specs/2026-08-13-boot-hotspot-design.md` — Task 4 追加"实测结果"节。
- 无新文件入仓;计时用 `/usr/bin/time`,不需要重建(QLang 源码在运行时加载,改 .ql 无需 cargo build)。

## 背景数据(探针,2026-08-13)

| 项 | 值 |
|---|---|
| 解释期 | ≈4.9s(FULL 6.10–6.14s − PARSE 1.18–1.22s)≈ 80% |
| 总 host User Function 分派 | ≈30 万次 |
| `isPropagating` 调用 | 54,107 → 合并后每次省 2 次分派 ≈ **省 10.8 万次** |
| evaluate 直方图 | Identifier 18,712 / BinaryOp 6,018 / Call 5,773 / MemberAccess 5,741 / IndexAccess 1,080 |

已否决(不改):guard 内联进 evaluate(P1 21.5s vs P0 14.8s);Identifier 直读 `env._values` 快路径(5.20s vs 4.82–4.87s 反而更慢)。代价单位是 **host 分派本身**;boot 层"1 次分派换若干轻操作"必然亏。

---

### Task 1: 建立语义回归基线(先测后改)

**Files:**
- Modify: `difftest.py:434`(在 `RISKY_CASES` 列表末尾、`("r34", ...)` 之后追加 5 个用例)
- Test: `python3 difftest.py`

**Interfaces:**
- Consumes: 现状(未改动)的 host 与 boot 解释器
- Produces: 5 个新差分用例 r35–r39,锁定 `isPropagating`/`isErrorVal` 真值表;一份全量验证基线(绿)

**为什么是"先测后改":** 本次改动的性质是**语义保持重构**——测试在改动前就是绿的,不存在"红→绿"的失败测试。TDD 的正确落地方式是把语义锁定成回归基线:先让新用例在**未改动**代码上跑绿(证明 oracle 有效、host/boot 现状一致),再让改动保持它绿(改动后任何一处语义漂移都会立刻被 r35–r39 或既有 419/419 抓出)。

- [ ] **Step 1: 在 `RISKY_CASES` 末尾追加 5 个传播真值表锁定用例**

在 `difftest.py` 中 `("r34", '(Error.raise("boom") ?) ?? 42;'),` 那一行之后追加(每个用例都注释锁定哪条热路径;所有模式与既有已证用例 r22–r34 同构,host/boot 现状一致,防止把新分歧当基线):

```python
    # ---- Step B: isPropagating / isErrorVal 真值表锁定(2026-08-13 Step B) ----
    # 共同基底: `let e = 1 / 0;` 把非传播错误值(propagate:false)绑进变量。
    #   r35 锁 isPropagating-在错误值上为 FALSE(热路径,506 行)+ ?? 回退分支的 isErrorVal(509 行)→ 42。
    #   r36/r37 锁 &&/|| 错误左操作数分支(520 行)→ evalBinaryOp(525 行)委托构造错误 → 两端都是错误值。
    #   r38 锁 UnaryOp ? 分支(552 行)构造 propagate:true 并上传 → 顶层错误。
    #   r39 锁错误值经变量进入函数实参 → 参数拒绝(与 r32 同构但错误来自 let 绑定)。
    ("r35", "let e = 1 / 0; e ?? 42;"),
    ("r36", "let e = 1 / 0; e && true;"),
    ("r37", "let e = 1 / 0; e || true;"),
    ("r38", "1 / 0 ?;"),
    ("r39", "let f = (x) -> x; let e = 1 / 0; f(e);"),
```

- [ ] **Step 2: 跑 difftest,确认基线为绿(含新用例)**

Run: `python3 difftest.py`
Expected: 结尾 `All identical ✔`;`=== Risky cases (isolated) ===` 中 r35–r39 无 divergence 行。若任一新用例报 divergence,说明该用例本身不可靠或暴露了真实 host/boot 分歧——**停在 Task 1**,回到 Phase 1 调查(用例写法 vs 语义缺陷),修复用例或单独立项,不允许带红基线进 Task 2。

- [ ] **Step 3: 跑全量验证基线并记录**

Run:
```bash
./target/release/qlang demo/type_gymnastics.ql > /tmp/host_base.out
./target/release/qlang bootstrapped/run_file.ql demo/type_gymnastics.ql > /tmp/boot_base.out
diff /tmp/host_base.out /tmp/boot_base.out && echo "BYTE-IDENTICAL"
```
Expected: `diff` 无输出(字节级一致)+ 两份输出均含 `RESULT: 419/419 asserts passed`(boot 侧多几行 banner,属预期差异——若逐字节 diff 失败,改用剥离 banner 后的 diff,spec 已允许)。

再 Run: `./target/release/qlang verify_bootstrap.ql`
Expected: 全 `PASS`,0 个 `FAIL`。

- [ ] **Step 4: Commit(只提交测试,不动 interpreter.ql)**

```bash
git add difftest.py
git commit -m "test(boot): add r35-r39 propagation truth-table diff cases (Step B baseline)"
```

---

### Task 2: 合并 `isPropagating` 三层闭包链(本方案主菜)

**Files:**
- Modify: `bootstrapped/interpreter.ql:88-90`
- Test: `python3 difftest.py` + Task 1 Step 3 的三条验证命令

**Interfaces:**
- Consumes: Task 1 的全量基线(绿)
- Produces: 合并后的 `isPropagating`(1 层分派),`isErrorVal`/`isWrapped` **保留定义**(其它调用点仍用,spec「影响面分析」要求);54,107 次调用 × 省 2 次分派 ≈ 10.8 万次净削减

- [ ] **Step 1: 改写 `isPropagating` 为合并形式**

旧(88–90):
```ql
  let isPropagating = (v) -> {
    isErrorVal(v) && v.propagate == true;
  };
```

新(合并 `isErrorVal`→`isWrapped` 两层为纯文本内联,注释注明等价论证):
```ql
  let isPropagating = (v) -> {
    // Step B: inlined isErrorVal(isWrapped(v)) && propagate — one boot-closure
    // dispatch instead of three (isPropagating → isErrorVal → isWrapped). Pure
    // textual expansion: same probe sequence (v.type ×2, v.propagate ×1), same
    // left-to-right short-circuit, predicates capture nothing — truth-table
    // identical for every input, only host dispatches drop (2/call × 54,107).
    v != null && !isError(v.type) && v.type == "Error" && v.propagate == true;
  };
```

等价性自查(逐输入真值表,可与 spec「语义等价性验证」对照):

| v | isErrorVal(v) 旧 | isPropagating 旧 | 合并后 |
|---|---|---|---|
| null | false(`v != null` 短路) | false(短路,`.propagate` 未探) | false(同短路) |
| 裸 host 值/native/std | false(`isError(v.type)` 真) | false | false(同) |
| boot 非 Error 包装 | false(`type != "Error"`) | false | false(同) |
| boot Error `propagate:false` | true | false(`== true` 假) | false(同) |
| boot Error `propagate:true` | true | true | true(同) |
| 裸 Error(泄漏) | 仅当其 kind 恰为 "Error" | 依 `.propagate` 探测 | 同(探测序列不变) |

每一行合并后与旧值一致——**结论:纯内联,无行为变化**。

- [ ] **Step 2: 跑 Task 1 Step 3 的三条全量验证命令**

Run: `python3 difftest.py`
Expected: `All identical ✔`,r35–r39 仍绿(尤其 r35/r36/r37:它们锁的就是 `isPropagating` 在错误值上 FALSE 后走 `isErrorVal` 的热路径)。

Run: 字节级 diff 三命令 + `verify_bootstrap.ql`
Expected: `BYTE-IDENTICAL` + `419/419` + PASS/0 FAIL,与基线一致。

- [ ] **Step 3: Commit**

```bash
git add bootstrapped/interpreter.ql
git commit -m "perf(boot): merge isPropagating via isErrorVal/isWrapped inline (-108k dispatches)"
```

---

### Task 3: 计数器审计 + 热调用点 `isErrorVal` 内联(证据驱动)

**Files:**
- Create(临时,不提交): `/tmp/bootprobe2/*.ql`(工作树 boot 全套的计数器副本)
- Modify: `bootstrapped/interpreter.ql` 的 5 个 `isErrorVal` 直调点(509/520/552/821/822)
- Test: 同 Task 2 Step 2

**Interfaces:**
- Consumes: Task 2 的合并后 `isPropagating`;既有探针结构 `/tmp/bootprobe/`
- Produces: 证据支撑的决策(哪些点内联、哪些不值得)+ 若干处内联后的热路径;计数器结论写入 commit message / Task 4 报告

**为什么需要计数器:** `isErrorVal` 直调点分布在不同操作符分支上(`??`/`&&`/`||`/`?`/二元委托),频率未知。按 spec「同类审计:evaluate 热路径其它 ≥2 层 helper 链一并合并」,**只合并计数显著的点**(阈值:≥1000 次/趟 demo),避免为 <1% 的分派量增加可读性负担。每个内联都是 `isErrorVal` 体(`isWrapped(v) && v.type == "Error"`)再内联 `isWrapped` 体(`v != null && !isError(v.type)`)的纯文本展开——与 Task 2 同一等价论证,短路顺序不变。

- [ ] **Step 1: 造计数器探针并测量**

把工作树 boot 全套复制到 `/tmp/bootprobe2/`(与工作树隔离):

```bash
mkdir -p /tmp/bootprobe2
cp bootstrapped/stdlib.ql bootstrapped/tokens.ql bootstrapped/lexer.ql bootstrapped/ast.ql \
   bootstrapped/parser.ql bootstrapped/main.ql /tmp/bootprobe2/
cp bootstrapped/interpreter.ql /tmp/bootprobe2/
cp bootstrapped/run_file.ql /tmp/bootprobe2/run_file2.ql
```

在 `/tmp/bootprobe2/interpreter.ql` 的 `let Interpreter` 作用域内、`let isPropagating` 定义附近加共享计数器对象:

```ql
  let __isErrC = { s509: 0, s520: 0, s552: 0, s821: 0, s822: 0, binop: 0 };
```

并在 5 个直调点各插一行自增(`binop` 挂在 `evalBinaryOp` 入口):

- 509(`??` 分支 `if isErrorVal(left) {` 之前):`__isErrC.s509 = __isErrC.s509 + 1;`
- 520(`&&`/`||` 分支同前):`__isErrC.s520 = __isErrC.s520 + 1;`
- 552(`?` 分支 `if isErrorVal(val) {` 之前):`__isErrC.s552 = __isErrC.s552 + 1;`
- 821:`__isErrC.s821 = __isErrC.s821 + 1;`
- 822:`__isErrC.s822 = __isErrC.s822 + 1;`
- `evalBinaryOp` 入口第一行:`__isErrC.binop = __isErrC.binop + 1;`

**导出方式沿用既有探针模式**(/tmp/bootprobe/interpreter.ql:1131-1138:计数器是 Interpreter 闭包内的局部量,main.ql 读不到裸绑定,必须经导出对象上的**闭包**读取)。把 `/tmp/bootprobe2/interpreter.ql` 的 export 对象(工作树 1098 行 `{ runProgram: runProgram, evaluate: evaluate, globalEnv: globalEnv };`)改为:

```ql
  { runProgram: runProgram, evaluate: evaluate, globalEnv: globalEnv, __isErrCStats: () -> {
    std.Number.toString(__isErrC.s509) + "," + std.Number.toString(__isErrC.s520) + "," + std.Number.toString(__isErrC.s552) + "," + std.Number.toString(__isErrC.s821) + "," + std.Number.toString(__isErrC.s822) + "," + std.Number.toString(__isErrC.binop);
  } };
```

在 `/tmp/bootprobe2/main.ql` 的 `runSource` 中 `let result = interpreter.runProgram(program);` 之后插一行:

```ql
  println("ISERRC " + interpreter.__isErrCStats());
```

Run: `./target/release/qlang /tmp/bootprobe2/run_file2.ql demo/type_gymnastics.ql | tail -2`
Expected: 一行 `ISERRC <s509>,<s520>,<s552>,<s821>,<s822>,<binop>`。预期量级(依 BinaryOp 6,018 推算):`binop` ≈ 6,000+;`s821`+`s822` ≈ 12,000+(每个 binop 各一次);`s509`/`s520`/`s552` = `??`/`&&`/`||`/`?` 在 demo 中的实际次数。**记录这些数字**——Task 4 报告与 commit message 都引用它们。

- [ ] **Step 2: 按计数内联(阈值 ≥1000)**

对计数 ≥1000 的点,做如下替换(给出全部 5 处;计数 <1000 的点**不动**并在 commit message 记录"跳过,计数不足"):

**① 821/822(evalBinaryOp 委托检查,预计最大头):**

旧:
```ql
    // The operation itself errors: error operand → delegate to the host to construct a new error (with cause), message matches the host
    if isErrorVal(left) { return evalDelegated(op, left, right); }
    if isErrorVal(right) { return evalDelegated(op, left, right); }
```

新:
```ql
    // The operation itself errors: error operand → delegate to the host to construct a new error (with cause), message matches the host
    // Step B: isErrorVal inlined (isWrapped body inlined too) — same probes, -2 dispatches per check
    if left != null && !isError(left.type) && left.type == "Error" { return evalDelegated(op, left, right); }
    if right != null && !isError(right.type) && right.type == "Error" { return evalDelegated(op, left, right); }
```

**② 509(`??` 分支):**

旧:
```ql
      if expr.operator == "??" {
        // ?? fallback: an Error left operand is replaced by the right operand
        if isErrorVal(left) {
```
新:
```ql
      if expr.operator == "??" {
        // ?? fallback: an Error left operand is replaced by the right operand
        if left != null && !isError(left.type) && left.type == "Error" {
```

**③ 520(`&&`/`||` 分支):**

旧:
```ql
        if isErrorVal(left) {
          // Error left operand: the host's operation zone poisons BEFORE the
```
新:
```ql
        if left != null && !isError(left.type) && left.type == "Error" {
          // Error left operand: the host's operation zone poisons BEFORE the
```

**④ 552(`?` 分支):**

旧:
```ql
        // ? propagation: an Error operand becomes a propagate-marked wrapper
        if isErrorVal(val) {
```
新:
```ql
        // ? propagation: an Error operand becomes a propagate-marked wrapper
        if val != null && !isError(val.type) && val.type == "Error" {
```

等价性论证(与 Task 2 同一表格):`isErrorVal(v)` ≡ `v != null && !isError(v.type) && v.type == "Error"`(把 `isWrapped` 体展开进 `isErrorVal` 体,短路顺序与探测次数逐位不变);调用点只把它当布尔用(全部是 `if` 条件),行为零变化。

- [ ] **Step 3: 全量验证**

Run: `python3 difftest.py` → `All identical ✔` + r35–r39 绿。
Run: Task 1 Step 3 的字节级 diff 三命令 + `verify_bootstrap.ql` → `BYTE-IDENTICAL` + `419/419` + PASS/0 FAIL。

- [ ] **Step 4: Commit(含计数器结论)**

```bash
git add bootstrapped/interpreter.ql
git commit -m "perf(boot): inline isErrorVal at hot call sites (measured s821+s822=~12k, ...)"
```

(把 Step 1 实测的 `s509/s520/s552/s821/s822/binop` 数字填进 commit message;跳过的点注明计数。)

---

### Task 4: 同窗口交错计时 + 决策门 + spec 实测结果

**Files:**
- Modify: `docs/superpowers/specs/2026-08-13-boot-hotspot-design.md`(在「实测基线」节后追加「Step B 实测结果」节)

**Interfaces:**
- Consumes: Task 1 基线 commit(HEAD 之前)、Task 3 成果(当前 HEAD)
- Produces: 同窗口交错计时结论;决策门输出(够 → 停 / 不够 → 立 Step A 计划);spec 实测结果节

**计时纪律(硬性):** 本机热漂移 ±20%,**只信同窗口内 A/B/A/B 交错**。QLang 源码运行时加载,改 .ql 无需重建——**不用 `git stash`**(此时所有改动已提交,stash 无内容),改为在两份 `interpreter.ql` 文件内容间即时 `cp` 切换:A 态 = Task 1 commit 的版本(未优化),B 态 = 当前 HEAD(Task 3 成果)。

- [ ] **Step 1: 同窗口 A/B/A/B 交错计时**

```bash
cd /root/projects/QLang
# 取两份 interpreter.ql:A 态 = Task 1 commit(HEAD~2),B 态 = 当前 HEAD(Task 3 成果)
git show HEAD~2:bootstrapped/interpreter.ql > /tmp/intr_A.ql
cp bootstrapped/interpreter.ql /tmp/intr_B.ql
# 计时用 FULL 全流程,同一窗口交错 2 轮 A + 3 轮 B
B1=$(/usr/bin/time -f "%e" ./target/release/qlang bootstrapped/run_file.ql demo/type_gymnastics.ql 2>&1 >/dev/null | tail -1)
cp /tmp/intr_A.ql bootstrapped/interpreter.ql
A1=$(/usr/bin/time -f "%e" ./target/release/qlang bootstrapped/run_file.ql demo/type_gymnastics.ql 2>&1 >/dev/null | tail -1)
cp /tmp/intr_B.ql bootstrapped/interpreter.ql
B2=$(/usr/bin/time -f "%e" ./target/release/qlang bootstrapped/run_file.ql demo/type_gymnastics.ql 2>&1 >/dev/null | tail -1)
cp /tmp/intr_A.ql bootstrapped/interpreter.ql
A2=$(/usr/bin/time -f "%e" ./target/release/qlang bootstrapped/run_file.ql demo/type_gymnastics.ql 2>&1 >/dev/null | tail -1)
cp /tmp/intr_B.ql bootstrapped/interpreter.ql
B3=$(/usr/bin/time -f "%e" ./target/release/qlang bootstrapped/run_file.ql demo/type_gymnastics.ql 2>&1 >/dev/null | tail -1)
# 收尾恢复 B 态(工作树 == HEAD),并确认无残留差异
git status --short   # 期望:空(或仅未跟踪文件)
echo "A1=$A1 A2=$A2 B1=$B1 B2=$B2 B3=$B3"
```

Expected: `A*` 应 ≈ 基线 6.1s 量级,`B*` 应明显低于 `A*`(Step B 净减 ≈10.8 万 + Task 3 若干万次分派)。**判定只看 A 与 B 各自组内配对**:若 B 组每值都显著小于 A 组每值(且 B 组中位数 < A 组中位数 × 0.9),判"明显变快";若组间重叠(漂移吞噬差异),判"未达明显",不跨窗口补测。

可选归因:若想单独看 `isPropagating` 合并(Task 2)的贡献,可额外把 `HEAD~1:bootstrapped/interpreter.ql` 作为中间态加一组 `git show HEAD~1:... > /tmp/intr_M.ql` 的 M 采样;非必需,Step 1 的 A/B 配对已足以出决策。

- [ ] **Step 2: 决策门**

- **够 → 停**:把结论写进 spec,Step B 收尾,不进入 Step A(host 裁剪)计划;本计划结束。
- **不够 → 立 Step A 计划**:spec 的「方案 A:host call_function_inner 分派开销裁剪」已给出方向(先量 child_env 分配、`call_stack` `"unknown".to_string()` 堆分配),但**另写一份实现计划**,不并入本计划(它碰 `src/interpreter.rs`,需独立回归)。

- [ ] **Step 3: 把实测结果写回 spec 并提交**

在 `docs/superpowers/specs/2026-08-13-boot-hotspot-design.md` 的「实测基线(2026-08-13,未改动,同一窗口交错)」表后追加一节,内容为实际数字:改动前后同一窗口交错计时表、`s509/s520/s552/s821/s822/binop` 计数器、决策门结论。提交时带上:

```bash
git add docs/superpowers/specs/2026-08-13-boot-hotspot-design.md
git commit -m "docs(boot): record Step B measured results (A x vs B y, decision: <stop|proceed to A>)"
```

---

## Self-Review(已执行)

**Spec 覆盖:**
- B 方案主菜(isPropagating 三合一)→ Task 2 ✓
- B 方案"同类审计:evaluate 热路径其它 ≥2 层 helper 链一并合并"→ Task 3(计数器门控)✓
- "isErrorVal/isWrapped 保留定义"→ Task 2 不动它们、Task 3 只在热调用点内联、定义保留 ✓
- "export 列表不动"→ 未触碰 1098 行 ✓
- 语义等价性验证(spec「语义等价性验证」节)→ Task 1 基线 + 每 Task 全量回归 + Task 2 真值表 ✓
- 影响面分析(仅 interpreter.ql + difftest.py)→ 全计划仅此两文件 ✓
- 验证策略 1–3(字节级 + difftest + 同窗口交错计时)→ Task 1/2/3 Step 验证 + Task 4 ✓
- 不做的事(YAGNI):无新 native ✓、不改 Value ✓、不做 guard 内联/Identifier 快路径 ✓、不做 Mu spine ✓、**不做 Step A(host 裁剪)**——留给决策门 ✓

**占位符扫描:** 全部步骤含真实代码/命令;Task 3 Step 2 的 5 处内联完整给出;唯一"条件性"步骤(Task 3 阈值、Task 4 决策门)都有明确判定规则与具体后续动作,非占位。

**类型一致性:** `isPropagating`/`isErrorVal` 合并前后签名不变(单参数 `v`);调用点只当布尔用;计数器对象名 `__isErrC` 在 Task 3 全步骤一致;r35–r39 的 cid 与既有 r34 不冲突(已查 difftest.py:451–470)。

## 关键风险与缓释

1. **Task 1 新用例 pre-change 分歧**:用例全部与既有已证模式同构;若仍分歧,Task 1 Step 2 明确要求停下调查,不进 Task 2。
2. **Task 3 内联破坏等价**:纯文本展开 + 全量回归;`if` 条件里的错误值探测行为在展开前后一致(短路顺序不变)。
3. **计时被热漂移吞噬**:Task 4 只做同窗口 A/B 组内配对,组间重叠即判"未达明显",不硬造结论。
