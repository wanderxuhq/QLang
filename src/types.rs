//! Type system: types as data (built-in type objects, std.Type).

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

use crate::environment::EnvRef;
use crate::token::Span;
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
        fields.fields.insert("of".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
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
        fields.fields.insert("make".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
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
            let length = match fields.fields.get("length") {
                Some(Value::Number(n)) if n.fract() == 0.0 && *n >= 0.0 => *n as usize,
                _ => return Ok(arg_error("Array", "metadata must have a non-negative integer 'length'")),
            };
            let element = match fields.fields.get("element") {
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
                return Ok(arg_error("Object", &format!("schema field '{}' is not a type value", k)));
            }
            schema.push((k.clone(), type_check_field(v).expect("type value has check")));
        }
        return Ok(user_type(object_check_schema(schema)));
    }
    Ok(arg_error("Object", "argument must be a type (keys) or a shape object (schema)"))
}
