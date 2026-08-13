//! Interpreter for QLang - executes AST

use std::path::Path;
use std::fs;
use std::rc::Rc;
use std::cell::RefCell;
use std::collections::HashMap;
use std::borrow::Cow;

use crate::ast::*;
use crate::lexer::Lexer;
use crate::parser::Parser;
use crate::token::Span;
use crate::value::{Value, ObjectValue, FunctionValue, NativeFunction, CallContext, RuntimeError, ErrorValue, StackFrame, is_error_value};
use crate::environment::{EnvRef, Lookup, new_env, child_env};
use crate::stdlib::register_builtins;

/// Full diagnostic text for an error value, including cause chain and stack frames
///
/// Format matches the ErrorValue to_string rendering (`<kind>: <message> (at line <L>, col <C>)`
/// with a `└─ caused by:` chain), plus one `    at <fn> (line <L>, col <C>)` line per stack frame.
/// Intended for top-level exits; Task 5 wires it into the runtime error path.
pub fn error_diag(err: &ErrorValue) -> String {
    let mut out = format!("{}: {} (at line {}, col {})", err.kind, err.message, err.line, err.col);
    let mut cause = err.cause.as_ref();
    while let Some(c) = cause {
        out.push_str(&format!("\n  └─ caused by: {}: {} (at line {}, col {})", c.kind, c.message, c.line, c.col));
        cause = c.cause.as_ref();
    }
    for f in &err.stack {
        out.push_str(&format!("\n    at {} (line {}, col {})", f.fn_name, f.line, f.col));
    }
    out
}

/// Control flow signal from statements
#[derive(Debug, Clone)]
pub enum ControlFlow {
    None,
    Return(Value),
    Value(Value),
}

/// The operation word used in TypeMismatch error messages, matching the
/// operation words of the `add_values`/`numeric_op`/`comparison_op`/`bitwise_op`
/// helpers ("cannot apply addition to Number and String", ...). And/Or have no
/// existing template word, so they use "logical operation".
fn op_word(op: BinaryOp) -> &'static str {
    match op {
        BinaryOp::Add => "addition",
        BinaryOp::Sub | BinaryOp::Mul | BinaryOp::Div | BinaryOp::Mod => "numeric operation",
        BinaryOp::Lt | BinaryOp::LtEq | BinaryOp::Gt | BinaryOp::GtEq => "comparison",
        BinaryOp::Eq | BinaryOp::NotEq => "comparison",
        BinaryOp::BitwiseAnd | BinaryOp::BitwiseOr | BinaryOp::BitwiseXor => "bitwise operation",
        BinaryOp::And | BinaryOp::Or => "logical operation",
        BinaryOp::Coalesce => "coalesce", // never used: `??` is handled before the operation zone
    }
}

/// The error value among the operands, if any (the cause of a new error value)
fn error_cause(v: &Value) -> Option<Rc<ErrorValue>> {
    match v {
        Value::Error(e) => Some(Rc::clone(e)),
        _ => None,
    }
}

/// Maximum recursion call depth, preventing deep user recursion from blowing the host stack.
/// Each QLang call consumes several KB of Rust stack (multi-frame evaluator);
/// 1000 levels have been measured to overflow the 8MB main-thread stack, so keep a safe margin.
const MAX_RECURSION_DEPTH: usize = 300;

/// Interpreter that executes QLang programs
pub struct Interpreter {
    pub global_env: EnvRef,
    call_stack: Vec<CallFrame>,
    exports: HashMap<String, Value>,
    recursion_depth: usize,
    /// Source text of the program currently being executed; used by `line_col`
    /// to convert byte offsets into 1-based (line, col) positions (Task 5 uses it).
    current_source: String,
}

#[derive(Debug, Clone)]
struct CallFrame {
    path: Cow<'static, str>,
    position: usize,
}

impl Interpreter {
    /// Create a new interpreter with built-in functions
    pub fn new() -> Self {
        let global_env = new_env();
        register_builtins(&global_env);
        crate::types::register_type_system(&global_env);
        crate::types::register_constructors(&global_env);
        // JSON5 number literals: Infinity / NaN predefined as globals (shadowable via let, matching JS)
        global_env.borrow_mut().define("Infinity".to_string(), Value::Number(f64::INFINITY));
        global_env.borrow_mut().define("NaN".to_string(), Value::Number(f64::NAN));

        Interpreter {
            global_env,
            call_stack: Vec::new(),
            exports: HashMap::new(),
            recursion_depth: 0,
            current_source: String::new(),
        }
    }

    /// Set script command-line arguments (defined as the global `args` array)
    ///
    /// Scripts access them via `args[0]` and `args.length`;
    /// when unset, `args` is an empty array.
    pub fn set_args(&mut self, args: &[String]) {
        let values = args.iter()
            .map(|s| Value::String(s.clone()))
            .collect::<Vec<_>>();
        self.global_env.borrow_mut()
            .define("args".to_string(), Value::Array(Rc::new(RefCell::new(values))));
    }

    /// Run a source file
    pub fn run_file(&mut self, path: &Path) -> Result<Value, RuntimeError> {
        let source = fs::read_to_string(path)
            .map_err(|e| RuntimeError::IoError(e.to_string()))?;

        self.run_source(&source, path.to_string_lossy().to_string())
    }

    /// Run source code
    pub fn run_source(&mut self, source: &str, path: String) -> Result<Value, RuntimeError> {
        self.current_source = source.to_string();

        let tokens = Lexer::new(source).tokenize()
            .map_err(|e| RuntimeError::NotImplemented(format!("{:?}", e)))?;

        let ast = Parser::new(tokens, source.to_string()).parse()
            .map_err(|e| RuntimeError::NotImplemented(format!("{:?}", e)))?;

        self.run_program(&ast, path)
    }

    /// Run a program
    pub fn run_program(&mut self, program: &Program, path: String) -> Result<Value, RuntimeError> {
        self.call_stack.push(CallFrame { path: Cow::Owned(path), position: 0 });
        let result = self.run_statements(&program.statements, &self.global_env.clone());
        self.call_stack.pop();
        match result {
            // Top-level `?` on an error value: surface it as the program's error result
            // (the top-level exit in main.rs renders the full diagnostic)
            Err(RuntimeError::UserError(e)) => Ok(Value::Error(e)),
            other => other,
        }
    }

    /// Convert a byte offset in `current_source` into a 1-based (line, col) pair.
    ///
    /// An offset past the end of the source reports the position just past the final
    /// character (line/col of the end of the last line). Mirrors `error::SourceLocation::from_offset`.
    pub fn line_col(&self, offset: usize) -> (usize, usize) {
        let mut line = 1;
        let mut col = 1;
        for (i, c) in self.current_source.char_indices() {
            if i >= offset {
                break;
            }
            if c == '\n' {
                line += 1;
                col = 1;
            } else {
                col += 1;
            }
        }
        (line, col)
    }

    /// Build an error value at a source position, with a cause chain.
    ///
    /// The stack is a snapshot of the current call stack (each frame renders as
    /// `<fn>` per the authoritative diagnostic format; the first frame is the
    /// program's path frame at position 0 → line 1, col 1, kept for host/boot parity).
    fn make_error(&self, kind: &str, message: String, span: Option<Span>, cause: Option<Rc<ErrorValue>>) -> Value {
        let (line, col) = match span { Some(s) => self.line_col(s.start), None => (0, 0) };
        Value::Error(Rc::new(ErrorValue {
            kind: kind.to_string(), message, line, col,
            stack: self.call_stack.iter().map(|f| StackFrame {
                fn_name: "<fn>".to_string(),
                line: self.line_col(f.position).0,
                col: self.line_col(f.position).1,
            }).collect(),
            cause,
        }))
    }

    /// Error read zone: an error value exposes its own fields
    /// (`.type` → kind, `.message` → message, `.cause` → error or null,
    /// `.line`/`.col` → numbers; unknown fields → UndefinedField error value).
    /// Shared by `get_field` (err.x) and `get_index` (err["x"]).
    fn error_read_zone(&self, err: &Rc<ErrorValue>, field: &str) -> Value {
        match field {
            "type" => Value::String(err.kind.clone()),
            "message" => Value::String(err.message.clone()),
            "cause" => match &err.cause {
                Some(cause) => Value::Error(Rc::clone(cause)),
                None => Value::Void,
            },
            "line" => Value::Number(err.line as f64),
            "col" => Value::Number(err.col as f64),
            _ => self.make_error("UndefinedField", format!("Undefined field: {}", field), None, None),
        }
    }

    /// Run a list of statements
    ///
    /// Expression statement values are tracked as the statement list's value (the last one wins),
    /// but do not interrupt execution — `Return` is the only way to break control flow.
    fn run_statements(&mut self, statements: &[Statement], env: &EnvRef) -> Result<Value, RuntimeError> {
        let mut last_value = Value::Void;
        for statement in statements {
            match self.run_statement(statement, env)? {
                ControlFlow::Return(value) => return Ok(value),
                ControlFlow::Value(value) => last_value = value,
                ControlFlow::None => {}
            }
        }
        Ok(last_value)
    }

    /// Run a single statement
    fn run_statement(&mut self, stmt: &Statement, env: &EnvRef) -> Result<ControlFlow, RuntimeError> {
        match stmt {
            Statement::Let(let_stmt) => {
                let mut annotation = None;
                if let Some(ann) = &let_stmt.type_annotation {
                    let text = self.annotation_text(ann);
                    let ty = self.eval_expression(ann, env)?;
                    annotation = Some((ty.clone(), text.clone()));
                    // The annotation check is done below, separately for the with-value and without-value cases
                }
                match &let_stmt.value {
                    Some(v) => {
                        let value = self.eval_expression(v, env)?;
                        let value = if let Some((ty, text)) = &annotation {
                            self.check_annotation(value, ty.clone(), text, Some(v.span()))?
                        } else { value };
                        if let Some(a) = annotation {
                            env.borrow_mut().define_annotated(Rc::from(let_stmt.name.clone()), value, Some(a));
                        } else {
                            env.borrow_mut().define(let_stmt.name.clone(), value);
                        }
                    }
                    None => {
                        if let Some((ty, _text)) = &annotation {
                            // No value: only check that the annotation is a type; do not check the value (there is none)
                            if !crate::types::is_type_value(ty) {
                                let err = self.make_error("TypeCheck",
                                    "type annotation is not a type value".to_string(),
                                    let_stmt.type_annotation.as_ref().map(|a| a.span()), None);
                                env.borrow_mut().define(let_stmt.name.clone(), err);
                            } else {
                                env.borrow_mut().define_uninitialized(let_stmt.name.clone(), annotation.clone());
                            }
                        } else {
                            env.borrow_mut().define_uninitialized(let_stmt.name.clone(), None);
                        }
                    }
                }
                Ok(ControlFlow::None)
            }

            Statement::Assign(assign_stmt) => {
                let value = self.eval_expression(&assign_stmt.value, env)?;
                self.assign_value(&assign_stmt.target, value, env)?;
                Ok(ControlFlow::None)
            }

            Statement::If(if_stmt) => {
                for branch in &if_stmt.branches {
                    let condition = self.eval_expression(&branch.condition, env)?;
                    if condition.is_truthy() {
                        let block_env = child_env(env);
                        return self.run_block(&branch.body, &block_env);
                    }
                }

                if let Some(ref else_body) = if_stmt.else_body {
                    let block_env = child_env(env);
                    return self.run_block(else_body, &block_env);
                }

                Ok(ControlFlow::None)
            }

            Statement::While(while_stmt) => {
                loop {
                    let condition = self.eval_expression(&while_stmt.condition, env)?;
                    if !condition.is_truthy() {
                        break;
                    }

                    let block_env = child_env(env);
                    match self.run_block(&while_stmt.body, &block_env)? {
                        ControlFlow::Return(value) => return Ok(ControlFlow::Return(value)),
                        ControlFlow::Value(_) => {}
                        ControlFlow::None => {}
                    }
                }
                Ok(ControlFlow::None)
            }

            Statement::Return(return_stmt) => {
                let value = self.eval_expression(&return_stmt.value, env)?;
                Ok(ControlFlow::Return(value))
            }

            Statement::Export(export_stmt) => {
                let value = self.eval_expression(&export_stmt.value, env)?;
                match &export_stmt.name {
                    // export let name = value;
                    Some(name) => {
                        self.exports.insert(name.clone(), value);
                    }
                    // export expr;
                    None => match &export_stmt.value {
                        // export x;
                        Expression::Identifier(id) => {
                            self.exports.insert(id.name.clone(), value);
                        }
                        // export { f, g }; — export each field of the object literal
                        Expression::Object(_) => {
                            if let Value::Object(fields_rc) = value {
                                let fields = fields_rc.borrow();
                                for (k, v) in fields.fields.iter() {
                                    self.exports.insert(k.clone(), v.clone());
                                }
                            }
                        }
                        // Other expressions (e.g. export 42;) have no exportable name; ignored
                        _ => {}
                    },
                }
                // export does not terminate program execution
                Ok(ControlFlow::None)
            }

            Statement::Expression(expr) => {
                // When if is a statement (parse_if_as_statement), returns in branches must
                // propagate outward. Otherwise `if c { return x; }`'s return would be swallowed
                // by the block expression as the branch value and the function would keep
                // running — recursive functions (if n <= 1 { return 1; }) would never terminate.
                if let Expression::If(if_expr) = expr {
                    return self.run_if_statement(if_expr, env);
                }
                let value = self.eval_expression(expr, env)?;
                Ok(ControlFlow::Value(value))
            }
        }
    }

    /// Run a block
    ///
    /// The block's value is its last statement's value. Expression statements are
    /// evaluated once by run_statement and passed via ControlFlow::Value, never re-evaluated.
    fn run_block(&mut self, block: &Block, env: &EnvRef) -> Result<ControlFlow, RuntimeError> {
        let mut last_value = Value::Void;
        for statement in &block.statements {
            match self.run_statement(statement, env)? {
                ControlFlow::Return(value) => return Ok(ControlFlow::Return(value)),
                ControlFlow::Value(value) => last_value = value,
                ControlFlow::None => {}
            }
        }
        Ok(ControlFlow::Value(last_value))
    }

    /// Execute an if expression with statement semantics: returns in branches propagate to function level
    fn run_if_statement(&mut self, if_expr: &IfExpr, env: &EnvRef) -> Result<ControlFlow, RuntimeError> {
        let condition = self.eval_expression(&if_expr.condition, env)?;
        if condition.is_truthy() {
            self.eval_statement_expr(&if_expr.then_branch, env)
        } else if let Some(else_branch) = &if_expr.else_branch {
            self.eval_statement_expr(else_branch, env)
        } else {
            Ok(ControlFlow::None)
        }
    }

    /// Evaluate if branches in statement context:
    /// block expressions run directly (preserving Return control flow instead of converting to a value), nested ifs recurse
    fn eval_statement_expr(&mut self, expr: &Expression, env: &EnvRef) -> Result<ControlFlow, RuntimeError> {
        match expr {
            Expression::Block(block) => {
                let block_env = child_env(env);
                self.run_block(&block.block, &block_env)
            }
            Expression::If(if_expr) => self.run_if_statement(if_expr, env),
            _ => {
                let value = self.eval_expression(expr, env)?;
                Ok(ControlFlow::Value(value))
            }
        }
    }

    /// Evaluate an expression
    fn eval_expression(&mut self, expr: &Expression, env: &EnvRef) -> Result<Value, RuntimeError> {
        match expr {
            Expression::Number(n) => Ok(Value::Number(n.value)),

            Expression::String(s) => {
                let mut result = String::new();
                for part in &s.parts {
                    match part {
                        StringPart::Literal(lit) => result.push_str(lit),
                        StringPart::Interpolation(expr) => {
                            let value = self.eval_expression(expr, env)?;
                            result.push_str(&value.to_string());
                        }
                    }
                }
                Ok(Value::String(result))
            }

            Expression::Boolean(b) => Ok(Value::Boolean(b.value)),

            Expression::Identifier(id) => {
                match env.borrow().lookup(&id.name) {
                    Lookup::Value(v) => Ok(v),
                    Lookup::Uninitialized => Ok(self.make_error("Uninitialized",
                        format!("variable \"{}\" is declared but not initialized", id.name), Some(id.span), None)),
                    Lookup::Undefined => Ok(self.make_error("UndefinedVariable",
                        format!("Undefined variable: {}", id.name), Some(id.span), None)),
                }
            }

            Expression::Array(arr) => {
                let elements: Result<Vec<_>, _> = arr.elements.iter()
                    .map(|e| self.eval_expression(e, env))
                    .collect();
                Ok(Value::Array(Rc::new(RefCell::new(elements?))))
            }

            Expression::Object(obj) => {
                let mut object = ObjectValue::new();
                for field in &obj.fields {
                    let value = if let Some(ref val_expr) = field.value {
                        self.eval_expression(val_expr, env)?
                    } else {
                        // Shorthand: {x} means {x = x}
                        match env.borrow().lookup(&field.name) {
                            Lookup::Value(v) => v,
                            Lookup::Uninitialized => self.make_error("Uninitialized",
                                format!("variable \"{}\" is declared but not initialized", field.name), None, None),
                            Lookup::Undefined => self.make_error("UndefinedVariable",
                                format!("Undefined variable: {}", field.name), None, None),
                        }
                    };
                    object.insert(field.name.clone(), value);
                }
                Ok(Value::Object(Rc::new(RefCell::new(object))))
            }

            Expression::Function(func) => {
                // Parameter annotations are evaluated at definition time (referencing the environment at the definition site, including shadowing semantics)
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
                // Rc-shared AST children: zero deep copies when creating function values (hot-path optimization)
                Ok(Value::Function(Rc::new(FunctionValue {
                    parameters: Rc::clone(&func.parameters),
                    body: Rc::clone(&func.body),
                    closure: Rc::clone(env),
                    param_types: Rc::new(param_types),
                    param_keys: Rc::new(func.parameters.iter().map(|p| Rc::from(p.name.as_str())).collect()),
                })))
            }

            Expression::Call(call) => {
                let callee = self.eval_expression(&call.callee, env)?;
                let args: Result<Vec<_>, _> = call.arguments.iter()
                    .map(|a| self.eval_expression(a, env))
                    .collect();
                self.call_function(callee, args?, call.span)
            }

            Expression::BinaryOp(bin) => {
                self.eval_binary_op(bin, env)
            }

            Expression::MemberAccess(ma) => {
                let object = self.eval_expression(&ma.object, env)?;
                self.get_field(&object, &ma.field, Some(ma.span))
            }

            Expression::IndexAccess(ia) => {
                let object = self.eval_expression(&ia.object, env)?;
                let index = self.eval_expression(&ia.index, env)?;
                self.get_index(&object, &index, Some(ia.span))
            }

            Expression::Parenthesized(inner) => {
                self.eval_expression(inner, env)
            }

            Expression::Import(import) => {
                self.run_import(&import.path, env)
            }

            // Placeholder for unimplemented expression types
            Expression::Null(_) => Ok(Value::Void),
            Expression::UnaryOp(unary) => {
                let operand = self.eval_expression(&unary.operand, env)?;
                match unary.operator {
                    UnaryOp::Not => Ok(Value::Boolean(!operand.is_truthy())),
                    // Unary minus/plus are operations: an Error operand poisons the
                    // operation (new error with cause); a non-Number operand becomes
                    // a TypeMismatch error value (existing message words unchanged).
                    UnaryOp::Neg => {
                        if is_error_value(&operand) {
                            return Ok(self.make_error("TypeMismatch",
                                format!("cannot apply unary negation to Error and Number"),
                                Some(unary.span), error_cause(&operand)));
                        }
                        match operand {
                            Value::Number(n) => Ok(Value::Number(-n)),
                            _ => Ok(self.make_error("TypeMismatch",
                                format!("cannot apply unary negation to {} and Number", operand.type_name()),
                                Some(unary.span), None)),
                        }
                    }
                    UnaryOp::Plus => {
                        if is_error_value(&operand) {
                            return Ok(self.make_error("TypeMismatch",
                                format!("cannot apply unary plus to Error and Number"),
                                Some(unary.span), error_cause(&operand)));
                        }
                        match operand {
                            Value::Number(n) => Ok(Value::Number(n)),
                            _ => Ok(self.make_error("TypeMismatch",
                                format!("cannot apply unary plus to {} and Number", operand.type_name()),
                                Some(unary.span), None)),
                        }
                    }
                    // `?` propagation: an Error operand becomes the internal UserError signal,
                    // which bubbles up to the enclosing function-call boundary (or the top level)
                    UnaryOp::Propagate => {
                        let value = self.eval_expression(&unary.operand, env)?;
                        match value {
                            Value::Error(e) => Err(RuntimeError::UserError(e)),
                            other => Ok(other),
                        }
                    }
                }
            }
            Expression::If(if_expr) => {
                let condition = self.eval_expression(&if_expr.condition, env)?;
                if condition.is_truthy() {
                    self.eval_expression(&if_expr.then_branch, env)
                } else if let Some(else_branch) = &if_expr.else_branch {
                    self.eval_expression(else_branch, env)
                } else {
                    Ok(Value::Void)
                }
            }
            Expression::Block(block_expr) => {
                self.eval_block_expression(&block_expr, env)
            }
        }
    }

    /// Evaluate a block expression and return its value
    fn eval_block_expression(&mut self, block: &BlockExpr, env: &EnvRef) -> Result<Value, RuntimeError> {
        let block_env = child_env(env);
        self.run_block(&block.block, &block_env)
            .map(|flow| match flow {
                ControlFlow::Return(value) => value,
                ControlFlow::Value(value) => value,
                ControlFlow::None => Value::Void,
            })
    }

    /// Evaluate binary operation
    ///
    /// `&&` / `||` short-circuit: only the needed operand is evaluated, and the operand's actual value is returned
    /// (README: "`&&` returns the first falsy value, `||` returns the first truthy value")
    fn eval_binary_op(&mut self, bin: &BinaryOpExpr, env: &EnvRef) -> Result<Value, RuntimeError> {
        let left = self.eval_expression(&bin.left, env)?;

        // `??` fallback: an Error left operand is replaced by the right operand's value.
        // Handled before everything else (it is the error-handling operator, so the
        // operation zone must not intercept its left operand); the right operand is
        // only evaluated when the left operand is an error value.
        if let BinaryOp::Coalesce = bin.operator {
            return match left {
                Value::Error(_) => self.eval_expression(&bin.right, env),
                other => Ok(other),
            };
        }

        // Operation zone: an Error left operand poisons the operation — including
        // `&&`/`||` (they do not short-circuit past an error) — and a new error is
        // built with the operand as cause.
        if is_error_value(&left) {
            return Ok(self.make_error(
                "TypeMismatch",
                format!("cannot apply {} to {} and {}", op_word(bin.operator), "Error", "unknown"),
                Some(bin.span),
                error_cause(&left),
            ));
        }

        // Short-circuit: handle && and || first (left is confirmed non-error here),
        // evaluating the right operand only when needed
        match bin.operator {
            BinaryOp::And => {
                if !left.is_truthy() {
                    return Ok(left);
                }
                return self.eval_expression(&bin.right, env);
            }
            BinaryOp::Or => {
                if left.is_truthy() {
                    return Ok(left);
                }
                return self.eval_expression(&bin.right, env);
            }
            _ => {}
        }

        let right = self.eval_expression(&bin.right, env)?;

        if is_error_value(&right) {
            return Ok(self.make_error(
                "TypeMismatch",
                format!("cannot apply {} to {} and {}", op_word(bin.operator), left.type_name(), "Error"),
                Some(bin.span),
                error_cause(&right),
            ));
        }

        match bin.operator {
            BinaryOp::Add => self.add_values(left, right),
            BinaryOp::Sub => self.numeric_op(left, right, |a, b| a - b),
            BinaryOp::Mul => self.numeric_op(left, right, |a, b| a * b),
            // Division by zero (incl. 0.0/0.0 and 1 % 0) becomes a DivisionByZero
            // error value; floating-point overflow to inf/NaN stays a plain number.
            BinaryOp::Div | BinaryOp::Mod => {
                match (&left, &right) {
                    (Value::Number(_), Value::Number(b)) if *b == 0.0 => {
                        return Ok(self.make_error(
                            "DivisionByZero",
                            "division by zero".to_string(),
                            Some(bin.span),
                            None,
                        ));
                    }
                    _ => {}
                }
                self.numeric_op(left, right, |a, b| if bin.operator == BinaryOp::Div { a / b } else { a % b })
            }
            BinaryOp::Eq => Ok(Value::Boolean(self.values_equal(&left, &right))),
            BinaryOp::NotEq => Ok(Value::Boolean(!self.values_equal(&left, &right))),
            BinaryOp::Lt => self.comparison_op(left, right, |a, b| a < b),
            BinaryOp::LtEq => self.comparison_op(left, right, |a, b| a <= b),
            BinaryOp::Gt => self.comparison_op(left, right, |a, b| a > b),
            BinaryOp::GtEq => self.comparison_op(left, right, |a, b| a >= b),
            BinaryOp::And | BinaryOp::Or => unreachable!("handled above"),
            BinaryOp::BitwiseAnd => self.bitwise_op(left, right, |a, b| a & b),
            BinaryOp::BitwiseOr => self.bitwise_op(left, right, |a, b| a | b),
            BinaryOp::BitwiseXor => self.bitwise_op(left, right, |a, b| a ^ b),
            BinaryOp::Coalesce => unreachable!("handled above"),
        }
    }

    /// Call a function
    fn call_function(&mut self, callee: Value, args: Vec<Value>, span: Span) -> Result<Value, RuntimeError> {
        self.call_function_inner(callee, args, span, false)
    }

    /// Internal call path; when exempt_error_args = true, the error-value argument check for user functions is skipped
    /// (used by the internal type-checking path; the native branch still judges by its own accepts_errors).
    fn call_function_inner(&mut self, callee: Value, args: Vec<Value>, span: Span, exempt_error_args: bool) -> Result<Value, RuntimeError> {
        match callee {
            Value::Function(func) => {
                // Argument check: user functions reject error values as arguments
                // (only the diagnostic natives are exempt; user functions never are)
                if !exempt_error_args {
                    if let Some(bad) = args.iter().find(|a| matches!(a, Value::Error(_))) {
                        return Ok(self.make_error(
                            "TypeMismatch",
                            "attempt to pass error value as argument".to_string(),
                            Some(span),
                            error_cause(bad),
                        ));
                    }
                }

                // Support currying - if not enough args, return a partial function.
                // The curried native captures the function value and the call-site span,
                // then routes the completed application through ctx.call so the full
                // call logic (param annotation checks, error-arg checks, recursion depth,
                // call stack) runs uniformly on every application step.
                if args.len() < func.parameters.len() {
                    let captured_func = Value::Function(Rc::clone(&func));
                    let all_args = args.clone();
                    return Ok(Value::NativeFunction(Rc::new(NativeFunction {
                        name: "<curried>".to_string(),
                        arity: Some(func.parameters.len() - args.len()),
                        accepts_errors: false,
                        // Native dispatch enforces exact arity, so the closure runs once
                        // with `arity` inner args; rebuild base+inner from the captured base.
                        func: Box::new(move |ctx, inner_args| {
                            let mut combined = all_args.clone();
                            combined.extend(inner_args);
                            ctx.call(captured_func.clone(), combined, span)
                        }),
                    })));
                }

                if args.len() != func.parameters.len() {
                    return Ok(self.make_error(
                        "ArityMismatch",
                        format!("Arity mismatch: expected {} arguments, got {}", func.parameters.len(), args.len()),
                        Some(span),
                        None,
                    ));
                }

                // Parameter annotation check: on failure → the function body does not run, and a TypeCheck error value is returned
                for (i, (_param, arg)) in func.parameters.iter().zip(args.iter()).enumerate() {
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

                // Recursion depth guard: deep user recursion becomes a recoverable
                // StackOverflow error value instead of blowing the host stack
                if self.recursion_depth >= MAX_RECURSION_DEPTH {
                    return Ok(self.make_error(
                        "StackOverflow",
                        "maximum recursion depth exceeded".to_string(),
                        Some(span),
                        None,
                    ));
                }
                self.recursion_depth += 1;

                let call_env = child_env(&func.closure);
                {
                    let mut env = call_env.borrow_mut();
                    for (i, (arg, key)) in args.into_iter().zip(func.param_keys.iter()).enumerate() {
                        env.define_annotated(Rc::clone(key), arg, func.param_types[i].clone());
                    }
                }

                self.call_stack.push(CallFrame {
                    path: Cow::Borrowed("unknown"),
                    position: span.start,
                });

                // Use match so recursion_depth / call_stack are restored correctly on errors
                let result = match self.run_block(&func.body, &call_env) {
                    Ok(flow) => Ok(match flow {
                        ControlFlow::Return(value) => value,
                        ControlFlow::Value(value) => value,
                        ControlFlow::None => Value::Void,
                    }),
                    // `?` inside the function body: the error becomes the function's return value
                    Err(RuntimeError::UserError(e)) => Ok(Value::Error(e)),
                    Err(other) => Err(other),
                };

                self.recursion_depth -= 1;
                self.call_stack.pop();
                result
            }

            Value::NativeFunction(native_fn) => {
                // Argument check: only the diagnostic natives (accepts_errors —
                // print/println plus the error constructors/checkers and the type
                // probe) accept error values
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
                    if args.len() != arity {
                        return Ok(self.make_error(
                            "ArityMismatch",
                            format!("Arity mismatch: expected {} arguments, got {}", arity, args.len()),
                            Some(span),
                            None,
                        ));
                    }
                }

                (native_fn.func)(self, args)
            }

            _ => Ok(self.make_error(
                "NotCallable",
                format!("Not callable: {}", callee.type_name()),
                Some(span),
                None,
            )),
        }
    }

    /// Is `v` of type `t`? If `t` is not a type value or the check errors → Err(error value).
    fn check_value(&mut self, v: &Value, t: &Value, span: Option<Span>) -> Result<bool, Value> {
        if !crate::types::is_type_value(t) {
            return Err(self.make_error("TypeCheck", "type annotation is not a type value".to_string(), span, None));
        }
        let check_fn = match self.get_field(t, "check", span) {
            Ok(f) => f,
            // Defensive branch: a type value is necessarily an object, so get_field does not actually Err;
            // RuntimeError has no direct conversion to an error value, so treat it as a check failure (message as below).
            Err(e) => return Err(self.make_error("TypeCheck", format!("type check failed: {}", e), span, None)),
        };
        match self.call_function_inner(check_fn, vec![v.clone()], span.unwrap_or_default(), true) {
            Ok(Value::Error(e)) => Err(Value::Error(e)), // the check itself errors → failure
            Ok(r) => Ok(r.is_truthy()),
            Err(e) => Err(self.make_error("TypeCheck", format!("type check failed: {}", e), span, None)),
        }
    }

    /// Annotation check: on pass, returns the original value; on failure, returns a TypeCheck error value (the message includes the annotation's source text).
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

    /// The annotation's source text (types have no names; the name in the message comes from the code you wrote).
    fn annotation_text(&self, expr: &Expression) -> String {
        let span = expr.span();
        let src = &self.current_source;
        if src.is_empty() || span.start >= span.end || span.end > src.len() {
            "?".to_string()
        } else {
            src[span.start..span.end].to_string()
        }
    }

    /// Assign to a target
    fn assign_value(&mut self, target: &AssignTarget, value: Value, env: &EnvRef) -> Result<(), RuntimeError> {
        if target.accessors.is_empty() {
            let value = match env.borrow().get_annotation(&target.name) {
                Some((ty, text)) => self.check_annotation(value, ty, &text, None)?,
                None => value,
            };
            env.borrow_mut().assign(&target.name, value)
        } else {
            // Handle nested assignment (a.b[0].c = value)
            let mut current = match env.borrow().lookup(&target.name) {
                Lookup::Value(v) => v,
                Lookup::Uninitialized => return Err(RuntimeError::Custom(format!(
                    "variable \"{}\" is declared but not initialized", target.name))),
                Lookup::Undefined => return Err(RuntimeError::UndefinedVariable(target.name.clone())),
            };

            // Navigate to the parent of the final accessor
            for accessor in target.accessors.iter().take(target.accessors.len() - 1) {
                current = match accessor {
                    Accessor::Field(name) => self.get_field(&current, name, None)?,
                    Accessor::Index(index_expr) => {
                        let index = self.eval_expression(index_expr, env)?;
                        self.get_index(&current, &index, Some(index_expr.span()))?
                    }
                };
            }

            // Perform the final assignment
            match target.accessors.last().unwrap() {
                Accessor::Field(name) => self.set_field(&current, name, value),
                Accessor::Index(index_expr) => {
                    let index = self.eval_expression(index_expr, env)?;
                    self.set_index(&current, &index, value)
                }
            }
        }
    }

    /// Run import statement
    fn run_import(&mut self, path: &str, env: &EnvRef) -> Result<Value, RuntimeError> {
        // Resolve path relative to current file
        let current_path = self.call_stack.last()
            .map(|f| f.path.clone())
            .unwrap_or_else(|| Cow::Borrowed("."));

        let base_path = Path::new(current_path.as_ref()).parent()
            .unwrap_or(Path::new("."));
        let import_path = base_path.join(path);

        let mut import_interpreter = Interpreter::new();
        import_interpreter.run_file(&import_path)?;

        // Merge exports into current environment
        for (name, value) in &import_interpreter.exports {
            env.borrow_mut().define(name.clone(), value.clone());
        }

        // Return the exports as an object
        let mut object = ObjectValue::new();
        for (name, value) in &import_interpreter.exports {
            object.insert(name.clone(), value.clone());
        }
        Ok(Value::Object(Rc::new(RefCell::new(object))))
    }

    // Helper methods for operations

    fn add_values(&self, left: Value, right: Value) -> Result<Value, RuntimeError> {
        match (&left, &right) {
            (Value::Number(a), Value::Number(b)) => Ok(Value::Number(a + b)),
            (Value::String(a), Value::String(b)) => Ok(Value::String(format!("{}{}", a, b))),
            // Type mismatch (an Error operand would already have been intercepted by
            // eval_binary_op; the cause lookup is kept defensively): error value
            // with the existing message template.
            _ => Ok(self.make_error(
                "TypeMismatch",
                format!("cannot apply addition to {} and {}", left.type_name(), right.type_name()),
                None,
                error_cause(&left).or_else(|| error_cause(&right)),
            )),
        }
    }

    fn numeric_op<F>(&self, left: Value, right: Value, op: F) -> Result<Value, RuntimeError>
    where
        F: Fn(f64, f64) -> f64,
    {
        match (&left, &right) {
            (Value::Number(a), Value::Number(b)) => Ok(Value::Number(op(*a, *b))),
            _ => Ok(self.make_error(
                "TypeMismatch",
                format!("cannot apply numeric operation to {} and {}", left.type_name(), right.type_name()),
                None,
                error_cause(&left).or_else(|| error_cause(&right)),
            )),
        }
    }

    fn comparison_op<F>(&self, left: Value, right: Value, op: F) -> Result<Value, RuntimeError>
    where
        F: Fn(f64, f64) -> bool,
    {
        match (&left, &right) {
            (Value::Number(a), Value::Number(b)) => Ok(Value::Boolean(op(*a, *b))),
            _ => Ok(self.make_error(
                "TypeMismatch",
                format!("cannot apply comparison to {} and {}", left.type_name(), right.type_name()),
                None,
                error_cause(&left).or_else(|| error_cause(&right)),
            )),
        }
    }

    fn bitwise_op<F>(&self, left: Value, right: Value, op: F) -> Result<Value, RuntimeError>
    where
        F: Fn(i64, i64) -> i64,
    {
        match (&left, &right) {
            (Value::Number(a), Value::Number(b)) => {
                Ok(Value::Number(op(*a as i64, *b as i64) as f64))
            }
            _ => Ok(self.make_error(
                "TypeMismatch",
                format!("cannot apply bitwise operation to {} and {}", left.type_name(), right.type_name()),
                None,
                error_cause(&left).or_else(|| error_cause(&right)),
            )),
        }
    }

    fn values_equal(&self, left: &Value, right: &Value) -> bool {
        match (left, right) {
            (Value::Void, Value::Void) => true,
            (Value::Number(a), Value::Number(b)) => a == b,
            (Value::String(a), Value::String(b)) => a == b,
            (Value::Boolean(a), Value::Boolean(b)) => a == b,
            (Value::Array(a), Value::Array(b)) => Rc::ptr_eq(a, b),
            (Value::Object(a), Value::Object(b)) => Rc::ptr_eq(a, b),
            (Value::Function(a), Value::Function(b)) => Rc::ptr_eq(a, b),
            (Value::NativeFunction(a), Value::NativeFunction(b)) => Rc::ptr_eq(a, b),
            _ => false,
        }
    }

    fn get_field(&self, object: &Value, field: &str, span: Option<Span>) -> Result<Value, RuntimeError> {
        // Error read zone: an error value exposes its own fields
        if let Value::Error(err) = object {
            return Ok(self.error_read_zone(err, field));
        }
        match object {
            Value::String(s) if field == "length" => {
                Ok(Value::Number(s.chars().count() as f64))
            }
            Value::Object(obj) => {
                // Missing field reads (obj.x) become UndefinedField error values
                Ok(obj.borrow().fields.get(field)
                    .cloned()
                    .unwrap_or_else(|| self.make_error(
                        "UndefinedField",
                        format!("Undefined field: {}", field),
                        span,
                        None,
                    )))
            }
            // Native functions expose their name (the boot layer reads func.name
            // to build the host-identical "attempt to pass error value as
            // argument to {name}" message)
            Value::NativeFunction(f) if field == "name" => Ok(Value::String(f.name.clone())),
            Value::Array(arr) => {
                // Handle array methods and properties
                match field {
                    "length" => Ok(Value::Number(arr.borrow().len() as f64)),
                    "add" => {
                        // Return a curried function for adding elements
                        let arr_clone = Rc::clone(arr);
                        Ok(Value::NativeFunction(Rc::new(NativeFunction {
                            name: "Array.add".to_string(),
                            arity: Some(1),
                            accepts_errors: false,
                            func: Box::new(move |_ctx, args| {
                                if let Some(element) = args.first() {
                                    arr_clone.borrow_mut().push(element.clone());
                                }
                                Ok(Value::Void)
                            }),
                        })))
                    }
                    "remove" => {
                        // Return a curried function for removing elements
                        let arr_clone = Rc::clone(arr);
                        Ok(Value::NativeFunction(Rc::new(NativeFunction {
                            name: "Array.remove".to_string(),
                            arity: Some(1),
                            accepts_errors: false,
                            func: Box::new(move |_ctx, args| {
                                if let Some(Value::Number(idx)) = args.first() {
                                    let len = arr_clone.borrow().len();
                                    if let Ok(index) = normalize_index(*idx, len) {
                                        arr_clone.borrow_mut().remove(index);
                                    }
                                }
                                Ok(Value::Void)
                            }),
                        })))
                    }
                    _ => Ok(self.make_error(
                        "UndefinedField",
                        format!("Undefined field: {}", field),
                        span,
                        None,
                    )),
                }
            }
            _ => Ok(self.make_error(
                "NotAnObject",
                format!("Not an object: {}", object.type_name()),
                span,
                None,
            )),
        }
    }

    /// Refuse writes to protected members of built-in (protected) type objects; plain objects and free members are unrestricted.
    fn check_protected(&self, object: &Value, field: &str) -> Result<(), RuntimeError> {
        if crate::types::is_protected_object(object) && crate::types::PROTECTED_FIELDS.contains(&field) {
            return Err(RuntimeError::Custom(format!(
                "cannot overwrite protected member '{}' of built-in type", field
            )));
        }
        Ok(())
    }

    fn set_field(&self, object: &Value, field: &str, value: Value) -> Result<(), RuntimeError> {
        match object {
            Value::Object(obj) => {
                self.check_protected(object, field)?;
                obj.borrow_mut().insert(field.to_string(), value);
                Ok(())
            }
            _ => Err(RuntimeError::NotAnObject(object.type_name().to_string())),
        }
    }

    fn get_index(&self, object: &Value, index: &Value, span: Option<Span>) -> Result<Value, RuntimeError> {
        match (object, index) {
            // Error read zone via index access too (err["message"] works like err.message)
            (Value::Error(err), Value::String(key)) => Ok(self.error_read_zone(err, key)),
            (Value::Array(arr), Value::Number(n)) => {
                let len = arr.borrow().len();
                let idx = match normalize_index(*n, len) {
                    Ok(i) => i,
                    Err(bad) => return Ok(self.make_error(
                        "IndexOutOfBounds",
                        format!("index {} out of bounds for length {}", bad, len),
                        span,
                        None,
                    )),
                };
                arr.borrow().get(idx)
                    .cloned()
                    .ok_or(RuntimeError::IndexOutOfBounds(idx))
            }
            (Value::Object(obj), Value::String(key)) => {
                // Missing keys (obj["x"]) become UndefinedField error values
                // (the old null probing is gone)
                Ok(obj.borrow().fields.get(key)
                    .cloned()
                    .unwrap_or_else(|| self.make_error(
                        "UndefinedField",
                        format!("Undefined field: {}", key),
                        span,
                        None,
                    )))
            }
            (Value::Object(obj), Value::Number(n)) => {
                // JS semantics: obj[0] === obj["0"]; the numeric key is stringified.
                // The boot interpreter does the same (Number.toString), so sparse
                // tapes / maps keyed by index behave identically on both.
                let key = format!("{}", n);
                Ok(obj.borrow().fields.get(&key)
                    .cloned()
                    .unwrap_or_else(|| self.make_error(
                        "UndefinedField",
                        format!("Undefined field: {}", key),
                        span,
                        None,
                    )))
            }
            (_, Value::String(_)) => {
                // Non-object + string key → CannotIndex error value (null probing is gone)
                Ok(self.make_error(
                    "CannotIndex",
                    format!("Cannot index into {}", object.type_name()),
                    span,
                    None,
                ))
            }
            (Value::String(s), Value::Number(n)) => {
                // String indexing: s[0] returns a single character (Unicode-safe)
                let chars: Vec<char> = s.chars().collect();
                let len = chars.len();
                let idx = match normalize_index(*n, len) {
                    Ok(i) => i,
                    Err(bad) => return Ok(self.make_error(
                        "IndexOutOfBounds",
                        format!("index {} out of bounds for length {}", bad, len),
                        span,
                        None,
                    )),
                };
                Ok(Value::String(chars[idx].to_string()))
            }
            _ => Ok(self.make_error(
                "CannotIndex",
                format!("Cannot index into {}", object.type_name()),
                span,
                None,
            )),
        }
    }

    fn set_index(&self, object: &Value, index: &Value, value: Value) -> Result<(), RuntimeError> {
        match (object, index) {
            (Value::Array(arr), Value::Number(n)) => {
                let len = arr.borrow().len();
                // JS semantics: arr[arr.length] = x appends an element
                // (normalize_index treats idx == len as out of bounds, so handle it first)
                if *n == len as f64 {
                    arr.borrow_mut().push(value);
                    return Ok(());
                }
                let idx = match normalize_index(*n, len) {
                    Ok(i) => i,
                    Err(bad) => return Err(RuntimeError::IndexOutOfBounds(bad)),
                };
                let mut borrowed = arr.borrow_mut();
                if idx < borrowed.len() {
                    borrowed[idx] = value;
                    Ok(())
                } else {
                    Err(RuntimeError::IndexOutOfBounds(idx))
                }
            }
            (Value::Object(obj), Value::String(key)) => {
                self.check_protected(object, key)?;
                obj.borrow_mut().insert(key.clone(), value);
                Ok(())
            }
            (Value::Object(obj), Value::Number(n)) => {
                // JS semantics: obj[0] = x === obj["0"] = x; numeric key stringified
                // (matches the boot interpreter's Number.toString key handling).
                let key = format!("{}", n);
                self.check_protected(object, &key)?;
                obj.borrow_mut().insert(key, value);
                Ok(())
            }
            _ => Err(RuntimeError::CannotIndex(object.type_name().to_string())),
        }
    }
}

/// Normalize an array index, supporting Python-style negative indices (arr[-1] is the last element).
///
/// - Negative: `len + n` (e.g. len=5, n=-1 → 4)
/// - NaN, infinity, and non-integer indices are treated as out of bounds
/// - Returns `Err(out-of-bounds display index)`: positive OOB keeps its value, negative OOB returns len (past the end)
pub(crate) fn normalize_index(n: f64, len: usize) -> Result<usize, usize> {
    if !n.is_finite() || n.fract() != 0.0 {
        return Err(0);
    }
    let idx = if n < 0.0 {
        let neg = (-n) as usize;
        if neg > len {
            return Err(len);
        }
        len - neg
    } else {
        n as usize
    };
    if idx < len {
        Ok(idx)
    } else {
        Err(idx)
    }
}

impl CallContext for Interpreter {
    fn call(&mut self, callee: Value, args: Vec<Value>, span: Span) -> Result<Value, RuntimeError> {
        self.call_function(callee, args, span)
    }
}
