# QLang → LLVM AOT M3:错误值 / `?` / `??` / 完整 stdlib / 419 四端 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 M2(复合值 + 四端 difftest)之上补齐错误值语义(`?`/`??`)、完整 QLang 自建 stdlib(Type/Error/Object/Number/Array/String/Math/JSON)与 6 项 M2 已知差异项修复,使 `demo/type_gymnastics.ql` 419/419 在 HOST / BOOT / NATIVE 三端输出逐字节一致,difftest 四端全绿。

**Architecture:** 错误值 = 48B tag-8 ERROR 盒(纯 QLang 构建,零新 native);`?` 经「函数 epilogue 寄存器 + label」把错误直接折回函数返回;`??` 用 br+phi 短路。**核心裁定**:`emitBinaryOp` 改 tag 感知双路径 —— 运行时左右 tag 均 == NUMBER → 数值路径**内联解盒 + fadd/fcmp + allocBox**(保留 M2 模式,保证 runtime.ql 自身算术不递归);否则派发到 runtime.ql 的 `__op_*`(字符串拼接 / tag 感知相等 / 类型不匹配 / 操作区错误)。所有 stdlib 与 10 个类型单例、`Array`/`Object` 构造器全部用 QLang 在 runtime.ql 中自建;`qlangc` 预扫递归收集分支级 `let` 并展开 else-if 链,使 419 的 147 处分支 let 与 40 处 else-if 可编译。

**Tech Stack:** QLang(自举,host Rust 解释器 + boot 解释器);qlangc.ql 发射文本 LLVM IR;`clang -fuse-ld=lld <tmp.ll> aot/runtime.c -o <out>`;difftest.py(Python)四端;`demo/type_gymnastics.ql`(419 断言)。

**Spec:** [M3 设计 §1-14](docs/superpowers/specs/2026-08-15-qlang-llvm-aot-m3-design.md)(已冻结);上游 [M0-M2 编译器设计](docs/superpowers/specs/2026-08-14-qlang-llvm-aot-compiler-design.md)(M3 行)。

## Global Constraints

1. **零新 native** —— `grep -o 'ql_[a-z_]*' aot/runtime.c | sort -u` 计数 = 7(ql_alloc / ql_write / ql_exit / ql_mem_get / ql_mem_store / ql_mem_get_ptr / ql_mem_store_ptr),+0;全部 stdlib 与错误原语用 QLang。
2. **boot 零改动、`src/`(host)零改动**;`difftest.py` 只在 T11 改。
3. **三端/四端逐字节一致**;difftest 四端全绿;M1 v1 套件 13/13、M2 t8 全绿、M2 白名单 51/51 无回归。
4. **qlangc emit 只调用 runtime.ql 的 QLang 层接口**;emitted code 无裸 leaf 调用。
5. **qlangc 无 return**;emitted code 用表达式 if/while/tail expressions。
6. **emitted code(runtime.ql 与测试程序)多路分支用嵌套 if/else(禁 else-if)**;qlangc.ql 自身 host 解释,自由 else-if + 分支内 let。
7. **分支/循环体内无 let**(已修订):qlangc 递归预扫 defineSlot 支持分支级 let(Gap D,§R8);emitted 代码不含分支内 let 声明语句。
8. **只用 LLVM 自带工具链**:`clang -fuse-ld=lld <tmp.ll> aot/runtime.c -o <out>`。
9. **docs/ 永不 commit;永不 `git add -A`**;每任务恰提交其改动文件。
10. **字符串 = tag-2 STRING box 统一**(`{tag@0=2, buf@8, len@16}`);`{buf,len}` 对象退役;`.length` NATIVE 返回字节数(ASCII 域 = 字符数)。

## Rulings(对 spec 的裁定/修正/扩充 — 执行者必须先读)

> 本计划在 spec 之上追加以下裁定。**与 spec 冲突处以本计划为准。**

- **R1(最重要,修正 spec §5 致命缺陷)· `emitBinaryOp` tag 感知双路径**:spec 说「emitBinaryOp 不再内联 fadd/fcmp,改为调用 __op_*」。这会让 runtime.ql 自身的算术(`__hash`/`readU64`/`__itoa` 用 `+`/`*`/`%` 大量运算)经 `__op_*` 派发而**无限递归**(`__op_add` 的数值分支若用 QLang 算术又会调 `__op_add`)。**裁定**:emitBinaryOp 无条件 emit L/R 盒 → 运行时查左右 tag 均 ==1(NUMBER)→ **数值路径内联**(load double @8 → fadd/fcmp/位运算 → allocBox,保留 M2 模式)→ 否则 br+phi 派发到 `__op_*`。`__op_*` 的数值分支在 emitted 层已是内联,`__op_*` 内**绝不做数值运算**。除零检查也内联在数值路径(见 T2)。双 NUMBER 字面量且非 `/`/`%` → 跳过 tag 检查直走内联(M2 快速路径保留)。
- **R2 · `__op_eq` 中 ERROR/ERROR = false**(spec §5.1 表写「ERROR/ERROR 指针同一」):镜像 host `values_equal`(interpreter.rs:1006-1018)的 `_ => false`;且操作区先于相等比较(任一操作数为 Error → TypeMismatch),ERROR/ERROR 分支不可达。
- **R3 · `Function` 单例谓词 = tag-7 仅**(spec §7 写「tag-7 或带 check 对象」):镜像 host `is_function` = Function|NativeFunction;带 check 的对象归属 Type 单例判定,不属 Function。
- **R4 · 类型单例识别 = check 字段**(spec §4 的 marker 方案简化为 check-field 探测):`__is_type_value(v)` = tag==6 && `__obj_get(v,"check")` 是 tag-7 函数盒。10 个单例 + 用户类型对象均带 check → 识别成立;普通对象无 check 域(取到 UndefinedField 错误)→ 否。std.Type 模块 = Type 单例自身(自反成立)。
- **R5(Gap A)· `obj["k"]` 字符串索引 tag-6 OBJECT 分支**:M2 `__get_index`/`__set_index` 只处理 tag5/tag2 → 对 OBJECT 报 CannotIndex。419 的 `o[k]` 读写(:101/:253-257/:280)依赖 → `__get_index`/`__set_index` 增 tag==6 → `__obj_get`/`__obj_set` 分支(T5)。
- **R6(Gap B)· `__obj_keys`/`__obj_values`**:遍历桶表收集键/值,空槽(== `__EMPTY`)跳过;供 `std.Object.keys/values` 与 Object 构造器的 keys 形式(T4 定义、T5 暴露)。
- **R7(Gap C)· else-if 链**:boot IfStmt = `{branches:[IfBranch...], elseBody}`(branches[1..] 即 else-if 链)。`emitIfStmt` 现只处理 branches[0] 并注释忽略。改为:else 侧递归合成嵌套 If(剩余 branches + elseBody),递归内 emitIfStmt 返回其 phi → 外层 elseIn。419 有 40 处 else-if(T9)。
- **R8(Gap D)· 分支级 let**:419 有 147 处分支内 `let`(`let k = ks[i];`、`let uni = ...`)。qlangc 增加 `collectLets` 递归预扫(Let/If 各分支/While 体),在 emitFunction 与 main 建帧前把全部 let 注册进作用域;`emitBlockStmts` 对分支 let 走 emitStoreByName(同槽位写入)。同名分支 let(如 inferType 的 `let i=0`/`let i=1`)由 defineSlot 幂等唯一化(T9)。
- **R9(差异项 4 归因修正)· boot parser 无 if-表达式**:boot parsePrimary 无 If 分支 → if-表达式在实参位产 `{type:"Error"}` 节点 → NATIVE 无法修复。修法 = 改写 difftest harness/case 为语句形(镜像 NODE_CASES);`emitExpr` 的 If 分支对 boot AST 是死代码 → **YAGNI 不实现**(spec §4.3 的 emitExpr-If 依赖 `??` 基建,但 `??` 直接用 br+phi 实现,不需要 emitExpr-If)。
- **R10 · ql_exit 接线**:runtime.c 已有 `void ql_exit(int)`(:42)但不在 qlangc `isLeaf`(:617)也不在 prelude declare → T3 补(`declare void @ql_exit(i32)` + isLeaf 条目)。
- **R11 · 顶层 `?` 不进四端白名单**:host 顶层错误 exit 1 + stderr、boot 继续跑 → 结构性发散。419 的 `?` 全在函数内(函数 epilogue 为关键路径);顶层 `?` 防御性实现(`__exit_error` + `unreachable`)。
- **R12 · `__exit_error` 依赖 `__op_add`**:错误链文本 `"{kind}: {message}"` 用字符串拼接 → 依赖 T2 的 `__op_add` 运行时派发;顶层 `?` 场景只能 T2 后生效(不影响 419,419 无顶层 `?`)。
- **R13 · `==` 永远走派发**(含两个字符串字面量):字符串内容相等、对象指针同一(载荷 `[+8]` 比较)是 419 关键依赖(`bad.message == "field 'a' failed its check"`、`std.Type.of(X) == std.Type`)。数值内联路径只对 tag 均 ==1 生效,字符串不命中。
- **R14 · 位运算(差异项 3)= 数值路径内联 `fptosi → and/or/xor → sitofp`**(spec §5.2 的 readU64 位模拟废弃):与算术同构,无精度问题;非数值路径派发 `__op_zone_error("bitwise operation", L, R)`。无需 `__op_band/bor/bxor` 函数。
- **R15 · emitCall 错误实参传播只对纯 Identifier callee(用户函数)**:MemberAccess callee(`std.Type.of`/`std.Error.raise`/`isError` 等接受错误的原生/模块函数)不走检查(否则 `Type.of(err)` 被错误截获,应返回 Error 单例)。用户函数第一个错误实参 → 该错误成为调用结果(host「拒绝错误实参」的归一化等价)。
- **R16 · 对象/数组/函数指针同一 = 载荷比较**:QLang 无指针等式 → `__op_eq` 对 tag5 比 `readU64(a,8)`(els@8)、tag6 比 `readU64(a,8)`(table@8)、tag7 比 `readU64(a,16)`(env@16) —— 各盒唯一,等价指针同一。
- **R17 · 差异项 6(Unicode 字节长度)提前到 T1**:`__err_chain` 的 `"└─"` 字形需要 byte-aware internString → 差异项 6 从 spec T6 提前到 T1(小修 qlangc.ql:69,`len = s.length` 改 UTF-8 字节数)。
- **R18 · 类型单例与构造器是 419 关键路径,须随 T4 落地**:spec §7 把 `Array`/`Object` 构造器挂在 std.Array/std.Object 模块,但 419 直接用**全局** `Array(desc)`/`Object(schema)`/`Object(pred)`(:67/:76/:83/:98/:137/:164/:174/:302/:342/:409/:551/…)与全局单例 `Number`/`String`/`Null`/`AnyArray`/`AnyObject`/`Function`/`Any`/`Never`/`Error`/`Type`。T4 必须定义这些全局(镜像 host types.rs register_type_system/register_constructors)。

## File Structure

| 文件 | 职责 | 变更 |
|---|---|---|
| `aot/runtime.ql` | 错误原语 + `__op_*` 派发 + stdlib + 类型系统 + `Array`/`Object` 构造器 | 大量新增(全 QLang) |
| `aot/qlangc.ql` | `emitBinaryOp` 双路径 / `?` epilogue / `??` / else-if / 分支 let 预扫 / `@ql_truthy` / ql_exit / 差异项 6 | 关键段重写 |
| `aot/runtime.c` | leaf 运行时 | **零改动**(ql_exit 已存在) |
| `aot/tests/t9_*.ql` | M3 模块测试(3-way 可跑) | 新增 |
| `difftest.py` | 四端白名单扩展 + `tg` NATIVE 入口 + t9 cids | 仅 T11 |
| `aot/run_v1_tests.sh` | v1 + t9 三端回归 | 仅 T11(追加 t9 循环) |
| `demo/type_gymnastics.ql` | 419 目标 | **零改动** |

## 前置依赖序

T1 → T2 → T3(错误值与派发地基)→ T4 → T5 → T6 → T7 → T8(stdlib,并行可)→ T9 → T10(控制流与 truthy)→ T11(测试/四端/419)→ T12(gate)。R1 双路径先于一切 stdlib;T9 的 Gap C/D 在 T11(419)之前即可,与 T4-T8 并行。

---

### Task 1:ERROR box 48B + 字符串表示统一 + 差异项 6

**Files:**
- Modify: `aot/runtime.ql`(`__err` 迁移、`__err_new`/`__isError`/`__err_get`/`__err_cause`、`__str_new`、`__itoa`/`__boolstr`/`__nullstr`/`__str` → tag-2 返回)
- Modify: `aot/qlangc.ql:67-69`(差异项 6:internString byte-aware 长度)
- Create: `aot/tests/t9_error.ql`(3-way 外壳)

**Interfaces:**
- Consumes: M2 box 模型(allocBox/readU64/writeU64/ql_mem_store_ptr)。
- Produces: `__err_new(kind,msg,cause)`→48B ERROR 盒;`__isError(v)`→BOOL 盒;`__err_get(e,field)`→域值或 UndefinedField 错误;`__err_cause(e)`→cause/nullbox;`__str_new(buf,len)`→24B tag-2 盒;`__itoa(n)`/`__boolstr(b)`/`__str(v)` 全部返回 tag-2 盒。**后续任务所有字符串值都是 tag-2 盒。**

- [ ] **Step 1:差异项 6 — internString byte-aware 长度**

`aot/qlangc.ql:66-69` 现用 `let len = s.length;`(host 字符数)作字节数组尺寸。改为 UTF-8 字节数(host 字符串是 UTF-8,`String::len()` 即字节数;但 qlangc 里 s 是 QLang 字符串值,`.length` = 字符数)。在 host 解释的 qlangc.ql 中,`s.length` 是字符数;取字节数可用 `std.String.length(s)`?—— host 的 `.length` 返回字符数。**可靠做法**:用 `std.Object` 无;直接以 `escapeC` 产出的字节序列长度为准:重构为两段 —— 先 `let cstr = escapeC(s);`(已是 C 转义串),再用 `cstr.length` 计字节数时有歧义(`\xNN` 算 4 字符)。**最终裁定**:在 qlangc 中把非 ASCII 字节计数交给 host 侧 — qlangc 本身跑在 host 解释器上,`node.value` 是 host Rust 字符串(UTF-8);取字节数 = 用 `\u{0}`…—— 不可用。**简单方案**:对字符串字面量,`len` 保持 `s.length`(字符数)不变,但把常量声明改为 `[len x i8]` + `escapeC` 保留字节 —— 这会使非 ASCII 字面量的常量数组长度偏小(UB)。**因 419 仅 T1 的 `__err_chain` 需非 ASCII**,且 T11 才用它 —— 本步把 qlangc 对 `String` 字面量节点的字节数改为「遍历 `escapeC` 输出中的 `\` 转义计数」:

```qlang
// qlangc.ql internString 内,把 len 计算替换为字节计数
let esc = escapeC(s);
let len = 0;
let j = 0;
while j < esc.length {
  if esc[j] == "\\" {
    len = len + 2;      // \xNN 恒 2 字节 (\x + 2 hex);\n \t 等 1 字节 —— 统一按 \xNN 处理
    j = j + 1;
  } else {
    len = len + 1;
  };
  j = j + 1;
};
```

> **注意**:escapeC 的输出形式决定计数。执行者须先读 `escapeC`(aot/qlangc.ql 顶部)确认它对 `\n`/`"`/`\`/`\xNN` 的编码,写一个与本任务测试字面量(含 `└─`)一致的精确计数函数。**验收**:`let s = "a└─b"; println(s);` 三端输出逐字节一致(NATIVE 无 UB)。

- [ ] **Step 2:验证差异项 6**

Run: `printf 'let s = "a"; println("[" + s + "]");\n' > /tmp/t.ql && ./target/debug/qlang --compile /tmp/t.ql -o /tmp/t.bin && /tmp/t.bin`
Expected: `[a]`(回归;ASCII 不受影响)

Run: `./target/debug/qlang bootstrapped/run_file.ql aot/qlangc.ql aot/runtime.ql > /dev/null 2>&1; echo $?`
Expected: qlangc 自举运行成功(exit 0)—— 自举后非 ASCII 字面量编译不崩溃。

- [ ] **Step 3:`__str_new` + `__err` 家族(runtime.ql)**

在 runtime.ql 顶部 `allocBox` 之后追加:

```qlang
// M3:tag-2 STRING 盒 {tag@0=2, buf@8, len@16}
let __str_new = (buf, len) -> {
  let box = allocBox(2, 24);
  ql_mem_store_ptr(box, 8, buf);
  writeU64(box, 16, len);
  box;
};

// M3:48B ERROR 盒 {tag@0=8, kind@8, message@16, line@24, col@32, cause@40}
// kind/message = tag-2 STRING 盒指针;line/col = interned 零盒;cause = ERROR 盒或 nullbox。
let __zero_num = 0;   // interned NUMBER 盒 0.0(line/col 读域恒 0)
let __err_new = (kind, msg, cause) -> {
  let b = allocBox(8, 48);
  ql_mem_store_ptr(b, 8, kind);
  ql_mem_store_ptr(b, 16, msg);
  ql_mem_store_ptr(b, 24, __zero_num);
  ql_mem_store_ptr(b, 32, __zero_num);
  ql_mem_store_ptr(b, 40, cause);
  b;
};
// 旧签名保持:2 参,缺省 cause = null
let __err = (kind, msg) -> {
  __err_new(kind, msg, null);
};
let __isError = (v) -> {
  readU64(v, 0) == 8;
};
let __err_cause = (e) -> {
  ql_mem_get_ptr(e, 40);
};
let __err_get = (e, field) -> {
  // 域:kind/message→STRING 盒、line/col→零盒、cause→ERROR/null、未知→UndefinedField
  let k = field;
  if k == "kind" { ql_mem_get_ptr(e, 8); }
  else { if k == "message" { ql_mem_get_ptr(e, 16); }
  else { if k == "line" { ql_mem_get_ptr(e, 24); }
  else { if k == "col" { ql_mem_get_ptr(e, 32); }
  else { if k == "cause" { ql_mem_get_ptr(e, 40); }
  else { __err("UndefinedField", "Undefined field: " + field); }; }; }; }; };
};
```

> **注意**:`k == "kind"` 是字符串内容相等 → 依赖 T2 的 `__op_eq`。**本任务内**该函数不会在 NATIVE 侧执行字符串比较语义(仅编译通过;运行时字符串比较在 T2 前返回错误)。**为不阻塞本任务自测,`__err_get` 的域比较临时用 `readU64` 打桩**:把 `k == "kind"` 等改为「与 interned 键盒指针同一」的字节判断不可行 → **本任务验收只测 `__err_new`/`__isError`/`__err_cause`/`__str_new` 的构造与 tag 读,`__err_get` 域读放 T2 后**。

- [ ] **Step 4:`__str`/`__boolstr`/`__nullstr`/`__itoa`/`__print` 迁移 tag-2**

`__str`(现 :514-550)的每个分支改为返回 tag-2 盒;`__itoa`(:457-483)末尾 `{ buf: buf, len: total }` → `__str_new(buf, total)`;`__boolstr`/`__nullstr` 同理;`__str` 的 tag-2 分支直接返回 v。`__print`(:552-568)保留双路径(tag-2 直读 buf/len;tag-6 旧对象兜底)。

- [ ] **Step 5:创建 `aot/tests/t9_error.ql`(3-way 外壳,本任务只测构造)**

```qlang
// M3 t9_error:错误值构造与探测(3-way;字符串比较语义 T2 后补测)
let e = __err("TestKind", "hello");
println(__isError(e));
println(!__isError(42));
let c = __err("C", "cause");
let e2 = __err("K", "m");
println(e2);
```

Run: `bash -c 'for t in aot/tests/t9_error.ql; do n=$(basename $t .ql); ./target/debug/qlang "$t" > /tmp/t9_$n.host 2>&1; ./target/debug/qlang --compile "$t" -o /tmp/t9_$n.bin >/dev/null 2>&1 && /tmp/t9_$n.bin > /tmp/t9_$n.native; diff /tmp/t9_$n.host /tmp/t9_$n.native && echo "PASS $n"; done'`
Expected: 编译通过 + host/native 一致。`println(e)` 输出 `?Error`(M2 `__str` tag-8 标签保留)。

- [ ] **Step 6:Commit**

```bash
git add aot/qlangc.ql aot/runtime.ql aot/tests/t9_error.ql
git commit -m "feat(aot): M3 T1 — 48B ERROR box + tag-2 STRING unification + unicode byte-length (差异项 6)"
```

---

### Task 2:`emitBinaryOp` tag 感知双路径 + `__op_*` 派发 + 位运算 + 除零

**Files:**
- Modify: `aot/qlangc.ql:149-201`(emitBinaryOp 重写)、`aot/qlangc.ql:116-147`(emitShortCircuit 左错误检查)
- Modify: `aot/runtime.ql`(`__op_add`/`__op_eq`/`__op_ne`/`__op_zone_error`/`__str_eq`/`__mkbool`;删旧 `__add`)

**Interfaces:**
- Consumes: T1 的 `__err_new`/`__str_new`/`__isError`;M2 `emitCallRegs`/`allocBox`/`temp`/`lbl`/`curLbl`。
- Produces: `emitBinaryOp` 对非数值操作数派发 `__op_add`(STR 拼接)/`__op_eq`/`__op_ne`/`__op_zone_error(word,L,R)`;`__op_div0(word)` 造除零错误;`emitShortCircuit` 左 Error → `__op_zone_error("logical operation",A,null)`。**runtime.ql 自身算术经内联路径,不递归。**

- [ ] **Step 1:qLangc 新增 emitNumOp / emitDispOp / emitBinaryOp 重写**

替换 `aot/qlangc.ql:149-201` 的整个 emitBinaryOp 与相关注释。新增两个 helper(放在 emitBinaryOp 之前):

```qlang
// 数值路径(内联):仅当调用方已确认左右 tag 均 == 1(NUMBER)。除零检查内联。
// 位运算:差异项 3 —— fptosi → and/or/xor → sitofp(与算术同构)。
let emitNumOp = (op, L, R) -> {
  let a1 = temp(); let f1 = temp(); let a2 = temp(); let f2 = temp();
  line("  " + a1 + " = getelementptr i8, ptr " + L + ", i64 8");
  line("  " + f1 + " = load double, ptr " + a1);
  line("  " + a2 + " = getelementptr i8, ptr " + R + ", i64 8");
  line("  " + f2 + " = load double, ptr " + a2);
  if op == "+" || op == "-" || op == "*" {
    let rr = temp();
    let fop = if op == "+" { "fadd" } else if op == "-" { "fsub" } else { "fmul" };
    line("  " + rr + " = " + fop + " double " + f1 + ", " + f2);
    let b = allocBox("1");
    let bpay = temp();
    line("  " + bpay + " = getelementptr i8, ptr " + b + ", i64 8");
    line("  store double " + rr + ", ptr " + bpay);
    b;
  } else if op == "/" || op == "%" {
    // 除零检查:R == 0.0 → __op_div0(造 DivisionByZero 错误)
    let z = temp(); let l0 = lbl(); let lOk = lbl(); let lEnd = lbl();
    line("  " + z + " = fcmp oeq double " + f2 + ", 0.0");
    line("  br i1 " + z + ", label %" + l0 + ", label %" + lOk);
    line(lOk + ":");
    curLbl = lOk;
    let rr = temp();
    if op == "%" {
      // a - b*trunc(a/b)(M2 内联,frem 降级规避)
      let q = temp(); let qi = temp(); let qf = temp(); let m = temp();
      line("  " + q + " = fdiv double " + f1 + ", " + f2);
      line("  " + qi + " = fptosi double " + q + " to i64");
      line("  " + qf + " = sitofp i64 " + qi + " to double");
      line("  " + m + " = fmul double " + f2 + ", " + qf);
      line("  " + rr + " = fsub double " + f1 + ", " + m);
    } else {
      line("  " + rr + " = fdiv double " + f1 + ", " + f2);
    };
    let b = allocBox("1");
    let bpay = temp();
    line("  " + bpay + " = getelementptr i8, ptr " + b + ", i64 8");
    line("  store double " + rr + ", ptr " + bpay);
    let okLbl = curLbl;
    line("  br label %" + lEnd);
    line(l0 + ":");
    curLbl = l0;
    let errV = emitCallRegs("__op_div0", []);
    let zeroLbl = curLbl;
    line("  br label %" + lEnd);
    line(lEnd + ":");
    curLbl = lEnd;
    let res = temp();
    line("  " + res + " = phi ptr [ " + b + ", %" + okLbl + " ], [ " + errV + ", %" + zeroLbl + " ]");
    res;
  } else if op == "==" || op == "!=" || op == "<" || op == "<=" || op == ">" || op == ">=" {
    let cmp = if op == "==" { "oeq" } else if op == "!=" { "une" } else if op == "<" { "olt" } else if op == "<=" { "ole" } else if op == ">" { "ogt" } else { "oge" };
    let c = temp(); let c2 = temp();
    line("  " + c + " = fcmp " + cmp + " double " + f1 + ", " + f2);
    line("  " + c2 + " = zext i1 " + c + " to i64");
    let b = allocBox("3");
    let bpay = temp();
    line("  " + bpay + " = getelementptr i8, ptr " + b + ", i64 8");
    line("  store i64 " + c2 + ", ptr " + bpay);
    b;
  } else {
    // 位运算 & | ^(差异项 3):fptosi → and/or/xor → sitofp
    let op2 = if op == "&" { "and" } else if op == "|" { "or" } else { "xor" };
    let i1 = temp(); let i2 = temp(); let ir = temp();
    line("  " + i1 + " = fptosi double " + f1 + " to i64");
    line("  " + i2 + " = fptosi double " + f2 + " to i64");
    line("  " + ir + " = " + op2 + " i64 " + i1 + ", " + i2);
    let fr = temp();
    line("  " + fr + " = sitofp i64 " + ir + " to double");
    let b = allocBox("1");
    let bpay = temp();
    line("  " + bpay + " = getelementptr i8, ptr " + b + ", i64 8");
    line("  store double " + fr + ", ptr " + bpay);
    b;
  };
};

// 非数值派发路径:每 op 有至多一个合法非数值组合(+ STR 拼接;== / != tag 感知),其余 TypeMismatch。
let emitDispOp = (op, L, R) -> {
  if op == "+" {
    emitCallRegs("__op_add", [L, R]);
  } else if op == "==" {
    emitCallRegs("__op_eq", [L, R]);
  } else if op == "!=" {
    emitCallRegs("__op_ne", [L, R]);
  } else {
    let word = if op == "-" || op == "*" || op == "/" || op == "%" {
      "numeric operation"
    } else if op == "<" || op == "<=" || op == ">" || op == ">=" {
      "comparison"
    } else {
      "bitwise operation"
    };
    emitCallRegs("__op_zone_error", [internString(word), L, R]);
  };
};

let emitBinaryOp = (node) -> {
  if node.operator == "&&" || node.operator == "||" {
    emitShortCircuit(node);
  } else if node.operator == "??" {
    emitCoalesce(node);        // T9 定义;T2 内先留 stub(见 Step 4)
  } else {
    let op = node.operator;
    let bothNum = node.left.type == "Number" && node.right.type == "Number";
    let isDivMod = op == "/" || op == "%";
    if bothNum && !isDivMod {
      let L = emitExpr(node.left);
      let R = emitExpr(node.right);
      emitNumOp(op, L, R);
    } else {
      let L = emitExpr(node.left);
      let R = emitExpr(node.right);
      let t1 = temp(); let t2 = temp(); let c1 = temp(); let c2 = temp(); let c3 = temp();
      line("  " + t1 + " = load i64, ptr " + L);
      line("  " + t2 + " = load i64, ptr " + R);
      line("  " + c1 + " = icmp eq i64 " + t1 + ", 1");
      line("  " + c2 + " = icmp eq i64 " + t2 + ", 1");
      line("  " + c3 + " = and i1 " + c1 + ", " + c2);
      let lNum = lbl(); let lDisp = lbl(); let lMerge = lbl();
      line("  br i1 " + c3 + ", label %" + lNum + ", label %" + lDisp);
      line(lNum + ":");
      curLbl = lNum;
      let numRes = emitNumOp(op, L, R);
      let numLbl = curLbl;
      line("  br label %" + lMerge);
      line(lDisp + ":");
      curLbl = lDisp;
      let dispRes = emitDispOp(op, L, R);
      let dispLbl = curLbl;
      line("  br label %" + lMerge);
      line(lMerge + ":");
      curLbl = lMerge;
      let res = temp();
      line("  " + res + " = phi ptr [ " + numRes + ", %" + numLbl + " ], [ " + dispRes + ", %" + dispLbl + " ]");
      res;
    };
  };
};
```

- [ ] **Step 2:emitShortCircuit 左错误检查**

在 `aot/qlangc.ql:121` 的 emitShortCircuit 开头(A = emitExpr 之后)插入:

```qlang
  // M3 R2:左操作数为 Error → 操作区截获(host:&&/|| 对错误不短路),结果 = TypeMismatch
  let tA = temp(); let eA = temp();
  line("  " + tA + " = load i64, ptr " + A);
  line("  " + eA + " = icmp eq i64 " + tA + ", 8");
  let lErr = lbl(); let lNorm = lbl(); let lDone = lbl();
  line("  br i1 " + eA + ", label %" + lErr + ", label %" + lNorm);
  line(lErr + ":");
  curLbl = lErr;
  let errRes = emitCallRegs("__op_zone_error", [internString("logical operation"), A, emitNull()]);
  let errLbl = curLbl;
  line("  br label %" + lDone);
  line(lNorm + ":");
  curLbl = lNorm;
```
并把原 `let lDone = lbl();` 改名为 `let lEvalB`(原 done 块改为 normRes 汇集点)。原结尾 phi 增第三项 `[ " + errRes + ", %" + errLbl + " ]`。**重写后的完整 emitShortCircuit**(替换 :121-147):

```qlang
let emitShortCircuit = (node) -> {
  let op = node.operator;
  let A = emitExpr(node.left);
  // M3:左 Error → 操作区(host:&&/|| 对错误不短路)
  let tA = temp(); let eA = temp();
  line("  " + tA + " = load i64, ptr " + A);
  line("  " + eA + " = icmp eq i64 " + tA + ", 8");
  let lErr = lbl(); let lNorm = lbl(); let lDone = lbl();
  line("  br i1 " + eA + ", label %" + lErr + ", label %" + lNorm);
  line(lErr + ":");
  curLbl = lErr;
  let errRes = emitCallRegs("__op_zone_error", [internString("logical operation"), A, emitNull()]);
  let errLbl = curLbl;
  line("  br label %" + lDone);
  line(lNorm + ":");
  curLbl = lNorm;
  let A2 = temp(); let trA = temp();
  line("  " + A2 + " = ptrtoint ptr " + A + " to i64");
  line("  " + trA + " = call i1 @ql_truthy(i64 " + A2 + ")");
  let predA = curLbl;
  let lEvalB = lbl();
  if op == "&&" {
    line("  br i1 " + trA + ", label %" + lEvalB + ", label %" + lDone);
  } else {
    line("  br i1 " + trA + ", label %" + lDone + ", label %" + lEvalB);
  };
  line(lEvalB + ":");
  curLbl = lEvalB;
  let B = emitExpr(node.right);
  let predB = curLbl;
  line("  br label %" + lDone);
  line(lDone + ":");
  curLbl = lDone;
  let res = temp();
  line("  " + res + " = phi ptr [ " + A + ", %" + predA + " ], [ " + B + ", %" + predB + " ], [ " + errRes + ", %" + errLbl + " ]");
  res;
};
```

- [ ] **Step 3:runtime.ql 派发函数**

在 runtime.ql 增(替换旧 `__add` :385-419):

```qlang
// M3:BOOL 盒 {tag3, i64 0/1}
let __mkbool = (b) -> {
  let box = allocBox(3, 16);
  let v = 0;
  if b { v = 1; };
  writeU64(box, 8, v);
  box;
};

// 操作区:任一操作数 Error → TypeMismatch(cause=出错操作数)。消息格式归一化下等价 host。
let __op_zone_error = (word, L, R) -> {
  let tL = readU64(L, 0);
  let tR = readU64(R, 0);
  if tL == 8 {
    __err_new("TypeMismatch", "cannot apply " + word + " to " + __type_of(L) + " and " + __type_of(R), L);
  } else {
    if tR == 8 {
      __err_new("TypeMismatch", "cannot apply " + word + " to " + __type_of(L) + " and " + __type_of(R), R);
    } else {
      __err("TypeMismatch", "cannot apply " + word + " to " + __type_of(L) + " and " + __type_of(R));
    };
  };
};

let __op_div0 = () -> {
  __err("DivisionByZero", "division by zero");
};

// 字符串内容相等:len 相等 + 逐字节相等(ASCII 域 len = 字符数)
let __str_eq = (a, b) -> {
  let la = readU64(a, 16);
  let lb = readU64(b, 16);
  let same = 0;
  if la == lb {
    let ba = ql_mem_get_ptr(a, 8);
    let bb = ql_mem_get_ptr(b, 8);
    let i = 0;
    let eq = 1;
    while i < la && eq == 1 {
      if ql_mem_get(ba, i) != ql_mem_get(bb, i) { eq = 0; };
      i = i + 1;
    };
    same = eq;
  };
  __mkbool(same == 1);
};

// tag 感知相等(host values_equal 镜像)。数值路径不达此(emit 内联);字符串内容、对象/数组/函数载荷同一。
let __op_eq = (a, b) -> {
  let ta = readU64(a, 0);
  let tb = readU64(b, 0);
  if ta == 8 {
    __op_zone_error("comparison", a, b);
  } else {
    if tb == 8 {
      __op_zone_error("comparison", a, b);
    } else {
      if ta == 4 && tb == 4 {
        true;
      } else {
        if ta == 2 && tb == 2 {
          __str_eq(a, b);
        } else {
          if ta == 3 && tb == 3 {
            __mkbool(readU64(a, 8) == readU64(b, 8));
          } else {
            if ta == 5 && tb == 5 {
              __mkbool(readU64(a, 8) == readU64(b, 8));
            } else {
              if ta == 6 && tb == 6 {
                __mkbool(readU64(a, 8) == readU64(b, 8));
              } else {
                if ta == 7 && tb == 7 {
                  __mkbool(readU64(a, 16) == readU64(b, 16));
                } else {
                  false;
                };
              };
            };
          };
        };
      };
    };
  };
};

let __op_ne = (a, b) -> {
  let ta = readU64(a, 0);
  let tb = readU64(b, 0);
  if ta == 8 {
    __op_zone_error("comparison", a, b);
  } else {
    if tb == 8 {
      __op_zone_error("comparison", a, b);
    } else {
      !__op_eq(a, b);
    };
  };
};

// 字符串拼接(STR+STR → tag-2;错误传播;其余 TypeMismatch)。数值路径不达此。
let __op_add = (a, b) -> {
  let ta = readU64(a, 0);
  let tb = readU64(b, 0);
  if ta == 8 {
    __op_zone_error("addition", a, b);
  } else {
    if tb == 8 {
      __op_zone_error("addition", a, b);
    } else {
      if ta == 2 && tb == 2 {
        let ab = ql_mem_get_ptr(a, 8);
        let al = readU64(a, 16);
        let bb = ql_mem_get_ptr(b, 8);
        let bl = readU64(b, 16);
        let nb = ql_alloc(al + bl);
        let i = 0;
        while i < al {
          ql_mem_store(nb, i, ql_mem_get(ab, i));
          i = i + 1;
        };
        let j = 0;
        while j < bl {
          ql_mem_store(nb, al + j, ql_mem_get(bb, j));
          j = j + 1;
        };
        __str_new(nb, al + bl);
      } else {
        __op_zone_error("addition", a, b);
      };
    };
  };
};
```

> **注意**:`__op_zone_error` 内 `"cannot apply " + word + ...` 是 STRING 拼接 → 编译时经 emitBinaryOp 派发 __op_add → __op_add 内字节拷贝算术内联 → **无递归**。`__op_eq` 内 `ta == 8` 是 NUMBER 比较 → 内联 fcmp,不递归。`true`/`false` 字面量 ✓。`__mkbool(readU64(a,8) == readU64(b,8))` 的 `==` 两侧 NUMBER 盒 → 内联 ✓。

- [ ] **Step 4:`??` stub(T9 前编译通过)**

emitBinaryOp 引用了 `emitCoalesce`(T9 定义)。T2 暂以 stub 占位,保证 qlangc 解析不崩:

```qlang
let emitCoalesce = (node) -> {
  line("; T2 stub: coalesce");
  emitNull();
};
```
(放在 emitBinaryOp 之前;T9 用真实实现替换。)

- [ ] **Step 5:验证**

Run: `bash aot/run_v1_tests.sh`
Expected: v1 套件 ALL PASS(数值内联路径无回归)。

Run: `bash -c 't=aot/tests/t8_str.ql; n=$(basename $t .ql); ./target/debug/qlang "$t" > /tmp/t8_$n.host 2>&1; ./target/debug/qlang --compile "$t" -o /tmp/t8_$n.bin >/dev/null 2>&1 && /tmp/t8_$n.bin > /tmp/t8_$n.native; diff /tmp/t8_$n.host /tmp/t8_$n.native && echo PASS'`
Expected: PASS(字符串 `+`/`==` 内容语义)。

Run: 除零/位运算/字符串内容探针:
```bash
printf 'println(10 / 4);\nprintln(5 %% 0);\nprintln(5 & 3);\nprintln("ab" == "ab");\nprintln("ab" != "ab");\n' > /tmp/top.ql
./target/debug/qlang /tmp/top.ql > /tmp/top.host 2>&1
./target/debug/qlang --compile /tmp/top.ql -o /tmp/top.bin && /tmp/top.bin > /tmp/top.native
diff /tmp/top.host /tmp/top.native && echo PASS
```
Expected: `2.5` / `<Error>`(除零归一化;host 侧 stderr 或 `<Error>`) / `1` / `true` / `false` 一致。(若 `10/4` 的 `2.5` host/native 不一致,属差异项 5,本任务仅确认**不崩溃**;白名单在 T5。)

- [ ] **Step 6:Commit**

```bash
git add aot/qlangc.ql aot/runtime.ql
git commit -m "feat(aot): M3 T2 — tag-aware emitBinaryOp dual path + __op_add/eq/ne/zone_error + bitwise inline + div-zero (R1/R14)"
```

---

### Task 3:`?` 后缀 epilogue codegen + emitCall 错误实参传播 + ql_exit

**Files:**
- Modify: `aot/qlangc.ql`(emitUnaryOp `?`、emitFunction epilogue、emitCall Identifier callee arg-check、emitPrelude + isLeaf 补 ql_exit、isTopLevel/curRetv/curEpiLbl 状态)
- Modify: `aot/runtime.ql`(`__err_chain`/`__err_write`/`__exit_error`)

**Interfaces:**
- Consumes: T2 `__op_zone_error`/`__op_add`;T1 `__err_get`/`__err_cause`/`__isError`。
- Produces: 每个 emitFunction 带 `%retv` alloca + `%epilogue` label;`?` 错误实参直接折回函数返回;顶层 `?` → `__exit_error`(stderr 打印 + exit 1)。

- [ ] **Step 1:状态变量 + emitFunction epilogue**

在 qlangc.ql(emitFunction 附近)加:

```qlang
// M3 T3:`?` 的传播目标 = 当前函数 epilogue(%retv alloca + %epilogue label)。
// 顶层(isTopLevel)无 epilogue → `?` 走 __exit_error + unreachable。
let curRetv = "";       // 当前函数 %retv 寄存器名
let curEpiLbl = "";     // 当前函数 epilogue label 名
let isTopLevel = true;  // main 顶层 ? → __exit_error
```

重写 emitFunction(:368-440)的函数体尾部(替换 :416-422):

```qlang
  // M3:epilogue —— %retv alloca 在 entry 分配;body 末 store + br;? 的 prop 分支同样 store 后 br。
  let rv = temp();
  line("  " + rv + " = alloca ptr");
  let bodyLast = emitBlockStmts(node.body.statements);
  let bl = bodyLast;
  if bl == null {
    bl = emitNull();
  };
  line("  store ptr " + bl + ", ptr " + rv);
  let lEpi = lbl();
  line("  br label %" + lEpi);
  line(lEpi + ":");
  let rv2 = temp();
  line("  " + rv2 + " = load ptr, ptr " + rv);
  line("  ret ptr " + rv2);
  line("}");
```
并在函数体 emit 前设置、emit 后恢复:

```qlang
  let savedRetv = curRetv; let savedEpi = curEpiLbl; let savedTop = isTopLevel;
  curRetv = rv; curEpiLbl = lEpi; isTopLevel = false;
  ...(参数拷贝 + emitBlockStmts + epilogue)...
  curRetv = savedRetv; curEpiLbl = savedEpi; isTopLevel = savedTop;
```

- [ ] **Step 2:emitUnaryOp `?`**

在 emitUnaryOp(:204-232)的 operator 分派最前插入:

```qlang
  if node.operator == "?" {
    // Propagate:operand 为 Error → 折回函数返回(或顶层 __exit_error);否则原值继续
    let tO = temp(); let eO = temp();
    line("  " + tO + " = load i64, ptr " + O);
    line("  " + eO + " = icmp eq i64 " + tO + ", 8");
    let lProp = lbl(); let lOk = lbl();
    line("  br i1 " + eO + ", label %" + lProp + ", label %" + lOk);
    line(lProp + ":");
    curLbl = lProp;
    if isTopLevel {
      emitCallRegs("__exit_error", [O]);
      line("  unreachable");
    } else {
      line("  store ptr " + O + ", ptr " + curRetv);
      line("  br label %" + curEpiLbl);
    };
    line(lOk + ":");
    curLbl = lOk;
    O;
  } else if node.operator == "-" {
```
(其余 `-`/`!` 分支保持;末尾 else 分支删除 —— `?`/`-`/`!` 全覆盖,防御性保留 `O;`。)

- [ ] **Step 3:emitCall 错误实参传播(仅 Identifier callee)**

替换 emitCall(:670-691)的 `} else if calleeIsId || node.callee.type == "MemberAccess" {` 分支为两个分支:

```qlang
  } else if calleeIsId {
    // M3 R15:用户函数(纯 Identifier callee)实参为 Error → 该错误成为调用结果(不进入 callee)。
    let FN = emitExpr(node.callee);
    let narg = node.arguments.length;
    let lAllDone = lbl();
    let argRegs = [];
    let errRegs = [];
    let errBlks = [];
    let i = 0;
    while i < narg {
      let v = emitExpr(node.arguments[i]);
      let t = temp(); let e = temp();
      line("  " + t + " = load i64, ptr " + v);
      line("  " + e + " = icmp eq i64 " + t + ", 8");
      let lNext = lbl(); let lErr = lbl();
      line("  br i1 " + e + ", label %" + lErr + ", label %" + lNext);
      line(lErr + ":");
      curLbl = lErr;
      errRegs[errRegs.length] = v;
      errBlks[errBlks.length] = curLbl;
      line("  br label %" + lAllDone);
      line(lNext + ":");
      curLbl = lNext;
      argRegs[argRegs.length] = v;
      i = i + 1;
    };
    let arr = temp();
    line("  " + arr + " = call ptr @ql_alloc(i64 " + std.String.toString(8 * narg) + ")");
    let j = 0;
    while j < narg {
      let aoff = temp();
      line("  " + aoff + " = getelementptr ptr, ptr " + arr + ", i64 " + std.String.toString(j));
      line("  store ptr " + argRegs[j] + ", ptr " + aoff);
      j = j + 1;
    };
    let codep = temp(); let codev = temp();
    line("  " + codep + " = getelementptr i8, ptr " + FN + ", i64 8");
    line("  " + codev + " = load ptr, ptr " + codep);
    let envp = temp(); let envv = temp();
    line("  " + envp + " = getelementptr i8, ptr " + FN + ", i64 16");
    line("  " + envv + " = load ptr, ptr " + envp);
    let r = temp();
    line("  " + r + " = call ptr " + codev + "(ptr " + envv + ", ptr " + arr + ", i64 " + std.String.toString(narg) + ")");
    let cleanBlk = curLbl;
    line("  br label %" + lAllDone);
    line(lAllDone + ":");
    curLbl = lAllDone;
    let res = temp();
    let ph = "  " + res + " = phi ptr [ " + r + ", %" + cleanBlk + " ]";
    let e2 = 0;
    while e2 < errBlks.length {
      ph = ph + ", [ " + errRegs[e2] + ", %" + errBlks[e2] + " ]";
      e2 = e2 + 1;
    };
    line(ph);
    res;
  } else if node.callee.type == "MemberAccess" {
    // M3 R15:MemberAccess callee(std.* / 实例方法)不走错误实参检查 —— 自处理错误。
    let FN = emitExpr(node.callee);
    let narg = node.arguments.length;
    let arr = temp();
    line("  " + arr + " = call ptr @ql_alloc(i64 " + std.String.toString(8 * narg) + ")");
    let i = 0;
    while i < narg {
      let v = emitExpr(node.arguments[i]);
      let aoff = temp();
      line("  " + aoff + " = getelementptr ptr, ptr " + arr + ", i64 " + std.String.toString(i));
      line("  store ptr " + v + ", ptr " + aoff);
      i = i + 1;
    };
    let codep = temp(); let codev = temp();
    line("  " + codep + " = getelementptr i8, ptr " + FN + ", i64 8");
    line("  " + codev + " = load ptr, ptr " + codep);
    let envp = temp(); let envv = temp();
    line("  " + envp + " = getelementptr i8, ptr " + FN + ", i64 16");
    line("  " + envv + " = load ptr, ptr " + envp);
    let r = temp();
    line("  " + r + " = call ptr " + codev + "(ptr " + envv + ", ptr " + arr + ", i64 " + std.String.toString(narg) + ")");
    r;
  } else {
```

- [ ] **Step 4:ql_exit 接线**

emitPrelude(:789-796)declare 区追加 `line("declare void @ql_exit(i32)");`;isLeaf(:617)追加 `|| cname == "ql_exit"`;emitCall 的 leaf 分派补:

```qlang
    } else if cname == "ql_exit" {
      let code = boxToInt(emitExpr(node.arguments[0]), "i32");
      line("  call void @ql_exit(i32 " + code + ")");
      emitNull();
    };
```

- [ ] **Step 5:runtime.ql `__err_chain`/`__exit_error`**

```qlang
// 错误链文本:`{kind}: {message}` + 每级 cause `\n  └─ caused by: {kind}: {message}`
let __err_chain = (e) -> {
  let base = __err_get(e, "kind") + ": " + __err_get(e, "message");
  let c = __err_cause(e);
  let r = base;
  if __isError(c) {
    r = base + "\n  └─ caused by: " + __err_chain(c);
  };
  r;
};
// 写 fd(1/2)+ 字符串(直接 STRING 盒)
let __wfd = (fd, s) -> {
  ql_write(fd, ql_mem_get_ptr(s, 8), readU64(s, 16));
  null;
};
// 顶层未捕获错误:stderr 打印错误链 + exit 1
let __exit_error = (e) -> {
  __wfd(2, __err_chain(e));
  let nl = ql_alloc(1);
  ql_mem_store(nl, 0, 10);
  ql_write(2, nl, 1);
  ql_exit(1);
  null;
};
```
> **注意**:`__err_chain` 递归调用自身 —— qlangc 已支持递归函数(M1)。`"\n  └─ caused by: "` 含非 ASCII → 依赖 T1 差异项 6(byte-aware internString)。

- [ ] **Step 6:验证 `?` 传播**

```bash
printf 'let f = (x) -> { let v = x ?; "unreached"; };\nlet r = f(42);\nprintln(r);\nlet e = f(null);\nprintln(__isError(e));\n' > /tmp/tq3.ql
./target/debug/qlang /tmp/tq3.ql > /tmp/tq3.host 2>&1
./target/debug/qlang --compile /tmp/tq3.ql -o /tmp/tq3.bin && /tmp/tq3.bin > /tmp/tq3.native
diff /tmp/tq3.host /tmp/tq3.native && echo PASS
```
Expected: `unreached` / `false`(`null` 非错误 → `?` 放行 → 函数返回 "unreached";`__isError("unreached")` = false)。再把 `x ?` 换 `let x2 = __err("K","m") ?;` 验证传播(见 Step 7)。

- [ ] **Step 7:错误实参传播 + 实错误传播**

```bash
printf 'let g = (x) -> x;\nlet e = __err("K", "boom");\nlet r = g(e);\nprintln(__isError(r));\nlet h = (x) -> { let v = __err("K2", "m2") ?; 99; };\nlet r2 = h(1);\nprintln(__isError(r2));\n' > /tmp/tq4.ql
./target/debug/qlang /tmp/tq4.ql > /tmp/tq4.host 2>&1; ./target/debug/qlang --compile /tmp/tq4.ql -o /tmp/tq4.bin && /tmp/tq4.bin > /tmp/tq4.native; diff /tmp/tq4.host /tmp/tq4.native && echo PASS
```
Expected: `true`(g 拒绝错误实参 → 返回该错误)/ `true`(`?` 把函数内错误折回)。

- [ ] **Step 8:Commit**

```bash
git add aot/qlangc.ql aot/runtime.ql
git commit -m "feat(aot): M3 T3 — ? propagation via fn epilogue, emitCall error-arg rejection (R15), ql_exit wiring (R10)"
```

---

### Task 4:isError + 类型系统(单例 + std.Type + Array/Object 构造器)+ std.Error

**Files:**
- Modify: `aot/runtime.ql`(全局 `isError`、10 单例、`std.Type`、`Array`/`Object` 构造器、`std.Error`、`__obj_keys`/`__obj_values`、`std` 对象)
- Create: `aot/tests/t9_type.ql`(3-way)

**Interfaces:**
- Consumes: T1 `__err`/`__isError`;T2 `__op_eq`/`__op_ne`;M2 `__obj_new`/`__obj_set`/`__obj_get`/`__type_of`/`__get_field`/`__get_length`/`__get_index`。
- Produces: 全局 `isError`、`Number`/`String`/`Boolean`/`Null`/`AnyArray`/`AnyObject`/`Function`/`Any`/`Never`/`Error`/`Type` 单例、全局 `Array`/`Object` 构造器、`std.Type`(=Type 单例,含 of/make/check)、`std.Error.raise`/`toString`、`std` 根对象。**419 的类型系统依赖全部在此落地。**

- [ ] **Step 1:`__obj_keys`/`__obj_values` + `__mk_otype` + `__is_type_value`**

在 runtime.ql 哈希表区之后:

```qlang
// M3:遍历桶表收集键/值(空槽哨兵跳过;键 = 表内指针 → 供 Object.keys/构造器)
let __obj_keys = (o) -> {
  let table = ql_mem_get_ptr(o, 8);
  let cap = readU64(o, 16);
  let ks = [];
  let i = 0;
  while i < cap {
    let k = ql_mem_get_ptr(table, i * 16);
    if k != __EMPTY {
      ks.add(k);
    };
    i = i + 1;
  };
  ks;
};
let __obj_values = (o) -> {
  let table = ql_mem_get_ptr(o, 8);
  let cap = readU64(o, 16);
  let vs = [];
  let i = 0;
  while i < cap {
    let k = ql_mem_get_ptr(table, i * 16);
    if k != __EMPTY {
      vs.add(ql_mem_get_ptr(table, i * 16 + 8));
    };
    i = i + 1;
  };
  vs;
};

// 用户类型对象:{check: fn}(R4:check 域是类型识别标志)
let __mk_otype = (c) -> {
  { check: c };
};
// R4:tag6 且 check 域为 tag-7 函数 → 类型值
let __is_type_value = (v) -> {
  if readU64(v, 0) == 6 {
    let c = __obj_get(v, __K_CHECK);
    readU64(c, 0) == 7;
  } else {
    false;
  };
};
```
> **注意**:`__obj_keys` 的 `ks.add(k)` → emitCall `.add` 降低 → `__arr_add` ✓;`k != __EMPTY` 字符串内容比较(`""` 哨兵)✓。`__K_CHECK = "check"`、`__K_LENGTH = "length"`、`__K_ELEMENT = "element"` 在 __K_BUF/__K_LEN 附近定义。

- [ ] **Step 2:谓词 + 单例 + std.Type**

```qlang
// 单例谓词(返回 BOOL 盒)
let __pred_number = (v) -> { readU64(v, 0) == 1; };
let __pred_string = (v) -> { readU64(v, 0) == 2; };
let __pred_boolean = (v) -> { readU64(v, 0) == 3; };
let __pred_null = (v) -> { readU64(v, 0) == 4; };
let __pred_array = (v) -> { readU64(v, 0) == 5; };
let __pred_anyobject = (v) -> { readU64(v, 0) == 6 && !__is_type_value(v); };
let __pred_function = (v) -> { readU64(v, 0) == 7; };
let __pred_error = (v) -> { readU64(v, 0) == 8; };
let __pred_any = (v) -> { true; };
let __pred_never = (v) -> { false; };
let __pred_type = (v) -> { __is_type_value(v); };

// 类型单例(R18:全局;带 check → 是类型值;Type 单例 = std.Type 自身)
let Number = { check: __pred_number };
let String = { check: __pred_string };
let Boolean = { check: __pred_boolean };
let Null = { check: __pred_null };
let AnyArray = { check: __pred_array };
let AnyObject = { check: __pred_anyobject };
let Function = { check: __pred_function };
let Any = { check: __pred_any };
let Never = { check: __pred_never };
let Error = { check: __pred_error };

// Type.of(v)(host types.rs:129-147 镜像):tag→单例;tag6 且类型值→Type 单例;tag6→AnyObject
let __type_of_val = (v) -> {
  let tag = readU64(v, 0);
  if tag == 1 { Number; }
  else { if tag == 2 { String; }
  else { if tag == 3 { Boolean; }
  else { if tag == 4 { Null; }
  else { if tag == 5 { AnyArray; }
  else { if tag == 7 { Function; }
  else { if tag == 8 { Error; }
  else { if tag == 6 && __is_type_value(v) { Type; }
  else { if tag == 6 { AnyObject; }
  else { Any; }; }; }; }; }; }; }; };
};
// Type.make(f)(host types.rs:148-159 镜像)
let __type_make = (f) -> {
  if readU64(f, 0) == 7 {
    __mk_otype(f);
  } else {
    __err("TypeMismatch", "Type.make: expected a function");
  };
};
// Type 单例 = std.Type(自反:R4)
let Type = { check: __pred_type, of: __type_of_val, make: __type_make };
```
> **注意**:`Type` 在 `__type_of_val` 里被引用但定义在其后 —— runtime.ql 顶层 let 前向引用安全(M2 pre-scan)✓。`{ check: __pred_number }` 是 ObjectExpr 字面量 ✓。**Object/Array 构造器(T5 的 __obj_keys 依赖)在此可用**:单例的 check 都是 tag-7 函数盒。

- [ ] **Step 3:全局 `Array` 构造器(host build_array_type 镜像)**

```qlang
let __compile_schema = (m) -> {
  if __is_type_value(m) {
    m;
  } else {
    if readU64(m, 0) == 6 {
      let ln = __obj_get(m, __K_LENGTH);
      if readU64(ln, 0) != 8 {
        __arr_ctor(m);
      } else {
        __obj_ctor(m);
      };
    } else {
      __err("TypeMismatch", "invalid descriptor");
    };
  };
};
let __arr_elem_check = (v, T) -> {
  let ok = 1;
  if readU64(v, 0) == 5 {
    let c = __get_field(T, __K_CHECK);
    let n = readU64(v, 16);
    let i = 0;
    while i < n && ok == 1 {
      let e = __get_index(v, i);
      let r = c(e);
      if readU64(r, 0) == 8 { ok = 0; } else { if !r { ok = 0; }; };
      i = i + 1;
    };
  } else { ok = 0; };
  __mkbool(ok == 1);
};
let __tuple_check = (v, types) -> {
  let ok = 1;
  if readU64(v, 0) == 5 {
    let n = readU64(v, 16);
    let nt = readU64(types, 16);
    if n == nt {
      let i = 0;
      while i < n && ok == 1 {
        let c = __get_field(__get_index(types, i), __K_CHECK);
        let e = __get_index(v, i);
        let r = c(e);
        if readU64(r, 0) == 8 { ok = 0; } else { if !r { ok = 0; }; };
        i = i + 1;
      };
    } else { ok = 0; };
  } else { ok = 0; };
  __mkbool(ok == 1);
};
let __meta_check = (v, ln, c) -> {
  let ok = 1;
  if readU64(v, 0) == 5 {
    let n = readU64(v, 16);
    if n == ln {
      let i = 0;
      while i < n && ok == 1 {
        let e = __get_index(v, i);
        let r = c(e);
        if readU64(r, 0) == 8 { ok = 0; } else { if !r { ok = 0; }; };
        i = i + 1;
      };
    } else { ok = 0; };
  } else { ok = 0; };
  __mkbool(ok == 1);
};
// 全局 Array(host build_array_type 4 分支镜像)
let Array = (x) -> {
  let tag = readU64(x, 0);
  if tag == 1 {
    if x % 1 != 0 || x < 0 {
      __err("TypeMismatch", "Array: length must be a non-negative integer");
    } else {
      __mk_otype((v) -> { let L = __get_length(v, __K_LENGTH); if readU64(L, 0) == 8 { false; } else { L == x; }; });
    };
  } else {
    if __is_type_value(x) {
      __mk_otype((v) -> { __arr_elem_check(v, x); });
    } else {
      if tag == 5 {
        let ok = true;
        let i = 0;
        while i < readU64(x, 16) && ok {
          if !__is_type_value(__get_index(x, i)) { ok = false; };
          i = i + 1;
        };
        if !ok {
          __err("TypeMismatch", "Array: tuple elements must all be type values");
        } else {
          __mk_otype((v) -> { __tuple_check(v, x); });
        };
      } else {
        if tag == 6 {
          let ln = __obj_get(x, __K_LENGTH);
          let el = __obj_get(x, __K_ELEMENT);
          if readU64(ln, 0) == 8 {
            __err("TypeMismatch", "Array: metadata must have a non-negative integer 'length'");
          } else {
            if readU64(el, 0) == 8 {
              __err("TypeMismatch", "Array: metadata must have a type 'element'");
            } else {
              let c = __compile_schema(el);
              if readU64(c, 0) == 8 {
                c;
              } else {
                __mk_otype((v) -> { __meta_check(v, ln, c); });
              };
            };
          };
        } else {
          __err("TypeMismatch", "Array: argument must be a length, a type, a list of types, or {length, element}");
        };
      };
    };
  };
};
```

- [ ] **Step 4:全局 `Object` 构造器(host build_object_type 镜像)**

```qlang
let __object_check_keys = (v, kcheck) -> {
  let ok = 1;
  if readU64(v, 0) == 6 && !__is_type_value(v) {
    let ks = __obj_keys(v);
    let n = readU64(ks, 16);
    let i = 0;
    while i < n && ok == 1 {
      let r = kcheck(__get_index(ks, i));
      if readU64(r, 0) == 8 { ok = 0; } else { if !r { ok = 0; }; };
      i = i + 1;
    };
  } else { ok = 0; };
  __mkbool(ok == 1);
};
let __object_check_schema = (v, schema) -> {
  let ok = 1;
  if readU64(v, 0) == 6 && !__is_type_value(v) {
    let ks = __obj_keys(schema);
    let n = readU64(ks, 16);
    let i = 0;
    while i < n && ok == 1 {
      let k = __get_index(ks, i);
      let c = __get_field(__get_field(schema, k), __K_CHECK);
      let fv = __get_field(v, k);
      if readU64(fv, 0) == 8 { ok = 0; }
      else {
        let r = c(fv);
        if readU64(r, 0) == 8 { ok = 0; } else { if !r { ok = 0; }; };
      };
      i = i + 1;
    };
  } else { ok = 0; };
  __mkbool(ok == 1);
};
let __object_check_pred = (v, pred) -> {
  if readU64(v, 0) == 6 && !__is_type_value(v) {
    let r = pred(v);
    if readU64(r, 0) == 8 { false; } else { r; };
  } else { false; };
};
let __obj_ctor = (x) -> {
  if __is_type_value(x) {
    __mk_otype((v) -> { __object_check_keys(v, __get_field(x, __K_CHECK)); });
  } else {
    if readU64(x, 0) == 6 {
      __mk_otype((v) -> { __object_check_schema(v, x); });
    } else {
      if readU64(x, 0) == 7 {
        __mk_otype((v) -> { __object_check_pred(v, x); });
      } else {
        __err("TypeMismatch", "Object: argument must be a type (keys), a shape object (schema), or a predicate function");
      };
    };
  };
};
let Object = (x) -> { __obj_ctor(x); };
```
> **注意**:`__get_field(schema, k)` 的 k 来自 `__obj_keys(schema)`(表内指针)→ 与 schema 键指针同一 → 哈希命中 ✓;`__get_field(v, k)` 中 v 的键是 interned 同内容 → 指针同一命中 ✓。

- [ ] **Step 5:std.Error + `std` 根对象**

```qlang
let __error_raise = (kind, message, cause) -> {
  let k = kind;
  let m = message;
  if readU64(k, 0) != 2 { k = "Error"; };
  if readU64(m, 0) != 2 { m = __str(m); };
  if __isError(cause) {
    __err_new(k, m, cause);
  } else {
    __err_new(k, m, null);
  };
};
let __error_tostring = (err) -> {
  if __isError(err) {
    __err_chain(err);
  } else {
    "not an error";
  };
};
let stdError = {
  raise: __error_raise,
  toString: __error_tostring,
};
let std = {
  Type: Type,
  Error: stdError,
};
```

- [ ] **Step 6:创建 `aot/tests/t9_type.ql`(3-way)**

```qlang
// M3 t9_type:类型系统(3-way)
println(isError(42));
let T = std.Type.make((v) -> readU64(v, 0) == 1);
println(T.check(5));
println(!T.check("s"));
println(std.Type.of(42) == Number);
println(std.Type.of("s") == String);
println(std.Type.of(Number) == std.Type);
println(std.Type.of(std.Type) == std.Type);
let A3 = Array({ length: 3, element: Number });
println(A3.check([1, 2, 3]));
println(!A3.check([1, 2]));
println(!A3.check([1, "s"]));
let O = Object({ a: Number });
println(O.check({ a: 1 }));
println(!O.check({ a: "s" }));
println(!O.check({}));
let P = Object((o) -> o.a > 0);
println(P.check({ a: 1 }));
println(!P.check({ a: -1 }));
let e = std.Error.raise("TypeMismatch", "boom", null);
println(isError(e));
println(e.type == "TypeMismatch");
println(e.message == "boom");
```

Run: `bash -c 't=aot/tests/t9_type.ql; n=$(basename $t .ql); ./target/debug/qlang "$t" > /tmp/t9_$n.host 2>&1; ./target/debug/qlang --compile "$t" -o /tmp/t9_$n.bin >/dev/null 2>&1 && /tmp/t9_$n.bin > /tmp/t9_$n.native; diff /tmp/t9_$n.host /tmp/t9_$n.native && echo PASS'`
Expected: 全部 host/native 逐字节一致(每个 println 输出 true/false)。**若某行发散,先查 host 输出语义再修 runtime.ql。**

- [ ] **Step 7:Commit**

```bash
git add aot/runtime.ql aot/tests/t9_type.ql
git commit -m "feat(aot): M3 T4 — isError + 10 type singletons + std.Type + Array/Object ctors + std.Error (R4/R18)"
```

---

### Task 5:std.Object + std.Number + `obj["k"]` OBJECT 索引 + `__itoa` 分数渲染

**Files:**
- Modify: `aot/runtime.ql`(`__get_index`/`__set_index` 增 tag6 分支;stdObject/stdNumber 模块;`__itoa` 分数路径)
- Create: `aot/tests/t9_object.ql`、`aot/tests/t9_number.ql`

**Interfaces:**
- Consumes: T4 的 `__obj_keys`/`__obj_values`;M2 `__norm_idx`;T1 tag-2 `__itoa`。
- Produces: `std.Object.keys/values/merge/hasOwn/get/field`;`std.Number.toString/isNaN/isFinite/parseFloat`;`o["k"]` 读写;差异项 5 `__itoa` 分数渲染。

- [ ] **Step 1:OBJECT 索引分支(Gap A)**

`__get_index`(:275-311)在 tag==5 分支后、tag==2 分支前,插入:

```qlang
    if tag == 6 {
      __obj_get(c, i);
    } else {
```
并相应闭合嵌套。`__set_index`(:313-350)同理加:

```qlang
    if tag == 6 {
      __obj_set(c, i, v);
      null;
    } else {
```
> `i` 是键 STRING 盒(419 的 `o[k]`);`__obj_get`/`__obj_set` 需要指针同一键 → interned/表内键 ✓。

- [ ] **Step 2:std.Object 模块**

```qlang
let __obj_merge = (o1) -> (o2) -> {
  let out = __obj_new();
  let k1 = __obj_keys(o1);
  let i = 0;
  while i < readU64(k1, 16) {
    let k = __get_index(k1, i);
    __obj_set(out, k, __obj_get(o1, k));
    i = i + 1;
  };
  let k2 = __obj_keys(o2);
  let j = 0;
  while j < readU64(k2, 16) {
    let k = __get_index(k2, j);
    __obj_set(out, k, __obj_get(o2, k));
    j = j + 1;
  };
  out;
};
let __obj_hasown = (o) -> (k) -> {
  let v = __obj_get(o, k);
  readU64(v, 0) != 8;
};
let __obj_get2 = (o) -> (k) -> {
  let v = __obj_get(o, k);
  if readU64(v, 0) == 8 { null; } else { v; };
};
let stdObject = {
  keys: __obj_keys,
  values: __obj_values,
  merge: __obj_merge,
  hasOwn: __obj_hasown,
  get: __obj_get2,
  field: (o) -> (k) -> { __obj_get(o, k); },
};
```
并把 `std` 对象增 `Object: stdObject`。
> **注意**:柯里化成员 `(o) -> (k) -> {...}` —— 419 不用,但 spec §7 要求;`__get_index(k1, i)` 返回的 k 是表内键 → `__obj_get(o1, k)` 指针同一命中 ✓。

- [ ] **Step 3:std.Number 模块**

```qlang
let __num_isnan = (n) -> {
  if readU64(n, 0) == 1 { n != n; } else { false; };
};
let __num_isfinite = (n) -> {
  if readU64(n, 0) == 1 { !(n != n || (n - n) != (n - n)); } else { false; };
};
let __parse_float = (s) -> {
  // trim 空白 + 可选 '-' + 数字;失败 → NaN
  let buf = ql_mem_get_ptr(s, 8);
  let len = readU64(s, 16);
  let i = 0;
  while i < len && ql_mem_get(buf, i) == 32 { i = i + 1; };
  let neg = 0;
  if i < len && ql_mem_get(buf, i) == 45 { neg = 1; i = i + 1; };
  let acc = 0;
  let any = 0;
  while i < len && ql_mem_get(buf, i) >= 48 && ql_mem_get(buf, i) <= 57 {
    acc = acc * 10 + (ql_mem_get(buf, i) - 48);
    any = 1;
    i = i + 1;
  };
  let fr = 0;
  let scale = 1;
  if i < len && ql_mem_get(buf, i) == 46 {
    i = i + 1;
    while i < len && ql_mem_get(buf, i) >= 48 && ql_mem_get(buf, i) <= 57 {
      fr = fr * 10 + (ql_mem_get(buf, i) - 48);
      scale = scale * 10;
      any = 1;
      i = i + 1;
    };
  };
  if any == 0 {
    __mknum_from_zero();   // NaN 不可廉价产 → 用 0 占位(已知发散,白名单不进 parseFloat 失败)
  } else {
    let v = acc + fr / scale;
    if neg == 1 { -v; } else { v; };
  };
};
let __mknum_from_zero = () -> { 0; };   // 占位;parseFloat 失败行为白名单外
let stdNumber = {
  toString: __itoa,
  isNaN: __num_isnan,
  isFinite: __num_isfinite,
  parseFloat: __parse_float,
};
```
并把 `std` 对象增 `Number: stdNumber`。
> **注意**:`__parse_float` 的 NaN 用 0 占位 —— 失败路径白名单外(已知发散);成功路径数值正确。`std.Number.toString` = `__itoa`(T5 后分数渲染)。

- [ ] **Step 4:`__itoa` 分数渲染(差异项 5)+ tag-2 返回**

替换 `__itoa`(:457-483)为:整数快速路径保留(T1 已 tag-2);`n` 非整数时尝试**精确十进制展开**(预算 ≤12 位小数,终止才渲染,否则回退整数截断):

```qlang
let __itoa = (n) -> {
  let neg = n < 0;
  let x = n;
  if neg { x = -n; };
  let ip = x - x % 1;              // 整数部分
  let fr = x % 1;                  // 小数部分(n%1:Q 内联 a-b*trunc(a/b))
  if fr == 0 {
    <M2 整数渲染:ip 逐位,产 tag-2 盒>
  } else {
    // 精确展开:预算 12 位小数,终止才渲染
    let digits = [];
    let f = fr;
    let budget = 12;
    let done = 0;
    while done == 0 {
      if f == 0 { done = 1; }
      else { if budget <= 0 { done = 2; }
      else {
        let t = f * 10;
        let d = t - t % 1;
        digits.add(d);
        f = t - d;
        budget = budget - 1;
      }; };
    };
    if done == 2 {
      <整数截断回退:M2 整数渲染 ip,产 tag-2 盒>
    } else {
      <整数渲染 ip + '.' + 逐位 digits,产 tag-2 盒>
    };
  };
};
```
> `digits.add(d)` 的 d 是 NUMBER 盒 → `.add` 降低 __arr_add ✓。字节写入:digit 字符 = 48 + d(读 payload:用 `readU64(d, 8)` 取整数)。**执行者按 M2 整数路径的逐位写法完成整数与拼接部分**,验收见 Step 5。

- [ ] **Step 5:验证**

```bash
printf 'println(std.Number.toString(10/4));\nprintln(std.Number.toString(1/8));\nprintln(std.Number.toString(42));\nprintln(std.Number.isNaN(0/0));\nprintln(std.Number.isFinite(5));\nlet o = { a: 1 };\nprintln(o["a"]);\nlet k = "a";\no[k] = 9;\nprintln(o[k]);\nprintln(std.Object.keys({ x: 1, y: 2 }).length);\n' > /tmp/tq5.ql
./target/debug/qlang /tmp/tq5.ql > /tmp/tq5.host 2>&1
./target/debug/qlang --compile /tmp/tq5.ql -o /tmp/tq5.bin && /tmp/tq5.bin > /tmp/tq5.native
diff /tmp/tq5.host /tmp/tq5.native && echo PASS
```
Expected: `2.5` / `0.125` / `42` / `<Error>`(0/0 除零;isNaN 未接错误 → 白名单外)/ `true` / `1` / `9` / `2`。

- [ ] **Step 6:Commit**

```bash
git add aot/runtime.ql aot/tests/t9_object.ql aot/tests/t9_number.ql
git commit -m "feat(aot): M3 T5 — obj[k] OBJECT indexing (Gap A), std.Object/Number, __itoa fraction (差异项 5)"
```

---

### Task 6:std.Array + std.String

**Files:**
- Modify: `aot/runtime.ql`(`__arr_push`/`__arr_pop`/`__arr_indexof`/`__arr_join`/`__arr_reverse`/`__arr_concat` 辅助 + stdArray/stdString 模块;`std` 增成员)
- Modify: `aot/qlangc.ql:662-669`(`.add`/`.remove` 降低加 Identifier-object 守卫)
- Create: `aot/tests/t9_array.ql`、`aot/tests/t9_string.ql`

**Interfaces:**
- Consumes: M2 `__arr_add`/`__arr_remove`/`__get_index`/`__set_index`/`__get_length`;T1 `__str_new`;T2 `__str_eq`/`__op_add`。
- Produces: `std.Array`(length/toString/add/remove/push/pop/get/indexOf/includes/join/reverse/concat/at);`std.String`(length/concat/toString/trim/toUpperCase/toLowerCase/includes/replace/split/repeat/startsWith/endsWith/join/at)。

- [ ] **Step 1:`.add`/`.remove` 降低守卫**

`aot/qlangc.ql:662` 的 `node.callee.field == "add"` 条件加 `&& node.callee.object.type == "Identifier"`(两处 add/remove 同理)。理由:`std.Array.add(x)`(模块成员,MemberAccess object)不应走 `__arr_add(std.Array, x)` 实例降低。419 实例 `.add`/`.remove` 的 object 都是 Identifier ✓(t8 回归需验证)。

- [ ] **Step 2:std.Array 模块**

```qlang
let __arr_push = (a) -> (v) -> {
  __arr_add(a, v);
  readU64(a, 16);
};
let __arr_pop = (a) -> () -> {
  let n = readU64(a, 16);
  if n == 0 { null; } else {
    let v = __get_index(a, n - 1);
    __arr_remove(a, n - 1);
    v;
  };
};
let __arr_indexof = (a) -> (v) -> {
  let n = readU64(a, 16);
  let i = 0;
  let found = -1;
  while i < n && found < 0 {
    if __op_eq(__get_index(a, i), v) { found = i; };
    i = i + 1;
  };
  found;
};
let __arr_join = (a) -> (sep) -> {
  let n = readU64(a, 16);
  let out = "";
  let i = 0;
  while i < n {
    if i > 0 { out = out + __str(sep); };
    out = out + __str(__get_index(a, i));
    i = i + 1;
  };
  out;
};
let __arr_reverse = (a) -> {
  let n = readU64(a, 16);
  let i = 0;
  while i < n / 2 {
    let lo = __get_index(a, i);
    let hi = __get_index(a, n - 1 - i);
    __set_index(a, i, hi);
    __set_index(a, n - 1 - i, lo);
    i = i + 1;
  };
  a;
};
let __arr_concat = (a) -> (b) -> {
  let out = [];
  let i = 0;
  while i < readU64(a, 16) { out.add(__get_index(a, i)); i = i + 1; };
  let j = 0;
  while j < readU64(b, 16) { out.add(__get_index(b, j)); j = j + 1; };
  out;
};
let stdArray = {
  length: (a) -> { readU64(a, 16); },
  toString: (a) -> { __arr_join(a)(","); },
  add: (a) -> (v) -> { __arr_add(a, v); },
  remove: (a) -> (i) -> { __arr_remove(a, i); },
  push: __arr_push,
  pop: __arr_pop,
  get: (a) -> (i) -> { __get_index(a, i); },
  indexOf: __arr_indexof,
  includes: (a) -> (v) -> { __arr_indexof(a)(v) >= 0; },
  join: __arr_join,
  reverse: __arr_reverse,
  concat: __arr_concat,
  at: (a, i) -> { __get_index(a, i); },
};
```
`std` 增 `Array: stdArray`。
> **注意**:`out = out + __str(sep)` —— `out`/`sep` STRING → `__op_add` 拼接 ✓。`__str(sep)` 对 STRING 盒返回自身 ✓。`__arr_join(a)(",")` 中 `(",")` 是柯里化第二参 ✓。

- [ ] **Step 3:std.String 模块(ASCII 字节操作)**

```qlang
let __s_len = (s) -> { readU64(s, 16); };
let __s_concat = (a, b) -> { __op_add(a, b); };
let __s_trim = (s) -> {
  let buf = ql_mem_get_ptr(s, 8);
  let len = readU64(s, 16);
  let i = 0;
  while i < len && ql_mem_get(buf, i) == 32 { i = i + 1; };
  let j = len;
  while j > i && ql_mem_get(buf, j - 1) == 32 { j = j - 1; };
  let nb = ql_alloc(j - i);
  let k = 0;
  while k < j - i {
    ql_mem_store(nb, k, ql_mem_get(buf, i + k));
    k = k + 1;
  };
  __str_new(nb, j - i);
};
let __s_case = (s, up) -> {
  let buf = ql_mem_get_ptr(s, 8);
  let len = readU64(s, 16);
  let nb = ql_alloc(len);
  let i = 0;
  while i < len {
    let c = ql_mem_get(buf, i);
    if up {
      if c >= 97 && c <= 122 { ql_mem_store(nb, i, c - 32); }
      else { ql_mem_store(nb, i, c); };
    } else {
      if c >= 65 && c <= 90 { ql_mem_store(nb, i, c + 32); }
      else { ql_mem_store(nb, i, c); };
    };
    i = i + 1;
  };
  __str_new(nb, len);
};
let __s_includes = (hay) -> (needle) -> {
  let hb = ql_mem_get_ptr(hay, 8);
  let hlen = readU64(hay, 16);
  let nb = ql_mem_get_ptr(needle, 8);
  let nlen = readU64(needle, 16);
  let found = 0;
  let i = 0;
  while i <= hlen - nlen && found == 0 {
    let j = 0;
    let eq = 1;
    while j < nlen && eq == 1 {
      if ql_mem_get(hb, i + j) != ql_mem_get(nb, j) { eq = 0; };
      j = j + 1;
    };
    if eq == 1 { found = 1; };
    i = i + 1;
  };
  found == 1;
};
let __s_replace = (s) -> (from) -> (to) -> {
  let sb = ql_mem_get_ptr(s, 8);
  let sl = readU64(s, 16);
  let fb = ql_mem_get_ptr(from, 8);
  let fl = readU64(from, 16);
  let tb = ql_mem_get_ptr(to, 8);
  let tl = readU64(to, 16);
  let pos = -1;
  let i = 0;
  while i <= sl - fl && pos < 0 {
    let j = 0;
    let eq = 1;
    while j < fl && eq == 1 {
      if ql_mem_get(sb, i + j) != ql_mem_get(fb, j) { eq = 0; };
      j = j + 1;
    };
    if eq == 1 { pos = i; };
    i = i + 1;
  };
  let out = ql_alloc(sl - fl + tl);
  let k = 0;
  while k < pos { ql_mem_store(out, k, ql_mem_get(sb, k)); k = k + 1; };
  let m = 0;
  while m < tl { ql_mem_store(out, pos + m, ql_mem_get(tb, m)); m = m + 1; };
  let r = 0;
  while r < sl - fl - pos { ql_mem_store(out, pos + tl + r, ql_mem_get(sb, pos + fl + r)); r = r + 1; };
  __str_new(out, sl - fl + tl);
};
let __s_repeat = (s) -> (n) -> {
  let sb = ql_mem_get_ptr(s, 8);
  let sl = readU64(s, 16);
  let nb = ql_alloc(sl * n);
  let i = 0;
  while i < n {
    let j = 0;
    while j < sl { ql_mem_store(nb, i * sl + j, ql_mem_get(sb, j)); j = j + 1; };
    i = i + 1;
  };
  __str_new(nb, sl * n);
};
let __s_sw = (s) -> (prefix) -> {
  let sb = ql_mem_get_ptr(s, 8);
  let pb = ql_mem_get_ptr(prefix, 8);
  let pl = readU64(prefix, 16);
  if readU64(s, 16) < pl { false; } else {
    let i = 0;
    let eq = 1;
    while i < pl && eq == 1 {
      if ql_mem_get(sb, i) != ql_mem_get(pb, i) { eq = 0; };
      i = i + 1;
    };
    eq == 1;
  };
};
let __s_ew = (s) -> (suffix) -> {
  let sb = ql_mem_get_ptr(s, 8);
  let sl = readU64(s, 16);
  let fb = ql_mem_get_ptr(suffix, 8);
  let fl = readU64(suffix, 16);
  if sl < fl { false; } else {
    let i = 0;
    let eq = 1;
    while i < fl && eq == 1 {
      if ql_mem_get(sb, sl - fl + i) != ql_mem_get(fb, i) { eq = 0; };
      i = i + 1;
    };
    eq == 1;
  };
};
let __s_split = (s) -> (sep) -> {
  let sb = ql_mem_get_ptr(s, 8);
  let sl = readU64(s, 16);
  let pb = ql_mem_get_ptr(sep, 8);
  let pl = readU64(sep, 16);
  let parts = [];
  let cur = [];
  let i = 0;
  while i < sl {
    let j = 0;
    let eq = 1;
    while j < pl && i + j < sl && eq == 1 {
      if ql_mem_get(sb, i + j) != ql_mem_get(pb, j) { eq = 0; };
      j = j + 1;
    };
    if eq == 1 && j == pl {
      let b = ql_alloc(cur.length);
      let k = 0;
      while k < cur.length { ql_mem_store(b, k, cur[k]); k = k + 1; };
      parts.add(__str_new(b, cur.length));
      cur = [];
      i = i + pl;
    } else {
      cur.add(ql_mem_get(sb, i));
      i = i + 1;
    };
  };
  let b = ql_alloc(cur.length);
  let k = 0;
  while k < cur.length { ql_mem_store(b, k, cur[k]); k = k + 1; };
  parts.add(__str_new(b, cur.length));
  parts;
};
let stdString = {
  length: __s_len,
  concat: __s_concat,
  toString: (s) -> { s; },
  trim: __s_trim,
  toUpperCase: (s) -> { __s_case(s, true); },
  toLowerCase: (s) -> { __s_case(s, false); },
  includes: __s_includes,
  replace: __s_replace,
  split: __s_split,
  repeat: __s_repeat,
  startsWith: __s_sw,
  endsWith: __s_ew,
  join: (a) -> (sep) -> { __arr_join(a)(sep); },
  at: (s, i) -> { __get_index(s, i); },
};
```
`std` 增 `String: stdString`。
> **注意**:`cur.length`(数组长度)用 `.length` → __get_length ✓;`cur[k]` 读字节(NUMBER)✓;`parts.add(...)` ✓。`__s_split` 的 sep 空串边界白名单外。

- [ ] **Step 4:验证**

```bash
printf 'let a = [1, 2, 3];\nprintln(a.length);\nstd.Array.push(a)(4);\nprintln(a.length);\nprintln(std.Array.includes(a)(2));\nprintln(std.Array.join(a)("-"));\nprintln(std.Array.indexOf(a)(3));\nprintln(std.Array.reverse([1,2,3]).length);\nprintln(std.String.toUpperCase("hi"));\nprintln(std.String.trim("  x  "));\nprintln(std.String.includes("hello")("ell"));\nprintln(std.String.repeat("ab")(3));\nprintln(std.String.startsWith("abc")("ab"));\nprintln(std.String.replace("aaa")("aa")("b"));\nprintln(std.String.split("a,b,c")(",").length);\n' > /tmp/tq6.ql
./target/debug/qlang /tmp/tq6.ql > /tmp/tq6.host 2>&1
./target/debug/qlang --compile /tmp/tq6.ql -o /tmp/tq6.bin && /tmp/tq6.bin > /tmp/tq6.native
diff /tmp/tq6.host /tmp/tq6.native && echo PASS
```
Expected: 逐字节一致(数字/字符串/布尔)。

- [ ] **Step 5:Commit**

```bash
git add aot/runtime.ql aot/qlangc.ql aot/tests/t9_array.ql aot/tests/t9_string.ql
git commit -m "feat(aot): M3 T6 — std.Array + std.String + .add/.remove identifier guard"
```

---

### Task 7:std.Math(纯 QLang)

**Files:**
- Modify: `aot/runtime.ql`(`__floor`/`__ceil`/`__round`/`__trunc`/`__sqrt`/`__pow`/`__max`/`__min`/`__sin`/`__cos` + stdMath 模块)

**Interfaces:**
- Consumes: 内联数值运算;`__itoa`(toString 白名单面)。
- Produces: `std.Math`(abs/floor/ceil/round/trunc/sqrt/pow/max/min/random/sin/cos)。白名单 = 整数域 + 完美平方 + 0。

- [ ] **Step 1:核心函数**

```qlang
let __math_abs = (n) -> { if n < 0 { -n; } else { n; }; };
let __math_trunc = (n) -> { n - n % 1; };
let __math_floor = (n) -> { let t = __math_trunc(n); if n < t { t - 1; } else { t; }; };
let __math_ceil = (n) -> { -__math_floor(-n); };
let __math_round = (n) -> {
  // half away from zero(host f64::round)
  let a = __math_abs(n);
  let f = __math_floor(a);
  let r = 0;
  if a - f >= 0.5 { r = f + 1; } else { r = f; };
  if n < 0 { -r; } else { r; };
};
let __math_sqrt = (n) -> {
  // 牛顿迭代 ~10 次;n==0 → 0;n<0 → 发散(白名单外)
  let x = n / 2;
  let i = 0;
  while i < 10 {
    x = (x + n / x) / 2;
    i = i + 1;
  };
  if n == 0 { 0; } else { x; };
};
let __math_pow = (a) -> (b) -> {
  // 整数指数快速幂(白名单:整数底+非负整数指数)
  let base = a;
  let exp = b;
  let acc = 1;
  while exp > 0 {
    acc = acc * base;
    exp = exp - 1;
  };
  acc;
};
let __math_max = (...args) -> {
  let m = args[0];
  let i = 1;
  while i < args.length {
    if args[i] > m { m = args[i]; };
    i = i + 1;
  };
  m;
};
let __math_min = (...args) -> {
  let m = args[0];
  let i = 1;
  while i < args.length {
    if args[i] < m { m = args[i]; };
    i = i + 1;
  };
  m;
};
let __math_random = () -> {
  // 恒定种子伪随机(0 <= r < 1);NATIVE-only,不进白名单
  0.5;
};
let __math_sin = (x) -> {
  // 泰勒 ~8 项;白名单只用 sin(0)=0
  let r = 0;
  let t = x;
  let n = 1;
  let sgn = 1;
  let k = 0;
  while k < 8 {
    r = r + sgn * t;
    t = t * x * x / ((2 * n) * (2 * n + 1));
    sgn = -sgn;
    n = n + 1;
    k = k + 1;
  };
  r;
};
let __math_cos = (x) -> {
  let r = 1;
  let t = 1;
  let sgn = -1;
  let n = 1;
  let k = 0;
  while k < 8 {
    t = t * x * x / ((2 * n - 1) * (2 * n));
    r = r + sgn * t;
    sgn = -sgn;
    n = n + 1;
    k = k + 1;
  };
  r;
};
let stdMath = {
  abs: __math_abs,
  floor: __math_floor,
  ceil: __math_ceil,
  round: __math_round,
  trunc: __math_trunc,
  sqrt: __math_sqrt,
  pow: __math_pow,
  max: __math_max,
  min: __math_min,
  random: __math_random,
  sin: __math_sin,
  cos: __math_cos,
};
```
`std` 增 `Math: stdMath`。
> **注意**:`(...args)` 可变参数 —— boot parser 是否支持?host FunctionExpr 支持 rest?**若 boot 不支持 rest,改用固定 arity**(max/min 白名单只测 2 参):`let __math_max = (a, b) -> { if a > b { a; } else { b; }; };`。**执行者先验证 boot parser 对 `...args` 的支持;不支持则用 2 参版(419 不用 max/min,白名单 2 参足够)。**

- [ ] **Step 2:验证**

```bash
printf 'println(std.Math.abs(-5));\nprintln(std.Math.floor(3.9));\nprintln(std.Math.ceil(3.1));\nprintln(std.Math.round(2.5));\nprintln(std.Math.trunc(2.9));\nprintln(std.Math.sqrt(16));\nprintln(std.Math.pow(2)(5));\nprintln(std.Math.sin(0));\nprintln(std.Math.cos(0));\n' > /tmp/tq7.ql
./target/debug/qlang /tmp/tq7.ql > /tmp/tq7.host 2>&1
./target/debug/qlang --compile /tmp/tq7.ql -o /tmp/tq7.bin && /tmp/tq7.bin > /tmp/tq7.native
diff /tmp/tq7.host /tmp/tq7.native && echo PASS
```
Expected: `5`/`3`/`4`/`3`/`2`/`4`/`32`/`0`/`1`。

- [ ] **Step 3:Commit**

```bash
git add aot/runtime.ql
git commit -m "feat(aot): M3 T7 — std.Math pure-QLang (mod/iterate/taylor)"
```

---

### Task 8:std.JSON

**Files:**
- Modify: `aot/runtime.ql`(`__json_stringify`/`__json_parse` + stdJSON 模块)

**Interfaces:**
- Consumes: `__str`/`__itoa`/`__obj_keys`/`__get_index`;T2 `__op_add`。
- Produces: `std.JSON.stringify`(精确格式,白名单单键对象/数组)/`parse`。多键对象字段序、非有限小数 → 已知发散。

- [ ] **Step 1:stringify**

```qlang
let __json_stringify = (v) -> {
  let tag = readU64(v, 0);
  if tag == 4 { "null"; }
  else { if tag == 3 { if readU64(v, 8) == 1 { "true"; } else { "false"; }; }
  else { if tag == 1 { __itoa(v); }
  else { if tag == 2 {
    // 转义 " \ \n \r \t
    let buf = ql_mem_get_ptr(v, 8);
    let len = readU64(v, 16);
    let out = "";
    let i = 0;
    while i < len {
      let c = ql_mem_get(buf, i);
      if c == 34 { out = out + "\\\""; }
      else { if c == 92 { out = out + "\\\\"; }
      else { if c == 10 { out = out + "\\n"; }
      else { if c == 13 { out = out + "\\r"; }
      else { if c == 9 { out = out + "\\t"; }
      else { out = out + __itoa(c); }; }; }; }; };
      i = i + 1;
    };
    "\"" + out + "\"";
  }
  else { if tag == 5 {
    let n = readU64(v, 16);
    let out = "[";
    let i = 0;
    while i < n {
      if i > 0 { out = out + ","; };
      out = out + __json_stringify(__get_index(v, i));
      i = i + 1;
    };
    out + "]";
  }
  else { if tag == 6 {
    let ks = __obj_keys(v);
    let n = readU64(ks, 16);
    let out = "{";
    let i = 0;
    while i < n {
      if i > 0 { out = out + ","; };
      let k = __get_index(ks, i);
      out = out + "\"" + __str(k) + "\"" + ":" + __json_stringify(__obj_get(v, k));
      i = i + 1;
    };
    out + "}";
  }
  else { "null"; }; }; }; }; };
};
```
> **注意**:字符串转义里 `out = out + __itoa(c)` —— 非 ASCII/控制字节经 __itoa 数字化(JSON 白名单字符串只含 ASCII 可打印,非 ASCII 透传白名单外)。多键对象字段序无保证(已知发散,白名单单键)。

- [ ] **Step 2:parse(递归下降)**

```qlang
// parse:递归下降;s 为源串,返回 [value, nextIndex] 数组或错误。白名单:简单对象/数组/字符串/数字/bool/null。
let __json_parse_val = (s, i) -> {
  // i 指向当前位置;跳过空白;分派。
  let buf = ql_mem_get_ptr(s, 8);
  let len = readU64(s, 16);
  let j = i;
  while j < len && (ql_mem_get(buf, j) == 32 || ql_mem_get(buf, j) == 10 || ql_mem_get(buf, j) == 9) { j = j + 1; };
  let c = 0;
  if j < len { c = ql_mem_get(buf, j); };
  if c == 123 {
    // { ... }
    let o = __obj_new();
    let k = j + 1;
    let done = 0;
    while done == 0 {
      let pair = __json_parse_val(s, k);
      ...
    };
  } else { ... };
  ...
};
```
> **注意**:`__json_parse` 的递归下降是纯字节扫描 + `__json_parse_val` 返回 `[val, idx]` 数组 —— **本任务实现要点**:字符串值 → `__str_new`;数字值 → 累积(复用 `__parse_float`);数组 → `__arr_add`;对象 → `__obj_set`;`true`/`false`/`null` 字面量 → 对应盒。**执行者完成完整递归下降;白名单只测简单结构(单键对象、短数组、数字、字符串、嵌套一层)。**

- [ ] **Step 3:验证**

```bash
printf 'println(std.JSON.stringify(null));\nprintln(std.JSON.stringify(true));\nprintln(std.JSON.stringify(42));\nprintln(std.JSON.stringify("hi"));\nprintln(std.JSON.stringify([1, "a", true]));\nprintln(std.JSON.stringify({ a: 1 }));\nprintln(std.JSON.stringify({ a: [1, 2] }));\n' > /tmp/tq8.ql
./target/debug/qlang /tmp/tq8.ql > /tmp/tq8.host 2>&1
./target/debug/qlang --compile /tmp/tq8.ql -o /tmp/tq8.bin && /tmp/tq8.bin > /tmp/tq8.native
diff /tmp/tq8.host /tmp/tq8.native && echo PASS
```
Expected: `null`/`true`/`42`/`"hi"`/`[1,"a",true]`/`{"a":1}`/`{"a":[1,2]}` 逐字节一致。

- [ ] **Step 4:Commit**

```bash
git add aot/runtime.ql
git commit -m "feat(aot): M3 T8 — std.JSON stringify/parse (single-key whitelist)"
```

---

### Task 9:else-if 链 + 分支级 let 预扫 + `??` 合并

**Files:**
- Modify: `aot/qlangc.ql`(emitIfStmt else-if 递归、collectLets 预扫、emitFunction/main 接 collectLets、emitCoalesce 真实实现、emitBlockStmts let 注释路径变死代码)

**Interfaces:**
- Consumes: 现有 emitIfStmt phi 结构;defineSlot/lookupSlot 幂等。
- Produces: else-if 链完整展开;分支级 let 编译;`??` 短路。**419 的 40 处 else-if + 147 处分支 let 依赖此。**

- [ ] **Step 1:collectLets(递归预扫)**

在 emitFunction 附近加:

```qlang
// M3 Gap D:递归收集分支级 let(If 各分支 + elseBody + While 体),defineSlot 幂等 → 同槽。
// 分支级 let 在 emitBlockStmts 走 emitStoreByName(同槽写入)。
let collectLets = (stmts) -> {
  let i = 0;
  while i < stmts.length {
    let s = stmts[i];
    if s.type == "Let" {
      defineSlot(s.name);
    } else {
      if s.type == "If" {
        let b = 0;
        while b < s.branches.length {
          collectLets(s.branches[b].body.statements);
          b = b + 1;
        };
        if s.elseBody != null { collectLets(s.elseBody.statements); };
      } else {
        if s.type == "While" {
          collectLets(s.body.statements);
        };
      };
    };
    i = i + 1;
  };
};
```

- [ ] **Step 2:emitFunction 与 main 接 collectLets**

emitFunction(:385-390)的顶层 let 预扫循环替换为 `collectLets(node.body.statements);`。main(:857-877)的 K 计数 + 注册两段替换为:

```qlang
  collectLets(program.statements);
  let K = std.Object.keys(globalScope.slots).length;
```
(帧分配 `16 + 8 * K` 不变;注册不再单独循环。)

- [ ] **Step 3:emitIfStmt else-if 递归(Gap C)**

替换 `emitIfStmt`(:495-534)的 else 侧(:518-521):

```qlang
  let ev = null;
  if node.branches.length > 1 {
    // else-if 链:else 侧 = 剩余 branches + elseBody 的嵌套 If(递归 → phi 即 else 值)
    let rest = [];
    let j = 1;
    while j < node.branches.length {
      rest.add(node.branches[j]);
      j = j + 1;
    };
    ev = emitIfStmt({ type: "If", branches: rest, elseBody: node.elseBody }, prevLast);
  } else {
    if node.elseBody != null {
      ev = emitBlockStmts(node.elseBody.statements);
    };
  };
```
并把函数头部的 `if node.branches.length > 1 { line("; v1: else-if branches ignored...") }` 删除(链现在处理)。**其余结构不变**(then/else phi 合并、curLbl 前驱技巧)。
> **注意**:嵌套 emitIfStmt 的 prevLast 沿用外层 prevLast(无 else + 条件假 → 沿用 last 语义在整链上保持)。外层 `ev` 非 null → 不触发 elseIn 兜底 ✓。

- [ ] **Step 4:`emitCoalesce` 真实实现(替换 T2 stub)**

```qlang
let emitCoalesce = (node) -> {
  // ?? :left Error → 求值 right(只此路);否则结果 = left(host Coalesce 在操作区之前)
  let A = emitExpr(node.left);
  let tA = temp(); let eA = temp();
  line("  " + tA + " = load i64, ptr " + A);
  line("  " + eA + " = icmp eq i64 " + tA + ", 8");
  let lUseB = lbl(); let lUseA = lbl(); let lDone = lbl();
  line("  br i1 " + eA + ", label %" + lUseB + ", label %" + lUseA);
  line(lUseA + ":");
  curLbl = lUseA;
  line("  br label %" + lDone);
  line(lUseB + ":");
  curLbl = lUseB;
  let B = emitExpr(node.right);
  let predB = curLbl;
  line("  br label %" + lDone);
  line(lDone + ":");
  curLbl = lDone;
  let res = temp();
  line("  " + res + " = phi ptr [ " + A + ", %" + lUseA + " ], [ " + B + ", %" + predB + " ]");
  res;
};
```
(删除 T2 的 stub。)

- [ ] **Step 5:emitBlockStmts 清理**

emitBlockStmts(:472-478)的 `let` 分支:lookupSlot 恒命中(collectLets 已预扫)→ 删 `hit == null` 的注释路径,直接 `emitStoreByName(s.name, s.value);`。保留注释说明 M3 语义。

- [ ] **Step 6:验证**

```bash
printf 'let f = (n) -> { let r = 0; if n == 1 { let r = 10; } else { if n == 2 { let r = 20; } else { let r = 30; }; }; r; };\nprintln(f(1));\nprintln(f(2));\nprintln(f(3));\nlet g = (x) -> { if x { "a"; } else { "b"; }; };\nprintln(g(true));\nprintln(g(false));\nlet e = __err("K", "m");\nprintln(e ?? "fallback");\nprintln(42 ?? "no");\n' > /tmp/tq9.ql
./target/debug/qlang /tmp/tq9.ql > /tmp/tq9.host 2>&1
./target/debug/qlang --compile /tmp/tq9.ql -o /tmp/tq9.bin && /tmp/tq9.bin > /tmp/tq9.native
diff /tmp/tq9.host /tmp/tq9.native && echo PASS
```
Expected: `10`/`20`/`30`(分支级同名 let 唯一槽)/ `a`/`b` / `fallback`/`42`。**`println(e ?? ...)` host 语义:error → 求值 right → "fallback";NATIVE 同。**

- [ ] **Step 7:Commit**

```bash
git add aot/qlangc.ql
git commit -m "feat(aot): M3 T9 — else-if chain (Gap C), branch-level let pre-scan (Gap D), ?? coalesce"
```

---

### Task 10:`@ql_truthy` 复合类型修复(差异项 1)

**Files:**
- Modify: `aot/qlangc.ql:803-830`(@ql_truthy)

**Interfaces:**
- Consumes: 无。
- Produces: `@ql_truthy` 镜像 host is_truthy —— STRING/ARRAY len!=0、OBJECT/FUNCTION/ERROR 恒真、NULL 假、NUMBER/BOOL 原语义。

- [ ] **Step 1:重写 @ql_truthy**

替换 emitPrelude(:803-830)的 @ql_truthy 实现为完整 tag 级联:

```qlang
  line("define internal i1 @ql_truthy(i64 %box) {");
  let te = lbl(); line(te + ":");
  let tboxp = temp(); let ttag = temp();
  line("  " + tboxp + " = inttoptr i64 %box to ptr");
  line("  " + ttag + " = load i64, ptr " + tboxp);
  // NUMBER:payload != 0
  let t1 = temp();
  line("  " + t1 + " = icmp eq i64 " + ttag + ", 1");
  let lb1 = lbl(); let lb2 = lbl();
  line("  br i1 " + t1 + ", label %" + lb1 + ", label %" + lb2);
  line(lb1 + ":");
  let pa = temp(); let fv = temp(); let ne0 = temp();
  line("  " + pa + " = getelementptr i8, ptr " + tboxp + ", i64 8");
  line("  " + fv + " = load double, ptr " + pa);
  line("  " + ne0 + " = fcmp une double " + fv + ", 0.0");
  line("  ret i1 " + ne0);
  line(lb2 + ":");
  // BOOL:payload != 0
  let t2 = temp();
  line("  " + t2 + " = icmp eq i64 " + ttag + ", 3");
  let lb3 = lbl(); let lb4 = lbl();
  line("  br i1 " + t2 + ", label %" + lb3 + ", label %" + lb4);
  line(lb3 + ":");
  let pb = temp(); let bv = temp(); let bn0 = temp();
  line("  " + pb + " = getelementptr i8, ptr " + tboxp + ", i64 8");
  line("  " + bv + " = load i64, ptr " + pb);
  line("  " + bn0 + " = icmp ne i64 " + bv + ", 0");
  line("  ret i1 " + bn0);
  line(lb4 + ":");
  // STRING / ARRAY:len@16 != 0(tag 2 / 5 共用)
  let t3 = temp();
  line("  " + t3 + " = icmp eq i64 " + ttag + ", 2");
  let lb5 = lbl(); let lb6 = lbl();
  line("  br i1 " + t3 + ", label %" + lb5 + ", label %" + lb6);
  line(lb5 + ":");
  let tl = temp(); let tln = temp(); let tln0 = temp();
  line("  " + tl + " = getelementptr i8, ptr " + tboxp + ", i64 16");
  line("  " + tln + " = load i64, ptr " + tl);
  line("  " + tln0 + " = icmp ne i64 " + tln + ", 0");
  line("  ret i1 " + tln0);
  line(lb6 + ":");
  let t4 = temp();
  line("  " + t4 + " = icmp eq i64 " + ttag + ", 5");
  let lb7 = lbl(); let lb8 = lbl();
  line("  br i1 " + t4 + ", label %" + lb7 + ", label %" + lb8);
  line(lb7 + ":");
  let al = temp(); let aln = temp(); let aln0 = temp();
  line("  " + al + " = getelementptr i8, ptr " + tboxp + ", i64 16");
  line("  " + aln + " = load i64, ptr " + al);
  line("  " + aln0 + " = icmp ne i64 " + aln + ", 0");
  line("  ret i1 " + aln0);
  line(lb8 + ":");
  // OBJECT / FUNCTION / ERROR:恒真(tag 6 / 7 / 8)
  let t6 = temp();
  line("  " + t6 + " = icmp eq i64 " + ttag + ", 6");
  let lb9 = lbl(); let lb10 = lbl();
  line("  br i1 " + t6 + ", label %" + lb9 + ", label %" + lb10);
  line(lb9 + ":");
  line("  ret i1 true");
  line(lb10 + ":");
  let t7 = temp();
  line("  " + t7 + " = icmp eq i64 " + ttag + ", 7");
  let lb11 = lbl(); let lb12 = lbl();
  line("  br i1 " + t7 + ", label %" + lb11 + ", label %" + lb12);
  line(lb11 + ":");
  line("  ret i1 true");
  line(lb12 + ":");
  let t8 = temp();
  line("  " + t8 + " = icmp eq i64 " + ttag + ", 8");
  let lb13 = lbl(); let lb14 = lbl();
  line("  br i1 " + t8 + ", label %" + lb13 + ", label %" + lb14);
  line(lb13 + ":");
  line("  ret i1 true");
  line(lb14 + ":");
  // NULL(tag 4)及其余:恒假
  line("  ret i1 false");
  line("}");
```

- [ ] **Step 2:验证**

```bash
printf 'println(!"" ? "e" : "x");\n' > /tmp/tq10.ql
```
改用 3-way 探针(避免三元,QLang 无三元;用 if 语句):

```bash
printf 'let t = (v) -> { if v { "T"; } else { "F"; }; };\nprintln(t(""));\nprintln(t("a"));\nprintln(t([]));\nprintln(t([1]));\nprintln(t({}));\nprintln(t(null));\nlet f = (x) -> x + 1;\nprintln(t(f));\nprintln(t(__err("K", "m")));\n' > /tmp/tq10.ql
./target/debug/qlang /tmp/tq10.ql > /tmp/tq10.host 2>&1
./target/debug/qlang --compile /tmp/tq10.ql -o /tmp/tq10.bin && /tmp/tq10.bin > /tmp/tq10.native
diff /tmp/tq10.host /tmp/tq10.native && echo PASS
```
Expected: `F`(空串)/ `T` / `F`(空数组)/ `T` / `T`(空对象恒真)/ `F` / `T` / `T`(错误恒真)逐字节一致。

- [ ] **Step 3:Commit**

```bash
git add aot/qlangc.ql
git commit -m "feat(aot): M3 T10 — @ql_truthy composite truthiness mirror host is_truthy (差异项 1)"
```

---

### Task 11:t9 测试集 + difftest 四端扩展 + 419/419 NATIVE

**Files:**
- Modify: `difftest.py`(NATIVE_CASES/白名单扩展 + `tg` NATIVE 入口 + t9 cids)
- Modify: `aot/run_v1_tests.sh`(t9 三端循环)
- Modify: `aot/tests/t9_*.ql`(补全各模块用例;else-if/分支 let/`??`/`?` 用例在此落地,因依赖 T9)

**Interfaces:**
- Consumes: 全部 T1-T10。
- Produces: difftest 四端全绿(含 t9 + stdlib + 错误值 cids);`tg` 419 NATIVE 三端逐字节;`RESULT: 419/419 asserts passed`。

- [ ] **Step 1:run_v1_tests.sh 追加 t9 循环**

在 `run_v1_tests.sh` 的 regression 循环后追加:

```bash
echo "== t9 (M3) =="
for t in aot/tests/t9_*.ql; do
  check3 "$t"
done
```

- [ ] **Step 2:补全 t9 测试文件(各模块用例集 + 差异项回归)**

按 §11.2 补全(现有 T1-T8 已建外壳):
- `t9_error.ql`:`?` 函数传播(函数内 `let v = __err(...) ?;` + 好值放行)、`??`(error/非 error 两路)、`__err_get` 各域(kind/message/line/col/cause)、操作区(`err + 1`、`1 + err` → isError)、除零(isError)、错误实参(`g(err)` → isError)。
- `t9_diff.ql`(六项差异项回归):① truthy 复合(`""`/`[]`/`{}`/`null`);② `null == 0` → false;③ 位运算(`5 & 3`、`1 | 2`、`3 ^ 1`);④ if-in-arg → **语句形改写**(见 Step 3);⑤ `10/4` → `2.5`;⑥ 非 ASCII 透传(`"a└─b"` 长度/拼接)。
- 其余按 §11.2 补足 stdlib 面。

- [ ] **Step 3:差异项 4 — 语句形 harness**

difftest 中任何用 if-表达式作实参的 case(host 支持、boot parser 不支持)→ 改写为等价语句形(先 let 绑定再作实参),保证三端可解析。**419 本身 0 处 if-in-arg,无需改 419。**

- [ ] **Step 4:difftest 白名单扩展(t9 + stdlib + 错误值 cids)**

`difftest.py` 的 `NATIVE_CASES` 追加 M3 cids(每条需 host/native 逐字节一致,先跑 host 核期望再入白名单):
- 错误值:`m10` `let e = std.Error.raise("K","m",null); isError(e);`、`m11` `let e = std.Error.raise("K","m",null); e.type == "K";`、`m12` `let e = std.Error.raise("K","m",null); e.message == "m";`、`m13` `let e = __err("K","m"); e ?? "fb";`、`m14` `let e = __err("K","m"); isError(e + 1);`、`m15` `let e = __err("K","m"); let f = (x) -> x; isError(f(e));`
- 类型:`m16` `std.Type.of(42) == Number;`、`m17` `std.Type.of(Number) == std.Type;`、`m18` `std.Type.of(std.Type) == std.Type;`、`m19` `Array(Number).check([1,2]);`、`m20` `Object({a: Number}).check({a: 1});`
- stdlib:`m21` `std.Number.toString(42);`、`m22` `std.Array.join([1,2])("-");`、`m23` `std.String.toUpperCase("hi");`、`m24` `std.JSON.stringify([1,"a"]);`、`m25` `std.Math.sqrt(16);`

> **每条入白名单前先 `cargo run -- <src>` 核 host 期望,再 `--compile` 核 native 一致,一致才加入列表。**

- [ ] **Step 5:`tg` NATIVE 入口**

difftest 增 `tg` 入口:编译 `demo/type_gymnastics.ql` → ELF → 跑 → 与 host/boot 输出逐字节 diff。机制(参考 run_v1_tests.sh 的 check3):

```python
def run_tg():
    tg = os.path.join(ROOT, "demo", "type_gymnastics.ql")
    # HOST
    host = subprocess.run(CARGO + [tg], capture_output=True, text=True)
    # BOOT(剥离 banner)
    boot_raw = subprocess.run(CARGO + ["bootstrapped/run_file.ql", tg], capture_output=True, text=True)
    boot = strip_boot(boot_raw.stdout)
    # NATIVE
    qlangc = subprocess.run(CARGO + ["--compile", tg, "-o", tg_bin], capture_output=True, text=True)
    nat = subprocess.run([tg_bin], capture_output=True, text=True)
    ok = host.stdout == nat.stdout == boot
    print("tg 419:", "PASS" if ok else "FAIL")
    return ok
```
> **执行者把 `strip_boot`/`CARGO`/`ROOT` 接入 difftest 既有结构;`tg` 跑在 difftest 主流程之外或作主流程新增节(不破坏既有四端)。**

- [ ] **Step 6:验证**

Run: `python3 difftest.py`
Expected: 既有 51/51 白名单 + M3 新 cids 全绿;`All identical ✔` exit 0。

Run: `bash aot/run_v1_tests.sh`
Expected: v1 13/13 + t9 全绿。

Run: `bash -c 'cd /root/projects/QLang && ./target/debug/qlang --compile demo/type_gymnastics.ql -o /tmp/tg.bin && /tmp/tg.bin | tail -1'`
Expected: `RESULT: 419/419 asserts passed`。

- [ ] **Step 7:Commit**

```bash
git add difftest.py aot/run_v1_tests.sh aot/tests/t9_error.ql aot/tests/t9_diff.ql
git commit -m "feat(aot): M3 T11 — t9 suite + difftest four-end expansion + tg 419/419 NATIVE"
```

---

### Task 12:退出 gate + 回归验证

**Files:**
- 无(纯验证)

**Interfaces:**
- Consumes: 全部。

- [ ] **Step 1:全量回归**

Run: `bash aot/run_v1_tests.sh`
Expected: v1 13/13 + t8 + t9 全绿。

Run: `python3 difftest.py`
Expected: 四端全绿(`All identical ✔`),含 M2 51/51 + M3 新 cids。

Run: `./target/debug/qlang bootstrapped/run_file.ql bootstrapped/run_file.ql demo/type_gymnastics.ql > /dev/null 2>&1; echo $?`
Expected: boot 自举 419 不回归(exit 0)。

- [ ] **Step 2:三端逐字节 + 419**

Run: `bash -c 'cd /root/projects/QLang && ./target/debug/qlang demo/type_gymnastics.ql > /tmp/tg_h.out 2>&1 && ./target/debug/qlang bootstrapped/run_file.ql demo/type_gymnastics.ql | awk "/^Interpreting/ {f=1; next} f && !/^Execution complete/ {print}" > /tmp/tg_b.out && ./target/debug/qlang --compile demo/type_gymnastics.ql -o /tmp/tg.bin >/dev/null 2>&1 && /tmp/tg.bin > /tmp/tg_n.out && diff /tmp/tg_h.out /tmp/tg_b.out && diff /tmp/tg_h.out /tmp/tg_n.out && echo "TG 3-way byte-identical" && tail -1 /tmp/tg_h.out'`
Expected: `TG 3-way byte-identical` + `RESULT: 419/419 asserts passed`。

- [ ] **Step 3:零新 native 审计**

Run: `grep -o 'ql_[a-z_]*' aot/runtime.c | sort -u | wc -l && grep -o 'ql_[a-z_]*' aot/runtime.c | sort -u`
Expected: `7` 且 = ql_alloc / ql_write / ql_exit / ql_mem_get / ql_mem_store / ql_mem_get_ptr / ql_mem_store_ptr。

Run: `grep -c 'ql_[a-z_]*' aot/runtime.c && grep -c 'declare.*@ql_' /tmp/tg_last.ll`(若有;声明数 = 7)

- [ ] **Step 4:boot/host 零改动审计**

Run: `git diff --stat src/ bootstrapped/ | tail -5`
Expected: 空(src/ 与 bootstrapped/ 零改动)。

Run: `git status --porcelain docs/`
Expected: 空(docs/ 永不 commit)。

- [ ] **Step 5:M2 回归确认 + 提交收尾**

Run: `git log --oneline -15`
Expected: T1-T11 提交序列清晰(仅 aot/ + difftest.py + run_v1_tests.sh 改动)。

> 若 T12 发现回归:回到对应任务修复,再重跑 gate。全部通过后**无需单独 commit**(验证零改动);若修复了代码,补 commit。

---

## Self-Review(已执行)

**Spec §1.1 覆盖**:① 错误值(§3)→ T1/T3;② `?`(§4.1)→ T3;③ `??`(§4.2)→ T9;④ 操作区/除零(§5)→ T2;⑤ 完整 stdlib(§7)→ T4-T8;⑥ 六项差异项(§6)→ T1(T6)/T2(T2,T3)/T5(T5)/T9(T4)/T10(T1)/T11(语句形);⑦ 419 → T11/T12。

**Spec §1.2 退出标准**:① tg 三端 → T11 Step 5;② 白名单四端 → T11 Step 4;③ t9 回归 → T11;④ 无回归 → T12;⑤ 零新 native → T12 Step 3;⑥ boot/host 零改动 + difftest 仅 T11 → 各任务文件域遵守。

**Spec §13 T1-T12**:逐条映射;差异:差异项 6 提前 T1(R17)、std.Object/Number 增 obj["k"] 索引(R5)、T4 增构造器与单例(R18)、T9 含 emitCoalesce、emitExpr-If 显式 YAGNI(R9)。

**Placeholder 扫描**:全部步骤含具体代码/命令/期望;无 TBD/TODO。

**类型一致性**:各任务 Produces/Consumes 交叉核对(`__err_new`/`__str_new`/`__op_add`/`__op_eq`/`__is_type_value`/`__obj_keys`/`Array`/`Object`/`std` 成员名一致)。
