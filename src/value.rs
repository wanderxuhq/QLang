//! Runtime value types for QLang

use std::rc::Rc;
use std::cell::RefCell;
use std::collections::HashMap;
use crate::ast::{Block, Parameter};
use crate::token::Span;
use crate::environment::EnvRef;

/// A stack frame recording where a function call happened
#[derive(Debug, Clone)]
pub struct StackFrame {
    pub fn_name: String,
    pub line: usize,
    pub col: usize,
}

/// An error value (Result style: errors are values, not terminations)
#[derive(Debug, Clone)]
pub struct ErrorValue {
    pub kind: String,
    pub message: String,
    pub line: usize,
    pub col: usize,
    pub stack: Vec<StackFrame>,
    pub cause: Option<Rc<ErrorValue>>,
}

impl ErrorValue {
    pub fn new(kind: &str, message: String) -> Self {
        ErrorValue { kind: kind.to_string(), message, line: 0, col: 0, stack: Vec::new(), cause: None }
    }
}

impl std::fmt::Display for ErrorValue {
    /// Renders `<kind>: <message> (at line <L>, col <C>)` plus the `└─ caused by:` chain.
    /// Mirrors the ErrorValue portion of `Value::to_string` / `error_diag`.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {} (at line {}, col {})", self.kind, self.message, self.line, self.col)?;
        let mut cause = self.cause.as_ref();
        while let Some(c) = cause {
            write!(f, "\n  └─ caused by: {}: {} (at line {}, col {})", c.kind, c.message, c.line, c.col)?;
            cause = c.cause.as_ref();
        }
        Ok(())
    }
}

/// Runtime value
#[derive(Debug, Clone)]
pub enum Value {
    Void,
    Number(f64),
    String(String),
    Boolean(bool),
    Array(Rc<RefCell<Vec<Value>>>),
    Object(Rc<RefCell<ObjectValue>>),
    Function(Rc<FunctionValue>),
    NativeFunction(Rc<NativeFunction>),
    Error(Rc<ErrorValue>),
}

/// Object value (hash map of fields)
#[derive(Debug, Clone)]
pub struct ObjectValue {
    pub fields: HashMap<String, Value>,
}

impl ObjectValue {
    pub fn new() -> Self {
        ObjectValue {
            fields: HashMap::new(),
        }
    }

    pub fn clone(&self) -> Self {
        ObjectValue {
            fields: self.fields.clone(),
        }
    }
}

/// User-defined function value
///
/// parameters/body are held via Rc (shared with the AST's FunctionExpr);
/// creating or copying a function value only clones the Rc, without deep-copying the function body AST.
#[derive(Debug, Clone)]
pub struct FunctionValue {
    pub parameters: Rc<Vec<Parameter>>,
    pub body: Rc<Block>,
    pub closure: EnvRef,
}

/// Native function
pub struct NativeFunction {
    pub name: String,
    pub arity: Option<usize>,
    pub func: Box<dyn Fn(Vec<Value>) -> Result<Value, RuntimeError> + 'static>,
}

impl NativeFunction {
    pub fn new(name: String, arity: Option<usize>, func: Box<dyn Fn(Vec<Value>) -> Result<Value, RuntimeError> + 'static>) -> Self {
        NativeFunction { name, arity, func }
    }
}

impl std::fmt::Debug for NativeFunction {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "NativeFunction({})", self.name)
    }
}

impl Clone for NativeFunction {
    fn clone(&self) -> Self {
        // Note: We can't actually clone the function, so we create a wrapper
        // This is a limitation - native functions shouldn't be cloned
        NativeFunction {
            name: self.name.clone(),
            arity: self.arity,
            func: Box::new(move |_args| Err(RuntimeError::NotCallable("cloned native function".to_string()))),
        }
    }
}

impl PartialEq for NativeFunction {
    fn eq(&self, _other: &Self) -> bool {
        false // Native functions are compared by identity
    }
}

impl PartialEq for Value {
    fn eq(&self, other: &Self) -> bool {
        match (self, other) {
            (Value::Void, Value::Void) => true,
            (Value::Number(a), Value::Number(b)) => a == b,
            (Value::String(a), Value::String(b)) => a == b,
            (Value::Boolean(a), Value::Boolean(b)) => a == b,
            (Value::Array(a), Value::Array(b)) => {
                let a_borrow = a.borrow();
                let b_borrow = b.borrow();
                if a_borrow.len() != b_borrow.len() {
                    return false;
                }
                a_borrow.iter().zip(b_borrow.iter()).all(|(a, b)| a == b)
            }
            (Value::Object(a), Value::Object(b)) => {
                let a_borrow = a.borrow();
                let b_borrow = b.borrow();
                if a_borrow.fields.len() != b_borrow.fields.len() {
                    return false;
                }
                a_borrow.fields.iter().all(|(k, v)| {
                    b_borrow.fields.get(k).map(|ov| v == ov).unwrap_or(false)
                })
            }
            // Functions are compared by identity (pointer equality)
            (Value::Function(a), Value::Function(b)) => Rc::ptr_eq(a, b),
            (Value::NativeFunction(a), Value::NativeFunction(b)) => Rc::ptr_eq(a, b),
            // Errors are compared by identity (pointer equality)
            (Value::Error(a), Value::Error(b)) => Rc::ptr_eq(a, b),
            (Value::Error(_), _) | (_, Value::Error(_)) => false,
            // Function types never equal non-function types
            (Value::Function(_), _) | (Value::NativeFunction(_), _) => false,
            (_, Value::Function(_)) | (_, Value::NativeFunction(_)) => false,
            _ => false,
        }
    }
}

impl Value {
    /// Get the type name of this value
    pub fn type_name(&self) -> &'static str {
        match self {
            Value::Void => "Void",
            Value::Number(_) => "Number",
            Value::String(_) => "String",
            Value::Boolean(_) => "Boolean",
            Value::Array(_) => "Array",
            Value::Object(_) => "Object",
            Value::Function(_) => "Function",
            Value::NativeFunction(_) => "Function",
            Value::Error(_) => "Error",
        }
    }

    /// Check if value is truthy
    pub fn is_truthy(&self) -> bool {
        match self {
            Value::Void => false,
            Value::Boolean(b) => *b,
            Value::Number(n) => *n != 0.0,
            Value::String(s) => !s.is_empty(),
            Value::Array(arr) => !arr.borrow().is_empty(),
            Value::Object(_) => true,
            Value::Function(_) => true,
            Value::NativeFunction(_) => true,
            Value::Error(_) => true,
        }
    }

    /// Convert to string representation
    pub fn to_string(&self) -> String {
        match self {
            Value::Void => "void".to_string(),
            Value::Number(n) => {
                // Non-finite numbers (NaN/Infinity) and numbers beyond i64's safe
                // range are left to Rust's f64 Display (producing NaN / inf / -inf / 1e30, etc.).
                // The integer fast path is limited to 1e15 so that f64 can represent them exactly.
                if n.is_finite() && n.fract() == 0.0 && n.abs() < 1e15 {
                    format!("{}", *n as i64)
                } else {
                    n.to_string()
                }
            }
            Value::String(s) => s.clone(),
            Value::Boolean(b) => b.to_string(),
            Value::Array(arr) => {
                let elements: Vec<String> = arr.borrow().iter()
                    .map(|v| v.to_string())
                    .collect();
                format!("[{}]", elements.join(", "))
            }
            Value::Object(obj) => {
                let fields: Vec<String> = obj.borrow().fields.iter()
                    .map(|(k, v)| format!("{}: {}", k, v.to_string()))
                    .collect();
                format!("{{{}}}", fields.join(", "))
            }
            Value::Function(_) => "<function>".to_string(),
            Value::NativeFunction(f) => format!("<native fn {}>", f.name),
            Value::Error(err) => {
                let mut out = format!("{}: {} (at line {}, col {})", err.kind, err.message, err.line, err.col);
                let mut cause = err.cause.as_ref();
                while let Some(c) = cause {
                    out.push_str(&format!("\n  └─ caused by: {}: {} (at line {}, col {})", c.kind, c.message, c.line, c.col));
                    cause = c.cause.as_ref();
                }
                out
            }
        }
    }

    /// Returns the error kind if this is an Error value
    pub fn err_kind(&self) -> Option<&str> {
        match self {
            Value::Error(e) => Some(&e.kind),
            _ => None,
        }
    }
}

pub fn is_error_value(v: &Value) -> bool {
    matches!(v, Value::Error(_))
}

/// Runtime error
#[derive(Debug, thiserror::Error)]
pub enum RuntimeError {
    #[error("Undefined variable: {0}")]
    UndefinedVariable(String),

    #[error("Undefined field: {0}")]
    UndefinedField(String),

    #[error("Type mismatch: cannot apply {operation} to {left} and {right}")]
    TypeMismatch {
        operation: String,
        left: String,
        right: String,
        span: Option<Span>,
    },

    #[error("Not callable: {0}")]
    NotCallable(String),

    #[error("Arity mismatch: expected {expected} arguments, got {got}")]
    ArityMismatch { expected: usize, got: usize },

    #[error("Cannot index into {0}")]
    CannotIndex(String),

    #[error("Index out of bounds: {0}")]
    IndexOutOfBounds(usize),

    #[error("Not an object: {0}")]
    NotAnObject(String),

    #[error("IO error: {0}")]
    IoError(String),

    #[error("Division by zero")]
    DivisionByZero,

    #[error("Not implemented: {0}")]
    NotImplemented(String),

    #[error("Stack overflow: maximum recursion depth exceeded")]
    StackOverflow,

    /// Internal propagation signal for the postfix `?` operator.
    /// Caught at function-call boundaries and the top level; never user-visible.
    #[error("user error: {0}")]
    UserError(Rc<ErrorValue>),
}

// Re-export for convenience
pub use self::RuntimeError as Error;
