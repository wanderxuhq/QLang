# QLang → LLVM AOT 编译器 M3 里程碑设计:错误值 / `?` / `??` / 完整 stdlib(纯 QLang)

- **日期**:2026-08-15
- **状态**:草稿(待用户审阅)
- **上游**:docs/superpowers/specs/2026-08-14-qlang-llvm-aot-compiler-design.md(冻结;M3 行 §125:字符串插值 + 错误值/`?`/`??`/JSON/Math/全部 stdlib + import;退出 = difftest 四端 + 419/419 编译通过)
- **范围**:NATIVE/AOT 路径补齐错误值语义与全部 stdlib(QLang 自建);6 项 M2 已知差异项修复;demo/type_gymnastics.ql 419/419 在 NATIVE 端编译通过
- **上游已定决策(M3,2026-08-15)**:① NATIVE stdlib = **QLang 自建完整**写入 runtime.ql;② **字符串插值推迟**(独立后续里程碑,先需 boot 支持);③ **import 推迟**(需新 AOT 多文件机制);④ 退出标准 = **B 完整四端**(419 + 所有 stdlib 面进入 difftest 四端白名单 + 6 项差异项修复)

## 1. 范围与退出标准

### 1.1 语言面(M3 补齐)

1. **错误值**:`Value::Error` 语义 —— kind/message/cause/line/col 五域可读(host `error_read_zone` 镜像,interpreter.rs:199)。
2. **`?` 后缀传播**(host UnaryOp::Propagate,interpreter.rs:552):operand 为 Error → 冒泡到函数调用边界/顶层;否则返回 operand 值。
3. **`??` 错误合并**(host BinaryOp::Coalesce,interpreter.rs:599):left 为 Error → 求值 right 并返回其值(right 只在 left 是 error 时才求值);否则返回 left。在 operation zone 之前处理。
4. **操作区(operation zone)**:二元运算任一操作数为 Error → 构造 `TypeMismatch` 错误(cause = 出错操作数),含 `&&`/`||`(对错误不短路);`/`、`%` 除零 → `DivisionByZero` 错误。
5. **完整 stdlib 模块**(§7):std.Type / std.Error / std.Object / std.Number / std.Array / std.String / std.Math / std.JSON + 全局 `isError`。
6. **6 项差异项修复**(§6)。
7. **demo/type_gymnastics.ql 419/419** 在 NATIVE 端编译通过,输出与 HOST/BOOT 逐字节一致。

### 1.2 退出标准(B 完整四端)

1. `demo/type_gymnastics.ql` 419/419 在 HOST / BOOT / NATIVE 三端输出逐字节一致(difftest 新增 `tg` NATIVE 入口)。
2. 全部 M3 stdlib 面 + 错误值/`?`/`??` 面进入 difftest 四端白名单,四端全绿(`All identical ✔` exit 0)。
3. 6 项差异项修复落地且有 t9_*.ql 回归用例覆盖。
4. M1 v1 套件(13/13)、M2 t8_*.ql(全绿)、M2 四端白名单(51/51)无回归。
5. 零新 native:grep `ql_` 计数 = 7(恰 M2 的 7 个),+0。
6. boot 零改动、`src/`(host)零改动;difftest.py 只在明确修改它的任务中改。

### 1.3 范围外(推迟,不 gate M3)

- **字符串插值**(独立里程碑)、**import**(独立里程碑)、**Error.stack 帧**(host 的 stack 域 NATIVE 不填充;Error.toString 不读 stack)。
- **错误 `.line`/`.col`**:NATIVE 无源码位置 → 恒为 0(host 为真实行列);白名单不读 `.line`/`.col`。
- **Math.random**:host 走 Rust RNG,NATIVE 无法复现 → **NATIVE-only 测试**(不进四端白名单)。
- **非有限小数渲染**(§9):`0.1+0.2` 类无限二进制展开 → 已知发散,不进白名单。
- **多键对象 JSON.stringify 字段序**:host 走 HashMap 随机序 → 与 NATIVE 桶序无保证一致 → 白名单只用单键对象或数组(§8)。
- **`<`/`<=`/`>`/`>=` 非 Number 操作数**:host 报 TypeMismatch,NATIVE 保持 fcmp(白名单只用 Number 比较)。

## 2. 硬性约束(M3 增量,继承 M0-M2 全部)

1. **零新 native** —— 全部 stdlib 与错误原语用 QLang;grep `ql_` 计数 = 7。
2. **boot 零改动、src/(host)零改动**;difftest.py 只在明确修改它的任务中改。
3. **三端/四端逐字节一致**;difftest 四端全绿。
4. **qlangc emit 只调用 runtime.ql 的 QLang 层接口**;emitted code 无裸 leaf 调用。
5. **qlangc 无 return**;emitted code 用表达式 if/while/tail expressions。
6. **emitted code 多路分支用嵌套 if/else**(禁 else-if);qlangc.ql 自身 host 解释,自由。
7. **分支/循环体内无 let**(Global Constraint #11);所有 `let` 在函数顶层。
8. **只用 LLVM 自带工具链**。
9. **docs/ 永不 commit;永不 `git add -A`**。
10. **字符串 = tag-2 STRING box 统一**(§10):所有字符串产生函数返回 tag-2 盒;`{buf,len}` 对象表示退役。

## 3. ERROR box 设计

### 3.1 布局(48B)

| tag 常量 | 对象 | 负载 |
|---|---|---|
| 8 ERROR | 错误值 | `{kind@8, message@16, line@24, col@32, cause@40}`(6 槽 × 8B) |

- `kind` / `message` = **STRING box 指针**(tag-2)
- `line` / `col` = **NUMBER box 指针**(指向 interned 全局零盒 `@.zerobox`)
- `cause` = ERROR box 指针 或 nullbox(无 cause)
- 读域(host `error_read_zone` 镜像):`.type`→kind 串、`.message`→message 串、`.cause`→cause 错误或 null、`.line`/`.col`→Number(恒 0);未知域 → `UndefinedField: Undefined field: {field}` 错误

### 3.2 原语(runtime.ql)

- `__err_new(kind, msg, cause)` → 48B ERROR box(替换 M2 的 32B `__err`)
- `__isError(v)` → BOOL(读 tag == 8)
- `__err_get(e, field)` → 域值(kind/message→STRING 盒、cause→ERROR/null、line/col→零盒);未知域 → UndefinedField 错误
- `__err_cause(e)` → cause 或 nullbox
- 现有 `__err(kind, msg)` 迁移到新布局(签名保持,`__err_new` 的 cause 缺省 null);`__str` tag-8 分支的 `?Error` 标签保留

### 3.3 错误值进入函数调用边界

host:用户函数拒绝 Error 实参(`attempt to pass error value as argument` TypeMismatch,interpreter.rs:783)。NATIVE:
- 函数调用的**实参为 Error 时,emitCall 传播**:qlangc 在调用前检查实参 tag==8 → 命中则把整个调用的结果设为该错误(不进入 callee);错误本身作为调用结果返回(与 host 的"拒绝实参 → 错误值"在错误归一化下等价)。
- **被调函数体内 `?` 产生的错误 → 直接作为该函数返回值**(见 §4)。

## 4. `?` / `??` codegen(qlangc.ql)

### 4.1 `?` 后缀(UnaryOp::Propagate)

每个 QLang 函数 emit 一个**函数 epilogue label**(返回寄存器 + `ret i64*`);`?` 的 emit:

```
%v  = emit operand
%t  = load tag@0 of %v
%e  = icmp eq i64 %t, 8
br i1 %e, label %prop, label %ok
prop: %retv = %v; br label %epilogue       ; 直接返回错误盒
ok:   ; %v 作为 `?` 的结果继续
```

- 嵌套在表达式/let 初始化器中的 `?`:emit 后把后续代码块切换到 `%ok`(块拆分);函数返回寄存器 = `%v`。
- **顶层 `?`**:prop 分支跳到 main epilogue,调 `__exit_error(%v)`(打印 `{kind}: {message}` + cause 链到 stderr,exit 1)。
- `__exit_error` 输出格式对齐 host 顶层诊断的归一化规则(见 §11 difftest:stderr 命中 `^[A-Za-z]+: .+` 或 `Error:` → ERROR_TOKEN)。

### 4.2 `??`(BinaryOp::Coalesce)

依赖 emitExpr 的 **If/phi 支持**(§5 T9 的 if-expr-in-arg 基础设施),emit:

```
%a    = emit left
%ta   = load tag@0 of %a
%e    = icmp eq i64 %ta, 8
br i1 %e, label %useb, label %usea
usea:  br label %merge
useb:  %b = emit right; br label %merge
merge: %r = phi [%a, %usea], [%b, %useb]
```

- right 只在 left 是 error 时求值(与 host 一致)。
- 语句上下文(值丢弃)可免 phi;表达式上下文(值被用)必须 phi。

### 4.3 emitExpr 分派新增分支

- `If`(if-表达式,host Expression::If):emit 条件 → `@ql_truthy` → br 两路 → 各分支体 → **phi 合并**结果(else 缺省 → nullbox)。这是 419 之外 t9 测试与差异项 4 的共同基础设施。
- `UnaryOp` operator=="Propagate" → §4.1;`BinaryOp` operator=="Coalesce" → §4.2。
- emitExpr 现有 fallback(`; unhandled expr`)只留作编译期注释,不再被合法 AST 命中。

## 5. 二元运算运行时派发(runtime.ql `__op_*` 全家)

**架构决策(重大变更)**:emitBinaryOp 不再内联 fadd/fcmp,改为调用 runtime.ql 派发函数。理由:① 419 需要**动态字符串拼接**(`"field '" + field + "' failed its check"`,field 是标识符非字面量 → M2 双字面量 `__add` 不覆盖)→ `+` 必须运行时按 tag 分派;② 419 需要**字符串内容相等**(`bad.message == "field 'a' failed its check"`,message 是运行时拼接的新盒 → M2 指针同一性 `==` 失配);③ 顺带修 差异项 2(null==0)、差异项 3(位运算)、除零、操作区错误。

**派发函数(runtime.ql,全部镜像 host eval_binary_op / add_values / numeric_op / comparison_op / bitwise_op):**

| emit 调用 | 语义(镜像 host) |
|---|---|
| `__op_add(L,R)` | NUM+NUM→fadd;STR+STR→tag-2 拼接(§10);否则 `TypeMismatch: cannot apply addition to {L} and {R}`,cause=L-or-R 错误 |
| `__op_sub/__op_mul/__op_div/__op_mod(L,R)` | `/`/`%` 先查 R==0.0 → `DivisionByZero: division by zero`;NUM+NUM→运算;否则 `cannot apply numeric operation to {L} and {R}` |
| `__op_eq/__op_ne(L,R)` | 见 §5.1(关键:STRING 内容比较) |
| `__op_lt/__op_le/__op_gt/__op_ge(L,R)` | 仅 NUM+NUM→比较;否则 `cannot apply comparison to {L} and {R}` |
| `__op_band/__op_bor/__op_bxor(L,R)` | 仅 NUM+NUM→`(a as i64) op (b as i64) as f64`;否则 `cannot apply bitwise operation to {L} and {R}` |

**统一结构**:每函数先查左 tag==8 → `TypeMismatch(cause=左)`(host 操作区);`&&`/`||` 不走派发(控制流),但 emit 时先查左 tag==8 → 命中则调用 `__op_zone_error("logical operation", L)` 得错误盒,否则 br 短路。

**一元运算(host interpreter.rs:525-545 镜像)**:`!` 无操作区检查(`!err` → `!is_truthy(err)` → false,落在差异项 1 的 `@ql_truthy` 修复上);`-`/一元 `+` 对 Error → TypeMismatch(cause=operand)、对非 Number → TypeMismatch。emitUnaryOp 对 `-` 补 tag 检查。

### 5.1 `__op_eq/__op_ne`(tag 感知相等,host `values_equal` 镜像)

| L/R | 语义 |
|---|---|
| NULL/NULL | true |
| NUM/NUM | f64 `==` |
| STRING/STRING | **内容相等**(len@16 相等 + 逐字节 buf 相等;ASCII 域内 len=字符数) |
| BOOL/BOOL | i64 相等 |
| ARRAY/ARRAY、OBJECT/OBJECT、FUNCTION/FUNCTION、ERROR/ERROR | 指针同一性(`[+8]` 载荷 ==) |
| 其余(tag 不匹配) | false |

- 自动修 差异项 2:`null == 0` → NULL/NUM 不匹配 → false(host 同)。
- M2 disp harness 的 `t == "Number"`(两个 interned 标签盒)→ 内容相等 → true,不回归。

### 5.2 除零与位运算的落地

- `__op_div/__op_mod`:R==0.0(含 0.0/0.0、1%0)→ DivisionByZero 错误(host interpreter.rs:642)。4096 之外 inf/NaN 溢出保持普通数字。
- `__op_band/__op_bor/__op_bxor`:`fptosi`→位运算→`sitofp`,QLang 层用 `readU64` 把 f64 当 i64 做位运算再 `__mknum` 写回(NUMBER 盒)。

## 6. 六项差异项修复(全部,M3 落地)

| # | 差异项 | M2 现状 | M3 修复 | 落点 |
|---|---|---|---|---|
| 1 | `@ql_truthy` 复合类型恒假 | switch: NUMBER/BOOL 判定,其余恒假 | 镜像 host is_truthy:STRING `len!=0`、ARRAY `length!=0`、OBJECT **恒真**、FUNCTION 真、ERROR **恒真**、NULL 假 | emitPrelude `@ql_truthy`(qlangc.ql:801-832) |
| 2 | `null == 0` payload 比较 | 无条件 `fcmp oeq [+8]` | `__op_eq/__op_ne` tag 感知(§5.1) | emitBinaryOp |
| 3 | 位运算 `& | ^` 无实现 | 落比较兜底 `fcmp oge` → BOOL | `__op_band/__op_bor/__op_bxor`(§5) | emitBinaryOp + runtime.ql |
| 4 | if-表达式在实参位 emit 为 null | emitExpr 无 If 分支 | emitExpr If 分支 + phi(§4.3) | emitExpr |
| 5 | 非整数渲染 `10/4` 截断 | `__itoa` 整数域 | `__itoa` 分数渲染(§9) | runtime.ql `__itoa` |
| 6 | Unicode 字节长度不匹配 | internString 用 `s.length`(字符数)当字节数组尺寸 | byte-aware 长度(UTF-8 字节数) | qlangc.ql:69 |

**连带修复(419 必需,并入上述架构)**:`+` 运行时派发(动态字符串拼接)、`==` 字符串内容比较。这两项不修,419 的 `"field '" + field + ...` 拼接与 `bad.message == "..."` 断言必然失败。

## 7. stdlib 全表(QLang 自建,runtime.ql 编译进产物)

全部实现为 runtime.ql 里的 QLang 函数;`std` 对象与各模块对象字面量构建。签名与 host 对齐;类型错误 → `TypeMismatch` 错误值(错误归一化下与 host 等价)。

### 全局
- `isError(v)` → BOOL(`__isError`)

### std.Type(419 关键路径)
- `Type.make(f)` → `{ check: f }`(f 非 Function → arg_error)
- `Type.of(v)` → 类型对象**单例**(tag→类型对象映射;OBJECT 且带 `check` 字段 → Type 单例;否则 AnyObject 单例;Error → Error 单例)
- 类型单例 globals:`Number` / `String` / `Boolean` / `Null` / `AnyArray` / `AnyObject` / `Function` / `Any` / `Never` / `Error` / `Type`,各自 `{ check: <谓词函数> }`
- `Type.check(v)` → BOOL(镜像 host is_type_value:对象带 check 字段)
- 谓词:`.check(v)` 用 `__type_of(v)` 与标签单例比较;`Any` 恒真;`Never` 恒假;`Function` = tag-7 或带 check 的对象

### std.Error
- `Error.raise(kind, message, cause)` → ERROR box(kind 非 String → "Error";message 非 String → 值 to_string;cause 非 Error → 忽略)
- `Error.toString(err)` → `"{kind}: {message}"` + cause 链每级 `"\n  └─ caused by: {kind}: {message}"`(非错误 → `"not an error"`)

### std.Object
- `Object.keys(o)` → key STRING 盒数组;`Object.values(o)` → 值数组;`Object.merge(o1, o2)` → 新对象(o2 覆盖同键);`Object.hasOwn(o, k)` → BOOL;`Object.get(o, k)` → 值或 UndefinedField 错误;`Object.field(o, k)` → 值或错误
- 基于 `__obj_get/__obj_set` + `__obj_keys/__obj_values`(新增:遍历桶表收集键/值)

### std.Number
- `Number.toString(n)` → tag-2 STRING 盒(`__itoa` 分数版)
- `Number.isNaN(n)` / `Number.isFinite(n)` → BOOL(f64 位/域判定;QLang 层读 payload 字节判 NaN/Inf 域)
- `Number.parseFloat(s)` → trim+parse;失败 → NaN(非字符串 → NaN)

### std.Array
- `length` / `toString`(`[e1, e2]` 逗号+空格,元素走 `__str`)/ `add`(柯里化,推入)/ `remove`(柯里化,index 移位)/ `push`(原地)/ `pop`(原地出栈)/ `get`(负索引)/ `indexOf` / `includes` / `join`(柯里化,分隔符串接)/ `reverse`(原地反转)/ `concat`(柯里化,新数组)/ `at`(负索引,越界 → IndexOutOfBounds 错误)
- 基于 M2 `__get_index/__set_index/__arr_add/__arr_remove` + 新增 `__arr_push/__arr_pop/__arr_indexof/__arr_join/__arr_reverse/__arr_concat`

### std.String
- `length`(字节数;ASCII 域 = 字符数)/ `concat(a,b)` / `toString` / `trim` / `toUpperCase` / `toLowerCase` / `includes` / `replace`(首次出现替换)/ `split`(分隔符切片数组)/ `repeat(n)` / `startsWith` / `endsWith` / `join`(柯里化,数组 join)/ `at`(负索引)
- 全部在 tag-2 字节缓冲上逐字节操作;ASCII 假定(白名单内非 ASCII 仅透传,不参与 case 操作)

### std.Math(纯 QLang 策略,§8)
- `abs` / `floor` / `ceil` / `round` / `trunc`(取模算术)/ `sqrt`(牛顿迭代,负 → 发散)/ `pow`(柯里化,整数指数快速幂)/ `max` / `min`(可变参数)/ `random`(NATIVE-only)/ `sin` / `cos`(泰勒级数)

### std.JSON
- `stringify(v)` → 精确格式(§8):null/true/false/数字(`to_string`)/字符串(转义 `"` `\` `\n` `\r` `\t`)/数组 `[a,b]`/对象 `{k:v,...}`(无空格);函数/错误 → "null"
- `parse(s)` → 递归下降;对象/数组/字符串/数字/true/false/null;失败 → TypeMismatch

## 8. 纯 QLang Math 策略与 JSON 格式

### 8.1 Math(取模 + 迭代,全 QLang)

| 函数 | 策略 |
|---|---|
| `abs` | `n < 0 ? -n : n` |
| `trunc` | `n - n % 1`(QLang `%` = frem;负号跟随被除数 → 直接给向零截断) |
| `floor` | `t = trunc(n); n < t ? t - 1 : t` |
| `ceil` | `-floor(-n)` |
| `round` | host f64::round = **half away from zero**:`a = abs(n); f = floor(a); r = (a - f >= 0.5) ? f + 1 : f; n < 0 ? -r : r` |
| `sqrt` | 牛顿 `x_{k+1} = (x_k + n/x_k)/2`,固定 ~10 次迭代,初值 `n/2`(n==0 → 0);n<0 → **已知发散**(host NaN,NATIVE 无法廉价产 NaN → 白名单用非负完美平方) |
| `pow` | 柯里化 `(a) -> (b) -> ...`;整数指数用快速幂(重复平方);非整数指数 → 已知发散 |
| `max`/`min` | 可变参数遍历取极值 |
| `random` | 无法复现 host RNG → 返回 `0 <= r < 1` 伪随机(种子恒定);**NATIVE-only 测试**,不进四端白名单 |
| `sin`/`cos` | 泰勒:`sin = x - x³/3! + x⁵/5! − ...`,`cos = 1 - x²/2! + x⁴/4! − ...`;先 `x mod 2π` 归约(π 硬编码 `3.141592653589793`),~8 项;仅 `sin(0)=0`/`cos(0)=1` 精确 → 白名单只用这类精确值 |

**白名单 Math 面(整数域)**:abs/floor/ceil/round/trunc/max/min 对整数输入 → 整数结果(安全);sqrt 完美平方 → 整数;pow 整数底+整数指数 → 整数;sin/cos 的 0 精确值。非精确值 → t9 测试但**不进四端白名单**(`__itoa` 分数限制)。

### 8.2 JSON.stringify 精确格式(逐字节)

- Void→`null`;Boolean→`true`/`false`;Number→`to_string`(受 `__itoa` 限制);String→转义后带引号;Array→`[e1,e2,...]`(逗号无空格);Object→`{k:v,k2:v2,...}`(键带引号、`:`无空格、逗号无空格);Function/Error→`null`。
- **多键对象字段序**:host 走 HashMap 随机序,Rust RandomState 每次进程随机 → **四端不可逐字节一致**。白名单 JSON.stringify 只用单键对象/数组;多键对象 stringify 记已知发散(t9 断言形状而非字节)。

## 9. `__itoa` 分数渲染(差异项 5)

- **整数快速路径保留**(当前实现)。
- 新增分数路径:对非整数 `n`,计算其**精确十进制展开**,仅当在位数预算内(如 ≤17 位)终止才渲染(如 `10/4`→`2.5`、`1/8`→`0.125`);不终止 → 回退整数截断(已知发散)。
- 对齐范围:f64 精确十进制短的值(二进有理数 → 短十进制,如 `2.5`/`0.125`)与 host `f64::to_string` 一致;`0.1`/`0.1+0.2` 的精确展开很长(host 用最短往返算法) → **已知发散,不进白名单**。
- host 渲染 `2.0` → `"2"`(无 `.0` 后缀);分数渲染保持同风格。

## 10. 字符串表示统一(tag-2 STRING box)

- **M3 起所有字符串值 = tag-2 STRING box**(`{tag@0=2, buf@8, len@16}`)。`{buf,len}` 对象表示退役。
- 新 helper `__str_new(buf, len)` → 24B STRING 盒;`__itoa`/`__str`/`__boolstr`/`__nullstr` 全部改为返回 tag-2 盒。
- `__print` 保留双路径(兼容 tag-2 与旧 {buf,len});t8 回归不依赖 `__str` 返回对象(已核:仅 `.length` 成员访问与 `__get_field`),零回归风险。
- 收益:std.String 操作、`__op_add` 拼接、`__op_eq` 内容比较、error kind/message 存储、`.length` 读域全部统一在 tag-2 上。
- **`.length` 语义**:NATIVE 返回字节数(host 返回字符数)。ASCII 域内一致;非 ASCII 字符串白名单只透传不操作。hash 键的字节扫描(前 24B)不受影响。

## 11. difftest 四端 + 测试计划

### 11.1 difftest 升级

- **`tg` NATIVE 入口**:`demo/type_gymnastics.ql` 编译→ELF→跑;输出与 host/boot 端逐字节 diff。编译产物 `runtime.ql + tg` 一次编译,可能需分拆 harness(`assert` 内 `+` 拼接走 `__op_add`;`chapterStart` 的 `"=== Chapter " + toString(n)` 全走运行时派发)。
- **四端白名单扩展**:新增 stdlib 面(§7/§8 白名单 Math/JSON/Type/Object/Number/Array/String/Error)+ 错误值/`?`/`??` 面;错误归一化沿用 `norm_err`(任何 `^[A-Za-z]+: .+` 渲染或 stderr `Error:` → `<Error>`;`?Error` → `<Error>`)。
- **风险面**:`?` 顶层未捕获 → host exit 1 + stderr 诊断;NATIVE `__exit_error` 同样 exit 1 + `{kind}: {message}` stderr → 归一化一致。
- 六项差异项各有 t9 回归;M2 白名单 51/51、v1 13/13、t8 全绿回归。

### 11.2 模块测试(aot/tests/t9_*.ql)

按模块:`t9_error.ql`(`?`/`??`/读域/传播/操作区/除零)、`t9_type.ql`、`t9_object.ql`、`t9_number.ql`、`t9_array.ql`、`t9_string.ql`、`t9_math.ql`、`t9_json.ql` + 差异项回归。全部遵守 emitted-code 纪律(嵌套 if、无分支内 let)。

### 11.3 419 编译依赖面(已核)

419 依赖:std.Type.make/check/of、std.Error.raise、isError、`?`(line 326/424)、std.Object.keys、std.Number.toString、Array/Object 构造器、对象字面量、动态字符串 `+` 拼接、字符串内容 `==`、类型值单例恒等 `!=`、多箭头函数定义(Church 数值)。**不依赖** `??`/Math/JSON/import/插值。

## 12. 已知发散(推迟,全部不进白名单)

- 非有限小数渲染(`0.1`/`0.1+0.2`);`<`/`>` 非 Number 操作数;`Math.pow(a,b)` 双参形式(原生定义柯里化 `(a)->(b)->…`);sqrt 负数/非完美平方;sin/cos 非 0 精确值;Math.random;多键对象 JSON.stringify 字段序;字符串 `.length` = 字节数(非字符);error `.line`/`.col` = 0;动态字符串键的哈希查找(白名单键全为 interned 字面量)。

## 13. 任务分解(T1-T12,草稿,writing-plans 细化)

| # | 内容 | 文件域 |
|---|---|---|
| T1 | ERROR box 48B + `__err_new/__isError/__err_get/__err_cause` + 字符串表示统一(`__str_new`,itoa/str/boolstr/nullstr → tag-2) | runtime.ql |
| T2 | `__op_*` 派发全家 + emitBinaryOp 重写 + `&&`/`||` 左错误检查 + 除零 + 位运算 | runtime.ql + qlangc.ql |
| T3 | `?` 后缀 codegen(函数 epilogue + 顶层 `__exit_error`)+ emitCall 错误实参传播 | qlangc.ql + runtime.ql |
| T4 | isError + std.Error + std.Type(单例 + Type.make/of + 谓词) | runtime.ql |
| T5 | std.Object + std.Number + `__itoa` 分数渲染 | runtime.ql |
| T6 | std.Array + std.String + Unicode byte-length 修复 | runtime.ql + qlangc.ql |
| T7 | std.Math(纯 QLang:取模/牛顿/泰勒/快速幂) | runtime.ql |
| T8 | std.JSON stringify/parse | runtime.ql |
| T9 | emitExpr If/phi + if-expr-in-arg(差异项 4)+ `??`(§4.2) | qlangc.ql |
| T10 | `@ql_truthy` 复合修复(差异项 1) | qlangc.ql |
| T11 | 419/419 NATIVE 编译 + difftest 四端白名单扩展 + t9_*.ql + `tg` 入口 | difftest.py + aot/tests/ |
| T12 | 退出 gate:M2 回归 + 白名单全绿 + 419 三端逐字节 + 零新 native 审计 | 验证 |

**前置顺序**:T1→T2→T3 为错误值与派发地基;T4/T5 在 T3 后(419 关键路径:std.Type + std.Error + std.Number.toString + `?`);T9 的 phi 基建在 T2/T3 后即可,与 stdlib 并行;T11 依赖全部。

## 14. 不做的事(YAGNI)

- 不做字符串插值(独立里程碑);不做 import(独立里程碑)。
- 不做 Error.stack 帧、不做 `.line`/`.col` 真实值。
- 不做 NaN-boxing / 类型特化 / JIT / GC(继承上游)。
- 不做 `__itoa` 最短往返小数渲染(Grisu/Ryu 级)—— 白名单用有限小数。
- 不做动态字符串键的哈希 intern —— 白名单键全为 interned 字面量。
- 不把编译器/产物性能当作 M3 gate(运行时派发有调用开销,M4 自举后优化)。
