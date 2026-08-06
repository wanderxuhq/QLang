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
