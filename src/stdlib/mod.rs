//! Standard library for QLang

use std::rc::Rc;
use std::cell::RefCell;
use std::collections::HashMap;
use std::io::{self};
use crate::value::{Value, ObjectValue, NativeFunction, RuntimeError, ErrorValue};
use crate::environment::EnvRef;
use crate::interpreter::normalize_index;

/// Build an error value for a native-function failure (error-as-value semantics:
/// natives must return error values instead of terminating the program — Task 8).
fn native_error(kind: &str, message: String) -> Value {
    Value::Error(Rc::new(ErrorValue {
        kind: kind.to_string(),
        message,
        line: 0,
        col: 0,
        stack: Vec::new(),
        cause: None,
    }))
}

/// Build a TypeMismatch error value reusing the interpreter.rs message template
/// ("cannot apply {operation} to {left} and {right}"), so host/boot diagnostics agree.
fn type_mismatch_error(operation: &str, left: String, right: String) -> Value {
    native_error("TypeMismatch", format!("cannot apply {} to {} and {}", operation, left, right))
}

/// Register all built-in functions and stdlib
pub fn register_builtins(env: &EnvRef) {
    let mut env_mut = env.borrow_mut();

    // print function
    env_mut.define("print".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "print".to_string(),
        arity: Some(1),
        accepts_errors: true,
        func: Box::new(|_ctx, args| {
            if let Some(value) = args.first() {
                print!("{}", value.to_string());
            }
            Ok(Value::Void)
        }),
    })));
    env_mut.define("println".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "println".to_string(),
        arity: Some(1),
        accepts_errors: true,
        func: Box::new(|_ctx, args| {
            if let Some(value) = args.first() {
                println!("{}", value.to_string());
            }
            Ok(Value::Void)
        }),
    })));

    // isError function
    env_mut.define("isError".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "isError".to_string(),
        arity: Some(1),
        accepts_errors: true,
        func: Box::new(|_ctx, args| {
            Ok(Value::Boolean(matches!(args.first(), Some(Value::Error(_)))))
        }),
    })));

    // debug function
    env_mut.define("debug".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "debug".to_string(),
        arity: Some(1),
        accepts_errors: false,
        func: Box::new(|_ctx, args| {
            if let Some(value) = args.first() {
                eprintln!("[DEBUG] {:?}", value);
            }
            Ok(Value::Void)
        }),
    })));

    // input function - read a line from stdin
    env_mut.define("input".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "input".to_string(),
        arity: Some(0),
        accepts_errors: false,
        func: Box::new(|_ctx, _args| {
            let mut input = String::new();
            match io::stdin().read_line(&mut input) {
                Ok(_) => {
                    if input.ends_with('\n') {
                        input.pop();
                    }
                    if input.ends_with('\r') {
                        input.pop();
                    }
                    Ok(Value::String(input))
                }
                Err(_) => Ok(Value::String(String::new())),
            }
        }),
    })));

    // std object containing all standard library modules
    let std_object = create_std_object();
    env_mut.define("std".to_string(), std_object);
}

/// Create the std object with all modules
fn create_std_object() -> Value {
    let mut fields = HashMap::new();

    // Internal bootstrap ABI, mirrored by the QLang runtime. Invoke the normal
    // dispatcher so native arity and Error policy are not duplicated here.
    fields.insert("__callNative".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "<native call bridge>".to_string(),
        arity: Some(2),
        accepts_errors: true,
        func: Box::new(|ctx, args| {
            let arguments = match &args[1] {
                Value::Array(values) => values.borrow().clone(),
                _ => return Ok(native_error("TypeMismatch", "native call bridge expects Array arguments".to_string())),
            };
            ctx.call(args[0].clone(), arguments, Default::default())
        }),
    })));
    fields.insert("Math".to_string(), create_math_module());
    fields.insert("JSON".to_string(), create_json_module());
    fields.insert("Array".to_string(), create_array_module());
    fields.insert("String".to_string(), create_string_module());
    fields.insert("Number".to_string(), create_number_module());
    fields.insert("Boolean".to_string(), create_boolean_module());
    fields.insert("Object".to_string(), create_object_module());
    fields.insert("Error".to_string(), create_error_module());
    fields.insert("fs".to_string(), create_fs_module());

    Value::Object(Rc::new(RefCell::new(ObjectValue { fields, order: Vec::new() })))
}

/// Create the std.Math module
fn create_math_module() -> Value {
    let mut fields = HashMap::new();

    // Constants
    fields.insert("PI".to_string(), Value::Number(std::f64::consts::PI));
    fields.insert("E".to_string(), Value::Number(std::f64::consts::E));

    // std.Math.abs(n)
    fields.insert("abs".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "Math.abs".to_string(),
        arity: Some(1),
        accepts_errors: false,
        func: Box::new(|_ctx, args| {
            match args.first() {
                Some(Value::Number(n)) => Ok(Value::Number(n.abs())),
                _ => Ok(type_mismatch_error("Math.abs", args.first().map(|v| v.type_name().to_string()).unwrap_or("none".to_string()), "Number".to_string())),
            }
        }),
    })));

    // std.Math.floor(n)
    fields.insert("floor".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "Math.floor".to_string(),
        arity: Some(1),
        accepts_errors: false,
        func: Box::new(|_ctx, args| {
            match args.first() {
                Some(Value::Number(n)) => Ok(Value::Number(n.floor())),
                _ => Ok(type_mismatch_error("Math.floor", args.first().map(|v| v.type_name().to_string()).unwrap_or("none".to_string()), "Number".to_string())),
            }
        }),
    })));

    // std.Math.ceil(n)
    fields.insert("ceil".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "Math.ceil".to_string(),
        arity: Some(1),
        accepts_errors: false,
        func: Box::new(|_ctx, args| {
            match args.first() {
                Some(Value::Number(n)) => Ok(Value::Number(n.ceil())),
                _ => Ok(type_mismatch_error("Math.ceil", args.first().map(|v| v.type_name().to_string()).unwrap_or("none".to_string()), "Number".to_string())),
            }
        }),
    })));

    // std.Math.round(n)
    fields.insert("round".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "Math.round".to_string(),
        arity: Some(1),
        accepts_errors: false,
        func: Box::new(|_ctx, args| {
            match args.first() {
                Some(Value::Number(n)) => Ok(Value::Number(n.round())),
                _ => Ok(type_mismatch_error("Math.round", args.first().map(|v| v.type_name().to_string()).unwrap_or("none".to_string()), "Number".to_string())),
            }
        }),
    })));

    // std.Math.sqrt(n)
    fields.insert("sqrt".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "Math.sqrt".to_string(),
        arity: Some(1),
        accepts_errors: false,
        func: Box::new(|_ctx, args| {
            match args.first() {
                Some(Value::Number(n)) => {
                    if *n >= 0.0 {
                        Ok(Value::Number(n.sqrt()))
                    } else {
                        Ok(type_mismatch_error("Math.sqrt", n.to_string(), "non-negative Number".to_string()))
                    }
                }
                _ => Ok(type_mismatch_error("Math.sqrt", args.first().map(|v| v.type_name().to_string()).unwrap_or("none".to_string()), "Number".to_string())),
            }
        }),
    })));

    // std.Math.pow(base)(exp) - curried
    fields.insert("pow".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "Math.pow".to_string(),
        arity: Some(1),
        accepts_errors: false,
        func: Box::new(|_ctx, args| {
            match args.first() {
                Some(Value::Number(base)) => {
                    let base_val = *base;
                    Ok(Value::NativeFunction(Rc::new(NativeFunction {
                        name: "Math.pow<curried>".to_string(),
                        arity: Some(1),
                        accepts_errors: false,
                        func: Box::new(move |_ctx, inner_args| {
                            match inner_args.first() {
                                Some(Value::Number(exp)) => Ok(Value::Number(base_val.powf(*exp))),
                                _ => Ok(type_mismatch_error("Math.pow", inner_args.first().map(|v| v.type_name().to_string()).unwrap_or("none".to_string()), "Number".to_string())),
                            }
                        }),
                    })))
                }
                _ => Ok(type_mismatch_error("Math.pow", args.first().map(|v| v.type_name().to_string()).unwrap_or("none".to_string()), "Number".to_string())),
            }
        }),
    })));

    // std.Math.max(n1, n2, ...)
    fields.insert("max".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "Math.max".to_string(),
        arity: None,
        accepts_errors: false,
        func: Box::new(|_ctx, args| {
            let mut max_val = f64::NEG_INFINITY;
            for arg in args {
                match arg {
                    Value::Number(n) => {
                        if n.is_nan() || n > max_val || (n == 0.0 && max_val == 0.0 && !n.is_sign_negative()) {
                            max_val = n;
                        }
                    }
                    _ => {
                        return Ok(type_mismatch_error("Math.max", arg.type_name().to_string(), "Number".to_string()));
                    }
                }
            }
            Ok(Value::Number(max_val))
        }),
    })));

    // std.Math.min(n1, n2, ...)
    fields.insert("min".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "Math.min".to_string(),
        arity: None,
        accepts_errors: false,
        func: Box::new(|_ctx, args| {
            let mut min_val = f64::INFINITY;
            for arg in args {
                match arg {
                    Value::Number(n) => {
                        if n.is_nan() || n < min_val || (n == 0.0 && min_val == 0.0 && n.is_sign_negative()) {
                            min_val = n;
                        }
                    }
                    _ => {
                        return Ok(type_mismatch_error("Math.min", arg.type_name().to_string(), "Number".to_string()));
                    }
                }
            }
            Ok(Value::Number(min_val))
        }),
    })));

    // std.Math.random() - returns number between 0 and 1
    fields.insert("random".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "Math.random".to_string(),
        arity: Some(0),
        accepts_errors: false,
        func: Box::new(|_ctx, _args| {
            Ok(Value::Number(rand::random()))
        }),
    })));

    // std.Math.sin(n)
    fields.insert("sin".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "Math.sin".to_string(),
        arity: Some(1),
        accepts_errors: false,
        func: Box::new(|_ctx, args| {
            match args.first() {
                Some(Value::Number(n)) => Ok(Value::Number(n.sin())),
                _ => Ok(type_mismatch_error("Math.sin", args.first().map(|v| v.type_name().to_string()).unwrap_or("none".to_string()), "Number".to_string())),
            }
        }),
    })));

    // std.Math.cos(n)
    fields.insert("cos".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "Math.cos".to_string(),
        arity: Some(1),
        accepts_errors: false,
        func: Box::new(|_ctx, args| {
            match args.first() {
                Some(Value::Number(n)) => Ok(Value::Number(n.cos())),
                _ => Ok(type_mismatch_error("Math.cos", args.first().map(|v| v.type_name().to_string()).unwrap_or("none".to_string()), "Number".to_string())),
            }
        }),
    })));

    // std.Math.trunc(n)
    fields.insert("trunc".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "Math.trunc".to_string(),
        arity: Some(1),
        accepts_errors: false,
        func: Box::new(|_ctx, args| {
            match args.first() {
                Some(Value::Number(n)) => Ok(Value::Number(n.trunc())),
                _ => Ok(type_mismatch_error("Math.trunc", args.first().map(|v| v.type_name().to_string()).unwrap_or("none".to_string()), "Number".to_string())),
            }
        }),
    })));

    Value::Object(Rc::new(RefCell::new(ObjectValue { fields, order: Vec::new() })))
}

/// Create the std.JSON module
fn create_json_module() -> Value {
    let mut fields = HashMap::new();

    // std.JSON.stringify(value)
    fields.insert("stringify".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "JSON.stringify".to_string(),
        arity: Some(1),
        accepts_errors: false,
        func: Box::new(|_ctx, args| {
            match args.first() {
                Some(value) => Ok(match json_stringify(value, 0) {
                    Ok(text) => Value::String(text),
                    Err(()) => native_error("TypeMismatch", "JSON.stringify nesting too deep".to_string()),
                }),
                _ => Ok(Value::String("null".to_string())),
            }
        }),
    })));

    // std.JSON.parse(str)
    fields.insert("parse".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "JSON.parse".to_string(),
        arity: Some(1),
        accepts_errors: false,
        func: Box::new(|_ctx, args| {
            match args.first() {
                Some(Value::String(s)) => json_parse(s),
                _ => Ok(type_mismatch_error("JSON.parse", args.first().map(|v| v.type_name().to_string()).unwrap_or("none".to_string()), "String".to_string())),
            }
        }),
    })));

    Value::Object(Rc::new(RefCell::new(ObjectValue { fields, order: Vec::new() })))
}

/// Convert a QLang value to a JSON string
fn json_stringify(value: &Value, depth: usize) -> Result<String, ()> {
    if depth > 128 { return Err(()); }
    Ok(match value {
        Value::Void => "null".to_string(),
        Value::Boolean(b) => b.to_string(),
        Value::Number(n) => if n.is_finite() { n.to_string() } else { "null".to_string() },
        Value::String(s) => {
            let mut escaped = String::new();
            for c in s.chars() {
                match c {
                    '"' => escaped.push_str("\\\""),
                    '\\' => escaped.push_str("\\\\"),
                    '\n' => escaped.push_str("\\n"),
                    '\r' => escaped.push_str("\\r"),
                    '\t' => escaped.push_str("\\t"),
                    '\u{0000}'..='\u{001f}' => escaped.push_str(&format!("\\u{:04x}", c as u32)),
                    _ => escaped.push(c),
                }
            }
            format!("\"{}\"", escaped)
        }
        Value::Array(arr) => {
            let elements: Vec<String> = arr.borrow().iter()
                .map(|v| json_stringify(v, depth + 1))
                .collect::<Result<Vec<_>, ()>>()?;
            format!("[{}]", elements.join(","))
        }
        Value::Object(obj) => {
            let pairs: Vec<String> = obj.borrow().fields.iter()
                .map(|(k, v)| Ok(format!("{}:{}", json_stringify(&Value::String(k.clone()), depth + 1)?, json_stringify(v, depth + 1)?)))
                .collect::<Result<Vec<_>, ()>>()?;
            format!("{{{}}}", pairs.join(","))
        }
        _ => "null".to_string(),
    })
}

/// Parse JSON with a byte cursor that advances only over ASCII syntax or whole
/// UTF-8 characters. Malformed input is a language error value, never a panic.
fn json_parse(s: &str) -> Result<Value, RuntimeError> {
    let mut parser = JsonParser { source: s, pos: 0 };
    let value = parser.value(0);
    parser.whitespace();
    Ok(match value {
        Some(value) if parser.pos == s.len() => value,
        _ => type_mismatch_error("JSON.parse", s.to_string(), "valid JSON".to_string()),
    })
}

struct JsonParser<'a> {
    source: &'a str,
    pos: usize,
}

impl JsonParser<'_> {
    fn peek(&self) -> Option<u8> {
        self.source.as_bytes().get(self.pos).copied()
    }

    fn consume(&mut self, byte: u8) -> bool {
        if self.peek() == Some(byte) {
            self.pos += 1;
            true
        } else {
            false
        }
    }

    fn whitespace(&mut self) {
        while matches!(self.peek(), Some(b' ' | b'\n' | b'\r' | b'\t')) {
            self.pos += 1;
        }
    }

    fn value(&mut self, depth: usize) -> Option<Value> {
        // Bound recursive descent for untrusted input, including nested arrays.
        if depth > 128 {
            return None;
        }
        self.whitespace();
        match self.peek()? {
            b'"' => self.string().map(Value::String),
            b'{' => {
                self.pos += 1;
                let mut object = ObjectValue::new();
                self.whitespace();
                if !self.consume(b'}') {
                    loop {
                        self.whitespace();
                        let key = self.string()?;
                        self.whitespace();
                        if !self.consume(b':') { return None; }
                        object.insert(key, self.value(depth + 1)?);
                        self.whitespace();
                        if self.consume(b'}') { break; }
                        if !self.consume(b',') { return None; }
                    }
                }
                Some(Value::Object(Rc::new(RefCell::new(object))))
            }
            b'[' => {
                self.pos += 1;
                let mut values = Vec::new();
                self.whitespace();
                if !self.consume(b']') {
                    loop {
                        values.push(self.value(depth + 1)?);
                        self.whitespace();
                        if self.consume(b']') { break; }
                        if !self.consume(b',') { return None; }
                    }
                }
                Some(Value::Array(Rc::new(RefCell::new(values))))
            }
            b'n' => self.literal("null", Value::Void),
            b't' => self.literal("true", Value::Boolean(true)),
            b'f' => self.literal("false", Value::Boolean(false)),
            b'-' | b'0'..=b'9' => self.number(),
            _ => None,
        }
    }

    fn literal(&mut self, text: &str, value: Value) -> Option<Value> {
        if self.source[self.pos..].starts_with(text) {
            self.pos += text.len();
            Some(value)
        } else {
            None
        }
    }

    fn number(&mut self) -> Option<Value> {
        let start = self.pos;
        self.consume(b'-');
        if !self.consume(b'0') {
            if !matches!(self.peek(), Some(b'1'..=b'9')) { return None; }
            while matches!(self.peek(), Some(b'0'..=b'9')) { self.pos += 1; }
        }
        if self.consume(b'.') {
            if !matches!(self.peek(), Some(b'0'..=b'9')) { return None; }
            while matches!(self.peek(), Some(b'0'..=b'9')) { self.pos += 1; }
        }
        if self.consume(b'e') || self.consume(b'E') {
            if !self.consume(b'+') { self.consume(b'-'); }
            if !matches!(self.peek(), Some(b'0'..=b'9')) { return None; }
            while matches!(self.peek(), Some(b'0'..=b'9')) { self.pos += 1; }
        }
        self.source[start..self.pos].parse::<f64>().ok().map(Value::Number)
    }

    fn hex_quad(&mut self) -> Option<u32> {
        let mut value = 0;
        for _ in 0..4 {
            let digit = self.peek()?;
            // Check ASCII before advancing; never leave pos inside a UTF-8 char.
            let n = match digit {
                b'0'..=b'9' => digit - b'0',
                b'a'..=b'f' => digit - b'a' + 10,
                b'A'..=b'F' => digit - b'A' + 10,
                _ => return None,
            };
            self.pos += 1;
            value = value * 16 + u32::from(n);
        }
        Some(value)
    }

    fn string(&mut self) -> Option<String> {
        if !self.consume(b'"') { return None; }
        let mut result = String::new();
        loop {
            let c = self.source[self.pos..].chars().next()?;
            self.pos += c.len_utf8();
            match c {
                '"' => return Some(result),
                '\\' => {
                    let escape = self.source[self.pos..].chars().next()?;
                    self.pos += escape.len_utf8();
                    match escape {
                        '"' | '\\' | '/' => result.push(escape),
                        'b' => result.push('\u{0008}'),
                        'f' => result.push('\u{000c}'),
                        'n' => result.push('\n'),
                        'r' => result.push('\r'),
                        't' => result.push('\t'),
                        'u' => {
                            let mut code = self.hex_quad()?;
                            if (0xd800..=0xdbff).contains(&code) {
                                if !self.consume(b'\\') || !self.consume(b'u') { return None; }
                                let low = self.hex_quad()?;
                                if !(0xdc00..=0xdfff).contains(&low) { return None; }
                                code = 0x10000 + ((code - 0xd800) << 10) + low - 0xdc00;
                            }
                            result.push(char::from_u32(code)?);
                        }
                        _ => return None,
                    }
                }
                '\u{0000}'..='\u{001f}' => return None,
                _ => result.push(c),
            }
        }
    }
}

/// Create the std.Array module
fn create_array_module() -> Value {
    let mut fields = HashMap::new();

    // std.Array.length(arr)
    fields.insert("length".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "Array.length".to_string(),
        arity: Some(1),
        accepts_errors: false,
        func: Box::new(|_ctx, args| {
            match args.first() {
                Some(Value::Array(arr)) => Ok(Value::Number(arr.borrow().len() as f64)),
                _ => Ok(type_mismatch_error("Array.length", args.first().map(|v| v.type_name().to_string()).unwrap_or("none".to_string()), "Array".to_string())),
            }
        }),
    })));

    // std.Array.toString(arr)
    fields.insert("toString".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "Array.toString".to_string(),
        arity: Some(1),
        accepts_errors: false,
        func: Box::new(|_ctx, args| {
            match args.first() {
                Some(Value::Array(arr)) => {
                    let elements: Vec<String> = arr.borrow().iter()
                        .map(|v| v.to_string())
                        .collect();
                    Ok(Value::String(format!("[{}]", elements.join(", "))))
                }
                Some(v) => Ok(Value::String(v.to_string())),
                _ => Ok(Value::String("[]".to_string())),
            }
        }),
    })));

    // std.Array.add(arr)(element) - curried
    fields.insert("add".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "Array.add".to_string(),
        arity: Some(1),
        accepts_errors: false,
        func: Box::new(|_ctx, args| {
            match args.first() {
                Some(Value::Array(arr)) => {
                    let arr_clone = Rc::clone(arr);
                    Ok(Value::NativeFunction(Rc::new(NativeFunction {
                        name: "Array.add<curried>".to_string(),
                        arity: Some(1),
                        accepts_errors: false,
                        func: Box::new(move |_ctx, inner_args| {
                            if let Some(element) = inner_args.first() {
                                arr_clone.borrow_mut().push(element.clone());
                            }
                            Ok(Value::Void)
                        }),
                    })))
                }
                _ => Ok(type_mismatch_error("Array.add", args.first().map(|v| v.type_name().to_string()).unwrap_or("none".to_string()), "Array".to_string()))
                }
        }),
    })));

    // std.Array.remove(arr)(index) - curried
    fields.insert("remove".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "Array.remove".to_string(),
        arity: Some(1),
        accepts_errors: false,
        func: Box::new(|_ctx, args| {
            match args.first() {
                Some(Value::Array(arr)) => {
                    let arr_clone = Rc::clone(arr);
                    Ok(Value::NativeFunction(Rc::new(NativeFunction {
                        name: "Array.remove<curried>".to_string(),
                        arity: Some(1),
                        accepts_errors: false,
                        func: Box::new(move |_ctx, inner_args| {
                            if let Some(Value::Number(idx)) = inner_args.first() {
                                let len = arr_clone.borrow().len();
                                if let Ok(index) = normalize_index(*idx, len) {
                                    arr_clone.borrow_mut().remove(index);
                                }
                            }
                            Ok(Value::Void)
                        }),
                    })))
                }
                _ => Ok(type_mismatch_error("Array.remove", args.first().map(|v| v.type_name().to_string()).unwrap_or("none".to_string()), "Array".to_string()))
                }
        }),
    })));

    // std.Array.push(arr)(element) - curried
    fields.insert("push".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "Array.push".to_string(),
        arity: Some(1),
        accepts_errors: false,
        func: Box::new(|_ctx, args| {
            match args.first() {
                Some(Value::Array(arr)) => {
                    let arr_clone = Rc::clone(arr);
                    Ok(Value::NativeFunction(Rc::new(NativeFunction {
                        name: "Array.push<curried>".to_string(),
                        arity: Some(1),
                        accepts_errors: false,
                        func: Box::new(move |_ctx, inner_args| {
                            if let Some(element) = inner_args.first() {
                                arr_clone.borrow_mut().push(element.clone());
                            }
                            Ok(Value::Number(arr_clone.borrow().len() as f64))
                        }),
                    })))
                }
                _ => Ok(type_mismatch_error("Array.push", args.first().map(|v| v.type_name().to_string()).unwrap_or("none".to_string()), "Array".to_string()))
                }
        }),
    })));

    // std.Array.pop(arr) - curried
    fields.insert("pop".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "Array.pop".to_string(),
        arity: Some(1),
        accepts_errors: false,
        func: Box::new(|_ctx, args| {
            match args.first() {
                Some(Value::Array(arr)) => {
                    let arr_clone = Rc::clone(arr);
                    Ok(Value::NativeFunction(Rc::new(NativeFunction {
                        name: "Array.pop<curried>".to_string(),
                        arity: Some(0),
                        accepts_errors: false,
                        func: Box::new(move |_ctx, _inner_args| {
                            let mut borrowed = arr_clone.borrow_mut();
                            if !borrowed.is_empty() {
                                Ok(borrowed.pop().unwrap_or(Value::Void))
                            } else {
                                Ok(Value::Void)
                            }
                        }),
                    })))
                }
                _ => Ok(type_mismatch_error("Array.pop", args.first().map(|v| v.type_name().to_string()).unwrap_or("none".to_string()), "Array".to_string()))
                }
        }),
    })));

    // std.Array.get(arr)(index) - curried
    fields.insert("get".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "Array.get".to_string(),
        arity: Some(1),
        accepts_errors: false,
        func: Box::new(|_ctx, args| {
            match args.first() {
                Some(Value::Array(arr)) => {
                    let arr_clone = Rc::clone(arr);
                    Ok(Value::NativeFunction(Rc::new(NativeFunction {
                        name: "Array.get<curried>".to_string(),
                        arity: Some(1),
                        accepts_errors: false,
                        func: Box::new(move |_ctx, inner_args| {
                            if let Some(Value::Number(idx)) = inner_args.first() {
                                let len = arr_clone.borrow().len();
                                let index = if *idx < 0.0 {
                                    let neg_idx = -*idx as usize;
                                    if neg_idx > len {
                                        // Negative index out of bounds
                                        return Ok(Value::Void);
                                    }
                                    len - neg_idx
                                } else {
                                    *idx as usize
                                };
                                let borrowed = arr_clone.borrow();
                                if index < borrowed.len() {
                                    Ok(borrowed[index].clone())
                                } else {
                                    Ok(Value::Void)
                                }
                            } else {
                                Ok(Value::Void)
                            }
                        }),
                    })))
                }
                _ => Ok(type_mismatch_error("Array.get", args.first().map(|v| v.type_name().to_string()).unwrap_or("none".to_string()), "Array".to_string()))
                }
        }),
    })));

    // std.Array.indexOf(arr)(value) - curried
    fields.insert("indexOf".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "Array.indexOf".to_string(),
        arity: Some(1),
        accepts_errors: false,
        func: Box::new(|_ctx, args| {
            match args.first() {
                Some(Value::Array(arr)) => {
                    let arr_clone = Rc::clone(arr);
                    Ok(Value::NativeFunction(Rc::new(NativeFunction {
                        name: "Array.indexOf<curried>".to_string(),
                        arity: Some(1),
                        accepts_errors: false,
                        func: Box::new(move |_ctx, inner_args| {
                            let target = inner_args.first().cloned().unwrap_or(Value::Void);
                            let borrowed = arr_clone.borrow();
                            let idx = borrowed.iter().position(|v| v == &target);
                            let result = match idx {
                                Some(i) => i as f64,
                                None => -1.0,
                            };
                            Ok(Value::Number(result))
                        }),
                    })))
                }
                _ => Ok(type_mismatch_error("Array.indexOf", args.first().map(|v| v.type_name().to_string()).unwrap_or("none".to_string()), "Array".to_string()))
                }
        }),
    })));

    // std.Array.includes(arr)(value) - curried
    fields.insert("includes".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "Array.includes".to_string(),
        arity: Some(1),
        accepts_errors: false,
        func: Box::new(|_ctx, args| {
            match args.first() {
                Some(Value::Array(arr)) => {
                    let arr_clone = Rc::clone(arr);
                    Ok(Value::NativeFunction(Rc::new(NativeFunction {
                        name: "Array.includes<curried>".to_string(),
                        arity: Some(1),
                        accepts_errors: false,
                        func: Box::new(move |_ctx, inner_args| {
                            let target = inner_args.first().cloned().unwrap_or(Value::Void);
                            let borrowed = arr_clone.borrow();
                            let found = borrowed.iter().any(|v| v == &target);
                            Ok(Value::Boolean(found))
                        }),
                    })))
                }
                _ => Ok(type_mismatch_error("Array.includes", args.first().map(|v| v.type_name().to_string()).unwrap_or("none".to_string()), "Array".to_string()))
                }
        }),
    })));

    // std.Array.join(arr)(separator) - curried
    fields.insert("join".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "Array.join".to_string(),
        arity: Some(1),
        accepts_errors: false,
        func: Box::new(|_ctx, args| {
            match args.first() {
                Some(Value::Array(arr)) => {
                    let arr_clone = Rc::clone(arr);
                    Ok(Value::NativeFunction(Rc::new(NativeFunction {
                        name: "Array.join<curried>".to_string(),
                        arity: Some(1),
                        accepts_errors: false,
                        func: Box::new(move |_ctx, inner_args| {
                            let separator = match inner_args.first() {
                                Some(Value::String(s)) => s.clone(),
                                _ => ",".to_string(),
                            };
                            let borrowed = arr_clone.borrow();
                            let parts: Vec<String> = borrowed.iter()
                                .map(|v| v.to_string())
                                .collect();
                            Ok(Value::String(parts.join(&separator)))
                        }),
                    })))
                }
                _ => Ok(type_mismatch_error("Array.join", args.first().map(|v| v.type_name().to_string()).unwrap_or("none".to_string()), "Array".to_string()))
                }
        }),
    })));

    // std.Array.reverse(arr) - returns new reversed array
    fields.insert("reverse".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "Array.reverse".to_string(),
        arity: Some(1),
        accepts_errors: false,
        func: Box::new(|_ctx, args| {
            match args.first() {
                Some(Value::Array(arr)) => {
                    let borrowed = arr.borrow();
                    let mut reversed = borrowed.clone();
                    reversed.reverse();
                    Ok(Value::Array(Rc::new(RefCell::new(reversed))))
                }
                _ => Ok(type_mismatch_error("Array.reverse", args.first().map(|v| v.type_name().to_string()).unwrap_or("none".to_string()), "Array".to_string()))
                }
        }),
    })));

    // std.Array.concat(arr1)(arr2) - curried
    fields.insert("concat".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "Array.concat".to_string(),
        arity: Some(1),
        accepts_errors: false,
        func: Box::new(|_ctx, args| {
            match args.first() {
                Some(Value::Array(arr1)) => {
                    let arr1_clone = Rc::clone(arr1);
                    Ok(Value::NativeFunction(Rc::new(NativeFunction {
                        name: "Array.concat<curried>".to_string(),
                        arity: Some(1),
                        accepts_errors: false,
                        func: Box::new(move |_ctx, inner_args| {
                            match inner_args.first() {
                                Some(Value::Array(arr2)) => {
                                    let mut result = arr1_clone.borrow().clone();
                                    result.extend(arr2.borrow().iter().cloned());
                                    Ok(Value::Array(Rc::new(RefCell::new(result))))
                                }
                                _ => Ok(type_mismatch_error("Array.concat", inner_args.first().map(|v| v.type_name().to_string()).unwrap_or("none".to_string()), "Array".to_string()))
                }
                        }),
                    })))
                }
                _ => Ok(type_mismatch_error("Array.concat", args.first().map(|v| v.type_name().to_string()).unwrap_or("none".to_string()), "Array".to_string()))
                }
        }),
    })));

    // std.Array.at(arr, idx) - element access that raises IndexOutOfBounds on
    // out-of-range indices (negative indices wrap, like array indexing). Used by
    // the bootstrapped interpreter to mirror the host's strict index semantics.
    fields.insert("at".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "Array.at".to_string(),
        arity: Some(2),
        accepts_errors: false,
        func: Box::new(|_ctx, args| {
            match (args.first(), args.get(1)) {
                (Some(Value::Array(arr)), Some(Value::Number(n))) => {
                    let len = arr.borrow().len();
                    match normalize_index(*n, len) {
                        Ok(i) => Ok(arr.borrow().get(i).cloned().unwrap_or(Value::Void)),
                        Err(bad) => Ok(native_error("IndexOutOfBounds", format!("index {} out of bounds for length {}", bad, len))),
                    }
                }
                (Some(Value::Array(_)), _) => Ok(type_mismatch_error("Array.at", args.get(1).map(|v| v.type_name().to_string()).unwrap_or("none".to_string()), "Number".to_string())),
                _ => Ok(type_mismatch_error("Array.at", args.first().map(|v| v.type_name().to_string()).unwrap_or("none".to_string()), "Array".to_string())),
            }
        }),
    })));

    Value::Object(Rc::new(RefCell::new(ObjectValue { fields, order: Vec::new() })))
}

/// Create the std.String module
fn create_string_module() -> Value {
    let mut fields = HashMap::new();

    // std.String.length(str) - char count, matching "str".length (Unicode-safe)
    fields.insert("length".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "String.length".to_string(),
        arity: Some(1),
        accepts_errors: false,
        func: Box::new(|_ctx, args| {
            match args.first() {
                Some(Value::String(s)) => Ok(Value::Number(s.chars().count() as f64)),
                _ => Ok(type_mismatch_error("String.length", args.first().map(|v| v.type_name().to_string()).unwrap_or("none".to_string()), "String".to_string()))
                }
        }),
    })));

    // std.String.concat(s1, s2)
    fields.insert("concat".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "String.concat".to_string(),
        arity: Some(2),
        accepts_errors: false,
        func: Box::new(|_ctx, args| {
            match (&args[0], &args[1]) {
                (Value::String(a), Value::String(b)) => Ok(Value::String(format!("{}{}", a, b))),
                _ => Ok(type_mismatch_error("String.concat", args[0].type_name().to_string(), args[1].type_name().to_string())),
            }
        }),
    })));

    // std.String.toString(value)
    fields.insert("toString".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "String.toString".to_string(),
        arity: Some(1),
        accepts_errors: false,
        func: Box::new(|_ctx, args| {
            Ok(Value::String(args.first().map(|v| v.to_string()).unwrap_or_else(|| "null".to_string())))
        }),
    })));

    // std.String.trim(str)
    fields.insert("trim".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "String.trim".to_string(),
        arity: Some(1),
        accepts_errors: false,
        func: Box::new(|_ctx, args| {
            match args.first() {
                Some(Value::String(s)) => Ok(Value::String(s.trim().to_string())),
                _ => Ok(type_mismatch_error("String.trim", args.first().map(|v| v.type_name().to_string()).unwrap_or("none".to_string()), "String".to_string()))
                }
        }),
    })));

    // std.String.toUpperCase(str)
    fields.insert("toUpperCase".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "String.toUpperCase".to_string(),
        arity: Some(1),
        accepts_errors: false,
        func: Box::new(|_ctx, args| {
            match args.first() {
                Some(Value::String(s)) => Ok(Value::String(s.to_uppercase())),
                _ => Ok(type_mismatch_error("String.toUpperCase", args.first().map(|v| v.type_name().to_string()).unwrap_or("none".to_string()), "String".to_string()))
                }
        }),
    })));

    // std.String.toLowerCase(str)
    fields.insert("toLowerCase".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "String.toLowerCase".to_string(),
        arity: Some(1),
        accepts_errors: false,
        func: Box::new(|_ctx, args| {
            match args.first() {
                Some(Value::String(s)) => Ok(Value::String(s.to_lowercase())),
                _ => Ok(type_mismatch_error("String.toLowerCase", args.first().map(|v| v.type_name().to_string()).unwrap_or("none".to_string()), "String".to_string()))
                }
        }),
    })));

    // std.String.includes(str)(substring) - curried
    fields.insert("includes".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "String.includes".to_string(),
        arity: Some(1),
        accepts_errors: false,
        func: Box::new(|_ctx, args| {
            match args.first() {
                Some(Value::String(s)) => {
                    let s_clone = s.clone();
                    Ok(Value::NativeFunction(Rc::new(NativeFunction {
                        name: "String.includes<curried>".to_string(),
                        arity: Some(1),
                        accepts_errors: false,
                        func: Box::new(move |_ctx, inner_args| {
                            if let Some(Value::String(sub)) = inner_args.first() {
                                Ok(Value::Boolean(s_clone.contains(sub)))
                            } else {
                                Ok(Value::Boolean(false))
                            }
                        }),
                    })))
                }
                _ => Ok(type_mismatch_error("String.includes", args.first().map(|v| v.type_name().to_string()).unwrap_or("none".to_string()), "String".to_string()))
                }
        }),
    })));

    // std.String.replace(str)(old)(new) - curried
    fields.insert("replace".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "String.replace".to_string(),
        arity: Some(1),
        accepts_errors: false,
        func: Box::new(|_ctx, args| {
            match args.first() {
                Some(Value::String(s)) => {
                    let s_clone = s.clone();
                    Ok(Value::NativeFunction(Rc::new(NativeFunction {
                        name: "String.replace<curried1>".to_string(),
                        arity: Some(1),
                        accepts_errors: false,
                        func: Box::new(move |_ctx, inner_args| {
                            let s_for_fallback = s_clone.clone();
                            if let Some(Value::String(old)) = inner_args.first() {
                                let old_clone = old.clone();
                                let s_inner = s_clone.clone();
                                Ok(Value::NativeFunction(Rc::new(NativeFunction {
                                    name: "String.replace<curried2>".to_string(),
                                    arity: Some(1),
                                    accepts_errors: false,
                                    func: Box::new(move |_ctx, inner_args2| {
                                        if let Some(Value::String(new)) = inner_args2.first() {
                                            let new_clone = new.clone();
                                            Ok(Value::String(s_inner.replace(&old_clone, &new_clone)))
                                        } else {
                                            Ok(Value::String(s_inner.clone()))
                                        }
                                    }),
                                })))
                            } else {
                                Ok(Value::NativeFunction(Rc::new(NativeFunction {
                                    name: "String.replace<curried1>".to_string(),
                                    arity: Some(1),
                                    accepts_errors: false,
                                    func: Box::new(move |_ctx, _inner_args| {
                                        Ok(Value::String(s_for_fallback.clone()))
                                    }),
                                })))
                            }
                        }),
                    })))
                }
                _ => Ok(type_mismatch_error("String.replace", args.first().map(|v| v.type_name().to_string()).unwrap_or("none".to_string()), "String".to_string()))
                }
        }),
    })));

    // std.String.split(str)(separator) - curried
    fields.insert("split".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "String.split".to_string(),
        arity: Some(1),
        accepts_errors: false,
        func: Box::new(|_ctx, args| {
            match args.first() {
                Some(Value::String(s)) => {
                    let s_clone = s.clone();
                    Ok(Value::NativeFunction(Rc::new(NativeFunction {
                        name: "String.split<curried>".to_string(),
                        arity: Some(1),
                        accepts_errors: false,
                        func: Box::new(move |_ctx, inner_args| {
                            if let Some(Value::String(sep)) = inner_args.first() {
                                let sep_clone = sep.clone();
                                let parts: Vec<Value> = s_clone.split(&sep_clone)
                                    .map(|p| Value::String(p.to_string()))
                                    .collect();
                                Ok(Value::Array(Rc::new(RefCell::new(parts))))
                            } else {
                                Ok(Value::Array(Rc::new(RefCell::new(vec![Value::String(s_clone.clone())]))))
                            }
                        }),
                    })))
                }
                _ => Ok(type_mismatch_error("String.split", args.first().map(|v| v.type_name().to_string()).unwrap_or("none".to_string()), "String".to_string()))
                }
        }),
    })));

    // std.String.repeat(str)(count) - curried
    fields.insert("repeat".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "String.repeat".to_string(),
        arity: Some(1),
        accepts_errors: false,
        func: Box::new(|_ctx, args| {
            match args.first() {
                Some(Value::String(s)) => {
                    let s_clone = s.clone();
                    Ok(Value::NativeFunction(Rc::new(NativeFunction {
                        name: "String.repeat<curried>".to_string(),
                        arity: Some(1),
                        accepts_errors: false,
                        func: Box::new(move |_ctx, inner_args| {
                            if let Some(Value::Number(count)) = inner_args.first() {
                                let count_val = *count;
                                Ok(Value::String(s_clone.repeat(count_val as usize)))
                            } else {
                                Ok(Value::String(s_clone.clone()))
                            }
                        }),
                    })))
                }
                _ => Ok(type_mismatch_error("String.repeat", args.first().map(|v| v.type_name().to_string()).unwrap_or("none".to_string()), "String".to_string()))
                }
        }),
    })));

    // std.String.startsWith(str)(prefix) - curried
    fields.insert("startsWith".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "String.startsWith".to_string(),
        arity: Some(1),
        accepts_errors: false,
        func: Box::new(|_ctx, args| {
            match args.first() {
                Some(Value::String(s)) => {
                    let s_clone = s.clone();
                    Ok(Value::NativeFunction(Rc::new(NativeFunction {
                        name: "String.startsWith<curried>".to_string(),
                        arity: Some(1),
                        accepts_errors: false,
                        func: Box::new(move |_ctx, inner_args| {
                            if let Some(Value::String(prefix)) = inner_args.first() {
                                Ok(Value::Boolean(s_clone.starts_with(prefix)))
                            } else {
                                Ok(Value::Boolean(false))
                            }
                        }),
                    })))
                }
                _ => Ok(type_mismatch_error("String.startsWith", args.first().map(|v| v.type_name().to_string()).unwrap_or("none".to_string()), "String".to_string()))
                }
        }),
    })));

    // std.String.endsWith(str)(suffix) - curried
    fields.insert("endsWith".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "String.endsWith".to_string(),
        arity: Some(1),
        accepts_errors: false,
        func: Box::new(|_ctx, args| {
            match args.first() {
                Some(Value::String(s)) => {
                    let s_clone = s.clone();
                    Ok(Value::NativeFunction(Rc::new(NativeFunction {
                        name: "String.endsWith<curried>".to_string(),
                        arity: Some(1),
                        accepts_errors: false,
                        func: Box::new(move |_ctx, inner_args| {
                            if let Some(Value::String(suffix)) = inner_args.first() {
                                Ok(Value::Boolean(s_clone.ends_with(suffix)))
                            } else {
                                Ok(Value::Boolean(false))
                            }
                        }),
                    })))
                }
                _ => Ok(type_mismatch_error("String.endsWith", args.first().map(|v| v.type_name().to_string()).unwrap_or("none".to_string()), "String".to_string()))
                }
        }),
    })));

    // std.String.join(arr)(separator) - curried
    fields.insert("join".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "String.join".to_string(),
        arity: Some(1),
        accepts_errors: false,
        func: Box::new(|_ctx, args| {
            match args.first() {
                Some(Value::Array(arr)) => {
                    let arr_clone = Rc::clone(arr);
                    Ok(Value::NativeFunction(Rc::new(NativeFunction {
                        name: "String.join<curried>".to_string(),
                        arity: Some(1),
                        accepts_errors: false,
                        func: Box::new(move |_ctx, inner_args| {
                            if let Some(Value::String(sep)) = inner_args.first() {
                                let sep_clone = sep.clone();
                                let elements: Vec<String> = arr_clone.borrow().iter()
                                    .map(|v| v.to_string())
                                    .collect();
                                Ok(Value::String(elements.join(&sep_clone)))
                            } else {
                                Ok(Value::String(String::new()))
                            }
                        }),
                    })))
                }
                _ => Ok(type_mismatch_error("String.join", args.first().map(|v| v.type_name().to_string()).unwrap_or("none".to_string()), "Array".to_string()))
                }
        }),
    })));

    // Unicode scalar indexing, using the same index rules as String.at.
    fields.insert("codePointAt".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "String.codePointAt".to_string(),
        arity: Some(1),
        accepts_errors: false,
        func: Box::new(|_ctx, args| {
            match args.first() {
                Some(Value::String(s)) => {
                    let s = s.clone();
                    Ok(Value::NativeFunction(Rc::new(NativeFunction {
                        name: "String.codePointAt<curried>".to_string(),
                        arity: Some(1),
                        accepts_errors: false,
                        func: Box::new(move |_ctx, args| {
                            match args.first() {
                                Some(Value::Number(n)) => {
                                    let len = s.chars().count();
                                    match normalize_index(*n, len) {
                                        Ok(i) => Ok(Value::Number(s.chars().nth(i).unwrap() as u32 as f64)),
                                        Err(bad) => Ok(native_error("IndexOutOfBounds", format!("index {} out of bounds for length {}", bad, len))),
                                    }
                                }
                                _ => Ok(type_mismatch_error("String.codePointAt", args.first().map(|v| v.type_name().to_string()).unwrap_or("none".to_string()), "Number".to_string())),
                            }
                        }),
                    })))
                }
                _ => Ok(type_mismatch_error("String.codePointAt", args.first().map(|v| v.type_name().to_string()).unwrap_or("none".to_string()), "String".to_string())),
            }
        }),
    })));

    // Inverse of codePointAt: build a String from one Unicode scalar value.
    fields.insert("fromCodePoint".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "String.fromCodePoint".to_string(),
        arity: Some(1),
        accepts_errors: false,
        func: Box::new(|_ctx, args| {
            match args.first() {
                Some(Value::Number(n)) => {
                    match char::from_u32(*n as u32) {
                        Some(c) if n.fract() == 0.0 && *n >= 0.0 && *n <= 0x10FFFF as f64 => Ok(Value::String(c.to_string())),
                        _ => Ok(native_error("RangeError", "String.fromCodePoint expects a Unicode scalar value".to_string())),
                    }
                }
                _ => Ok(type_mismatch_error("String.fromCodePoint", args.first().map(|v| v.type_name().to_string()).unwrap_or("none".to_string()), "Number".to_string())),
            }
        }),
    })));

    // std.String.at(s, idx) - Unicode-safe char access that raises IndexOutOfBounds
    // on out-of-range indices (negative indices wrap, like string indexing). Used by
    // the bootstrapped interpreter to mirror the host's strict index semantics.
    fields.insert("at".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "String.at".to_string(),
        arity: Some(2),
        accepts_errors: false,
        func: Box::new(|_ctx, args| {
            match (args.first(), args.get(1)) {
                (Some(Value::String(s)), Some(Value::Number(n))) => {
                    let chars: Vec<char> = s.chars().collect();
                    let len = chars.len();
                    match normalize_index(*n, len) {
                        Ok(i) => Ok(Value::String(chars[i].to_string())),
                        Err(bad) => Ok(native_error("IndexOutOfBounds", format!("index {} out of bounds for length {}", bad, len))),
                    }
                }
                (Some(Value::String(_)), _) => Ok(type_mismatch_error("String.at", args.get(1).map(|v| v.type_name().to_string()).unwrap_or("none".to_string()), "Number".to_string())),
                _ => Ok(type_mismatch_error("String.at", args.first().map(|v| v.type_name().to_string()).unwrap_or("none".to_string()), "String".to_string())),
            }
        }),
    })));

    Value::Object(Rc::new(RefCell::new(ObjectValue { fields, order: Vec::new() })))
}

/// Mirrors the AOT `ql_number_bits` intrinsic: sign<<63 | exponent<<52 | mantissa.
fn host_number_bits(mantissa: f64, exponent: f64, negative: bool) -> f64 {
    let m = (mantissa as i64 as u64) & 0x000F_FFFF_FFFF_FFFF;
    let e = (exponent as i64 as u64) << 52;
    let s = (negative as u64) << 63;
    f64::from_bits(m | e | s)
}

/// Mirrors the AOT `__math_scale`: m * 2^e with staged subnormal/overflow handling.
fn host_ldexp(m: f64, e: f64) -> f64 {
    if e > 1023.0 { return (m * host_number_bits(0.0, e, false)) * host_number_bits(0.0, 2046.0, false); }
    if e < -1022.0 { return (m * host_number_bits(0.0, e + 1074.0 + 1023.0, false)) * host_number_bits(1.0, 0.0, false); }
    m * host_number_bits(0.0, e + 1023.0, false)
}

/// Create the std.Number module
fn create_number_module() -> Value {
    let mut fields = HashMap::new();

    // std.Number.toString(n)
    fields.insert("toString".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "Number.toString".to_string(),
        arity: Some(1),
        accepts_errors: false,
        func: Box::new(|_ctx, args| {
            Ok(Value::String(args.first().map(|v| v.to_string()).unwrap_or_else(|| "null".to_string())))
        }),
    })));

    // std.Number.isNaN(n)
    fields.insert("isNaN".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "Number.isNaN".to_string(),
        arity: Some(1),
        accepts_errors: false,
        func: Box::new(|_ctx, args| {
            match args.first() {
                Some(Value::Number(n)) => Ok(Value::Boolean(n.is_nan())),
                _ => Ok(Value::Boolean(false)),
            }
        }),
    })));

    // std.Number.isFinite(n)
    fields.insert("isFinite".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "Number.isFinite".to_string(),
        arity: Some(1),
        accepts_errors: false,
        func: Box::new(|_ctx, args| {
            match args.first() {
                Some(Value::Number(n)) => Ok(Value::Boolean(n.is_finite())),
                _ => Ok(Value::Boolean(false)),
            }
        }),
    })));

    // std.Number.parseFloat(s)
    fields.insert("parseFloat".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "Number.parseFloat".to_string(),
        arity: Some(1),
        accepts_errors: false,
        func: Box::new(|_ctx, args| {
            match args.first() {
                Some(Value::String(s)) => {
                    match s.trim().parse::<f64>() {
                        Ok(n) => Ok(Value::Number(n)),
                        Err(_) => Ok(Value::Number(std::f64::NAN)),
                    }
                }
                _ => Ok(Value::Number(std::f64::NAN)),
            }
        }),
    })));

    // std.Number.frexp(x) -> [mantissa, exponent] with x = mantissa * 2^exponent
    // and the mantissa in [1,2). Representation-only mechanism matching the AOT
    // runtime; every Math algorithm that uses it lives in the shared library.
    fields.insert("frexp".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "Number.frexp".to_string(),
        arity: Some(1),
        accepts_errors: false,
        func: Box::new(|_ctx, args| {
            match args.first() {
                Some(Value::Number(x)) => {
                    let x = *x;
                    if x == 0.0 || !x.is_finite() {
                        return Ok(Value::Array(Rc::new(RefCell::new(vec![Value::Number(x), Value::Number(0.0)]))));
                    }
                    let mut m = x.abs();
                    let mut e = 0i32;
                    while m >= 2.0 { m /= 2.0; e += 1; }
                    while m < 1.0 { m *= 2.0; e -= 1; }
                    if x < 0.0 { m = -m; }
                    Ok(Value::Array(Rc::new(RefCell::new(vec![Value::Number(m), Value::Number(e as f64)]))))
                }
                _ => Ok(type_mismatch_error("Number.frexp", args.first().map(|v| v.type_name().to_string()).unwrap_or("none".to_string()), "Number".to_string())),
            }
        }),
    })));

    // std.Number.ldexp(m)(e) -> m * 2^e, staged to avoid premature over/underflow.
    fields.insert("ldexp".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "Number.ldexp".to_string(),
        arity: Some(1),
        accepts_errors: false,
        func: Box::new(|_ctx, args| {
            match args.first() {
                Some(Value::Number(m)) => {
                    let m = *m;
                    Ok(Value::NativeFunction(Rc::new(NativeFunction {
                        name: "Number.ldexp<curried>".to_string(),
                        arity: Some(1),
                        accepts_errors: false,
                        func: Box::new(move |_ctx, args| {
                            match args.first() {
                                Some(Value::Number(e)) => Ok(Value::Number(host_ldexp(m, *e))),
                                _ => Ok(type_mismatch_error("Number.ldexp", args.first().map(|v| v.type_name().to_string()).unwrap_or("none".to_string()), "Number".to_string())),
                            }
                        }),
                    })))
                }
                _ => Ok(type_mismatch_error("Number.ldexp", args.first().map(|v| v.type_name().to_string()).unwrap_or("none".to_string()), "Number".to_string())),
            }
        }),
    })));

    Value::Object(Rc::new(RefCell::new(ObjectValue { fields, order: Vec::new() })))
}

/// Create the std.Boolean module
fn create_boolean_module() -> Value {
    let mut fields = HashMap::new();

    // std.Boolean.toString(b)
    fields.insert("toString".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "Boolean.toString".to_string(),
        arity: Some(1),
        accepts_errors: false,
        func: Box::new(|_ctx, args| {
            match args.first() {
                Some(Value::Boolean(b)) => Ok(Value::String(b.to_string())),
                Some(other) => Ok(Value::String(other.to_string())),
                _ => Ok(Value::String("false".to_string())),
            }
        }),
    })));

    Value::Object(Rc::new(RefCell::new(ObjectValue { fields, order: Vec::new() })))
}

/// Create the std.Object module
fn create_object_module() -> Value {
    let mut fields = HashMap::new();

    // std.Object.keys(obj)
    fields.insert("keys".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "Object.keys".to_string(),
        arity: Some(1),
        accepts_errors: false,
        func: Box::new(|_ctx, args| {
            match args.first() {
                Some(Value::Object(obj)) => {
                    let keys: Vec<Value> = obj.borrow().key_order()
                        .into_iter()
                        .filter(|k| k != crate::types::TYPE_MARKER)
                        .map(Value::String)
                        .collect();
                    Ok(Value::Array(Rc::new(RefCell::new(keys))))
                }
                _ => Ok(type_mismatch_error("Object.keys", args.first().map(|v| v.type_name().to_string()).unwrap_or("none".to_string()), "Object".to_string()))
                }
        }),
    })));

    // std.Object.values(obj)
    fields.insert("values".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "Object.values".to_string(),
        arity: Some(1),
        accepts_errors: false,
        func: Box::new(|_ctx, args| {
            match args.first() {
                Some(Value::Object(obj)) => {
                    let values: Vec<Value> = obj.borrow().key_order()
                        .into_iter()
                        .filter(|k| k != crate::types::TYPE_MARKER)
                        .filter_map(|k| obj.borrow().fields.get(&k).cloned())
                        .collect();
                    Ok(Value::Array(Rc::new(RefCell::new(values))))
                }
                _ => Ok(type_mismatch_error("Object.values", args.first().map(|v| v.type_name().to_string()).unwrap_or("none".to_string()), "Object".to_string()))
                }
        }),
    })));

    // std.Object.merge(obj1)(obj2) - curried
    fields.insert("merge".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "Object.merge".to_string(),
        arity: Some(1),
        accepts_errors: false,
        func: Box::new(|_ctx, args| {
            match args.first() {
                Some(Value::Object(obj1)) => {
                    let obj1_clone = Rc::clone(obj1);
                    Ok(Value::NativeFunction(Rc::new(NativeFunction {
                        name: "Object.merge<curried>".to_string(),
                        arity: Some(1),
                        accepts_errors: false,
                        func: Box::new(move |_ctx, inner_args| {
                            match inner_args.first() {
                                Some(Value::Object(obj2)) => {
                                    let mut merged = obj1_clone.borrow().clone();
                                    merged.remove(crate::types::TYPE_MARKER);
                                    for k in obj2.borrow().key_order() {
                                        if k != crate::types::TYPE_MARKER {
                                            if let Some(v) = obj2.borrow().fields.get(&k) {
                                                merged.insert(k, v.clone());
                                            }
                                        }
                                    }
                                    Ok(Value::Object(Rc::new(RefCell::new(merged))))
                                }
                                _ => Ok(type_mismatch_error("Object.merge", "Object".to_string(), inner_args.first().map(|v| v.type_name().to_string()).unwrap_or("none".to_string()))),
                            }
                        }),
                    })))
                }
                _ => Ok(type_mismatch_error("Object.merge", args.first().map(|v| v.type_name().to_string()).unwrap_or("none".to_string()), "Object".to_string()))
                }
        }),
    })));

    // std.Object.hasOwn(obj)(key) - curried
    fields.insert("hasOwn".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "Object.hasOwn".to_string(),
        arity: Some(1),
        accepts_errors: false,
        func: Box::new(|_ctx, args| {
            match args.first() {
                Some(Value::Object(obj)) => {
                    let obj_clone = Rc::clone(obj);
                    Ok(Value::NativeFunction(Rc::new(NativeFunction {
                        name: "Object.hasOwn<curried>".to_string(),
                        arity: Some(1),
                        accepts_errors: false,
                        func: Box::new(move |_ctx, inner_args| {
                            if let Some(Value::String(key)) = inner_args.first() {
                                let has = obj_clone.borrow().fields.contains_key(key);
                                Ok(Value::Boolean(has))
                            } else {
                                Ok(Value::Boolean(false))
                            }
                        }),
                    })))
                }
                _ => Ok(type_mismatch_error("Object.hasOwn", args.first().map(|v| v.type_name().to_string()).unwrap_or("none".to_string()), "Object".to_string()))
                }
        }),
    })));

    // std.Object.get(obj)(key) - curried
    fields.insert("get".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "Object.get".to_string(),
        arity: Some(1),
        accepts_errors: false,
        func: Box::new(|_ctx, args| {
            match args.first() {
                Some(Value::Object(obj)) => {
                    let obj_clone = Rc::clone(obj);
                    Ok(Value::NativeFunction(Rc::new(NativeFunction {
                        name: "Object.get<curried>".to_string(),
                        arity: Some(1),
                        accepts_errors: false,
                        func: Box::new(move |_ctx, inner_args| {
                            if let Some(Value::String(key)) = inner_args.first() {
                                if let Some(val) = obj_clone.borrow().fields.get(key) {
                                    Ok(val.clone())
                                } else {
                                    Ok(Value::Void)
                                }
                            } else {
                                Ok(Value::Void)
                            }
                        }),
                    })))
                }
                _ => Ok(type_mismatch_error("Object.get", args.first().map(|v| v.type_name().to_string()).unwrap_or("none".to_string()), "Object".to_string()))
                }
        }),
    })));

    // std.Object.field(obj, name) - field access that raises UndefinedField when the
    // field is missing (strict semantics for obj.x; obj["x"] probing stays null-tolerant).
    // Used by the bootstrapped interpreter to mirror the host's strict field semantics.
    fields.insert("field".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "Object.field".to_string(),
        arity: Some(2),
        accepts_errors: false,
        func: Box::new(|_ctx, args| {
            match (args.first(), args.get(1)) {
                (Some(Value::Object(obj)), Some(Value::String(name))) => {
                    Ok(obj.borrow().fields.get(name)
                        .cloned()
                        .unwrap_or_else(|| native_error("UndefinedField", format!("Undefined field: {}", name))))
                }
                (Some(Value::Object(_)), _) => Ok(type_mismatch_error("Object.field", args.get(1).map(|v| v.type_name().to_string()).unwrap_or("none".to_string()), "String".to_string())),
                _ => Ok(type_mismatch_error("Object.field", args.first().map(|v| v.type_name().to_string()).unwrap_or("none".to_string()), "Object".to_string())),
            }
        }),
    })));

    Value::Object(Rc::new(RefCell::new(ObjectValue { fields, order: Vec::new() })))
}

/// Create the std.Error module
fn create_error_module() -> Value {
    Value::Object(Rc::new(RefCell::new(ObjectValue {
        fields: {
            let mut fields = std::collections::HashMap::new();
            fields.insert("raise".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
                name: "Error.raise".to_string(),
                arity: Some(3),
                accepts_errors: true,
                func: Box::new(|_ctx, args| {
                    let kind = args.get(0).map(|v| match v { Value::String(s) => s.clone(), _ => "Error".to_string() }).unwrap_or_else(|| "Error".to_string());
                    let message = args.get(1).map(|v| match v { Value::String(s) => s.clone(), v => v.to_string() }).unwrap_or_default();
                    let cause = match args.get(2) { Some(Value::Error(e)) => Some(Rc::clone(e)), _ => None };
                    Ok(Value::Error(Rc::new(ErrorValue { kind, message, line: 0, col: 0, stack: Vec::new(), cause })))
                }),
            })));
            // std.Error.toString(err) - diagnostic text WITHOUT positions (kind +
            // message + cause chain), used by the boot's top-level exit and by the
            // difftest error normalization (positions differ between host and boot).
            fields.insert("toString".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
                name: "Error.toString".to_string(),
                arity: Some(1),
                accepts_errors: true,
                func: Box::new(|_ctx, args| match args.first() {
                    Some(Value::Error(e)) => {
                        let mut out = format!("{}: {}", e.kind, e.message);
                        let mut cause = e.cause.as_ref();
                        while let Some(c) = cause {
                            out.push_str(&format!("\n  └─ caused by: {}: {}", c.kind, c.message));
                            cause = c.cause.as_ref();
                        }
                        Ok(Value::String(out))
                    }
                    _ => Ok(Value::String("not an error".to_string())),
                }),
            })));
            fields
        },
        order: Vec::new(),
    })))
}

/// Create the std.fs module
fn create_fs_module() -> Value {
    let mut fields = HashMap::new();

    // Compile-time and interpreter module loaders share canonical path identity.
    fields.insert("canonicalPath".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "fs.canonicalPath".to_string(), arity: Some(1), accepts_errors: false,
        func: Box::new(|_ctx, args| match args.first() {
            Some(Value::String(path)) => match std::fs::canonicalize(path) {
                Ok(path) => Ok(Value::String(path.to_string_lossy().into_owned())),
                Err(e) => Ok(native_error("IOError", format!("cannot resolve {}: {}", path, e))),
            },
            _ => Ok(native_error("TypeMismatch", "path must be a string".into())),
        }),
    })));

    // std.fs.readFileText(path)
    fields.insert("readFileText".to_string(), Value::NativeFunction(Rc::new(NativeFunction {
        name: "fs.readFileText".to_string(),
        arity: Some(1),
        accepts_errors: false,
        func: Box::new(|_ctx, args| {
            match args.first() {
                Some(Value::String(path)) => {
                    match std::fs::read_to_string(path) {
                        Ok(content) => Ok(Value::String(content)),
                        Err(e) => Ok(native_error("IOError", format!("cannot read {}: {}", path, e))),
                    }
                }
                _ => Ok(native_error("TypeMismatch", "path must be a string".into())),
            }
        }),
    })));

    Value::Object(Rc::new(RefCell::new(ObjectValue { fields, order: Vec::new() })))
}
