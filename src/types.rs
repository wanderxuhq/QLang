//! Type system: types as data (built-in type objects, std.Type).

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

use crate::environment::{EnvRef, Lookup};
use crate::token::Span;
use crate::value::{CallContext, ErrorValue, NativeFunction, ObjectValue, RuntimeError, Value};

/// Core members of built-in type objects that cannot be overwritten.
pub const PROTECTED_FIELDS: &[&str] = &["check", "raise", "of", "make"];
/// The hidden marker field name of built-in type objects. The lexer never produces NUL-prefixed identifiers, so user code cannot write it.
pub const TYPE_MARKER: &str = "\u{1}type";

/// Is `v` a type value? Built-in types (with the marker) or structural determination (an object with a callable check field).
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

/// Is `v` a built-in (protected) type object?
pub fn is_protected_object(v: &Value) -> bool {
    matches!(v, Value::Object(o) if o.borrow().fields.contains_key(TYPE_MARKER))
}

/// User type object: {check: f} (an ordinary data object, not protected).
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
        accepts_errors: true, // type predicates are diagnostic operations
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

/// Error value for a failed type check (illegal constructor arguments, etc.).
fn arg_error(fn_name: &str, msg: &str) -> Value {
    Value::Error(Rc::new(ErrorValue::new("TypeMismatch", format!("{}: {}", fn_name, msg))))
}

/// Register the built-in type constants (globals) and the merged std.Type (both a module and a type value).
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

    // Error type object: {check: isError, raise: <constructor>} (migrated from the old global Error constructor, stdlib/mod.rs:66-90)
    let error_t = builtin_type("Error", is_error);
    if let Value::Object(obj) = &error_t {
        obj.borrow_mut().fields.insert("raise".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
            name: "Error.raise".to_string(),
            arity: None, // 1 or 2 arguments: (msg) / (msg, cause)
            accepts_errors: true, // the cause argument may be an error value
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

    // std.Type: the type of types + a module. Members: check / of / make. Type : Type is self-referential.
    let type_t = builtin_type("Type", |v| is_type_value(v));
    let (number_c, string_c, boolean_c, null_c) = (number_t.clone(), string_t.clone(), boolean_t.clone(), null_t.clone());
    let (any_array_c, any_object_c, function_c) = (any_array_t.clone(), any_object_t.clone(), function_t.clone());
    let (error_c, type_c) = (error_t.clone(), type_t.clone());
    if let Value::Object(obj) = &type_t {
        let mut fields = obj.borrow_mut();
        fields.fields.insert("of".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
            name: "Type.of".to_string(),
            arity: Some(1),
            accepts_errors: true, // must be able to receive error values (Type.of(err) → Error)
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
    g.define("Error".to_string(), error_t); // overrides the old global constructor

    // std.Type is merged into the std object (replacing the old create_type_module)
    let std_val = match g.lookup("std") {
        Lookup::Value(v) => v,
        _ => panic!("std must be registered"),
    };
    if let Value::Object(std_obj) = std_val {
        std_obj.borrow_mut().fields.insert("Type".to_string(), type_t);
    }
}

/// Register the type constructors Array/Object as global functions.
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

/// Extract the check function value of a type object (type values always have this field).
fn type_check_field(t: &Value) -> Option<Value> {
    if let Value::Object(o) = t {
        o.borrow().fields.get("check").cloned()
    } else {
        None
    }
}

/// Common skeleton of check closures: call the check on every target value; any failure/error → false.
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
    Element(Value),      // the check function
    Tuple(Vec<Value>),   // the check function for each position
}

fn build_array_type(x: &Value) -> Result<Value, RuntimeError> {
    // union member 1: Number (fixed length, arbitrary elements)
    if let Value::Number(n) = x {
        if n.fract() != 0.0 || *n < 0.0 {
            return Ok(arg_error("Array", "length must be a non-negative integer"));
        }
        return Ok(user_type(array_check(ArrayMode::FixedLen(*n as usize))));
    }
    // union member 2: Type (element type)
    if is_type_value(x) {
        let check = type_check_field(x).expect("type value has check");
        return Ok(user_type(array_check(ArrayMode::Element(check))));
    }
    // union member 3: [Type] (per-position types)
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
    // union member 4: {length, element} (metadata combination)
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
                    None => return Ok(Value::Boolean(false)), // missing field
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
    // union member 1: Type (all keys of type T; Object(String) ≡ AnyObject)
    if is_type_value(x) {
        let check = type_check_field(x).expect("type value has check");
        return Ok(user_type(object_check_keys(check)));
    }
    // union member 2: shape object (schema)
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
