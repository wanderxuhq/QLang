# QLang 类型系统(类型即数据,运行时断言)实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 QLang 落地运行时断言类型系统——类型值是带 `check` 谓词的对象,标注(`let x: T = v`、`(a: T) -> ...`、重赋值)在执行时检查,失败产生 `TypeCheck` 错误值;内置类型为受保护注册实例,`Array`/`Object` 为 union 参数构造器。

**Architecture:** 类型系统在 host(Rust)与 boot(QLang)两层各自实现、difftest 对账。host 侧:新建 `src/types.rs`(类型对象构造、内置常量注册、构造器),`NativeFunction` 先获得调用上下文(`CallContext` trait)与错误值豁免字段(`accepts_errors`),标注语法从"标识符"扩展为完整表达式,检查逻辑在解释器内(`check_value`/`check_annotation`)。boot 侧:parser.ql/stdlib.ql/interpreter.ql 镜像同一语义。

**Tech Stack:** Rust(host 解释器)、QLang(boot 层)、Python(difftest/fuzzexpr)、`cargo test`(doc-tests,14 个)+ 新建集成测试文件 `tests/type_system.rs`。

## Global Constraints

- 类型值 = 带可调用 `check` 字段的对象;`check` 判定归属,truthy 通过、falsy 失败、返回错误值 = 失败(cause 链)。
- 类型值不可被调用;类型**构造器**(`Array`/`Object`)是函数,可调用。
- 内置类型核心成员(`check`/`raise`/`of`/`make`)不可覆盖(错误);名字可遮蔽。
- 错误值豁免只属于:内部检查路径、内置原生 check/`Type.of`;复合与用户 check 不豁免(两层一致)。
- 检查失败产生 `TypeCheck` 错误值(不终止,永不静默);消息含标注源码文本。
- `std.Type` 合并(模块兼类型值),无全局 `Type` 别名;`Error` 全局 = 类型对象 `{check, raise}`(构造器迁移 `Error("msg")` → `Error.raise("msg")`)。
- `std.Type.of` 返回类型值(数组 → `AnyArray`,对象 → `AnyObject`,类型值 → `std.Type` 自指)。
- 构造器参数形态:构造时验证,非法 → 错误值(不静默)。
- 自举一致性:host/boot 行为一致,difftest 全绿;`cargo test` 全绿。

## 文件结构

| 文件 | 责任 |
|---|---|
| `src/value.rs` | `CallContext` trait、`NativeFunction` 加 `accepts_errors` 与调用上下文、`FunctionValue.param_types` |
| `src/types.rs`(**新建**) | 类型对象构造(内置/用户)、`is_type_value`/`is_protected_object`、`register_type_system`/`register_constructors`(常量、std.Type、Error、Array/Object) |
| `src/ast.rs` | `LetStmt`/`Parameter` 的 `type_annotation` 从 `TypeAnnotation` 改为 `Expression`;删 `TypeAnnotation` |
| `src/parser.rs` | 标注解析为完整表达式(let + 参数列表) |
| `src/interpreter.rs` | `call_function_inner`(豁免参数)、`check_value`/`check_annotation`/`annotation_text`、let/参数/重赋值检查、`set_field`/`set_index` 保护、curried 路径重构 |
| `src/environment.rs` | `Binding { value, annotation }`、`define_annotated`/`get_annotation` |
| `src/stdlib/mod.rs` | 全部原生函数迁移新签名与豁免字段;删旧 `create_type_module` 与全局 `Error` 构造器(迁入 types.rs) |
| `bootstrapped/parser.ql` | 标注语法(let + 参数) |
| `bootstrapped/stdlib.ql` | 类型常量、构造器、合并的 `Type` 模块、`Error` 类型对象 |
| `bootstrapped/interpreter.ql` | 检查语义 + 内部 `Type.of` 字符串比较迁移 |
| `bootstrapped/environment.ql` | 绑定携带标注 |
| `tests/type_system.rs`(**新建**) | 集成测试(TDD 载体) |
| `difftest.py` / `verify_bootstrap.ql` / `fuzzexpr.py` / `README.md` | 测试与文档更新 |

---

### Task 1: NativeFunction 重构——调用上下文 + 错误值豁免字段

**Files:**
- Modify: `src/value.rs:94-105`(NativeFunction)、`src/interpreter.rs:637-775`(call_function、is_diagnostic_native)
- Modify: `src/stdlib/mod.rs`(全部原生站点,约 84 处)
- Test: `tests/type_system.rs`(新建)

**Interfaces:**
- Consumes: 无(基础设施)
- Produces:
  - `pub trait CallContext { fn call(&mut self, callee: Value, args: Vec<Value>, span: Span) -> Result<Value, RuntimeError>; }`(value.rs)
  - `NativeFunction { name: String, arity: Option<usize>, accepts_errors: bool, func: Box<dyn Fn(&mut dyn CallContext, Vec<Value>) -> Result<Value, RuntimeError> + 'static> }`
  - `impl CallContext for Interpreter`(interpreter.rs,委托 `call_function`)

- [ ] **Step 1: 写失败测试(测试载体本身)**

```rust
// tests/type_system.rs
use qlang::Interpreter;

fn run(src: &str) -> String {
    let mut interp = Interpreter::new();
    interp.run_source(src, "test".to_string())
        .expect("run failed")
        .to_string()
}

#[test]
fn smoke_baseline() {
    assert_eq!(run("1 + 2;"), "3");
    assert_eq!(run("let s = \"a\" + \"b\"; s;"), "ab");
}
```

- [ ] **Step 2: 运行验证失败**

Run: `cargo test --test type_system`
Expected: FAIL("can't find crate for `qlang`" 或 test binary 未生成)——`tests/` 目录尚不存在。

- [ ] **Step 3: 实现 value.rs 改动**

```rust
// value.rs, NativeFunction 定义处(94-105):
/// Call-back interface natives use to invoke user functions (e.g. type-check closures).
pub trait CallContext {
    fn call(&mut self, callee: Value, args: Vec<Value>, span: Span) -> Result<Value, RuntimeError>;
}

pub struct NativeFunction {
    pub name: String,
    pub arity: Option<usize>,
    /// Whether this native may receive error values as arguments (diagnostic natives).
    pub accepts_errors: bool,
    pub func: Box<dyn Fn(&mut dyn CallContext, Vec<Value>) -> Result<Value, RuntimeError> + 'static>,
}
```

- [ ] **Step 4: 机械迁移全部原生站点**

在 `src/stdlib/mod.rs` 与 `src/interpreter.rs` 中,把每个 `Box::new(|args| ...)` 改为 `Box::new(|_ctx, args| ...)`,并在每个 `NativeFunction { name: ..., arity: ..., func: ... }` 结构体字面量中插入 `accepts_errors: false`。豁免站点(原名在 `is_diagnostic_native` 列表中)改为 `accepts_errors: true`:

```rust
// 豁免站点(7 处):name 为 "print" / "println" / "isError" / "Error"(全局构造器)/
// "Error.raise"(std.Error.raise)/ "Error.toString" / "Type.of"
// 例:
env_mut.define("isError".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
    name: "isError".to_string(),
    arity: Some(1),
    accepts_errors: true,
    func: Box::new(|_ctx, args| {
        Ok(Value::Boolean(matches!(args.first(), Some(Value::Error(_)))))
    }),
})));
```

interpreter.rs 的 currying 站点(661-665)同步改签名(闭包保留内嵌解释器,Task 6 再重构):

```rust
func: Box::new(move |_ctx, inner_args: Vec<Value>| { /* 原逻辑不变 */ }),
```

- [ ] **Step 5: 改 call_function 与移除名字表**

interpreter.rs `is_diagnostic_native`(71-74)整个删除;原生分支(753-770)改为字段判断:

```rust
Value::NativeFunction(native_fn) => {
    if !native_fn.accepts_errors {
        if let Some(bad) = args.iter().find(|a| matches!(a, Value::Error(_))) {
            return Ok(self.make_error(
                "TypeMismatch",
                format!("attempt to pass error value as argument to {}", native_fn.name),
                Some(span),
                error_cause(bad),
            ));
        }
    }
    if let Some(arity) = native_fn.arity {
        if args.len() != arity { /* ArityMismatch,原逻辑 */ }
    }
    (native_fn.func)(self, args)
}
```

文件底部加:

```rust
impl CallContext for Interpreter {
    fn call(&mut self, callee: Value, args: Vec<Value>, span: Span) -> Result<Value, RuntimeError> {
        self.call_function(callee, args, span)
    }
}
```

- [ ] **Step 6: 全量验证**

Run: `cargo test` 与 `python3 difftest.py`
Expected: 14 doc-tests PASS;difftest "All identical ✔"(126 用例)——纯重构,行为不变。

- [ ] **Step 7: 提交**

```bash
git add -A
git commit -m "refactor: natives gain call context (CallContext) and error-arg exemption flag

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: 标注语法——let 与参数标注改为完整表达式(host)

**Files:**
- Modify: `src/ast.rs:120-124`、`src/ast.rs:766-770`、删除 `src/ast.rs:1144-1158`
- Modify: `src/parser.rs:179-210`(parse_let_statement)、`src/parser.rs:588-700`(parse_primary 参数列表)、删除 `src/parser.rs:1230-1237`
- Test: `tests/type_system.rs`

**Interfaces:**
- Produces: `LetStmt.type_annotation: Option<Expression>`;`Parameter.type_annotation: Option<Expression>`;`Expression::span()`(已有)作为标注源码文本来源。

- [ ] **Step 1: 写失败测试**

```rust
#[test]
fn annotation_parses_as_expression() {
    // 标注是完整表达式:构造器调用、成员访问、对象字面量
    assert_eq!(run("let x: std.Type = Number; std.Type.check(x);"), "true");
    assert_eq!(run("let f = (a: Number) -> a + 1; f(5);"), "6");
    // 标注语法错误仍是解析错误(Err,不 panic)
    assert!(Interpreter::new().run_source("let x: ;", "t".into()).is_err());
}
```

- [ ] **Step 2: 运行验证失败**

Run: `cargo test --test type_system annotation_parses_as_expression`
Expected: FAIL——`let x: std.Type` 解析报错("Expected identifier")。

- [ ] **Step 3: ast.rs 改动**

```rust
// LetStmt(120-124):
pub struct LetStmt {
    pub name: String,
    pub value: Expression,
    /// 类型标注:完整表达式,求值得到类型值(运行时断言)
    pub type_annotation: Option<Expression>,
    pub span: Span,
}

// Parameter(766-770):
pub struct Parameter {
    pub name: String,
    pub type_annotation: Option<Expression>,
}
```

删除整个 `TypeAnnotation` 结构体(1144-1158)及其 `impl`;删除文档中对其的引用。

- [ ] **Step 4: parser.rs——let 标注**

`parse_let_statement`(179-210)中,替换标注解析:

```rust
// 之前:Some(self.parse_type_annotation()?)
let type_annotation = if self.match_token(&TokenKind::Colon) {
    Some(self.parse_expression()?)
} else {
    None
};
```

删除 `parse_type_annotation`(1230-1237)。注意:`parse_expression` 在 `=` 前自然停止(`=` 不是表达式运算符),`let x: Array(3) = ...`、`let x: {a: String} = ...`、`let x: std.Type = ...` 均正确。

- [ ] **Step 5: parser.rs——参数标注**

`parse_primary` 的 `LeftParen` 分支(588 起)。在 `let first = self.parse_expression()?;` 之后、分支判定之前,插入标注解析:

```rust
let first = self.parse_expression()?;

// 参数类型标注:`(a: Type, ...) -> ...`(仅标识符参数可带标注)
let mut annotation: Option<Expression> = None;
if matches!(first, Expression::Identifier(_)) && self.check(&TokenKind::Colon) {
    self.advance();
    annotation = Some(self.parse_expression()?);
}

// 参数列表判定:原条件 + 有标注时强制走参数路径(避免 (x: T) 被静默当作分组)
let is_param_list = self.check(&TokenKind::Comma)
    || (self.check(&TokenKind::RightParen) && self.peek_next_is_arrow())
    || annotation.is_some();
if is_param_list {
    let mut params = vec![self.expression_to_parameter_annotated(first, annotation)?];
    while self.match_token(&TokenKind::Comma) {
        let param_expr = self.parse_expression()?;
        let mut ann = None;
        if matches!(param_expr, Expression::Identifier(_)) && self.check(&TokenKind::Colon) {
            self.advance();
            ann = Some(self.parse_expression()?);
        }
        params.push(self.expression_to_parameter_annotated(param_expr, ann)?);
    }
    self.expect(&TokenKind::RightParen)?;
    if self.match_token(&TokenKind::Arrow) {
        return self.parse_function_body(params, token.span.start);
    }
    return Err(ParseError::Expected("->".to_string(), self.peek().clone()));
}
// ... 原分组路径不变(此时 annotation 必为 None)
```

在 `expression_to_parameter` 旁新增辅助函数:

```rust
fn expression_to_parameter_annotated(&mut self, expr: Expression, annotation: Option<Expression>) -> Result<Parameter, ParseError> {
    let mut param = self.expression_to_parameter(expr)?;
    param.type_annotation = annotation;
    Ok(param)
}
```

其余两个单参数路径(656、682、692 附近的 `expression_to_parameter(first)` 调用)改为 `expression_to_parameter_annotated(first, annotation.take())`——注意这些路径只在 `annotation` 为 None 时可达(有标注已走参数列表路径),传 `None` 即可。

- [ ] **Step 6: 运行验证**

Run: `cargo test --test type_system` 与 `cargo test`(doc-tests 不受影响)
Expected: 新测试 PASS;`(x: T)` 无箭头仍报 `Expected "->"`。

- [ ] **Step 7: 提交**

```bash
git add -A
git commit -m "feat: type annotations become full expressions (let and params)

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: 类型系统模块——内置常量、std.Type 合并、Error 迁移(host)

**Files:**
- Create: `src/types.rs`
- Modify: `src/lib.rs`(`pub mod types;`)、`src/interpreter.rs:98-101`(`Interpreter::new`)、`src/stdlib/mod.rs:66-90`(删全局 Error 构造器)、`src/stdlib/mod.rs:139` 与 `1509-1523`(删 std.Type)

**Interfaces:**
- Consumes: Task 1 的 `NativeFunction`(accepts_errors + ctx)、`ErrorValue::new`(value.rs)
- Produces:
  - `pub const PROTECTED_FIELDS: &[&str]`
  - `pub const TYPE_MARKER: &str`(隐藏标记字段名 `"\u{1}type"`)
  - `pub fn is_type_value(v: &Value) -> bool`、`pub fn is_protected_object(v: &Value) -> bool`
  - `pub fn register_type_system(global_env: &EnvRef) -> ()`(全局常量 + std.Type 合并)
  - `pub fn user_type(check: Value) -> Value`(后续任务复用)

- [ ] **Step 1: 写失败测试**

```rust
#[test]
fn builtin_types_registered() {
    assert_eq!(run("Number.check(42);"), "true");
    assert_eq!(run("Number.check(\"a\");"), "false");
    assert_eq!(run("std.Type.of(42) == Number;"), "true");
    assert_eq!(run("std.Type.of(null) == Null;"), "true");
    assert_eq!(run("std.Type.of([1]) == AnyArray;"), "true");
    assert_eq!(run("std.Type.of({a: 1}) == AnyObject;"), "true");
    assert_eq!(run("std.Type.of(Number) == std.Type;"), "true");   // Type : Type
    assert_eq!(run("std.Type.of(std.Type) == std.Type;"), "true"); // 自指
    assert_eq!(run("std.Type.check(Number);"), "true");
    assert_eq!(run("std.Type.check(42);"), "false");
    assert_eq!(run("std.Type.make((v) -> v > 0).check(5);"), "true");
    assert_eq!(run("let e = Error.raise(\"boom\"); std.Type.of(e) == Error;"), "true");
}
```

- [ ] **Step 2: 运行验证失败**

Run: `cargo test --test type_system builtin_types_registered`
Expected: FAIL——`Number` 未定义(UndefinedVariable 错误值,to_string 输出错误文本)。

- [ ] **Step 3: 创建 src/types.rs**

```rust
//! Type system: types as data (built-in type objects, std.Type).

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

use crate::environment::EnvRef;
use crate::value::{CallContext, ErrorValue, NativeFunction, ObjectValue, RuntimeError, Value};

/// 内置类型对象上不可覆盖的核心成员。
pub const PROTECTED_FIELDS: &[&str] = &["check", "raise", "of", "make"];
/// 内置类型对象的隐藏标记字段名。lexer 永远不会产出 NUL 前缀标识符,用户代码无法书写。
pub const TYPE_MARKER: &str = "\u{1}type";

/// `v` 是类型值?内置类型(带标记)或结构判定(对象且有可调用 check 字段)。
pub fn is_type_value(v: &Value) -> bool {
    match v {
        Value::Object(obj) => {
            let f = obj.borrow();
            if f.fields.contains_key(TYPE_MARKER) {
                return true;
            }
            matches!(f.fields.get("check"), Some(Value::Function(_)) | Some(Value::NativeFunction(_)))
        }
        _ => false,
    }
}

/// `v` 是内置(受保护)类型对象?
pub fn is_protected_object(v: &Value) -> bool {
    matches!(v, Value::Object(o) if o.borrow().fields.contains_key(TYPE_MARKER))
}

/// 用户类型对象:{check: f}(普通数据对象,不受保护)。
pub fn user_type(check: Value) -> Value {
    let mut fields = HashMap::new();
    fields.insert("check".to_string(), check);
    Value::Object(Rc::new(RefCell::new(ObjectValue { fields })))
}

fn marker_native() -> Value {
    Value::NativeFunction(Rc::new(NativeFunction {
        name: TYPE_MARKER.to_string(),
        arity: None,
        accepts_errors: false,
        func: Box::new(|_ctx, _args| Ok(Value::Void)),
    }))
}

fn native_predicate(name: &str, pred: fn(&Value) -> bool) -> Value {
    Value::NativeFunction(Rc::new(NativeFunction {
        name: name.to_string(),
        arity: Some(1),
        accepts_errors: true, // 类型判定是诊断性操作
        func: Box::new(move |_ctx, args| {
            Ok(Value::Boolean(pred(args.first().unwrap_or(&Value::Void))))
        }),
    }))
}

fn builtin_type(name: &str, pred: fn(&Value) -> bool) -> Value {
    let mut fields = HashMap::new();
    fields.insert("check".to_string(), native_predicate(&format!("{}.check", name), pred));
    fields.insert(TYPE_MARKER.to_string(), marker_native());
    Value::Object(Rc::new(RefCell::new(ObjectValue { fields })))
}

fn is_number(v: &Value) -> bool { matches!(v, Value::Number(_)) }
fn is_string(v: &Value) -> bool { matches!(v, Value::String(_)) }
fn is_boolean(v: &Value) -> bool { matches!(v, Value::Boolean(_)) }
fn is_null(v: &Value) -> bool { matches!(v, Value::Void) }
fn is_array(v: &Value) -> bool { matches!(v, Value::Array(_)) }
fn is_function(v: &Value) -> bool { matches!(v, Value::Function(_) | Value::NativeFunction(_)) }
fn is_error(v: &Value) -> bool { matches!(v, Value::Error(_)) }
fn is_object_not_type(v: &Value) -> bool { matches!(v, Value::Object(_)) && !is_type_value(v) }

/// 类型检查失败的错误值(构造器参数非法等)。
fn arg_error(fn_name: &str, msg: &str) -> Value {
    Value::Error(Rc::new(ErrorValue::new("TypeMismatch", format!("{}: {}", fn_name, msg))))
}

/// 注册内置类型常量(全局)与合并的 std.Type(模块兼类型值)。
pub fn register_type_system(global_env: &EnvRef) {
    let number_t   = builtin_type("Number", is_number);
    let string_t   = builtin_type("String", is_string);
    let boolean_t  = builtin_type("Boolean", is_boolean);
    let null_t     = builtin_type("Null", is_null);
    let any_array_t  = builtin_type("AnyArray", is_array);
    let any_object_t = builtin_type("AnyObject", is_object_not_type);
    let function_t = builtin_type("Function", is_function);
    let any_t      = builtin_type("Any", |_| true);
    let never_t    = builtin_type("Never", |_| false);

    // Error 类型对象:{check: isError, raise: <构造器>}(迁移自旧全局 Error 构造器,stdlib/mod.rs:66-90)
    let error_t = builtin_type("Error", is_error);
    if let Value::Object(obj) = &error_t {
        obj.borrow_mut().fields.insert("raise".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
            name: "Error.raise".to_string(),
            arity: None, // 1 或 2 个参数:(msg) / (msg, cause)
            accepts_errors: true, // cause 参数可能是错误值
            func: Box::new(|_ctx, args| {
                let msg = match args.first() {
                    Some(Value::String(s)) => s.clone(),
                    Some(v) => v.to_string(),
                    None => "error".to_string(),
                };
                let cause = match args.get(1) {
                    Some(Value::Error(e)) => Some(Rc::clone(e)),
                    _ => None,
                };
                Ok(Value::Error(Rc::new(ErrorValue {
                    kind: "Error".to_string(),
                    message: msg,
                    line: 0, col: 0,
                    stack: Vec::new(),
                    cause,
                })))
            }),
        })));
    }

    // std.Type:类型的类型 + 模块。成员:check / of / make。Type : Type 自指。
    let type_t = builtin_type("Type", |v| is_type_value(v));
    let (number_c, string_c, boolean_c, null_c) = (number_t.clone(), string_t.clone(), boolean_t.clone(), null_t.clone());
    let (any_array_c, any_object_c, function_c) = (any_array_t.clone(), any_object_t.clone(), function_t.clone());
    let (error_c, type_c) = (error_t.clone(), type_t.clone());
    if let Value::Object(obj) = &type_t {
        let mut fields = obj.borrow_mut();
        fields.insert("of".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
            name: "Type.of".to_string(),
            arity: Some(1),
            accepts_errors: true, // 必须能接收错误值(Type.of(err) → Error)
            func: Box::new(move |_ctx, args| {
                let v = args.first().unwrap_or(&Value::Void);
                Ok(match v {
                    Value::Number(_) => number_c.clone(),
                    Value::String(_) => string_c.clone(),
                    Value::Boolean(_) => boolean_c.clone(),
                    Value::Void => null_c.clone(),
                    Value::Array(_) => any_array_c.clone(),
                    Value::Function(_) | Value::NativeFunction(_) => function_c.clone(),
                    Value::Error(_) => error_c.clone(),
                    Value::Object(_) if is_type_value(v) => type_c.clone(),
                    Value::Object(_) => any_object_c.clone(),
                })
            }),
        })));
        fields.insert("make".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
            name: "Type.make".to_string(),
            arity: Some(1),
            accepts_errors: false,
            func: Box::new(|_ctx, args| {
                let f = &args[0];
                if !matches!(f, Value::Function(_) | Value::NativeFunction(_)) {
                    return Ok(arg_error("Type.make", "expected a function"));
                }
                Ok(user_type(f.clone()))
            }),
        })));
    }

    let mut g = global_env.borrow_mut();
    g.define("Number".to_string(), number_t);
    g.define("String".to_string(), string_t);
    g.define("Boolean".to_string(), boolean_t);
    g.define("Null".to_string(), null_t);
    g.define("AnyArray".to_string(), any_array_t);
    g.define("AnyObject".to_string(), any_object_t);
    g.define("Function".to_string(), function_t);
    g.define("Any".to_string(), any_t);
    g.define("Never".to_string(), never_t);
    g.define("Error".to_string(), error_t); // 覆盖旧全局构造器

    // std.Type 合并进 std 对象(替换旧的 create_type_module)
    let std_val = g.get("std").expect("std must be registered");
    if let Value::Object(std_obj) = std_val {
        std_obj.borrow_mut().fields.insert("Type".to_string(), type_t);
    }
}
```

- [ ] **Step 4: 接线**

`src/lib.rs` 加 `pub mod types;`。`src/interpreter.rs` `Interpreter::new`(98-101):

```rust
pub fn new() -> Self {
    let global_env = new_env();
    register_builtins(&global_env);
    crate::types::register_type_system(&global_env);
    global_env.borrow_mut().define("Infinity".to_string(), Value::Number(f64::INFINITY));
    global_env.borrow_mut().define("NaN".to_string(), Value::Number(f64::NAN));
    Interpreter { /* 原字段 */ }
}
```

`src/stdlib/mod.rs`:`register_builtins` 中删除全局 `Error` 构造器(66-90);`create_std_object` 中删除 `fields.insert("Type"...)`(139);删除 `create_type_module`(1509-1523)。

- [ ] **Step 5: 运行验证**

Run: `cargo test --test type_system` 与 `python3 difftest.py`
Expected: 新测试 PASS;difftest 中旧用例(`std.Type.of(...)` 返回字符串的断言)可能开始失败——**预期内**,Task 7 统一迁移;先确认非 Type.of 用例仍绿。若 `isError(Error("x"))` 类用例失败(旧 `Error("msg")` 调用),属预期迁移,在 Task 7 处理。

- [ ] **Step 6: 提交**

```bash
git add -A
git commit -m "feat: built-in type constants, merged std.Type, Error as type object

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 4: check_value / check_annotation + let 标注检查(host)

**Files:**
- Modify: `src/interpreter.rs`(call_function → call_function_inner 重构;新增 check_value/check_annotation/annotation_text;run_statement::Let 检查)

**Interfaces:**
- Consumes: Task 3 的 `types::is_type_value`
- Produces:
  - `fn call_function_inner(&mut self, callee: Value, args: Vec<Value>, span: Span, exempt_error_args: bool) -> Result<Value, RuntimeError>`(call_function 委托,exempt=false)
  - `fn check_value(&mut self, v: &Value, t: &Value, span: Option<Span>) -> Result<bool, Value>`(t 非类型 → Err(TypeCheck 错误值);check 返回错误值 → Err(该错误);否则 Ok(truthy))
  - `fn check_annotation(&mut self, value: Value, ty: Value, ann_text: &str, span: Option<Span>) -> Result<Value, RuntimeError>`(通过返回原值;失败返回 TypeCheck 错误值)
  - `fn annotation_text(&self, expr: &Expression) -> String`(current_source 切片)

- [ ] **Step 1: 写失败测试**

```rust
#[test]
fn let_annotation_checks() {
    assert_eq!(run("let x: Number = 42; x;"), "42");
    assert_eq!(run("let x: Number = \"a\"; isError(x);"), "true");
    assert_eq!(run("let x: Number = \"a\"; x.type;"), "TypeCheck");
    assert_eq!(run("let x: Error = Error.raise(\"boom\"); x.message;"), "boom");
    assert_eq!(run("let x: Number = Error.raise(\"boom\"); isError(x);"), "true");
    // cause 链:被检查值本身是错误值
    assert_eq!(run("let x: Number = Error.raise(\"boom\"); x.cause.type;"), "Error");
    // 标注不是类型值
    assert_eq!(run("let T = 42; let x: T = 5; isError(x);"), "true");
    // 用户自定义类型
    assert_eq!(run("let Positive = std.Type.make((v) -> v > 0); let x: Positive = 5; x;"), "5");
    assert_eq!(run("let Positive = std.Type.make((v) -> v > 0); let x: Positive = -5; isError(x);"), "true");
    // check 自身出错 → 失败
    assert_eq!(run("let Bad = std.Type.make((v) -> 1 / 0); let x: Bad = 5; isError(x);"), "true");
    // 无标注 = 完全动态
    assert_eq!(run("let x = \"a\"; x;"), "a");
}
```

- [ ] **Step 2: 运行验证失败**

Run: `cargo test --test type_system let_annotation_checks`
Expected: FAIL——`let x: Number = "a"` 未检查,绑定的是 "a"。

- [ ] **Step 3: call_function 重构(豁免通道)**

```rust
fn call_function(&mut self, callee: Value, args: Vec<Value>, span: Span) -> Result<Value, RuntimeError> {
    self.call_function_inner(callee, args, span, false)
}

/// 内部调用路径;exempt_error_args = true 时跳过用户函数的错误值参数检查
/// (内部类型检查路径用;原生分支仍按各自 accepts_errors 判断)。
fn call_function_inner(&mut self, callee: Value, args: Vec<Value>, span: Span, exempt_error_args: bool) -> Result<Value, RuntimeError> {
    match callee {
        Value::Function(func) => {
            if !exempt_error_args {
                if let Some(bad) = args.iter().find(|a| matches!(a, Value::Error(_))) {
                    return Ok(self.make_error("TypeMismatch", "attempt to pass error value as argument".to_string(), Some(span), error_cause(bad)));
                }
            }
            /* 其余原逻辑原样(currying/arity/递归深度/参数绑定/run_block) */
        }
        Value::NativeFunction(native_fn) => { /* 原逻辑(Task 1 后) */ }
        _ => { /* 原 NotCallable */ }
    }
}
```

- [ ] **Step 4: 检查方法**

在 `impl Interpreter` 内新增:

```rust
/// `v` 是否属于类型 `t`?t 非类型值或 check 出错 → Err(错误值)。
fn check_value(&mut self, v: &Value, t: &Value, span: Option<Span>) -> Result<bool, Value> {
    if !crate::types::is_type_value(t) {
        return Err(self.make_error("TypeCheck", "type annotation is not a type value".to_string(), span, None));
    }
    let check_fn = match self.get_field(t, "check", span) {
        Ok(f) => f,
        Err(e) => return Err(Value::Error(e)),
    };
    match self.call_function_inner(check_fn, vec![v.clone()], span.unwrap_or_default(), true) {
        Ok(Value::Error(e)) => Err(Value::Error(e)), // check 自身出错 → 失败
        Ok(r) => Ok(r.is_truthy()),
        Err(e) => Err(self.make_error("TypeCheck", format!("type check failed: {}", e), span, None)),
    }
}

/// 标注检查:通过返回原值;失败返回 TypeCheck 错误值(消息含标注源码文本)。
fn check_annotation(&mut self, value: Value, ty: Value, ann_text: &str, span: Option<Span>) -> Result<Value, RuntimeError> {
    match self.check_value(&value, &ty, span) {
        Ok(true) => Ok(value),
        Ok(false) => {
            let cause = match &value { Value::Error(e) => Some(Rc::clone(e)), _ => None };
            Ok(self.make_error(
                "TypeCheck",
                format!("value of type \"{}\" does not match the annotated type \"{}\"", value.type_name(), ann_text),
                span, cause,
            ))
        }
        Err(e) => Ok(e),
    }
}

/// 标注的源码文本(类型无名,消息里的名字来自你写下的代码)。
fn annotation_text(&self, expr: &Expression) -> String {
    let span = expr.span();
    let src = &self.current_source;
    if src.is_empty() || span.start >= span.end || span.end > src.len() {
        "?".to_string()
    } else {
        src[span.start..span.end].to_string()
    }
}
```

- [ ] **Step 5: run_statement::Let 接入检查**

```rust
Statement::Let(let_stmt) => {
    let value = self.eval_expression(&let_stmt.value, env)?;
    let value = if let Some(ann) = &let_stmt.type_annotation {
        let text = self.annotation_text(ann);
        let ty = self.eval_expression(ann, env)?;
        self.check_annotation(value, ty, &text, Some(ann.span()))?
    } else {
        value
    };
    env.borrow_mut().define(let_stmt.name.clone(), value);
    Ok(ControlFlow::None)
}
```

- [ ] **Step 6: 运行验证**

Run: `cargo test --test type_system`、`cargo test`
Expected: 新测试 PASS;`x.cause.type` 为 "Error"(cause 链上被检查的错误值)。

- [ ] **Step 7: 提交**

```bash
git add -A
git commit -m "feat: let annotations checked at declaration (TypeCheck error values)

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 5: 参数标注检查(host)——定义时求值,调用时检查

**Files:**
- Modify: `src/value.rs:88-92`(FunctionValue 加 param_types)、`src/interpreter.rs`(Expression::Function 求值;call_function_inner Function 分支参数检查;curried 路径重构)

**Interfaces:**
- Consumes: Task 4 的 `check_value`/`annotation_text`;Task 2 的 `Parameter.type_annotation`
- Produces: `FunctionValue.param_types: Rc<Vec<Option<(Value, String)>>>`(定义时求值的 (类型值, 源码文本))

- [ ] **Step 1: 写失败测试**

```rust
#[test]
fn param_annotations_checked_at_call() {
    assert_eq!(run("let f = (a: Number) -> a + 1; f(5);"), "6");
    assert_eq!(run("let f = (a: Number) -> a + 1; let r = f(\"x\"); isError(r);"), "true");
    assert_eq!(run("let f = (a: Number) -> a + 1; let r = f(\"x\"); r.type;"), "TypeCheck");
    // 检查失败 → 函数体不执行
    assert_eq!(run("let f = (a: Number) -> { 1 / 0; }; let r = f(\"x\"); isError(r);"), "true");
    // 多参数
    assert_eq!(run("let f = (a: Number, b: String) -> a + b; f(1, \"x\");"), "1x");
    assert_eq!(run("let f = (a: Number, b: String) -> a + b; let r = f(\"x\", \"y\"); isError(r);"), "true");
    // 标注在定义时求值(引用外层变量)
    assert_eq!(run("let T = Number; let f = (a: T) -> a; f(1);"), "1");
    // 遮蔽后标注求值指向遮蔽值
    assert_eq!(run("let Number = 42; let f = (a: Number) -> a; let r = f(1); isError(r);"), "true");
}
```

- [ ] **Step 2: 运行验证失败**

Run: `cargo test --test type_system param_annotations_checked_at_call`
Expected: FAIL——`f("x")` 返回 "x+1" 而非错误值。

- [ ] **Step 3: FunctionValue 加字段**

```rust
// value.rs:
pub struct FunctionValue {
    pub parameters: Rc<Vec<Parameter>>,
    pub body: Rc<Block>,
    pub closure: EnvRef,
    /// 定义时求值的参数标注:(类型值, 源码文本);None = 该参数无标注。
    pub param_types: Rc<Vec<Option<(Value, String)>>>,
}
```

- [ ] **Step 4: Expression::Function 求值处(interpreter.rs ~448)**

```rust
Expression::Function(func) => {
    let mut param_types = Vec::with_capacity(func.parameters.len());
    for p in func.parameters.iter() {
        match &p.type_annotation {
            Some(ann) => {
                let ty = self.eval_expression(ann, env)?;
                param_types.push(Some((ty, self.annotation_text(ann))));
            }
            None => param_types.push(None),
        }
    }
    Ok(Value::Function(Rc::new(FunctionValue {
        parameters: Rc::clone(&func.parameters),
        body: Rc::clone(&func.body),
        closure: Rc::clone(env),
        param_types: Rc::new(param_types),
    })))
}
```

- [ ] **Step 5: call_function_inner Function 分支参数检查**

在 arity 检查通过后、递归深度检查前插入:

```rust
// 参数标注检查:失败 → 函数体不执行,返回 TypeCheck 错误值
for (i, (param, arg)) in func.parameters.iter().zip(args.iter()).enumerate() {
    if let Some(Some((ty, text))) = func.param_types.get(i) {
        match self.check_value(arg, ty, Some(span)) {
            Ok(true) => {}
            Ok(false) => return Ok(self.make_error(
                "TypeCheck",
                format!("argument {} does not match the annotated type \"{}\"", i + 1, text),
                Some(span), None,
            )),
            Err(e) => return Ok(e),
        }
    }
}
```

（`param` 未用时用 `_param` 或仅用索引;参数绑定处改为:`call_env.borrow_mut().define_annotated(param.name.clone(), arg, func.param_types[i].clone())`——`define_annotated` 在 Task 6 提供,此处先保持 `define`,Task 6 一并替换。）

- [ ] **Step 6: curried 路径重构(复用完整调用逻辑)**

替换 659-702 的内嵌解释器实现:

```rust
if args.len() < func.parameters.len() {
    let captured_func = Value::Function(Rc::clone(&func));
    let mut all_args = args.clone();
    return Ok(Value::NativeFunction(Rc::new(NativeFunction {
        name: "<curried>".to_string(),
        arity: Some(func.parameters.len() - args.len()),
        accepts_errors: false,
        func: Box::new(move |ctx, inner_args| {
            all_args.extend(inner_args);
            ctx.call(captured_func.clone(), all_args, span)
        }),
    })));
}
```

（`span` 是 `Span`(Copy)——闭包直接捕获。行为差异:参数检查/错误值检查现由 `call_function` 统一执行;多步柯里化行为与原来一致——curried 原生按 arity 先挡掉不足的参数。）

- [ ] **Step 7: 运行验证**

Run: `cargo test --test type_system` 与 `python3 difftest.py`(柯里化用例 r/cases 须仍绿)
Expected: 新测试 PASS;difftest 柯里化与闭包用例不变。

- [ ] **Step 8: 提交**

```bash
git add -A
git commit -m "feat: param annotations evaluated at definition, checked at call

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 6: 环境绑定携带标注 + 重赋值检查(host)

**Files:**
- Modify: `src/environment.rs`(values → Binding;define/assign/get/contains/get_mut;新增 define_annotated/get_annotation)
- Modify: `src/interpreter.rs`(run_statement::Let 存储标注;assign_value 检查;call_function 参数绑定用 define_annotated)

**Interfaces:**
- Consumes: Task 4/5 的 `check_annotation`/`check_value`
- Produces:
  - `struct Binding { value: Value, annotation: Option<(Value, String)> }`
  - `pub fn define_annotated(&mut self, name: String, value: Value, annotation: Option<(Value, String)>)`
  - `pub fn get_annotation(&self, name: &str) -> Option<(Value, String)>`(沿作用域链)

- [ ] **Step 1: 写失败测试**

```rust
#[test]
fn reassignment_rechecks_annotation() {
    assert_eq!(run("let x: Number = 42; x = 100; x;"), "100");
    assert_eq!(run("let x: Number = 42; x = \"a\"; isError(x);"), "true");
    assert_eq!(run("let x: Number = 42; x = \"a\"; x.type;"), "TypeCheck");
    // 无标注的变量照常
    assert_eq!(run("let x = 42; x = \"a\"; x;"), "a");
    // 函数参数带标注,体内重赋值再查
    assert_eq!(run("let f = (a: Number) -> { a = \"x\"; return a; }; let r = f(1); isError(r);"), "true");
}
```

- [ ] **Step 2: 运行验证失败**

Run: `cargo test --test type_system reassignment_rechecks_annotation`
Expected: FAIL——`x = "a"` 未被拦截。

- [ ] **Step 3: environment.rs 改动**

```rust
/// 变量绑定:值 + 可选的类型标注((求值后的类型值, 源码文本))。
pub struct Binding {
    pub value: Value,
    pub annotation: Option<(Value, String)>,
}

pub struct Environment {
    values: HashMap<String, Binding>,
    parent: Option<EnvRef>,
}

pub fn define(&mut self, name: String, value: Value) {
    self.values.insert(name, Binding { value, annotation: None });
}

/// 带标注的绑定(标注为 Some 时,重赋值会再次检查)。
pub fn define_annotated(&mut self, name: String, value: Value, annotation: Option<(Value, String)>) {
    self.values.insert(name, Binding { value, annotation });
}

pub fn get(&self, name: &str) -> Option<Value> {
    if let Some(b) = self.values.get(name) { Some(b.value.clone()) }
    else if let Some(ref parent) = self.parent { parent.borrow().get(name) }
    else { None }
}

/// 沿作用域链查找变量的标注(仅用于重赋值检查)。
pub fn get_annotation(&self, name: &str) -> Option<(Value, String)> {
    if let Some(b) = self.values.get(name) { b.annotation.clone() }
    else if let Some(ref parent) = self.parent { parent.borrow().get_annotation(name) }
    else { None }
}

pub fn assign(&mut self, name: &str, value: Value) -> Result<(), RuntimeError> {
    if let Some(b) = self.values.get_mut(name) {
        b.value = value; // 保留 annotation
        Ok(())
    } else if let Some(ref parent) = self.parent {
        parent.borrow_mut().assign(name, value)
    } else {
        Err(RuntimeError::UndefinedVariable(name.to_string()))
    }
}

// contains / get_mut 相应改为 Binding 上操作:
pub fn contains(&self, name: &str) -> bool { self.values.contains_key(name) }
pub fn get_mut(&mut self, name: &str) -> Option<&mut Value> {
    self.values.get_mut(name).map(|b| &mut b.value)
}
```

- [ ] **Step 4: interpreter.rs——let 存储标注**

Task 4 的 `run_statement::Let` 改为:

```rust
Statement::Let(let_stmt) => {
    let value = self.eval_expression(&let_stmt.value, env)?;
    let mut annotation = None;
    let value = if let Some(ann) = &let_stmt.type_annotation {
        let text = self.annotation_text(ann);
        let ty = self.eval_expression(ann, env)?;
        annotation = Some((ty.clone(), text));
        self.check_annotation(value, ty, &text, Some(ann.span()))?
    } else {
        value
    };
    if let Some(a) = annotation {
        env.borrow_mut().define_annotated(let_stmt.name.clone(), value, Some(a));
    } else {
        env.borrow_mut().define(let_stmt.name.clone(), value);
    }
    Ok(ControlFlow::None)
}
```

- [ ] **Step 5: interpreter.rs——assign_value 检查**

`assign_value`(791)的空 accessor 分支:

```rust
if target.accessors.is_empty() {
    let value = match env.borrow().get_annotation(&target.name) {
        Some((ty, text)) => self.check_annotation(value, ty, &text, None)?,
        None => value,
    };
    env.borrow_mut().assign(&target.name, value)
}
```

Task 5 的参数绑定处(`call_function_inner` Function 分支唯一一处绑定循环;curried 路径已重构进 `call_function`,无需单独处理):

```rust
for (i, (param, arg)) in func.parameters.iter().zip(args).enumerate() {
    call_env.borrow_mut().define_annotated(param.name.clone(), arg, func.param_types[i].clone());
}
```

- [ ] **Step 6: 运行验证**

Run: `cargo test --test type_system` 与 `python3 difftest.py`
Expected: 新测试 PASS;既有用例不受影响。

- [ ] **Step 7: 提交**

```bash
git add -A
git commit -m "feat: bindings carry annotations; reassignment re-checks

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 7: 受保护成员 + Type.of 迁移(host 收尾)

**Files:**
- Modify: `src/interpreter.rs`(`set_field`/`set_index` 保护;`is_diagnostic_native` 移除后的清理)
- Modify: `src/stdlib/mod.rs`(`std.Object.keys/values/entries` 过滤 TYPE_MARKER)

**Interfaces:**
- Consumes: Task 3 的 `types::is_protected_object` / `PROTECTED_FIELDS` / `TYPE_MARKER`

- [ ] **Step 1: 写失败测试**

```rust
#[test]
fn protected_members_are_read_only() {
    // 覆盖核心成员 → 运行时错误(赋值是语句,错误经异常通道,与 set_field 的
    // NotAnObject 一致;`x = v` 不能作为表达式)
    assert!(Interpreter::new().run_source("Number.check = 42;", "t".into()).is_err());
    assert!(Interpreter::new().run_source("Error.raise = 1;", "t".into()).is_err());
    assert!(Interpreter::new().run_source("std.Type.of = 1;", "t".into()).is_err());
    // 自由挂载新成员照旧
    assert_eq!(run("Number.myHelper = 1; Number.myHelper;"), "1");
    // 用户类型不受保护
    assert_eq!(run("let T = std.Type.make((v) -> true); T.check = 42; std.Type.check(T);"), "false");
    // 标记字段不泄漏
    assert_eq!(run("std.Object.keys(Number).length;"), "1");  // 只有 check
}

#[test]
fn type_of_returns_type_values() {
    assert_eq!(run("std.Type.of(42) == Number;"), "true");
    assert_eq!(run("std.Type.of(\"a\") == String;"), "true");
    assert_eq!(run("std.Type.of(true) == Boolean;"), "true");
    assert_eq!(run("std.Type.of(null) == Null;"), "true");
    assert_eq!(run("std.Type.of([1]) == AnyArray;"), "true");
    assert_eq!(run("std.Type.of({}) == AnyObject;"), "true");
    assert_eq!(run("std.Type.of(() -> 1) == Function;"), "true");
    assert_eq!(run("std.Type.of(Error.raise(\"x\")) == Error;"), "true");
    assert_eq!(run("std.Type.of(Number) == std.Type;"), "true");
}
```

- [ ] **Step 2: 运行验证失败**

Run: `cargo test --test type_system protected_members_are_read_only`
Expected: FAIL——`Number.check = 42` 成功写入。

- [ ] **Step 3: set_field 保护**

```rust
fn set_field(&self, object: &Value, field: &str, value: Value) -> Result<(), RuntimeError> {
    match object {
        Value::Object(obj) => {
            if crate::types::is_protected_object(object) && crate::types::PROTECTED_FIELDS.contains(&field) {
                return Err(RuntimeError::Custom(format!(
                    "cannot overwrite protected member '{}' of built-in type", field
                )));
            }
            obj.borrow_mut().fields.insert(field.to_string(), value);
            Ok(())
        }
        _ => Err(RuntimeError::NotAnObject(object.type_name().to_string())),
    }
}
```

`set_index`(1077)的 `(Value::Object(obj), Value::String(key))` 分支:在插入前加同一判断(可提取 `fn check_protected(&self, object: &Value, field: &str) -> Result<(), RuntimeError>`,两处调用)。

- [ ] **Step 4: Object.keys/values/entries 过滤标记**

`src/stdlib/mod.rs` 中 `Object.keys/values/entries` 的原生实现:遍历 fields 时跳过 `crate::types::TYPE_MARKER`:

```rust
// keys 例:
let mut keys: Vec<Value> = obj.borrow().fields.iter()
    .filter(|(k, _)| *k != crate::types::TYPE_MARKER)
    .map(|(k, _)| Value::String(k.clone()))
    .collect();
```

（values/entries 同样过滤;若不实现本步,`std.Object.keys(Number)` 会暴露 `"\u{1}type"`——测试会红,必须做。）

- [ ] **Step 5: difftest 旧用例迁移(字符串 → 类型值)**

`difftest.py` 中所有依赖 `std.Type.of(...)` 返回字符串的断言(若有)改为与对应类型常量比较(`== Number` 等);`Error("msg")` 调用改为 `Error.raise("msg")`。运行 `python3 difftest.py` 定位全部失败点并逐个迁移。

- [ ] **Step 6: 运行验证**

Run: `cargo test --test type_system`、`cargo test`、`python3 difftest.py`
Expected: 全绿;`Error("msg")` 相关用例已迁移(旧调用现在返回 NotCallable 错误值——`Error` 是对象)。

- [ ] **Step 7: 提交**

```bash
git add -A
git commit -m "feat: protect built-in type members; migrate Type.of to type values

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 8: Array/Object 构造器(host,union 参数)

**Files:**
- Modify: `src/types.rs`(register_constructors + 构造逻辑)
- Modify: `src/interpreter.rs`(`Interpreter::new` 调用 register_constructors)

**Interfaces:**
- Consumes: Task 1 的 `CallContext`;Task 3 的 `is_type_value`/`user_type`/`arg_error`
- Produces: 全局函数 `Array(x)` / `Object(x)`,union 参数分发(见 Global Constraints);`pub fn register_constructors(global_env: &EnvRef)`

- [ ] **Step 1: 写失败测试**

```rust
#[test]
fn array_constructor_union_params() {
    // Type 成员:元素类型
    assert_eq!(run("let x: Array(Number) = [1, 2]; x;"), "[1, 2]");
    assert_eq!(run("let x: Array(Number) = [1, \"a\"]; isError(x);"), "true");
    // Number 成员:定长
    assert_eq!(run("let x: Array(3) = [1, 2, 3]; x;"), "[1, 2, 3]");
    assert_eq!(run("let x: Array(3) = [1, 2]; isError(x);"), "true");
    // [Type] 成员:逐位类型(tuple)
    assert_eq!(run("let x: Array([Number, String]) = [1, \"a\"]; x;"), "[1, a]");
    assert_eq!(run("let x: Array([Number, String]) = [1, 2]; isError(x);"), "true");
    // 元数据成员:{length, element}
    assert_eq!(run("let x: Array({length: 2, element: Number}) = [1, 2]; x;"), "[1, 2]");
    assert_eq!(run("let x: Array({length: 2, element: Number}) = [1]; isError(x);"), "true");
    // 非法形态 → 构造错误值
    assert_eq!(run("let x = Array(3.5); isError(x);"), "true");
    assert_eq!(run("let x = Array([1, 2]); isError(x);"), "true"); // [Type] 里非类型
    // 嵌套 + 用户类型
    assert_eq!(run("let Positive = std.Type.make((v) -> v > 0); let x: Array(Positive) = [1, 2]; x;"), "[1, 2]");
}

#[test]
fn object_constructor_union_params() {
    // Type 成员:keys 全为 T(Object(String) ≡ AnyObject)
    assert_eq!(run("let x: Object(String) = {a: 1, b: \"s\"}; x;"), "{a: 1, b: s}");
    assert_eq!(run("let x: Object(String) = Number; isError(x);"), "true"); // 类型对象不是 Object
    // schema 成员:必选字段子集,额外字段允许
    assert_eq!(run("let x: Object({name: String}) = {name: \"a\", age: 1}; x;"), "{name: a, age: 1}");
    assert_eq!(run("let x: Object({name: String}) = {age: 1}; isError(x);"), "true"); // 缺字段
    assert_eq!(run("let x: Object({name: String}) = {name: 1}; isError(x);"), "true"); // 字段类型不符
    // schema 构造验证
    assert_eq!(run("let x = Object({bad: 42}); isError(x);"), "true");
    // 嵌套 schema
    assert_eq!(run("let x: Object({user: Object({name: String})}) = {user: {name: \"a\"}}; x;"), "{user: {name: a}}");
}
```

- [ ] **Step 2: 运行验证失败**

Run: `cargo test --test type_system array_constructor_union_params`
Expected: FAIL——`Array` 未定义(UndefinedVariable)。

- [ ] **Step 3: types.rs 实现构造器**

```rust
/// 注册类型构造器 Array/Object 为全局函数。
pub fn register_constructors(global_env: &EnvRef) {
    global_env.borrow_mut().define("Array".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "Array".to_string(), arity: Some(1), accepts_errors: false,
        func: Box::new(|_ctx, args| build_array_type(&args[0])),
    })));
    global_env.borrow_mut().define("Object".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "Object".to_string(), arity: Some(1), accepts_errors: false,
        func: Box::new(|_ctx, args| build_object_type(&args[0])),
    })));
}

/// 取出类型对象的 check 函数值(类型值必有此字段)。
fn type_check_field(t: &Value) -> Option<Value> {
    if let Value::Object(o) = t {
        o.borrow().fields.get("check").cloned()
    } else {
        None
    }
}

/// 检查闭包公共骨架:对每个目标值调用检查,任一失败/出错 → false。
fn all_check(ctx: &mut dyn CallContext, targets: Vec<Value>, check: &Value) -> Result<Value, RuntimeError> {
    for t in targets {
        match ctx.call(check.clone(), vec![t], Span::new(0, 0)) {
            Ok(Value::Error(_)) => return Ok(Value::Boolean(false)),
            Ok(r) if !r.is_truthy() => return Ok(Value::Boolean(false)),
            Ok(_) => {}
            Err(_) => return Ok(Value::Boolean(false)),
        }
    }
    Ok(Value::Boolean(true))
}

fn array_check(mode: ArrayMode) -> Value {
    Value::NativeFunction(Rc::new(NativeFunction {
        name: "<Array.check>".to_string(), arity: Some(1), accepts_errors: false,
        func: Box::new(move |ctx, args| {
            let elems = match &args[0] {
                Value::Array(a) => a.borrow().clone(),
                _ => return Ok(Value::Boolean(false)),
            };
            match &mode {
                ArrayMode::FixedLen(len) => Ok(Value::Boolean(elems.len() == *len)),
                ArrayMode::Element(check) => all_check(ctx, elems, check),
                ArrayMode::Tuple(checks) => {
                    if elems.len() != checks.len() { return Ok(Value::Boolean(false)); }
                    for (e, c) in elems.iter().zip(checks.iter()) {
                        match ctx.call(c.clone(), vec![e.clone()], Span::new(0, 0)) {
                            Ok(Value::Error(_)) => return Ok(Value::Boolean(false)),
                            Ok(r) if !r.is_truthy() => return Ok(Value::Boolean(false)),
                            Ok(_) => {}
                            Err(_) => return Ok(Value::Boolean(false)),
                        }
                    }
                    Ok(Value::Boolean(true))
                }
            }
        }),
    }))
}

enum ArrayMode {
    FixedLen(usize),
    Element(Value),      // check 函数
    Tuple(Vec<Value>),   // 每位的 check 函数
}

fn build_array_type(x: &Value) -> Result<Value, RuntimeError> {
    // union 成员 1:Number(定长,元素任意)
    if let Value::Number(n) = x {
        if n.fract() != 0.0 || *n < 0.0 {
            return Ok(arg_error("Array", "length must be a non-negative integer"));
        }
        return Ok(user_type(array_check(ArrayMode::FixedLen(*n as usize))));
    }
    // union 成员 2:Type(元素类型)
    if is_type_value(x) {
        let check = type_check_field(x).expect("type value has check");
        return Ok(user_type(array_check(ArrayMode::Element(check))));
    }
    // union 成员 3:[Type](逐位类型)
    if let Value::Array(elems) = x {
        let mut checks = Vec::with_capacity(elems.borrow().len());
        for e in elems.borrow().iter() {
            if !is_type_value(e) {
                return Ok(arg_error("Array", "tuple elements must all be type values"));
            }
            checks.push(type_check_field(e).expect("type value has check"));
        }
        return Ok(user_type(array_check(ArrayMode::Tuple(checks))));
    }
    // union 成员 4:{length, element}(元数据组合)
    if let Value::Object(obj) = x {
        if !is_type_value(x) {
            let fields = obj.borrow();
            let length = match fields.get("length") {
                Some(Value::Number(n)) if n.fract() == 0.0 && *n >= 0.0 => *n as usize,
                _ => return Ok(arg_error("Array", "metadata must have a non-negative integer 'length'")),
            };
            let element = match fields.get("element") {
                Some(e) if is_type_value(e) => type_check_field(e).expect("type value has check"),
                _ => return Ok(arg_error("Array", "metadata must have a type 'element'")),
            };
            return Ok(user_type(array_check(ArrayMode::Tuple(
                std::iter::repeat(element).take(length).collect()
            ))));
        }
    }
    Ok(arg_error("Array", "argument must be a length, a type, a list of types, or {length, element}"))
}

fn object_check_keys(key_check: Value) -> Value {
    Value::NativeFunction(Rc::new(NativeFunction {
        name: "<Object.check>".to_string(), arity: Some(1), accepts_errors: false,
        func: Box::new(move |ctx, args| {
            let fields = match &args[0] {
                Value::Object(o) if !is_type_value(&args[0]) => o.borrow().fields.clone(),
                _ => return Ok(Value::Boolean(false)),
            };
            let keys: Vec<Value> = fields.keys().map(|k| Value::String(k.clone())).collect();
            all_check(ctx, keys, &key_check)
        }),
    }))
}

fn object_check_schema(schema: Vec<(String, Value)>) -> Value {
    Value::NativeFunction(Rc::new(NativeFunction {
        name: "<Object.check>".to_string(), arity: Some(1), accepts_errors: false,
        func: Box::new(move |ctx, args| {
            let fields = match &args[0] {
                Value::Object(o) if !is_type_value(&args[0]) => o.borrow().fields.clone(),
                _ => return Ok(Value::Boolean(false)),
            };
            for (k, check) in schema.iter() {
                let fv = match fields.get(k) {
                    Some(fv) => fv.clone(),
                    None => return Ok(Value::Boolean(false)), // 缺字段
                };
                match ctx.call(check.clone(), vec![fv], Span::new(0, 0)) {
                    Ok(Value::Error(_)) => return Ok(Value::Boolean(false)),
                    Ok(r) if !r.is_truthy() => return Ok(Value::Boolean(false)),
                    Ok(_) => {}
                    Err(_) => return Ok(Value::Boolean(false)),
                }
            }
            Ok(Value::Boolean(true))
        }),
    }))
}

fn build_object_type(x: &Value) -> Result<Value, RuntimeError> {
    // union 成员 1:Type(keys 全为 T;Object(String) ≡ AnyObject)
    if is_type_value(x) {
        let check = type_check_field(x).expect("type value has check");
        return Ok(user_type(object_check_keys(check)));
    }
    // union 成员 2:形状对象(schema)
    if let Value::Object(obj) = x {
        let mut schema = Vec::new();
        for (k, v) in obj.borrow().fields.iter() {
            if !is_type_value(v) {
                return Ok(arg_error("Object", format!("schema field '{}' is not a type value", k)));
            }
            schema.push((k.clone(), type_check_field(v).expect("type value has check")));
        }
        return Ok(user_type(object_check_schema(schema)));
    }
    Ok(arg_error("Object", "argument must be a type (keys) or a shape object (schema)"))
}
```

- [ ] **Step 4: 接线**

`src/interpreter.rs` `Interpreter::new`:在 `register_type_system` 之后加 `crate::types::register_constructors(&global_env);`。`src/types.rs` 顶部 import 补 `Span`(`use crate::token::Span;`)。

- [ ] **Step 5: 运行验证**

Run: `cargo test --test type_system` 与 `python3 difftest.py`
Expected: 新测试 PASS;difftest 不受影响(新语法未用)。

- [ ] **Step 6: 提交**

```bash
git add -A
git commit -m "feat: Array/Object type constructors with union parameters

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 9: Boot——parser.ql 标注语法

**Files:**
- Modify: `bootstrapped/parser.ql`(let 语句与参数列表)、`bootstrapped/ast.ql`(LetStmt/Parameter 记录加 annotation 字段)

**Interfaces:**
- Consumes: host 侧语义(标注 = 完整表达式,QLang 版)
- Produces: boot AST 的 `LetStmt.annotation` / `Parameter.annotation`(QLang 表达式记录)

- [ ] **Step 1: 写失败测试**

在 `difftest.py` 的 `SAFE_CASES` 末尾追加(随后会随各任务继续扩展):

```python
("t01", 'let x: Number = 42; x;'),
("t02", 'let x: Number = "a"; isError(x);'),
```

Run: `python3 difftest.py`
Expected: FAIL——boot 侧解析 `let x: Number` 报错("Expected =")。

- [ ] **Step 2: 实现 ast.ql 记录扩展**

`bootstrapped/ast.ql`:找到 `LetStmt` 与 `Parameter` 记录构造处,加字段:

```qlang
// Parameter 例(原为 { name: ... }):
{ name: name, annotation: annotation }
// LetStmt 例:
{ name: name, value: value, annotation: annotation }
```

- [ ] **Step 3: 实现 parser.ql 参数标注**

`bootstrapped/parser.ql` 参数列表解析(532-582):读参数名 token 后,若 `peek() == ":"`,消费并 `parseExpression()` 得标注;参数记录带 `annotation`。多参数循环同样处理。注意:`(a: T)` 无箭头时报错逻辑保持。

- [ ] **Step 4: 实现 parser.ql let 标注**

let 语句解析:名字 token 后若 `peek() == ":"`,消费并 `parseExpression()` 得标注,存入 LetStmt 记录;随后继续等 `=`。

- [ ] **Step 5: 运行验证**

Run: `python3 difftest.py`
Expected: t01 PASS(boot 解析成功;检查逻辑尚未实现,`let x: Number = "a"` 此时 boot 仍返回 "a" → t02 FAIL——预期,Task 11 实现检查后转绿)。

- [ ] **Step 6: 提交**

```bash
git add -A
git commit -m "feat(boot): parse type annotations (let and params)

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 10: Boot——stdlib.ql 类型库

**Files:**
- Modify: `bootstrapped/stdlib.ql`(类型常量、构造器、合并的 Type、Error 类型对象)

**Interfaces:**
- Consumes: boot 值包装 `{type, value}`(null 无包装)
- Produces: boot 全局 `Number`/`String`/`Boolean`/`Null`/`AnyArray`/`AnyObject`/`Function`/`Any`/`Never`/`Error`(类型对象)、`Array`/`Object`(构造器函数)、`Type`(check/of/make 合并)

- [ ] **Step 1: 写失败测试**

```python
# difftest.py SAFE_CASES 追加:
("t03", 'Number.check(42);'),
("t04", 'Number.check("a");'),
("t05", 'std.Type.of(42) == Number;'),
("t06", 'std.Type.of(null) == Null;'),
("t07", 'std.Type.of(Number) == std.Type;'),
("t08", 'std.Type.check(Number);'),
("t09", 'std.Type.make((v) -> v > 0).check(5);'),
("t10", 'let x: Array(Number) = [1, 2]; x;'),
("t11", 'let x: Object({name: String}) = {name: "a"}; x;'),
("t12", 'let e = Error.raise("boom"); std.Type.of(e) == Error;'),
```

Run: `python3 difftest.py`
Expected: t03-t12 FAIL(boot 侧 Number/std.Type 等未定义或行为旧)。

- [ ] **Step 2: 实现类型常量与判定**

`bootstrapped/stdlib.ql` 中,把旧的 `let Type = { of: ... }`(约 229-240 行)替换为完整类型库。boot 值判定基于包装:`v != null && v.type == "..."`:

```qlang
let isTypeValue = (v) -> v != null && v.type == "Object"
    && v.check != null && v.check.type == "function";

let Number   = { check: (v) -> v != null && v.type == "Number" };
let String   = { check: (v) -> v != null && v.type == "String" };
let Boolean  = { check: (v) -> v != null && v.type == "Boolean" };
let Null     = { check: (v) -> v == null };
let AnyArray = { check: (v) -> v != null && v.type == "Array" };
let AnyObject= { check: (v) -> v != null && v.type == "Object" && !isTypeValue(v) };
let Function = { check: (v) -> v != null && (v.type == "function" || v.type == "native") };
let Any      = { check: (v) -> true };
let Never    = { check: (v) -> false };
let Error    = { check: (v) -> v != null && v.type == "Error",
                 raise: (msg, cause) -> std.Error.raise("Error", msg, cause) };
```

（`v.type == "native"` 视 boot 对原生函数的包装而定——以 interpreter.ql 现有调用分支为准;若 boot 原生探测为 null,则 Function 判定用 `v != null && (v.type == "function" || v.type == null)` 并核对 difftest。）

- [ ] **Step 3: 实现合并的 Type 模块**

```qlang
let Type = {
  check: (v) -> isTypeValue(v),
  of: (v) -> {
    if v == null { Null; }
    else if isTypeValue(v) { Type; }
    else if v.type == "Number" { Number; }
    else if v.type == "String" { String; }
    else if v.type == "Boolean" { Boolean; }
    else if v.type == "Array" { AnyArray; }
    else if v.type == "Object" { AnyObject; }
    else if v.type == "function" || v.type == "native" { Function; }
    else if v.type == "Error" { Error; }
    else { Type; };
  },
  make: (f) -> { check: f },
};
```

- [ ] **Step 4: 实现 Array/Object 构造器**

```qlang
// 逐元素检查骨架(注意:boot 的 stdlib 没有 forEach,用 while)
let allMatch = (arr, check) -> {
  let ok = true;
  let i = 0;
  while i < arr.length && ok {
    let r = check(arr[i]);
    if r == null || r == false || r.type == "Error" { ok = false; };
    i = i + 1;
  };
  ok;
};

// Array 构造器:union 参数(Number | Type | [Type] | {length, element})
// mode: { length: Number|null, element: check|null, tuple: [check]|null }
let arrayCheck = (mode) -> (v) -> {
  if v == null || v.type != "Array" { false; }
  else if mode.length != null {
    if v.value.length != mode.length { false; }
    else if mode.element != null { allMatch(v.value, mode.element); }
    else { true; };
  }
  else if mode.tuple != null {
    if v.value.length != mode.tuple.length { false; }
    else {
      let ok = true;
      let i = 0;
      while i < mode.tuple.length && ok {
        let r = mode.tuple[i](v.value[i]);
        if r == null || r == false || r.type == "Error" { ok = false; };
        i = i + 1;
      };
      ok;
    };
  }
  else if mode.element != null { allMatch(v.value, mode.element); }
  else { true; };
};

let Array = (x) -> {
  if x != null && x.type == "Number" && x.value >= 0 && x.value % 1 == 0 {
    Type.make(arrayCheck({ length: x.value, element: null, tuple: null }));
  }
  else if isTypeValue(x) {
    Type.make(arrayCheck({ length: null, element: x.check, tuple: null }));
  }
  else if x != null && x.type == "Array" {
    // [Type] 成员:逐位类型(构造时验证每个元素都是类型)
    let checks = [];
    let i = 0;
    while i < x.value.length {
      let t = x.value[i];
      if !isTypeValue(t) {
        return std.Error.raise("TypeMismatch", "Array: tuple elements must all be type values");
      };
      checks[checks.length] = t.check;
      i = i + 1;
    };
    Type.make(arrayCheck({ length: null, element: null, tuple: checks }));
  }
  else if x != null && x.type == "Object" && !isTypeValue(x) {
    // {length, element} 元数据成员
    let length = x.value["length"];
    let element = x.value["element"];
    if length == null || length.type != "Number" || length.value < 0 || length.value % 1 != 0 {
      std.Error.raise("TypeMismatch", "Array: metadata must have a non-negative integer 'length'");
    }
    else if element == null || !isTypeValue(element) {
      std.Error.raise("TypeMismatch", "Array: metadata must have a type 'element'");
    }
    else {
      Type.make(arrayCheck({ length: length.value, element: element.check, tuple: null }));
    };
  }
  else {
    std.Error.raise("TypeMismatch", "Array: argument must be a length, a type, a list of types, or {length, element}");
  };
};

// Object 构造器:union 参数(Type | 形状对象)
let Object = (x) -> {
  if isTypeValue(x) {
    // Type 成员:keys 全为 T(Object(String) ≡ AnyObject)
    Type.make((v) -> {
      if v == null || v.type != "Object" || isTypeValue(v) { false; }
      else {
        let keys = std.Object.keys(v);
        let ok = true;
        let i = 0;
        while i < keys.length && ok {
          let r = x.check(keys[i]);
          if r == null || r == false || r.type == "Error" { ok = false; };
          i = i + 1;
        };
        ok;
      };
    });
  }
  else if x != null && x.type == "Object" && !isTypeValue(x) {
    // 形状对象成员:schema(构造时验证值都是类型;缺字段/字段不符 → false)
    let entries = std.Object.entries(x);
    let i = 0;
    while i < entries.length {
      if !isTypeValue(entries[i][1]) {
        return std.Error.raise("TypeMismatch", "Object: schema field '" + entries[i][0] + "' is not a type value");
      };
      i = i + 1;
    };
    Type.make((v) -> {
      if v == null || v.type != "Object" || isTypeValue(v) { false; }
      else {
        let ok = true;
        let j = 0;
        while j < entries.length && ok {
          let key = entries[j][0];
          let fv = v.value[key];
          if fv == null {
            ok = false; // 缺字段
          }
          else {
            let r = entries[j][1].check(fv);
            if r == null || r == false || r.type == "Error" { ok = false; };
          };
          j = j + 1;
        };
        ok;
      };
    });
  }
  else {
    std.Error.raise("TypeMismatch", "Object: argument must be a type (keys) or a shape object (schema)");
  };
};
```

（boot 的对象字段访问与 `std.Object.keys/entries` 以 boot 的 stdlib.ql 现有实现为准;`x.value[key]` 是 boot 对象包装的字段读取,若 boot 的 stdlib 已提供字段读取原生则优先复用。`return` 在 boot 函数内可用,`std.Error.raise(kind, msg, cause)` 构造错误值。最终都经 `Type.make` 包装为类型对象,与 host 行为对账于 difftest。）

- [ ] **Step 5: 运行验证**

Run: `python3 difftest.py`
Expected: t03-t12 转绿(标检查询与构造器;标注检查 t02 仍红——Task 11)。

- [ ] **Step 6: 提交**

```bash
git add -A
git commit -m "feat(boot): type constants, constructors, merged Type module

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 11: Boot——interpreter.ql 检查语义 + 内部 Type.of 迁移

**Files:**
- Modify: `bootstrapped/interpreter.ql`(let/参数/重赋值检查;内部 `std.Type.of(...) == "..."` 迁移;函数记录携带参数标注)、`bootstrapped/environment.ql`(绑定携带标注)、`bootstrapped/stdlib.ql`(受保护类型列表)

**Interfaces:**
- Consumes: Task 9/10 的语法与类型库
- Produces: boot 侧与 host 一致的检查行为(两层 difftest 对账)

- [ ] **Step 1: 写失败测试**

```python
# difftest.py SAFE_CASES 追加(host 侧已实现,直接对比):
("t13", 'let x: Number = "a"; isError(x);'),
("t14", 'let x: Number = "a"; x.type;'),
("t15", 'let f = (a: Number) -> a + 1; let r = f("x"); isError(r);'),
("t16", 'let x: Number = 42; x = "a"; isError(x);'),
("t18", 'let x: Error = Error.raise("boom"); x.message;'),
("t19", 'let x: Array(3) = [1, 2]; isError(x);'),
("t20", 'let Positive = std.Type.make((v) -> v > 0); let x: Positive = -5; isError(x);'),
```

Run: `python3 difftest.py`
Expected: t13-t16、t18-t20 FAIL(boot 无检查)或 host/boot 不一致。

- [ ] **Step 2: 迁移 boot 内部 Type.of 字符串比较**

`bootstrapped/interpreter.ql` 中所有 `std.Type.of(...) == "X"` 改为与类型常量比较(72、74、81、207、218、361、367、419、424 行附近,以及 717 行的 `"Null"` 判断):

```qlang
// 例:std.Type.of(v) == "Object"  →  std.Type.of(v) == AnyObject
//     std.Type.of(t) != "String" →  std.Type.of(t) != String
//     std.Type.of(rv) == "Error" →  std.Type.of(rv) == Error
//     std.Type.of(raw) == "Null" →  std.Type.of(raw) == Null
```

- [ ] **Step 3: environment.ql 绑定携带标注**

boot 环境记录加标注映射:`env.annotations`(name → (类型值, 文本)),`defineAnnotated(name, value, ann)`、`getAnnotation(name)`(沿链)、`assign` 保留标注。boot 的 `define` 保持无标注。

- [ ] **Step 4: interpreter.ql——let 检查**

boot 的 let 执行:求值 value → 若有 annotation:求值标注 → 调用 `T.check(v)`(走 boot 的调用路径,内部路径豁免错误值参数——boot 的调用检查函数需加"内部豁免"分支,仅类型检查用)→ truthy 通过(绑定带标注)/ falsy 或 check 出错 → 绑定 TypeCheck 错误值(用 `std.Error.raise("TypeCheck", message, cause)` 构造,message 含标注文本——boot 源码文本从 parser 的 span/位置字段取,若 boot AST 无 span 则用 `"?"`)。

- [ ] **Step 5: interpreter.ql——参数检查**

boot 函数记录(closure 记录)加 `paramTypes`(定义时求值,与 host 一致);boot 调用函数处,参数绑定前逐位检查,失败 → 返回 TypeCheck 错误值(函数体不执行)。curried 路径(boot 的调用函数内)复用同一检查。

- [ ] **Step 6: interpreter.ql——重赋值检查**

boot 的赋值语句:查 `getAnnotation(name)`,有则检查,失败 → 错误值。

- [ ] **Step 7: 受保护成员(boot)**

boot 的字段写入路径:维护内置类型列表(在 interpreter.ql 或 stdlib.ql:`let __protectedTypes = [Number, String, Boolean, Null, AnyArray, AnyObject, Function, Any, Never, Error, Type];`),写入前若对象是其中之一且字段在 `["check", "raise", "of", "make"]` → 产生错误(经 boot 错误通道传播,顶层出口与 host 的异常出口同为"程序出错")。difftest 以 RISKY 用例对账:`("p1", "Number.check = 42;")`——两侧均报错即通过(host 退出码 1 与 boot 退出码 0 的差异走现有 RISKY 归一化)。

- [ ] **Step 8: 运行验证**

Run: `python3 difftest.py`
Expected: t01-t20 全绿;原 126 用例保持绿(除已迁移的 Type.of/Error 语义)。

- [ ] **Step 9: 提交**

```bash
git add -A
git commit -m "feat(boot): annotation checks, Type.of migration, protected members

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 12: 测试与文档收尾

**Files:**
- Modify: `difftest.py`(完整用例集)、`verify_bootstrap.ql`、`fuzzexpr.py`(如需)、`README.md`(类型系统章节)

**Interfaces:**
- Consumes: 全部任务

- [ ] **Step 1: verify_bootstrap.ql 迁移**

运行 `cargo run -- verify_bootstrap.ql`;把所有 `std.Type.of(...) == "X"` 断言与 `Error("msg")` 调用迁移(同 Task 11 Step 2 规则);保持 33 条断言全过。

- [ ] **Step 2: difftest 补全边界用例**

```python
# SAFE_CASES 追加:
("t21", 'let x: AnyArray = [1, "a"]; x;'),
("t22", 'let x: Object(String) = {a: 1}; x;'),
("t23", 'let x: Object(String) = Number; isError(x);'),           # 类型对象不是 Object
("t24", 'let T = 42; let x: T = 5; isError(x);'),                 # 标注不是类型
("t25", 'let Number = 42; let y: Number = 5; isError(y);'),       # 遮蔽
("t26", 'Number.myHelper = 1; Number.myHelper;'),                 # 自由挂载
("t27", 'let U = std.Type.make((v) -> Number.check(v) || String.check(v)); let x: U = 42; x;'),
("t28", 'std.Type.of([1]) == AnyArray;'),
("t29", 'let x = Array(3.5); isError(x);'),                       # 构造器非法形态
("t30", 'let x: Array([Number, String]) = [1, "a"]; x;'),
("t31", 'let f = (a: Number) -> { a = "x"; return a; }; let r = f(1); isError(r);'),
("t32", 'let Bad = std.Type.make((v) -> 1 / 0); let x: Bad = 5; isError(x);'),  # check 出错
("t33", 'let x: Number = Error.raise("boom"); x.cause.type;'),
```

`RISKY_CASES` 追加(受保护成员,两侧均报错即通过):

```python
("p1", "Number.check = 42;"),
```

Run: `python3 difftest.py`
Expected: 全绿;host/boot 一致。

- [ ] **Step 3: fuzzexpr.py 检查**

运行 `python3 fuzzexpr.py`(390 用例)。若预言机或生成器涉及 `Type.of` 字符串语义或 `Error(` 调用,同步迁移;否则保持全绿。

- [ ] **Step 4: README 类型系统章节**

按 spec §1-§6 重写 README 的类型部分:类型即数据(check 谓词)、内置常量表、`std.Type`(check/of/make)、`Error.raise` 迁移说明、标注语法(let/参数/重赋值)、`Array`/`Object` 构造器 union 参数表、联合/自定义/依赖类型的规范写法、TypeCheck 错误语义、遮蔽与受保护成员规则。

- [ ] **Step 5: 全量验证**

Run: `cargo test`、`python3 difftest.py`、`python3 fuzzexpr.py`、`cargo run -- verify_bootstrap.ql`
Expected: 全部通过。

- [ ] **Step 6: 提交**

```bash
git add -A
git commit -m "test: differential cases, verify_bootstrap migration, README type chapter

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## 自审记录

- **Spec 覆盖**:常量表(Task 3/10)、构造器 union 参数(Task 8/10)、检查语义 let/参数/重赋值(Task 4/5/6/11)、TypeCheck 错误值(Task 4)、豁免规则(Task 1/4)、受保护成员(Task 7/11)、Type.of 迁移(Task 7/11)、Error.raise 迁移(Task 3/10/12)、规范写法(文档 Task 12)、未来注记(spec 记录,不实现)。
- **类型一致性**:`CallContext::call` 签名、`check_value` 返回 `Result<bool, Value>`、`check_annotation` 返回 `Result<Value, RuntimeError>`、`param_types: Rc<Vec<Option<(Value, String)>>>`、`get_annotation` 返回 `Option<(Value, String)>`——各任务间一致。
- **已知取舍**:boot 无 AST span,标注文本用 `"?"`(host 用源码切片);构造器闭包内调用用 `Span::new(0,0)`(位置信息缺失,诊断性可接受);boot 的 `Function` 判定对原生函数包装的探测语义以 interpreter.ql 现有分支为准,实现时以 difftest 对账。
