# 直接调用与纯 Number 内联(2026-10-26)

这是 P0 切片(编译器优化,不改语言语义)的落地口径。判别夹具:
`aot/tests/t58_direct_calls.ql`、`aot/tests/t59_inline_pure.ql`。

## 1. 两种形状

### A. 直接调用(boxed ABI)

适用:用户程序里的 `let f = <Function>` 绑定,且:

- 绑定在**用户程序 AST**里从未被赋值、重声明或导出;每次 `let`/赋值都会清掉旧的直接目标;
- 函数体是 **leaf**:自己的 body 没有 `Call` / `Import`(嵌套 `Function` 是值,不算调用);
- **没有参数注解**(参数注解检查由通用 dispatcher 负责;返回注解可以保留,函数体返回边仍检查);
- 调用点 arity 与函数形参**精确相等**(部分应用/超参仍走通用路径);
- 每个实参的 `cannotBeError == true`(通用路径的“Error 不能作实参”规则静态成立);
- 调用点经 `lookupSlot` 命中的就是登记该函数的作用域(遮蔽/重声明会清表)。

发射效果:不再构造 `__call_borrowed` 的借用数组/通用分派,直接
`call %ql_value @ql_fnN(env, args, argc, annotations)`。函数体/闭包仍保留,
所以函数值、别名、动态调用都不受影响。

### B. 纯 Number 内联(raw)

在 A 的基础上再收紧:

- 该绑定在用户程序里**只有这一个 callee 引用**,没有任何 value use(别名、
  export、作为实参等都会使候选失效);重声明也会使候选失效;
- 每个参数 `unboxType == "Number"`(注解 Number 或分析证明);
- body 只有一条表达式,且是 `+ - * & | ^`、一元 `+/-`、Identifier 或 Number 字面量;
- body `staticType == "Number"` 且 `cannotBeError == true`,无 call,并且 body 里的
  Identifier 只能是本函数的参数(捕获自由变量会让 inlining 读错作用域);
- 返回注解缺省或 `Number`;
- 调用实参 `staticType == "Number"` 且 `cannotBeError == true`。

发射效果:**不发出该函数的 ql_fn 与闭包盒**;调用点把实参读成 raw double,
用 inline 替换参数后直接生成 body 的 `fadd`/`fmul` 等,结果再装箱。
单次调用、纯计算、无副作用。

## 2. 判别数字(同源 `target/selfhost/stage2` 形态;下表是判别程序,不是夹具全文)

| 程序 | 机器指令 |
|---|---:|
| 空文件 | 125,673 |
| t20(20 次 `x = x + 1`) | 125,735(不变) |
| 直接调用判别(5 次 `add(i,1)`) | **125,870** |
| 同上走后门: `f = add; f(i,1)` | 125,889 |
| 纯 Number 内联判别(5 次 `pure(i,1)`) | **125,744** |
| 同上走后门: `f = pure; f(i,1)` | 125,939 |

- 直接调用:静态 **−19**,但循环体不再进入 771 条静态指令的通用分派体;
- 纯 Number 内联:静态 **−195**,函数体/闭包被删掉,循环体成为 raw `fadd`。
- 20M 次微基准(本机、受后台套件争用影响,只作量级参考):
  inline 用户态约 **0.05–0.08s**,通用分派路径约 **36s**。

## 3. 同源验收(2026-10-26,最终编译器 `target/selfhost/stage2`)

- `stage2` 自编译 `stage2/stage3` 的 IR **逐字节相同**;
- `run_semantic_diagnostic_tests.py`:10/10;
- `run_interpreter_tests.py`:ALL CHECKS PASS,59 PASS(含 `t58`/`t59`);
- `run_assignment_tests.py`、`run_diagnostic_tests.py`、`run_call_tests.py`、
  `run_numeric_tests.py`、`run_array_tests.py`、`run_object_tests.py`:ALL CHECKS PASS;
- `run_selfhost_tests.py --self`:ALL REQUESTED CHECKS PASS(含 `t58`/`t59` 与 stage2/stage3 identical);
- `/tmp/t20.ql` 仍是 IR 188,453 / 机器 125,735 / 输出 20(普通程序不变;收益只在已知目标/纯 Number 单点)。

## 4. 边界与后续

- A 仍保留 boxed 参数缓冲/函数 frame/返回装箱;下一步是把多调用点、注解参数
  的 raw ABI 形式做出来(而不是继续扩大内联)。
- B 只覆盖单调用点的纯 Number 表达式;有 value use、重声明、赋值、调用、
  错误边、除零/取模、字符串/数组的函数一律回退到 A 或通用路径。
- 判别套件:`run_selfhost_tests.py` + `run_interpreter_tests.py`(
  `t58_direct_calls` / `t59_inline_pure`);两者 native/boot 输出必须一致。
- 静态指令数不是动态指令数;本机没有 perf/valgrind,20M 微基准只用于量级判断。
