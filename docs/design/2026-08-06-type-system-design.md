# QLang 类型系统设计:类型即数据(运行时断言)

日期:2026-08-06
状态:已批准(经头脑风暴逐节确认;同日修订:构造器 = union 参数)
实现状态:未实现

## 1. 背景与目标

QLang 目前是纯动态类型(运行时只有 `std.Type.of` 返回类型名字符串;`let x: Number = 10` 语法已解析但被忽略)。目标是建立 **Idris 式类型系统**的地基:类型是一等值、参与计算,为将来的依赖类型铺路。

本轮决策:

1. **运行时断言,不做编译阶段**——`let x: T = v` 在声明时检查值,失败产生错误值。`(a: T) -> ...` 在调用进函数时检查。重赋值再查。
2. **"能提前的尽可能提前"原则**——检查函数必须是纯函数(值 × 类型对象 → 判定),将来若引入编译阶段,同一判定逻辑可被更早调用,无需重写。
3. **检查算法在 Rust 层(host)实现**;类型值本身是 QLang 一等值,参与计算。
4. **类型即数据**——类型值 = 普通 QLang 对象,核心字段 `check`(归属判定函数),可自由挂载成员。类型没有名称;`Number`/`String` 等只是常量指向类型值。

约束:自举(host Rust + boot QLang 两层语义一致,类型库 ×2 实现,difftest 对账);错误值语义已存在(Result 风格,`?`/`??`/isError,错误是三区制)。

## 2. 核心模型:类型即数据

- 类型值 = 对象,核心字段 **`check`**(可调用函数,判定"v 是否属于此类型")。
- **类型无名**:`Number`、`Object` 等全局常量只是指向类型值的名字(和 `let addOne = (a) -> a + 1` 同构);类型值本身不携带名字,错误消息里的类型名取自标注的源码文本。
- **Type : Type 自指**:`std.Type.of(Number)` → `std.Type`;`std.Type.of(std.Type)` → `std.Type`。类型宇宙单层闭合,类型值就是类型值的类型。
- **类型参与计算**:可传参、可存储、可比较(对象结构化相等 + 函数身份)。
- **类型值不可被调用**:`Number(42)` 是"调用对象"→ 错误;归属判定的入口是 `Number.check(42)`(与 `isError(v)` 同款)。**类型构造器除外**——`Array`/`Object` 是函数(§3.2/§4),`Array(Number)` 是调用构造器,返回类型对象。
- **依赖类型自然掉落**:类型构造函数 = 返回类型对象的普通函数。`Vect = (n) -> ...类型对象...`,`let v: Vect(3) = ...` 的标注求值即得类型对象。这是 Cayenne/CoC 的路径:类型就是项,依赖类型不需要新机制。

## 3. 类型值类别

### 3.1 判定规则("什么算类型")

- **结构判定(用户类型)**:带可调用 `check` 字段的对象 = 类型。用户手写 `{check: fn}` 即类型——类型是无名数据,伪造即构造。
- **身份判定(内置类型)**:解释器注册的规范实例,优先按身份识别(见 §3.3)。
- `{check: 42}` 不是类型(不可调用),归 Object。
- **类型构造器不是类型值**:`Array`/`Object` 是函数(参数为 union,见 §4),调用后返回类型对象;裸构造器当标注用 → "标注不是类型"错误(Idris 的 `List` 同理,单独用不是类型)。
- `Type` 的 check = "v 是类型?"(见 §3.5)。

### 3.2 内置类型常量(host 注册 / boot 各自注册,行为一致)

| 常量 | check 语义 |
|---|---|
| `Number` | v 是 Number |
| `String` | v 是 String |
| `Boolean` | v 是 Boolean |
| `Null` | v == null |
| `Array` | **类型构造器(函数)**:`Array(x)`,x 的参数类型是 union(见 §4);返回数组类型对象。裸 `Array` 不是类型 |
| `Object` | **类型构造器(函数)**:`Object(x)`,x 的参数类型是 union(见 §4);返回对象类型对象。裸 `Object` 不是类型 |
| `AnyArray` | v 是数组(任意内容)——`std.Type.of` 对数组返回它 |
| `AnyObject` | v 是对象且**不是**类型(类型是独立类别,`AnyObject.check(Number)` → false)——`std.Type.of` 对对象返回它 |
| `Function` | v 是函数 |
| `Any` | 恒 true(顶类型) |
| `Never` | 恒 false(底类型) |
| `Error` | v 是错误值(`isError`);成员 `raise`(见 §3.4 迁移) |
| `std.Type` | 类型判定(模块兼类型值,见 §3.5) |

### 3.3 内置类型特殊化("特殊也不特殊")

内置类型与解释器交互(字面量识别、Type.of 分发、错误机制、内部检查),因此:

- **原生成员只读保护**——`Number.check`、`Error.raise`、`std.Type.of` 等内置成员不可被覆盖(覆盖即错误),防止一次性静默毁掉类型机制。
- **自由新增成员照旧**——`Number.myHelper = ...` 允许,内置类型不封死。
- **Type.of 按身份识别**——host 持注册表,返回规范实例,不现造。
- **内部检查可快速路径**——内置类型直接调原生谓词,不走通用调用机制。
- **名字仍可遮蔽**——`let Number = 42` 合法(与 `Infinity`/`NaN` 可遮蔽一致;局部、可见、可恢复,与"静默毁掉 check"性质不同)。遮蔽后 `let y: Number = 5` 的标注求值得 42 → "标注不是类型"错误值。

"特殊也不特殊":内置类型在**实现与防护**上特殊,在**语言语义**上不特殊——仍是值、仍满足类型判定规则、仍可参与计算。

### 3.4 用户类型

- `std.Type.make(f)` → `{check: f}`;f 不可调用 → 错误值。
- 用户类型是普通数据对象,不受保护,破坏自担(覆盖 check 后不再是类型)。
- `Error` 全局 = 错误类型对象 `{check: isError, raise: <构造器>}`:
  - `Error.raise("msg")` / `Error.raise("msg", cause)` → Error 值(kind="Error")。
  - **迁移**:`Error("msg")` → `Error.raise("msg")`(README、difftest、boot 用例;2026-08-05 错误处理设计文档记一条偏差)。
  - `std.Error.raise`(3 参:kind/message/cause,boot 内部构造任意 kind 错误用)保留不动,与 `Error.raise` 签名不同,不冲突。
  - 注:raise 不是"构造器"(见 §11 未来注记),只是错误类型的一个普通成员函数——错误值是唯一"不能从字面量来"的值,所以是唯一需要造值函数的类型。

### 3.5 std.Type(合并:模块兼类型值)

`std.Type` 一个对象,两个身份:

- **作为类型**:check = "v 是类型?";Type : Type 自指成立(`std.Type.of(std.Type)` → `std.Type`)。
- **作为模块**:成员 `check` / `of` / `make`(操作)。错误类型值不在其中——它在全局 `Error`(见 §3.4),全部类型对称。

无全局 `Type` 别名——标注写 `let T: std.Type = Number`;将来"省略 std"特性落地后 `Type.make` 等写法才可用(见 §11)。

## 4. 类型构造器与类型运算

### 4.1 内置构造器:union 参数(不是重载)

`Array`/`Object` 是**函数(构造器)**,各收**一个参数**;参数的类型是一个 **union 类型值**(合法形态的并集),校验走 union 的 check,计算方式由命中哪个成员决定。

**`Array(x)` — 参数类型 = `Number | Type | [Type] | {length: Number, element: Type}`**:

| 命中成员 | 语义 | check |
|---|---|---|
| `Number`(x 是数值 n) | 定长 n,元素任意 | 是数组 && length == n |
| `Type`(x 是类型 T) | 任意长,元素都是 T | 是数组 && 每元素过 T.check |
| `[Type]`(x = [T1, T2, ...]) | 定长 n,第 i 个元素过 Ti.check(逐位类型) | length == n && 逐位检查 |
| `{length, element}`(元数据对象) | 定长 + 元素类型组合 | 是数组 && length == n && 每元素过 element.check |

成员自描述:`[Type]` 即 `Array(std.Type)`,`{length, element}` 即 `Object({length: Number, element: std.Type})`;成员天然互斥(数值不是类型值,类型值不是数值)。

**`Object(x)` — 参数类型 = `Type | 形状对象`**:

| 命中成员 | 语义 | check |
|---|---|---|
| `Type`(x 是类型 T) | **keys 全为 T 的对象**:`Object(String)` ≡ AnyObject(不限 key);`Object(Number)` keys 为数值 | 非类型对象 && 每个 key 过 T.check |
| 形状对象(x 是 schema) | 记录类型:`Object({name: String, age: Number})` | 非类型对象 && schema 每个字段存在且各自过检查(**必选字段子集,额外字段允许**) |

- **构造时验证形态**:非法形态 → 错误值(数值非整数/负数、`[Type]` 里有非类型、schema 值不是类型、元数据缺字段等)
- Object 家族(AnyObject 与 Object(x))一律排除类型对象(类型是独立类别)

### 4.2 规范写法(用户自定义)

union 不引入 `std.Type.union` 原生——手写即可(3 行):

```qlang
// 联合类型(规范写法)
let Union = (A, B) -> std.Type.make((v) -> A.check(v) || B.check(v))

// 用户自定义类型
let Positive = std.Type.make((v) -> v > 0)

// 依赖类型:类型构造函数 = 返回类型对象的函数
let Vect = (n) -> std.Type.make((v) -> std.Type.of(v) == AnyArray && v.length == n)
```

用户自定义构造器与内置同构:参数类型用 union(成员都是类型值),命中后返回类型对象。

### 4.3 原生实现说明

- 构造器原生(host):先用参数 union 校验 x(成员是内置谓词,校验不需要调用能力),命中成员后构造 check 闭包
- check 闭包要调用元素/字段的 check(可能是用户函数)→ **原生需要调用用户函数的能力**(实现改动,见 §7)
- 组合检查出错视为失败:`Array(Positive)` 检查时某元素 check 出错 → 该元素不通过

## 5. 检查语义

### 5.1 触发位置

| 位置 | 时机 |
|---|---|
| `let x: T = v` | 声明时(标注表达式在声明处求值) |
| `(a: T) -> ...` | 参数标注在**函数定义时求值一次**存进函数记录;每次调用进函数时检查,失败 → 函数体不执行,错误值返回调用方 |
| 重赋值 `x = v` | x 的绑定携带标注,再查 |

### 5.2 检查过程

1. 标注表达式求值 → 必须是类型值(结构判定或身份判定),否则产生"标注不是类型"错误值。
2. `T.check(v)`:
   - truthy → 通过,绑定原值。
   - falsy → 失败。
   - check 自身出错(返回错误值)→ 失败,错误链 cause 指向 check 的错误。
   - 参数化检查(Array(x)/Object(x) 的产物):任一元素/字段 check 失败或出错 → 整体失败。

### 5.3 错误值豁免

- **解释器内部检查路径一律豁免**错误值参数——`let x: Number = risky()` 中 judge 收到错误值,判定 false → TypeCheck 错误值。
- **内置原生 check / Type.of 豁免**(诊断性,由豁免字段标记,取代现有按名字的 `is_diagnostic_native` 表)。
- **复合 check 不豁免**(用户组合与构造器产物——`Array(x)`/`Object(x)` 的闭包):错误值参数按普通函数规则被拦截(三层区红线);host 侧构造器闭包是原生但标记不豁免,boot 侧是 QLang 闭包,两层一致。

### 5.4 失败行为

- 产生 **`TypeCheck`** 错误值(新 kind,与运算类 TypeMismatch 区分),**不终止**;`?`/`??`/isError 照常处理。
- 消息含标注的源码文本(类型无名,名字来自写下的代码):`value of type "String" does not match the annotated type "Number"`。
- 被检查的值是错误值且检查失败 → TypeCheck 错误值,cause 链上原错误值(根因可见)。

### 5.5 无标注

完全动态,零开销,当前行为不变。

## 6. 语法

- `let x: <表达式> = v`——标注从"标识符"改为**完整表达式**(`Number`、`Error`、`std.Type.make(...)`、`Vect(3)`、`Union(A, B)`、`Array(Number)`、`Array(3)`、`Object({name: String})` 皆合法)。
- 函数参数 `(a: <表达式>) -> ...`——参数列表支持 `name: expr`。
- 现有 `TypeAnnotation`(只吃名字)改为持有表达式;AST 的 let/param 携带可选标注。

## 7. 宿主层(Rust)实现

1. **内置类型注册表**:规范实例(Number/String/Boolean/Null/AnyArray/AnyObject/Function/Any/Never/Error/std.Type)+ 构造器(Array/Object 原生函数),原生 check 谓词,核心成员只读保护,Type.of 按身份返回。
2. **check_value 内部方法**(解释器):`(v, T) -> 判定`,let/参数/重赋值三处调用;错误值豁免;快速路径。
3. **错误值豁免机制**:`is_diagnostic_native` 名字表 → `NativeFunction` 字段标记(豁免集:print/println/isError/Error.raise/Error.toString/Type.of/内置 check 等)。
4. **标注语法**:parser 标注改完整表达式;AST let/param 携带标注;环境绑定携带标注(重赋值检查)。
5. **`std.Type.of` 破坏性变更**:返回类型值(非字符串;数组 → AnyArray,对象 → AnyObject);迁移 boot 的 interpreter.ql(`Type.of(...) == "Null"` 判断)与 difftest 字符串断言。
6. **Error 迁移**:全局 `Error` 从构造器函数变为类型对象 `{check, raise}`;`Error("msg")` → `Error.raise("msg")`(README、difftest、boot 用例)。
7. `std.Type` 合并:check/of/make 成员。
8. **原生获得调用用户函数的能力**:`NativeFunction` 签名加调用上下文(Array/Object 构造器返回的 check 闭包要调用元素/字段 check,可能是用户函数);现有原生机械更新(大部分忽略新参数)。

## 8. Boot 层(interpreter.ql / stdlib.ql)实现

- 类型库 ×2(自举常态):内置类型常量(QLang 对象,check 为 QLang 函数或宿主原生谓词)、std.Type(QLang 实现)、标注支持(parser.ql + interpreter.ql)。
- 检查语义与豁免规则与 host 一致(内部检查路径豁免;内置原生豁免;复合/用户不豁免)。
- boot 的 interpreter.ql 中 `std.Type.of(raw) == "Null"` 判断迁移。
- boot 函数记录携带参数标注(与 host 的 FunctionValue 对应)。

## 9. 测试

- **difftest.py**:新增用例——标注通过/失败/遮蔽/联合(规范写法)/错误类型/参数检查/重赋值检查;`Type.of` 返回值断言从字符串迁移到类型值;Error 迁移同步。host 与 boot 两侧结果一致。
- **fuzzexpr.py**:标注相关表达式(少量;错误比较沿用 norm_err)。
- **verify_bootstrap.ql**:更新受 Type.of 变更影响的断言。
- README:类型系统章节重写。

## 10. 不变量(设计红线)

1. 类型值不可被调用——归属判定入口是 `T.check(v)`;类型**构造器**(Array/Object)是函数,可以调用。
2. 内置类型核心成员不可覆盖;名字可遮蔽(文档写明)。
3. check 出错 = 检查失败——错误值不伪装成通过。
4. 错误值豁免只属于:内部检查路径、内置原生 check/Type.of;复合与用户 check 不豁免(两层一致)。
5. 检查失败产生 TypeCheck 错误值,永不静默、永不终止。
6. 构造器构造时验证参数形态(非法 → 错误值,不静默)。

## 11. 未来注记(本轮不做)

- **省略 std**:`import std.Type` 后 `Type` 直接可用(`Type.union` 等)——std.Type 合并设计就是为它铺路,届时无重名。
- **编译阶段**:检查是纯函数,将来可更早调用(标注在编译期求值/判定);"能提前的尽可能提前"。
- **data 声明与构造器**:静态系统若引入 `data`,类型对象才需要真正的构造器信息(值空间,给检查器用);当前模型中"构造器"不成立——值来自字面量和普通函数,类型是观察者(谓词),不是创造者。转换函数(`String.fromCodePoint`、`Number.parseFloat`)就是"伪装构造器",将来随"std 模块融入类型"迁移轮自然成为类型成员。
- **`(e: Error)` 解锁错误值参数**:2026-08-05 错误处理设计 §11 的承诺——涉及"错误值不能穿越用户函数边界"红线的放宽,本轮不做。
- **std 模块融入类型**:`String.length` 等成员上移到 `String` 类型对象(能力已具备:类型可自由挂载成员;单独一轮做,破坏性大)。
- **构造器参数形态扩展**:union 成员可增(如 `Object([keys])` 键列表、更多元数据字段),构造器实现不变——校验与计算都在 union 语义内。

## 12. 实现顺序建议

host 语法(标注表达式 + 参数标注 + 环境绑定)→ 内置类型注册表 + 构造器(Array/Object,含"原生调用用户函数"能力)→ check_value → 错误值豁免改字段标记 → Type.of 变更与迁移 → Error 全局迁移(Error.raise)→ boot 同步(类型库 + 构造器 + 标注 + 迁移)→ difftest/fuzzexpr/verify_bootstrap/README 更新。各步独立可验证。
