# Boot 解释器包装数组 `.length` O(1) 直读实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 boot 解释器包装数组的 `.length` 访问从 O(n) boot 循环重算改为 O(1) 直读 raw 数组长度,消除词法分析 O(n²),使 boot 整体运行 294.5s → ~60s 上下。

**Architecture:** `MemberAccess` 的 Array 分支读取 `obj.value.length`(raw JS 数组的 O(1) 属性)替代 `getArrayLength(obj.value)`(boot 层 O(n) 计数循环)。raw 数组是唯一真相源,不引入缓存、不写回、无失效口。删除因此变成死代码的 `getArrayLength` 与本就无调用的 `getArrayElement`。

**Tech Stack:** QLang(boot 解释器,运行于 Rust host);验证工具为 `difftest.py`(Python)、`verify_bootstrap.ql`、`demo/type_gymnastics.ql`。

## Global Constraints

- **范围**:仅 `bootstrapped/interpreter.ql`;测试辅助允许加一条 `difftest.py` 回归用例。**不碰** `src/`(host Rust)、demo、parser、master 分支。
- **字节级一致**:`demo/type_gymnastics.ql` 在 host 与 boot 下输出字节级相同,且 `RESULT: 419/419 asserts passed`。
- **差分全绿**:`difftest.py` 结束于 `All identical ✔`,新增用例 c40 输出 `c40=3`。
- **自举语义**:`verify_bootstrap.ql` 33/33 PASS、0 FAIL。
- **零状态**:不引入缓存字段、不做写回;raw 数组是 `.length` 唯一真相源(native `std.Array.push(a.value)(x)` 原地变异后 `.length` 必须仍新鲜)。
- **复杂度**:`.length` 读路径 O(1);删除 `getArrayLength`/`getArrayElement` 后无死代码残留。
- **性能目标**:boot lexing 146.6s → 个位数秒;boot 整体 294.5s → ~60s 上下(基线见 Task 1 Step 1)。
- 在分支 `rust` 上工作。

---

### Task 1: 包装数组 `.length` 直读 + 删除死代码 + 回归用例

**Files:**
- Modify: `bootstrapped/interpreter.ql:603-605`(MemberAccess Array `length` 分支)
- Modify: `bootstrapped/interpreter.ql:59-80`(删除 `getArrayLength` 与 `getArrayElement`,保留 `pushArray` 于第 82-85 行)
- Modify: `difftest.py:362-363`(SAFE_CASES 末尾 `d09` 之后追加 `c40`)

**Interfaces:**
- Consumes: 无(本计划唯一任务,基线状态为当前 HEAD,已确认 difftest 绿、boot demo 294.5s)。
- Produces: 包装数组 `.length` 的真相源改为 `obj.value.length`(raw O(1));`getArrayLength`/`getArrayElement` 不再存在(无调用点依赖,已确认);新差分用例 `c40`(native push 后 `.length` 新鲜性回归守护)。

- [ ] **Step 1: 确认基线**(当前已实测,直接引用)

当前 HEAD 已确认的基线(本会话测得,无需重跑 5 分钟 boot demo):

| 项 | 基线 |
|---|---|
| `difftest.py` | `All identical ✔`(~1m28s) |
| `verify_bootstrap.ql` | 33/33 PASS,0 FAIL |
| boot demo 总耗时 | 294.5s |
| boot demo lexing 阶段 | 146.6s |
| boot demo 执行(Ch.1-15) | ~141s |

验证:确认工作区无未提交改动(除已提交的 spec `fa20720`),`git status` 干净。

- [ ] **Step 2: 改 MemberAccess Array `length` 分支直读真相源**

在 `bootstrapped/interpreter.ql` 中,`else if t == "Array"` 分支(约第 603 行)的 `fieldName == "length"` 处理:

```ql
// before (line ~604-605)
          if fieldName == "length" {
            { type: "Number", value: getArrayLength(obj.value) };
          } else if fieldName == "type" {

// after
          if fieldName == "length" {
            { type: "Number", value: obj.value.length };
          } else if fieldName == "type" {
```

只改这一行表达式,分支结构不动。

- [ ] **Step 3: 删除死代码 `getArrayLength` 与 `getArrayElement`**

在 `bootstrapped/interpreter.ql` 中删除第 59-80 行整块(注释行 `// Helper functions that don't use std` 保留,`pushArray` 定义保留):

```ql
// DELETE this entire block (lines 59-80):
  let getArrayLength = (arr) -> {
    let count = 0;
    let i = 0;
    while i < arr.length {
      count = count + 1;
      i = i + 1;
    }
    count;
  };

  let getArrayElement = (arr, index) -> {
    let i = 0;
    let result = null;
    while i < arr.length {
      if i == index {
        result = arr[i];
      }
      i = i + 1;
    }
    result;
  };
```

删除后确认 `pushArray`(第 82-85 行)仍在,且文件内不再出现 `getArrayLength`/`getArrayElement`:

Run: `grep -n "getArrayLength\|getArrayElement" bootstrapped/interpreter.ql`
Expected: 无输出(已全部删除)

- [ ] **Step 4: 加 difftest 回归用例 c40(native push 后 `.length` 新鲜性)**

在 `difftest.py` 的 `SAFE_CASES` 列表末尾(`("d09", ...),` 之后、`]` 之前)追加:

```python
    ("c40", 'let a = [1, 2]; std.Array.push(a)(3); a.length;'),  # native raw-array mutation stays visible to .length (freshness invariant)
```

该用例的 host/boot 输出已实测均为 `c40=3`,守护「raw 数组是 `.length` 真相源」——若将来有人把 `.length` 改回缓存且漏同步,此用例即红。

- [ ] **Step 5: 跑 difftest 确认无回归 + c40 绿**

Run: `python3 difftest.py > /tmp/dt_after.txt 2>&1; tail -1 /tmp/dt_after.txt`
Expected: 末行 `All identical ✔`。
(safe-batch 用例只在**发散时**打印逐行;c40 是 safe case,其守护由「All identical ✔」承载——若 host 与 boot 的 `.length` 语义开始不一致,c40 必然发散并被 difftest 报告。)(~1m28s)

- [ ] **Step 6: 跑 verify_bootstrap 确认自举语义**

Run: `cargo run --quiet -- verify_bootstrap.ql 2>&1 | grep "^PASS" | wc -l; cargo run --quiet -- verify_bootstrap.ql 2>&1 | grep "^FAIL"`
Expected: 第一命令输出 `33`,第二命令无输出。

- [ ] **Step 7: demo 字节级一致 + 419/419**

Run:
```bash
cargo run --quiet -- demo/type_gymnastics.ql > /tmp/tg_host.out
cargo run --quiet -- bootstrapped/run_file.ql demo/type_gymnastics.ql | awk '/^Interpreting\.\.\.$/ {found=1; next} found && !/^Execution complete\.$/ {print}' > /tmp/tg_boot.out
diff /tmp/tg_host.out /tmp/tg_boot.out && echo BYTE-IDENTICAL
grep "RESULT:" /tmp/tg_boot.out
```
Expected: `BYTE-IDENTICAL` 且 `RESULT: 419/419 asserts passed`。
(注意:此步 boot demo 需 ~60s,较原 294.5s 已大幅缩短;若耗时异常仍接近 5 分钟,说明优化未生效,回到 Step 2-3。)

- [ ] **Step 8: 复测 boot demo 耗时(优化生效证明)**

Run: `python3 /tmp/timed_run.py "cargo run --quiet -- bootstrapped/run_file.ql" demo/type_gymnastics.ql`
Expected: `Lexing...` 阶段从 146.6s 降到个位数秒;`total:` 从 294.5s 降到 ~60s 上下。记录实测表到 commit message。

- [ ] **Step 9: Commit**

```bash
git add bootstrapped/interpreter.ql difftest.py
git commit -m "perf(boot): read wrapped-array .length directly from raw array (O(1))

MemberAccess Array .length ran getArrayLength(), an O(n) boot-loop count
that duplicates raw array .length — making every `arr[arr.length] = x`
append and `while i < arr.length` traversal O(n^2). Lexing 146.6s -> ~Xs,
total 294.5s -> ~Ys. Delete now-dead getArrayLength/getArrayElement; add
difftest c40 guarding the raw-array-as-truth-source freshness invariant.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

(把 Step 8 实测的 X、Y 填入 commit message。)

---

## 验证汇总(全部通过才算任务完成)

1. `difftest.py` → `All identical ✔`,含 c40
2. `verify_bootstrap.ql` → 33 PASS / 0 FAIL
3. demo host/boot 字节级一致 + `RESULT: 419/419 asserts passed`
4. boot lexing 146.6s → 个位数秒;boot 整体 294.5s → ~60s 上下
5. `git status` 干净;`grep getArrayLength bootstrapped/interpreter.ql` 无输出
