# Step A: host call_function_inner 固定机制开销裁剪 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 裁剪 Rust host `call_function_inner` 用户分支的逐调用固定开销(`call_stack` 每调用 `"unknown"` String 堆分配 + 每参数 name String clone),以同窗口 A/B 配对实测判定是否"明显变快";并如实记录决策门结论(够 → 停;不够 → 停止 host 机制方向、不硬造结论)。

**Architecture:** 两个独立、低风险的宿主侧(编译器/运行时机制)裁剪,均不动 boot/QLang 层源码与数据表示:

1. **`CallFrame.path: String → Cow<'static, str>`**:调用热路径的 `"unknown".to_string()`(每次分派一次堆分配)改为 `Cow::Borrowed("unknown")`(零分配);程序级帧仍为 `Cow::Owned(真实路径)`,`run_import` 相对路径解析语义不变。
2. **`Environment.values: HashMap<String, Binding> → HashMap<Rc<str>, Binding>` + `FunctionValue` 预建 `param_keys: Rc<Vec<Rc<str>>>`**:调用热路径每参数绑定由 `param.name.clone()`(String 堆分配)改为 `Rc::clone`(引用计数 +1,零分配)。`Rc::from(String)` 复用 String 缓冲(单次分配),`define(name: String)` 的 20 处调用点零改动;`&str` 查找经 `Borrow<str> for Rc<str>` 原样工作。

回归门:字节级 host/boot 一致 + `RESULT: 419/419` + difftest 三端 `All identical ✔` + verify_bootstrap PASS/0 FAIL + `cargo test` 34 绿。最后 Task 3 以两套预编译二进制同窗口 A/B/A/B 交错计时,出决策门并写回 spec。

**Tech Stack:** Rust(host:`src/interpreter.rs`、`src/environment.rs`、`src/value.rs`)、`cargo build --release`、`python3 difftest.py`、bash 内建 `time`(`/usr/bin/time` 本机缺失,沿用 Step B Task 4 已证等价方案)。

**Spec:** `docs/superpowers/specs/2026-08-13-boot-hotspot-design.md` — 方案 A(lines 62-72)、Step B 实测结果(lines 127-137,决策门规则与"另立实现计划"承诺)。

## Global Constraints

- **零新 native**:只复用既有运行时机制;QLang 的数据与语言层函数必须保持 QLang 实现("离开 rust 的摇篮")。本计划只改 host Rust,不改 `bootstrapped/*.ql` 与 `demo/*`。
- **只在 branch `rust` 工作**,不在 master。
- **回归门(每 Task 提交前必须全绿)**:
  - `cargo test --release` → 34 passed / 0 failed;
  - host 直跑 vs boot 自举跑 `demo/type_gymnastics.ql` 字节级一致(剥 12 行 boot banner + `^Execution complete\.$` 后 `diff` 空)+ 两者 `RESULT: 419/419 asserts passed`;
  - `python3 difftest.py` → `All identical ✔`,零 divergence/mismatch;
  - `./target/release/qlang verify_bootstrap.ql` → PASS/0 FAIL。
- **计时只信同窗口内 A/B/A/B 配对交错**(本机热漂移 ±20%,跨窗口漂移 ~1.3s);决策门规则逐字:"若 B 组每值都显著小于 A 组每值(且 B 组中位数 < A 组中位数 × 0.9),判'明显变快';若组间重叠(漂移吞噬差异),判'未达明显',不跨窗口补测。"
- **委托 git commits 给 subagent**;每 Task 独立 commit。

## 预期幅度(证据推断,诚实前置)

Step B 实测:119k 次分派削减 → 端到端净提速 ≈1.8%(0.0895s),即每次被删分派的完整机制(含极小函数体)+ 其内部工作 ≈0.75μs(有噪,受漂移限制)。剩余解释期 ~180k 次分派 → 纯机制总量 ≤0.14s ≈ **≤2.8%**。Task 1+2 移除其中约一半(约 45 万次小堆分配)→ 预期净收益 **~1%,大概率仍"未达明显"**。

**这不构成不做的理由**:两项裁剪本身正确、低风险、是 spec 方案 A 明确要求的宿主机制改进;且 Task 3 的决策门以实测为准(不预设结论)。若确"未达明显",其价值在于**证伪 host 机制方向**——把后续优化引向真正的大头(boot 侧数据/分配,受"QLang 数据必须用 QLang 的"约束)或接受机器级上限。这是 Step B 决策门精神的延续。

## 文件结构

- `src/interpreter.rs` — 唯一同时被两 Task 触碰的文件:
  - Task 1:`CallFrame`(84-87)、`run_program`(144)、`call_function_inner` 热路径 push(765-768)、`run_import`(912-913);新增 `use std::borrow::Cow;`。
  - Task 2:`FunctionValue` 构造点(474-479)、let 标注绑定点(246)、`call_function_inner` 参数绑定热循环(760-763)。
- `src/environment.rs` — Task 2:`values` 字段类型(112)、`define`(157-159)、`define_annotated` 签名(162-164)、`define_uninitialized`(213-215);`get/lookup/get_annotation/assign/contains` 不改(经 `Borrow<str>` 查找 `Rc<str>` key);`bindings()`/`iter_bindings()` 签名随字段自动变、无外部调用者(已 grep 证实)。
- `src/value.rs` — Task 2:`FunctionValue` 加 `param_keys: Rc<Vec<Rc<str>>>`(128-134)。
- `docs/superpowers/specs/2026-08-13-boot-hotspot-design.md` — Task 3 追加「Step A 实测结果」节。

## Task 1: CallFrame.path 改 `Cow<'static, str>`(去掉每调用 "unknown" 堆分配)

**Files:**
- Modify: `src/interpreter.rs:84-87`(CallFrame)、`:144`(run_program)、`:765-768`(call_function_inner 热路径)、`:912-913`(run_import);顶部 import 区(第 7 行 `use std::collections::HashMap;` 后)

**Interfaces:**
- Consumes: 现状 `CallFrame { path: String, position: usize }`。
- Produces: `CallFrame { path: Cow<'static, str>, position: usize }` — `run_import` 仍从 `call_stack.last().path` 取当前文件路径(相对 import 解析语义不变);`make_error` 只读 `position`,零改动。

- [ ] **Step 1: 加 import**

在 `src/interpreter.rs` 第 7 行 `use std::collections::HashMap;` 之后加:

```rust
use std::borrow::Cow;
```

- [ ] **Step 2: 改 `CallFrame` struct(84-87 行)**

```rust
#[derive(Debug, Clone)]
struct CallFrame {
    path: Cow<'static, str>,
    position: usize,
}
```

- [ ] **Step 3: 改 `run_program` 顶层帧(144 行)**

```rust
self.call_stack.push(CallFrame { path: Cow::Owned(path), position: 0 });
```

- [ ] **Step 4: 改 `call_function_inner` 热路径 push(765-768 行)**

```rust
self.call_stack.push(CallFrame {
    path: Cow::Borrowed("unknown"),
    position: span.start,
});
```

- [ ] **Step 5: 改 `run_import`(912-913 行)**

```rust
let current_path = self.call_stack.last()
    .map(|f| f.path.clone())
    .unwrap_or_else(|| Cow::Borrowed("."));
let base_path = Path::new(current_path.as_ref()).parent()
    .unwrap_or(Path::new("."));
```

(`Cow` 的 `Clone` 对 `Borrowed` 帧只是拷贝静态引用,零分配;仅 import 场景走 `Owned` clone,量可忽略。`run_import` 只在 import 语句执行时触发,不在地热路径。)

- [ ] **Step 6: 编译**

Run: `cargo build --release`
Expected: 0 errors,0 warnings。

- [ ] **Step 7: 回归门(全绿)**

```bash
cargo test --release   # 34 passed / 0 failed
./target/release/qlang demo/type_gymnastics.ql > /tmp/host_t1.out 2>&1
./target/release/qlang bootstrapped/run_file.ql demo/type_gymnastics.ql > /tmp/boot_t1.out 2>&1
grep -c "asserts passed" /tmp/host_t1.out   # 1
grep -c "asserts passed" /tmp/boot_t1.out   # 1
diff /tmp/host_t1.out <(tail -n +13 /tmp/boot_t1.out | grep -v '^Execution complete\.$') && echo "STRIPPED-IDENTICAL"
python3 difftest.py   # All identical ✔
./target/release/qlang verify_bootstrap.ql  # PASS / 0 FAIL
```

Expected: 全绿。difftest 若因 boot banner 首行非纯文本导致 exit 1,属既有 runner artifact(Step B Task 3 已记录:剥离 banner 后 BYTE-IDENTICAL),非缺陷。

- [ ] **Step 8: Commit**

```bash
git add src/interpreter.rs
git commit -m "perf(host): CallFrame.path -> Cow<'static,str> (kill per-call \"unknown\" String alloc)"
```

## Task 2: Environment key 改 `Rc<str>` + FunctionValue 预绑定参数名(去掉每参数 name String clone)

**Files:**
- Modify: `src/environment.rs:112`、`:157-159`、`:162-164`、`:213-215`
- Modify: `src/value.rs:128-134`(FunctionValue 加字段)
- Modify: `src/interpreter.rs:474-479`(FunctionValue 构造)、`:246`(let 标注绑定)、`:760-763`(热路径参数绑定)

**Interfaces:**
- Consumes: Task 1 的 `CallFrame { path: Cow<'static, str>, ... }`;现有 `FunctionValue { parameters, body, closure, param_types }` 单一构造点(interpreter.rs:474)。
- Produces: `Environment::define_annotated(name: Rc<str>, value, annotation)`(签名变更,调用点共 2 处同步适配);`FunctionValue.param_keys: Rc<Vec<Rc<str>>>`(Task 3 构建 A/B 二进制依赖此不变量,行为必须与 Task 2 前逐字节一致)。

- [ ] **Step 1: 改 `Environment.values` 字段类型(environment.rs:112)**

```rust
values: HashMap<Rc<str>, Binding>,
```

(`Rc` 已在文件顶部 import;`HashMap<Rc<str>, _>::get(&str)` 经 `impl Borrow<str> for Rc<str>` 正常工作;123/138 行的 `HashMap::new()` 构造点类型从字段推断,无需改动。)

- [ ] **Step 2: 改 `define`(157-159 行)**

```rust
pub fn define(&mut self, name: String, value: Value) {
    self.values.insert(Rc::from(name), Binding { value: Some(value), annotation: None });
}
```

(`Rc::from(String)` 复用 String 缓冲、单次分配,与旧 `HashMap<String,_>` insert 成本等价,20 处调用点零改动。)

- [ ] **Step 3: 改 `define_annotated` 签名为 `Rc<str>`(162-164 行)**

```rust
pub fn define_annotated(&mut self, name: Rc<str>, value: Value, annotation: Option<(Value, String)>) {
    self.values.insert(name, Binding { value: Some(value), annotation });
}
```

- [ ] **Step 4: 改 `define_uninitialized`(213-215 行)**

```rust
pub fn define_uninitialized(&mut self, name: String, annotation: Option<(Value, String)>) {
    self.values.insert(Rc::from(name), Binding { value: None, annotation });
}
```

- [ ] **Step 5: `get`/`lookup`/`get_annotation`/`assign`/`contains` 不改**

它们全部以 `&str` 参数经 `self.values.get/get_mut/contains_key(&str)` 查找——`Borrow<str> for Rc<str>` 使代码无需改动。`bindings()`(269-271)与 `iter_bindings()`(274-276)签名随字段类型自动变为 `&HashMap<Rc<str>, Binding>` / `(&Rc<str>, &Binding)`;已 grep 证实无外部调用者,不另行适配。

- [ ] **Step 6: `FunctionValue` 加 `param_keys` 字段(value.rs:128-134)**

```rust
pub struct FunctionValue {
    pub parameters: Rc<Vec<Parameter>>,
    pub body: Rc<Block>,
    pub closure: EnvRef,
    /// Parameter annotation evaluated at definition time: (type value, source text); None = the parameter has no annotation.
    pub param_types: Rc<Vec<Option<(Value, String)>>>,
    /// Pre-built Rc<str> parameter-name keys: per-call param binding clones the Rc
    /// (refcount bump) instead of allocating a fresh String per parameter per call.
    pub param_keys: Rc<Vec<Rc<str>>>,
}
```

- [ ] **Step 7: `FunctionValue` 构造点加 `param_keys`(interpreter.rs:474-479)**

```rust
Ok(Value::Function(Rc::new(FunctionValue {
    parameters: Rc::clone(&func.parameters),
    body: Rc::clone(&func.body),
    closure: Rc::clone(env),
    param_types: Rc::new(param_types),
    param_keys: Rc::new(func.parameters.iter().map(|p| Rc::from(p.name.as_str())).collect()),
})))
```

(函数定义期一次构建;`Rc::from(&str)` 单次分配,每函数定义一次,非热路径。)

- [ ] **Step 8: 适配 let 标注绑定调用点(interpreter.rs:246)**

```rust
env.borrow_mut().define_annotated(Rc::from(let_stmt.name.clone()), value, Some(a));
```

- [ ] **Step 9: 热路径参数绑定改 `Rc::clone`(interpreter.rs:760-763)**

```rust
let call_env = child_env(&func.closure);
{
    let mut env = call_env.borrow_mut();
    for (i, (arg, key)) in args.into_iter().zip(func.param_keys.iter()).enumerate() {
        env.define_annotated(Rc::clone(key), arg, func.param_types[i].clone());
    }
}
```

(原逻辑逐参数 `param.name.clone()` + `param_types[i].clone()` + insert;新逻辑以 Rc clone 替代 name String clone。`param_types[i].clone()` 保留——`None` 免费,`Some` 的标注需存入 Binding 供重赋值检查。块作用域释放 `borrow_mut`,随后 `run_block(&func.body, &call_env)` 再次 borrow 无冲突。)

- [ ] **Step 10: 编译 + 回归门**

```bash
cargo build --release   # 0 errors / 0 warnings
cargo test --release    # 34 passed / 0 failed
./target/release/qlang demo/type_gymnastics.ql > /tmp/host_t2.out 2>&1
./target/release/qlang bootstrapped/run_file.ql demo/type_gymnastics.ql > /tmp/boot_t2.out 2>&1
grep -c "asserts passed" /tmp/host_t2.out && grep -c "asserts passed" /tmp/boot_t2.out   # 1 / 1
diff /tmp/host_t2.out <(tail -n +13 /tmp/boot_t2.out | grep -v '^Execution complete\.$') && echo "STRIPPED-IDENTICAL"
python3 difftest.py   # All identical ✔
./target/release/qlang verify_bootstrap.ql  # PASS / 0 FAIL
```

Expected: 全绿。特别核对 difftest 的 host 端用例(host 直跑路径)与 r40-r44/错误值/类型标注交叉用例。

- [ ] **Step 11: Commit**

```bash
git add src/environment.rs src/value.rs src/interpreter.rs
git commit -m "perf(host): pre-bind FunctionValue param keys as Rc<str> (kill per-call name String clone)"
```

## Task 3: 同窗口 A/B 交错计时 + 决策门 + spec 实测结果

**Files:**
- Modify: `docs/superpowers/specs/2026-08-13-boot-hotspot-design.md`(在「Step B 实测结果」节后追加「Step A 实测结果」节)

**Interfaces:**
- Consumes: Task 2 成果(HEAD)与计划起点 BASE(未优化 host);两者均为已提交 commit,工作树干净。
- Produces: 同窗口 A/B 交错计时结论;决策门输出(够 → 停 / 不够 → 停止 host 机制方向);spec 实测结果节。

**计时纪律(硬性):** 本机热漂移 ±20%,只信同窗口内 A/B/A/B 交错。**A 态 = 计划起点 BASE commit(当前 `8fa6653`,即 Step B 最终 HEAD)**——用 hash pin,不用 `HEAD~2`(Step B 已踩 HEAD~2 指针漂移坑,spec 8fa6653 专门改为 pin blob)。A/B 二进制各自 `cp` 出独立副本,运行互不干扰。

- [ ] **Step 1: 预编译 A/B 两个 release 二进制**

```bash
cd /root/projects/QLang
BASE_HASH=8fa6653   # 计划起点(Step B 最终 HEAD);若 controller dispatch 时给的实际 base hash 不同,以它为准
git worktree add --detach /tmp/qlang_stepA_A "$BASE_HASH"
# A 态:worktree 内构建,复用主 target 的依赖缓存(只重编 qlang crate)
cd /tmp/qlang_stepA_A && CARGO_TARGET_DIR=/root/projects/QLang/target cargo build --release
cp /root/projects/QLang/target/release/qlang /tmp/qlang_A_bin
# B 态:回主 worktree 增量构建(Task 1+2 成果)
cd /root/projects/QLang && cargo build --release
cp /root/projects/QLang/target/release/qlang /tmp/qlang_B_bin
git worktree remove /tmp/qlang_stepA_A
ls -la /tmp/qlang_A_bin /tmp/qlang_B_bin   # 两者存在
```

(A 态工作树是独立检出,`CARGO_TARGET_DIR` 指向主 target 故 worktree 内无 target 目录,`git worktree remove` 不报未跟踪文件。构建时间不计入运行计时。)

- [ ] **Step 2: 同窗口 A/B/A/B 交错计时(FULL 全流程,只测运行,不计构建)**

```bash
cd /root/projects/QLang
TIMEFORMAT='%R'
B1=$( { time /tmp/qlang_B_bin bootstrapped/run_file.ql demo/type_gymnastics.ql >/dev/null; } 2>&1 )
A1=$( { time /tmp/qlang_A_bin bootstrapped/run_file.ql demo/type_gymnastics.ql >/dev/null; } 2>&1 )
B2=$( { time /tmp/qlang_B_bin bootstrapped/run_file.ql demo/type_gymnastics.ql >/dev/null; } 2>&1 )
A2=$( { time /tmp/qlang_A_bin bootstrapped/run_file.ql demo/type_gymnastics.ql >/dev/null; } 2>&1 )
B3=$( { time /tmp/qlang_B_bin bootstrapped/run_file.ql demo/type_gymnastics.ql >/dev/null; } 2>&1 )
echo "A1=$A1 A2=$A2 B1=$B1 B2=$B2 B3=$B3"
```

Expected: 5 个秒数值落在 ~4.7-4.9s 量级。判定只看 A 与 B 各自组内配对。

可选归因(非必需):若想单独看 Task 1(Cow)贡献,可额外把 `HEAD~1`(Task 1 commit)构为 M 态加一组 M 采样;本计划决策门以 A/B 总差为准,不做 M 也完整。

- [ ] **Step 3: 决策门**

规则(逐字):"若 B 组每值都显著小于 A 组每值(且 B 组中位数 < A 组中位数 × 0.9),判'明显变快';若组间重叠(漂移吞噬差异),判'未达明显',不跨窗口补测。"

- **够 → 停**:spec 记录结论"Step A 达标",host 机制裁剪收尾,本计划结束;后续优化另立项(如 boot 侧数据/分配,受架构约束)。
- **不够 → 停止 host 机制方向**:spec 记录实测数字 + 归因(每次分派机制 ≈Xμs、机制占解释期 ≈Y%,被漂移吞噬),明确"不再沿 host 机制方向加码"。

- [ ] **Step 4: 把实测结果写回 spec 并提交**

在 `docs/superpowers/specs/2026-08-13-boot-hotspot-design.md` 的「Step B 实测结果」节后追加「Step A 实测结果」节,含:两态 commit(A = BASE hash,B = Task 2 hash)、同窗口交错表(A1/A2/B1/B2/B3 秒数 + 组中位数)、决策门代入数字、结论(达标 / 未达明显)。提交:

```bash
git add docs/superpowers/specs/2026-08-13-boot-hotspot-design.md
git commit -m "docs(boot): record Step A measured results (A x vs B y, decision: <reached|not-reached>)"
```

---

## Self-Review(已执行)

**Spec 覆盖:**
- 方案 A「child_env 分配 + 参数绑定(最重)」→ Task 2(预绑定 `Rc<str>` 参数名,去掉每参数 name String clone,属"轻量局部绑定"的安全形态)✓
- 方案 A「call_stack String 分配 → 静态借用/驻留」→ Task 1(Cow Borrowed)✓
- 方案 A「扫描/柯里化/元数/标注检查相对轻,保留语义不动者」→ 未触碰 ✓
- 允许性("运行时机制可用 host Rust";零新 native;数据层不动)→ Global Constraints ✓
- 验证策略 1-4(字节级 + difftest + 同窗口计时)→ Task 1/2 Step 7/10 + Task 3 ✓
- 决策门(够 → 停;不够 → 立计划)→ Task 3 Step 3;spec「Step B 实测结果」节记载的"后续 Step A 另立实现计划"承诺即本计划 ✓
- 不做的事(YAGNI):无新 native ✓、不改 Value/数据表示 ✓、不做 guard 内联/Identifier 直读 ✓、不做 Mu spine ✓

**占位符扫描:** 全部代码块为逐字内容;Task 3 唯一"条件性"步骤是决策门(有明确判定规则与两种明确后续动作,非占位)。`BASE_HASH=8fa6653` 为当前真实 hash(controller dispatch 时可核对/替换)。

**类型一致性:**
- `Cow<'static, str>`:`run_program` `Cow::Owned(path)`、热路径 `Cow::Borrowed("unknown")`、`run_import` `Cow::Borrowed(".")` + `current_path.as_ref()` → `&str` → `Path::new`,三处类型一致 ✓
- `Rc<str>` key:`define`/`define_uninitialized` `Rc::from(String)`、`define_annotated(name: Rc<str>)`、热循环 `Rc::clone(key)`、`get/lookup/assign/get_annotation/contains(&str)` 经 `Borrow<str>` 一致 ✓
- `FunctionValue.param_keys: Rc<Vec<Rc<str>>>`:构造点(474)与热循环(760)两处字段名一致;`derive(Clone)`/`PartialEq(ptr_eq)` 不受影响 ✓

**诚实性:** 预期幅度节明确给出"~1% 大概率未达明显"的证据推断,不粉饰;计划仍执行(裁剪正确、低风险、spec 要求),以决策门实测为准。

## 关键风险与缓释

1. **Task 2 改 `Environment` 全局 key 类型**:风险 = `Rc<str>` 与 `String` 语义差异(Hash/Borrow/Debug)。缓释:`&str` 查找经 `Borrow<str> for Rc<str>` 语义不变;`bindings()`/`iter_bindings()` 已 grep 证实无外部调用;全量回归门(字节级一致 + difftest + verify_bootstrap + cargo test)兜底,任何可观察差异都会暴露。
2. **Task 3 A 态指针漂移**:pin hash `8fa6653`(Step B 已踩 `HEAD~2` 坑并改为 pin blob),worktree 独立检出,不用 `HEAD~2`。
3. **预期幅度不足 → 决策门否定**:如实记录,不硬造结论(与 Step B Task 4 同款纪律);计划的价值之一是证伪 host 机制方向,把后续引向真正大头。
4. **A 态冷构建耗时**:`CARGO_TARGET_DIR` 复用主 target 依赖缓存,只重编 qlang crate;构建时间不计入运行计时。若 worktree 构建异常,回退为:主 worktree `git checkout $BASE -- src/` → build → cp A bin → `git checkout HEAD -- src/` 恢复(勿用 stash)。
5. **`/usr/bin/time` 缺失**:沿用 bash 内建 `time` + `TIMEFORMAT='%R'`(Step B Task 4 已验证与 `%e` 等价)。
