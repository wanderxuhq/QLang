# QLang 错误处理设计:错误值(Result 风格)

日期:2026-08-05
状态:已批准(经头脑风暴逐节确认)
实现状态:已按计划实现(2026-08-05)

**偏差说明(与 spec 的差异,记录在案):**

- **方案 C —— 错误诊断比较剥离位置**:difftest/fuzzexpr 的错误比较经 `norm_err` 剥离 "(at line L, col C)"。boot AST 无 span,其 line/col 无法与 host 逐字节一致(属设计使然)。§10 的"逐字节一致"对正常值保持;错误诊断比较类型 + 消息 + cause 链。后续可做 boot parser 增强(AST 带 span)作为独立任务。
- **stack 帧不参与比较**:boot 调用栈首版与 host 不一致,错误诊断比较不含 stack。顶层出口 host 打印完整诊断(含 stack)并 exit 1;boot 无 exit 原语,打印 `std.Error.toString`(无位置)后 exit 0。
- **已知不对称(两侧实现一致,记录在案)**:`!err` 返回 `false`(is_truthy(Error) = true);`x && err` 裸返回 `err`,而 `x + err` 包装新错误带 cause;`(Error("boom") ?) ?? 42` 传播到顶层(`??` 只捕 `Value::Error`,不捕 `?` 抛出的 `UserError` 信号)。
- **已知边界(自举里程碑后续)**:boot 无 import 支持(嵌套 import 显式返回 `NotImplemented` 错误值);boot 无未定义变量错误(返回 null)。
- §11 渐进类型接口仅预留,未实现(符合 spec 的"不在本期实现")。

## 1. 背景与目标

当前错误模型是"错误即终止":任何运行时错误(类型不匹配、越界、字段缺失)都终止整个程序,无 try/catch、无错误值、无恢复,错误消息没有位置信息。boot 层靠"触发 host 错误"来抛错。此外存在若干"静默"行为:`obj["x"]` 缺失返回 null(不对称探测)、`1/0` → inf、`0/0` → NaN(IEEE 静默)。

QLang 的定位**不是** JS 类似语言。错误处理重新设计,目标是:

1. **可恢复** — 程序可以捕获错误、处理、继续执行,而不是整个程序终止
2. **更丰富诊断** — 错误携带行号/列号、调用栈、根因链
3. **显式性** — 错误不能被静默忽略(没有 inf/NaN/null 伪装成正常值)

约束:QLang 是自举语言(boot 层 interpreter.ql 用 QLang 写 QLang 解释器),错误机制必须在 host(Rust)与 boot(QLang)两层都可实现且语义一致。未来计划加入渐进类型系统,保留动态类型——本设计为其留好接口。

## 2. 核心模型:错误是值,不是控制流

错误是**普通值**(独立 `Error` 类型),通过表达式流传播,而不是通过栈展开。程序永远不会"卡在错误状态":错误被处理(`?`/`??`/检查)的那一刻,一切恢复如常。

对比异常模型:异常是控制流中断(需要 unwinding,程序真的中断在错误里);错误值是数据流(值在流动,处理即恢复)。

## 3. 错误值类型

独立 `Error` 类型(宿主层 `Value::Error`),正常值裸露(隐式 Ok,不包装)。结构:

```
Error {
  type:     "TypeMismatch" | "IndexOutOfBounds" | "UndefinedField"
            | "UndefinedVariable" | "DivisionByZero" | "StackOverflow" | "Error"(用户)
  message:  "..."                  // 人类可读描述
  line:     12                     // 错误发生行号
  col:      7                      // 错误发生列号
  stack:    [ {fn, line, col}, ... ]  // 调用栈快照,仅用户函数帧
  cause:    Error | null           // 错误链:运算即报错产生新错误时,自动引用原错误
}
```

构造方式:

- 运行时自动产生(见 §4)
- 用户主动制造:`Error("msg")` 构造函数(type="Error"),可选 `Error("msg", cause)` 带根因。不用 throw/raise 关键字——错误就是值,用 `return` 返回(与 Go 一致),不破坏"错误是值"的单原则

## 4. 产生错误的操作

所有运行时错误返回 Error 值,不终止程序:

| 操作 | 结果 |
|---|---|
| 类型不匹配(`1 + "a"`) | TypeMismatch(保持,从"终止"变"返回值") |
| 越界(`arr[10]`、`arr[-100]`) | IndexOutOfBounds(负数回绕保留:arr[-1] → 末尾) |
| 字段缺失读取(`obj.x` / `obj["x"]`) | UndefinedField(**修改:去掉 null 探测不对称**,两者统一报错) |
| 字段写入缺失键(`obj.x = v`) | 与 JS 一致:自动创建字段(不改) |
| 除零(`1/0`、`0/0`) | DivisionByZero(**修改:去掉 inf/NaN**) |

> 注:只有**除数为零**才报 DivisionByZero。浮点运算溢出产生的 inf/NaN(如 `1e300 * 10`)保持 IEEE 语义,与 Python/Rust 一致,不算错误。
| 未定义变量 | UndefinedVariable |
| 递归深度超限 | StackOverflow(可恢复,见 §7) |

## 5. 处理机制

全部是表达式,不需要语句级 try/catch:

```ql
let x = risky() ?            // 错误 → 从当前函数返回(传播);非错误 → 解包
let y = risky() ?? 42        // 错误 → 求值 42 作为默认值(兜底);非错误 → 解包
if isError(e) {              // 显式检查
  print(e.message)           // 读取区:访问错误自身字段
}
return Error("余额不足")      // 主动抛错
```

### 语法规则:`?` 与 `??`

- `?` 后缀一元 = 传播(错误则从当前函数返回)——Rust 惯例
- `??` 二元 = 兜底(错误则用默认值)——C# null-coalescing 惯例
- **优先级**:`??` 最低(低于 `||`),默认值部分吃整个表达式:`risky() ?? 42 + 1` = `risky() ?? (42 + 1)`;截断需括号:`(risky() ?? 42) + 1`。与 if/else 表达式同规则
- **结合性**:`??` 左结合,`a ?? b ?? c` = `(a ?? b) ?? c`(逐级兜底)
- **歧义消解**:token 天然区分(`?` vs `??` 复合 token,最长匹配优先),无需 peek 规则;`(risky() ?) ?? 42` 组合写法无歧义
- **频率分配**:传播(高频)用单字符,兜底(低频)用双字符

### 错误值的三种合法使用(三区制)

| 区 | 允许的操作 | 例子 |
|---|---|---|
| 传播区 | `?` 传播、`??` 兜底、isError 检查、return | `let x = risky() ?` |
| 读取区 | 访问错误**自己的**字段 `.type` `.message` `.cause` `.line` `.col`、print/log | `e.message` → 普通字符串,可自由使用 |
| 运算区(禁止) | 算术、比较、索引、**函数参数**、成员访问、序列化 | `db.insert(err)` → 新错误,**函数未执行** |

## 6. 运算即报错 + 错误链

任何运算(算术、比较、索引、函数调用参数、成员访问、序列化)遇到 Error 值 → 产生**新错误**,并自动引用原错误为 `cause`:

```
TypeMismatch: cannot apply + to Number and Error
  └─ caused by: IndexOutOfBounds: index 10 out of bounds for length 3 (at line 5, col 12)
```

错误链保证根因可见:新错误("attempt to use error value")不掩盖真正的错误。错误值不能作为函数调用参数——`db.insert(err)` 在进入函数之前被拦截,产生新错误并传播给调用方,**错误无法穿过函数边界渗透到数据库/外部系统**。print/log 等内置诊断函数例外,允许接收错误值(打印诊断文本)。自定义函数解锁参数接收(`(e: Error)` 标注)推迟到类型系统阶段。

## 7. 边界与出口

### 顶层出口

错误值到达程序顶层(脚本结束)→ 运行时打印完整诊断(类型、消息、行号、错误链、调用栈)并非零退出码。错误永不无声消失。

### 栈溢出

递归超限 → StackOverflow **错误值**(可恢复,不是终止),与所有错误统一(Python 的 RecursionError、Java 的 StackOverflowError 皆可捕获)。boot 层由 interpreter.ql 自己维护递归深度,达到限制返回 StackOverflow 错误值,不依赖 host guard 硬终止。

## 8. 宿主层(Rust)实现

现有 host 的 eval 返回 `Result<Value, RuntimeError>`——这就是现成的错误传播通道,不推翻,增量改造:

1. 新增 `Value::Error` 变体(type/message/line/col/stack/cause 字段)
2. **运算即报错**:binary/unary/index/member 等运算处,操作数含 `Value::Error` → 构造新错误(带 cause),作为普通值返回,不抛异常
3. **`?` 传播**:遇到 `Value::Error` → 抛内部信号 `RuntimeError::UserError(err)`;函数调用边界捕获它、还原为函数返回值(不加 cause、不展开——错误从函数里传出来)
4. **`??` 兜底**:错误 → 求值默认分支;非错误 → 解包
5. **顶层出口**:最终结果是 `Value::Error` → 打印完整诊断并非零退出
6. **行为修改**:除零、`obj["x"]` 字段缺失 → 返回错误值(取消 inf/NaN/null 伪装);host 300 层 guard 触发 → 转成 StackOverflow 错误值
7. 内置诊断函数(print/log)允许接收 `Value::Error`
8. AST/lexer/parser 支持 `?` 后缀与 `??` 二元(token、优先级最低、左结合)

## 9. Boot 层(interpreter.ql)实现

**删除**现有"触发 host 错误"机制(std.Array.at/std.String.at/std.Object.field/raiseTypeMismatch 抛 host 错误)——新模型下更简单:

1. boot 的 `{type, value}` 包装新增 `type: "error"` 分支
2. boot 的 eval 遇到错误 → 返回 `{type:"error", value: <Error 值>}`,错误在值层面自然传播,不需要任何 host 魔法
3. boot 实现 `?`:eval 结果 type=="error" → 直接返回该包装(与 `?` 语义同构)
4. boot 实现 `??`:type=="error" → 求值默认分支
5. boot 维护调用栈(记录函数名/位置构造 stack 字段),递归深度限制 → 返回 StackOverflow 错误值
6. parser.ql 加 `?`/`??` 两个 token 与优先级
7. 清理 boot 自身代码依赖旧语义处(`std.Object.field` 返回 null 检查、依赖 inf 的分支)

## 10. 差分测试(红利:错误诊断可完整比较)

之前错误只能比"错误类别";新模型下错误是**值**,可完整比较诊断文本——host 直接跑 vs boot 解释执行,同一源码产生的错误值(类型、消息、行号、错误链、调用栈)应**逐字节一致**(stack 只记录用户函数帧,boot 不掺入解释器自身帧)。

- difftest.py:错误用例从"预期错误类别"改为"捕获错误值,比较完整诊断";新增 `?`/`??`/isError/错误链/顶层出口用例
- fuzzexpr.py:预言机同步——Python 侧生成相同错误值形态;除零、类型不匹配用例从"跳过"改为"比错误"
- verify_bootstrap 33/33 保持
- README 错误语义表重写

## 11. 渐进类型接口(未来,不在本期实现)

- 函数签名 `(e: Error)` 解锁错误值参数——唯一需要的语法扩展
- 静态检查:标注返回 `Int | Error` 的函数,调用处未处理/未传播 → 编译期警告或报错
- 本设计保证接口不被堵死:Error 是一等类型、错误值是数据、`?`/`??` 是唯一解包点

## 12. 不变式(设计红线)

1. 错误值**不能**变成正常值(没有 inf/NaN/null 伪装)
2. 错误值**不能**穿过函数参数边界(除内置诊断函数)
3. 错误值**只有**三种出口:被 `?`/`??` 解包、被 isError/字段读取消费、到达顶层打印

## 13. 实现顺序建议

宿主错误值核心(类型+运算语义) → `?`/`??` 语法 → 顶层出口与诊断 → boot 层同步 → 测试套件更新。各步独立可验证。
