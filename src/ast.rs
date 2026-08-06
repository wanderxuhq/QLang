/*!
 * QLang abstract syntax tree (AST) module
 *
 * This module defines the abstract syntax tree structure of QLang programs.
 * The AST is a tree representation of the program structure and serves as the bridge between lexical analysis and interpretation.
 *
 * # Design philosophy
 *
 * 1. **Separation of expressions and statements** - Expression and Statement represent two different syntactic constructs
 * 2. **Expression-first** - almost every syntactic construct can be evaluated as an expression
 * 3. **Position information** - every node carries its source position, facilitating error reporting
 *
 * # AST hierarchy
 *
 * ```text
 * Program (the whole program)
 *   └── statements: Vec<Statement>
 *         ├── LetStmt (variable declaration)
 *         ├── AssignStmt (assignment)
 *         ├── IfStmt (conditional statement)
 *         ├── WhileStmt (loop)
 *         ├── ReturnStmt (return)
 *         ├── ExportStmt (export)
 *         └── Expression (expression statement)
 *
 * Expression (expression)
 *   ├── Number, String, Boolean, Null (literals)
 *   ├── Identifier (identifier)
 *   ├── Array, Object (composite literals)
 *   ├── Function (function definition)
 *   ├── Call (function call)
 *   ├── BinaryOp, UnaryOp (operators)
 *   ├── If (if expression)
 *   ├── MemberAccess, IndexAccess (member access)
 *   ├── Block (block expression)
 *   └── Parenthesized (parenthesized expression)
 * ```
 */

use std::rc::Rc;
use crate::token::Span;

/// A complete QLang program
///
/// Program is the root node of the AST, representing a complete source file.
/// It contains a list of statements, which are executed in order from top to bottom.
///
/// # Example
///
/// ```qlang
/// let x = 1;
/// let y = 2;
/// println(x + y);
/// ```
///
/// This is parsed into a Program containing 3 Statements.
#[derive(Debug, Clone)]
pub struct Program {
    /// The list of statements in the program
    pub statements: Vec<Statement>,
    /// The position range of the program in the source code
    pub span: Span,
}

impl Program {
    /// Creates a new program
    ///
    /// # Parameters
    ///
    /// - `statements` - the list of statements
    /// - `span` - the position range of the whole program
    pub fn new(statements: Vec<Statement>, span: Span) -> Self {
        Program { statements, span }
    }
}

/// Statement type
///
/// Statement represents an executable statement in the program.
/// Statements do not produce values (except expression statements); they are mainly used to control program flow.
///
/// The difference between statements and expressions:
/// - Statement: performs an action and does not produce a value (e.g., variable declaration, loop)
/// - Expression: produces a value (e.g., 1 + 2 produces 3)
#[derive(Debug, Clone)]
pub enum Statement {
    /// Variable declaration statement: `let x = value;`
    Let(LetStmt),
    /// Assignment statement: `x = value;`
    Assign(AssignStmt),
    /// Conditional statement: `if condition { ... } else { ... }`
    If(IfStmt),
    /// Loop statement: `while condition { ... }`
    While(WhileStmt),
    /// Return statement: `return value;`
    Return(ReturnStmt),
    /// Export statement: `export value;` (used by the module system)
    Export(ExportStmt),
    /// Expression statement: a single expression used as a statement
    Expression(Expression),
}

/// Variable declaration statement
///
/// Syntax: `let identifier = expression;`
/// Used to create a new variable and bind it to a value.
///
/// # Example
///
/// ```qlang
/// let x = 10;
/// let name = "Alice";
/// ```
///
/// Characteristics:
/// - Variables declared with `let` cannot be redeclared
/// - Can be initialized directly at declaration time
/// - Accessed via Identifier after declaration
#[derive(Debug, Clone)]
pub struct LetStmt {
    /// The variable name
    pub name: String,
    /// 类型标注:完整表达式,求值得到类型值(运行时断言)
    pub type_annotation: Option<Expression>,
    /// The initial value expression
    pub value: Expression,
    /// The position of the declaration statement in the source code
    pub span: Span,
}

impl LetStmt {
    /// Creates a new variable declaration
    ///
    /// # Parameters
    ///
    /// - `name` - the variable name
    /// - `value` - the initial value expression
    /// - `span` - the source position
    pub fn new(name: String, value: Expression, span: Span) -> Self {
        LetStmt {
            name,
            type_annotation: None,
            value,
            span,
        }
    }
}

/// Assignment statement
///
/// Syntax: `target = value;`
/// Used to modify the value of a variable; supports nested assignment (object properties, array elements).
///
/// # Supported assignment targets
///
/// 1. Simple variable: `x = 5`
/// 2. Object property: `obj.field = 5`
/// 3. Array element: `arr[0] = 5`
/// 4. Nested access: `obj.arr[0].field = 5`
#[derive(Debug, Clone)]
pub struct AssignStmt {
    /// The assignment target
    pub target: AssignTarget,
    /// The value to be assigned
    pub value: Expression,
    /// The position of the assignment statement
    pub span: Span,
}

/// Assignment target
///
/// Describes the target location of an assignment operation.
/// It is located by a name and a series of access operations.
#[derive(Debug, Clone)]
pub struct AssignTarget {
    /// The initial variable name
    pub name: String,
    /// The list of subsequent access operations
    pub accessors: Vec<Accessor>,
    /// The position of the target
    pub span: Span,
}

impl AssignTarget {
    /// Creates a new assignment target
    pub fn new(name: String) -> Self {
        AssignTarget {
            name,
            accessors: Vec::new(),
            span: Span::new(0, 0),
        }
    }
}

/// Access operation
///
/// Used to describe the access path of a nested assignment target.
#[derive(Debug, Clone)]
pub enum Accessor {
    /// Member access: `object.field`
    Field(String),
    /// Index access: `array[index]`
    Index(Box<Expression>),
}

/// Conditional statement
///
/// Syntax:
/// ```qlang
/// if condition1 { ... }
/// else if condition2 { ... }
/// else { ... }
/// ```
///
/// # Execution logic
///
/// 1. Check the condition of each branch in order
/// 2. The first branch whose condition is true is executed
/// 3. If no condition is true, the else branch is executed
/// 4. If there is no else branch, the result is null
///
/// # As an expression
///
/// QLang's if statement can be used as an expression:
/// ```qlang
/// let result = if x > 0 { "positive" } else { "negative" };
/// ```
#[derive(Debug, Clone)]
pub struct IfStmt {
    /// All if/else if branches
    pub branches: Vec<IfBranch>,
    /// The optional else branch
    pub else_body: Option<Block>,
    /// The position of the whole if statement
    pub span: Span,
}

impl IfStmt {
    /// Creates a new conditional statement
    pub fn new(branches: Vec<IfBranch>, else_body: Option<Block>, span: Span) -> Self {
        IfStmt {
            branches,
            else_body,
            span,
        }
    }
}

/// A single if branch
#[derive(Debug, Clone)]
pub struct IfBranch {
    /// The condition expression
    pub condition: Expression,
    /// The block executed when the condition is true
    pub body: Block,
}

impl IfBranch {
    /// Creates a new if branch
    pub fn new(condition: Expression, body: Block) -> Self {
        IfBranch { condition, body }
    }
}

/// while loop statement
///
/// Syntax: `while condition { body }`
///
/// # Execution logic
///
/// 1. Check the condition first
/// 2. If the condition is true, execute the loop body
/// 3. Repeat steps 1-2 until the condition is false
/// 4. If the condition is false from the start, the loop body is not executed
///
/// # Notes
///
/// - `break` can be used inside the loop body to exit early
/// - `continue` can be used inside the loop body to skip the current iteration
/// - Be careful to avoid infinite loops
#[derive(Debug, Clone)]
pub struct WhileStmt {
    /// The loop condition
    pub condition: Expression,
    /// The loop body
    pub body: Block,
    /// The position of the loop statement
    pub span: Span,
}

impl WhileStmt {
    /// Creates a new while loop
    pub fn new(condition: Expression, body: Block, span: Span) -> Self {
        WhileStmt {
            condition,
            body,
            span,
        }
    }
}

/// Return statement
///
/// Syntax: `return expression;`
/// Used to return a value from a function.
///
/// # Characteristics
///
/// - A return statement terminates the execution of the function
/// - If there is no return statement, the function returns null
/// - return can only be used inside a function body
#[derive(Debug, Clone)]
pub struct ReturnStmt {
    /// The value to be returned
    pub value: Expression,
    /// The position of the return statement
    pub span: Span,
}

impl ReturnStmt {
    /// Creates a new return statement
    pub fn new(value: Expression, span: Span) -> Self {
        ReturnStmt { value, span }
    }
}

/// Export statement
///
/// Syntax: `export expression;`
/// Used to export values in the module system.
///
/// # Example
///
/// ```qlang
/// // mymodule.ql
/// export let add = (a, b) -> a + b;
/// export let pi = 3.14159;
/// ```
///
/// Exported values can be imported and used by other modules.
#[derive(Debug, Clone)]
pub struct ExportStmt {
    /// The export name (the name in `export let name = value;`, None in other forms)
    pub name: Option<String>,
    /// The value to be exported
    pub value: Expression,
    /// The position of the export statement
    pub span: Span,
}

impl ExportStmt {
    /// Creates a new export statement
    pub fn new(name: Option<String>, value: Expression, span: Span) -> Self {
        ExportStmt { name, value, span }
    }
}

/// Block
///
/// A sequence of statements surrounded by braces:
/// ```qlang
/// {
///     statement1;
///     statement2;
///     statement3;
/// }
/// ```
///
/// # Block characteristics
///
/// 1. **Scope** - variables declared inside the block are only visible within the block
/// 2. **Execution order** - statements are executed in order
/// 3. **Return value** - the value of the last statement in the block is the value of the block
#[derive(Debug, Clone)]
pub struct Block {
    /// The list of statements in the block
    pub statements: Vec<Statement>,
    /// The position of the block
    pub span: Span,
}

impl Block {
    /// Creates a new block
    pub fn new(statements: Vec<Statement>, span: Span) -> Self {
        Block { statements, span }
    }
}

/// Block expression
///
/// Used to use a block in an expression context.
/// Syntactically identical to Block, but semantically evaluated as an expression.
///
/// # Example
///
/// ```qlang
/// let result = {
///     let x = 10;
///     let y = 20;
///     x + y  // the block returns the result of x + y
/// };
/// ```
///
/// A block expression allows multiple statements in a function body,
/// and the result of the last statement is the value of the whole block.
#[derive(Debug, Clone)]
pub struct BlockExpr {
    /// The wrapped block
    pub block: Block,
}

impl BlockExpr {
    /// Creates a new block expression
    pub fn new(block: Block) -> Self {
        BlockExpr { block }
    }
}

/// Expression type
///
/// Expression represents an expression that can be evaluated.
/// An expression always produces a value (even if the value is null or undefined).
///
/// # Expression vs statement
///
/// - Expression: `1 + 2` produces the value 3
/// - Statement: `let x = 1;` modifies the variable environment and produces no value
#[derive(Debug, Clone)]
pub enum Expression {
    /// Numeric literal: `42`, `3.14`, `-10`
    Number(NumberExpr),
    /// String literal: `"hello"`, `'world'`, template strings
    String(StringExpr),
    /// Boolean literal: `true`, `false`
    Boolean(BooleanExpr),
    /// Null value: `null`
    Null(NullExpr),
    /// Identifier/variable reference: `x`, `myFunction`
    Identifier(IdentifierExpr),
    /// Array literal: `[1, 2, 3]`
    Array(ArrayExpr),
    /// Object literal: `{ name: "Alice", age: 30 }`
    Object(ObjectExpr),
    /// Function definition: `(x, y) -> x + y`
    Function(FunctionExpr),
    /// Function call: `add(1, 2)`, `obj.method()`
    Call(CallExpr),
    /// Binary operator: `a + b`, `x && y`
    BinaryOp(BinaryOpExpr),
    /// Unary operator: `-x`, `!flag`
    UnaryOp(UnaryOpExpr),
    /// if expression (an extension of the ternary expression)
    If(IfExpr),
    /// Member access: `obj.field`
    MemberAccess(MemberAccessExpr),
    /// Index access: `arr[index]`
    IndexAccess(IndexAccessExpr),
    /// Parenthesized expression: `(expr)`
    Parenthesized(Box<Expression>),
    /// Import expression: `import "module"`
    Import(ImportExpr),
    /// Block expression: `{ ... }`
    Block(BlockExpr),
}

/// Numeric literal expression
///
/// Supports integers and decimals, stored as Rust's f64 type.
///
/// # Example
///
/// ```qlang
/// let integer = 42;
/// let decimal = 3.14159;
/// let negative = -10;
/// ```
#[derive(Debug, Clone)]
pub struct NumberExpr {
    /// The numeric value
    pub value: f64,
    /// The position of the literal
    pub span: Span,
}

impl NumberExpr {
    /// Creates a new number expression
    pub fn new(value: f64, span: Span) -> Self {
        NumberExpr { value, span }
    }
}

/// String literal expression
///
/// Supports plain strings and template strings.
/// Template strings are wrapped in backticks and support `${expr}` interpolation.
///
/// # Example
///
/// ```qlang
/// let simple = "Hello";
/// let template = "Hello, ${name}!";
/// ```
///
/// # Implementation details
///
/// A string is parsed as a combination of multiple StringPart values:
/// - Literal parts: plain text
/// - Interpolation parts: expressions inside ${} (to be evaluated)
#[derive(Debug, Clone)]
pub struct StringExpr {
    /// The list of parts of the string
    pub parts: Vec<StringPart>,
    /// The position of the literal
    pub span: Span,
}

impl StringExpr {
    /// Creates a new string expression
    pub fn new(parts: Vec<StringPart>, span: Span) -> Self {
        StringExpr { parts, span }
    }
}

/// String part
///
/// The internal representation used for template strings.
#[derive(Debug, Clone)]
pub enum StringPart {
    /// Plain text
    Literal(String),
    /// Interpolation expression (in AST form)
    Interpolation(Box<Expression>),
}

/// Boolean literal expression
///
/// Has only two values: `true` and `false`.
///
/// # Example
///
/// ```qlang
/// let yes = true;
/// let no = false;
/// ```
#[derive(Debug, Clone)]
pub struct BooleanExpr {
    /// The boolean value
    pub value: bool,
    /// The position of the literal
    pub span: Span,
}

impl BooleanExpr {
    /// Creates a new boolean expression
    pub fn new(value: bool, span: Span) -> Self {
        BooleanExpr { value, span }
    }
}

/// Null value expression
///
/// Represents the value of "nothing" or "undefined".
///
/// # Example
///
/// ```qlang
/// let empty = null;
/// ```
///
/// # Comparison with other languages
///
/// - JavaScript: null, undefined
/// - Python: None
/// - Rust: ()
/// - QLang: null
#[derive(Debug, Clone)]
pub struct NullExpr {
    /// Position information
    pub span: Span,
}

impl NullExpr {
    /// Creates a new null expression
    pub fn new(span: Span) -> Self {
        NullExpr { span }
    }
}

/// Identifier expression
///
/// Used to reference a variable or function.
///
/// # Example
///
/// ```qlang
/// let x = 10;
/// let y = x;  // Identifier("x")
/// ```
///
/// # Semantics
///
/// When evaluated, an identifier looks up its corresponding value in the current scope.
/// If not found, a runtime error is thrown.
#[derive(Debug, Clone)]
pub struct IdentifierExpr {
    /// The identifier name
    pub name: String,
    /// Position
    pub span: Span,
}

impl IdentifierExpr {
    /// Creates a new identifier expression
    pub fn new(name: String, span: Span) -> Self {
        IdentifierExpr { name, span }
    }
}

/// Array literal expression
///
/// # Example
///
/// ```qlang
/// let numbers = [1, 2, 3, 4, 5];
/// let mixed = [1, "hello", true, null];
/// let nested = [[1, 2], [3, 4]];
/// ```
///
/// # Characteristics
///
/// - Array elements can be values of any type
/// - Arrays can be nested
/// - Array length can change dynamically
#[derive(Debug, Clone)]
pub struct ArrayExpr {
    /// The element list
    pub elements: Vec<Expression>,
    /// Position
    pub span: Span,
}

impl ArrayExpr {
    /// Creates a new array expression
    pub fn new(elements: Vec<Expression>, span: Span) -> Self {
        ArrayExpr { elements, span }
    }
}

/// Object literal expression
///
/// # Syntax variants
///
/// ```qlang
/// // standard syntax
/// let obj1 = { name: "Alice", age: 30 };
///
/// // shorthand syntax (when the value is a variable with the same name)
/// let name = "Bob";
/// let obj2 = { name };  // equivalent to { name: name }
/// ```
///
/// # Characteristics
///
/// - Field names must be identifiers
/// - Field values can be any expression
/// - Nested objects are supported
#[derive(Debug, Clone)]
pub struct ObjectExpr {
    /// The list of object fields
    pub fields: Vec<ObjectField>,
    /// Position
    pub span: Span,
}

impl ObjectExpr {
    /// Creates a new object expression
    pub fn new(fields: Vec<ObjectField>, span: Span) -> Self {
        ObjectExpr { fields, span }
    }
}

/// Object field
///
/// # Example
///
/// ```qlang
/// { name: "Alice", age: 30 }
/// ```
///
/// Here `name: "Alice"` is an ObjectField.
#[derive(Debug, Clone)]
pub struct ObjectField {
    /// The field name
    pub name: String,
    /// The field value (optional, supporting shorthand syntax)
    pub value: Option<Expression>,
}

impl ObjectField {
    /// Creates a new object field
    pub fn new(name: String, value: Option<Expression>) -> Self {
        ObjectField {
            name,
            value,
        }
    }
}

/// Function definition expression
///
/// QLang uses arrow function syntax:
/// ```qlang
/// // no parameters
/// let greet = () -> "Hello!";
///
/// // single parameter
/// let double = (x) -> x * 2;
/// let double = x -> x * 2;  // parentheses can be omitted
///
/// // multiple parameters
/// let add = (a, b) -> a + b;
///
/// // multi-statement function body
/// let greet = (name) -> {
///     let prefix = "Hello, ";
///     return prefix + name + "!";
/// };
/// ```
///
/// # Characteristics
///
/// - The parentheses around the parameter list can be omitted (for a single parameter)
/// - The function body can be a single expression or a block
/// - A function can access the scope in which it was defined (closure)
#[derive(Debug, Clone)]
pub struct FunctionExpr {
    /// Parameter list (Rc-shared: zero-copy on every function value creation, hot-path optimization)
    pub parameters: Rc<Vec<Parameter>>,
    /// Function body (Rc-shared: zero-copy on every function value creation, hot-path optimization)
    pub body: Rc<Block>,
    /// Position
    pub span: Span,
}

impl FunctionExpr {
    /// Creates a new function expression
    pub fn new(parameters: Vec<Parameter>, body: Block, span: Span) -> Self {
        FunctionExpr {
            parameters: Rc::new(parameters),
            body: Rc::new(body),
            span,
        }
    }
}

/// Function parameter
///
/// # Example
///
/// ```qlang
/// (a, b, c) -> ...
/// ```
///
/// Here `a`, `b`, `c` are all Parameters.
#[derive(Debug, Clone)]
pub struct Parameter {
    /// The parameter name
    pub name: String,
    /// 类型标注:完整表达式,求值得到类型值(运行时断言)
    pub type_annotation: Option<Expression>,
}

impl Parameter {
    /// Creates a new parameter
    pub fn new(name: String) -> Self {
        Parameter {
            name,
            type_annotation: None,
        }
    }
}

/// Function call expression
///
/// # Syntax
///
/// ```qlang
/// // direct call
/// greet("Alice")
///
/// // chained call
/// std.Math.sqrt(16)
///
/// // nested call
/// print(add(1, 2))
/// ```
///
/// # Evaluation process
///
/// 1. Evaluate the callee expression (obtain the function)
/// 2. Evaluate all argument expressions in order (obtain the argument values)
/// 3. Execute the function with the argument values
/// 4. Return the result of the function execution
#[derive(Debug, Clone)]
pub struct CallExpr {
    /// The expression being called (usually an identifier or member access)
    pub callee: Box<Expression>,
    /// The argument list
    pub arguments: Vec<Expression>,
    /// Position
    pub span: Span,
}

impl CallExpr {
    /// Creates a new call expression
    pub fn new(callee: Box<Expression>, arguments: Vec<Expression>, span: Span) -> Self {
        CallExpr {
            callee,
            arguments,
            span,
        }
    }
}

/// Binary operator expression
///
/// A binary operator requires two operands, in the form: `left operator right`
///
/// # Supported operators
///
/// | Category | Operator | Description |
/// |------|--------|------|
/// | Arithmetic | +, -, *, /, % | addition, subtraction, multiplication, division, modulo |
/// | Comparison | ==, !=, <, <=, >, >= | equality, inequality, less than, greater than, etc. |
/// | Logical | &&, \|\| | logical AND, logical OR |
/// | Bitwise | &, \|, ^ | bitwise AND, OR, XOR |
///
/// # Example
///
/// ```qlang
/// 1 + 2        // BinaryOp(Add, 1, 2)
/// x > 0 && x < 10  // nested BinaryOp
/// ```
#[derive(Debug, Clone)]
pub struct BinaryOpExpr {
    /// The operator
    pub operator: BinaryOp,
    /// The left operand
    pub left: Box<Expression>,
    /// The right operand
    pub right: Box<Expression>,
    /// Position
    pub span: Span,
}

impl BinaryOpExpr {
    /// Creates a new binary operator expression
    pub fn new(operator: BinaryOp, left: Box<Expression>, right: Box<Expression>, span: Span) -> Self {
        BinaryOpExpr {
            operator,
            left,
            right,
            span,
        }
    }
}

/// Unary operator expression
///
/// A unary operator requires only one operand.
///
/// # Supported operators
///
/// | Operator | Description | Example |
/// |--------|------|------|
/// | - | negation | -5, -x |
/// | ! | logical NOT | !true |
/// | ? (postfix) | error propagation | f()? |
#[derive(Debug, Clone)]
pub struct UnaryOpExpr {
    /// The operator
    pub operator: UnaryOp,
    /// The operand
    pub operand: Box<Expression>,
    /// Position
    pub span: Span,
}

impl UnaryOpExpr {
    /// Creates a new unary operator expression
    pub fn new(operator: UnaryOp, operand: Box<Expression>, span: Span) -> Self {
        UnaryOpExpr {
            operator,
            operand,
            span,
        }
    }
}

/// Unary operator type
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UnaryOp {
    /// Logical NOT: `!expr`
    Not,
    /// Numeric negation: `-expr`
    Neg,
    /// Numeric plus sign: `+expr` (JSON5 number literals)
    Plus,
    /// Postfix `?` - error propagation
    Propagate,
}

/// if expression
///
/// QLang's if can be used like a ternary operator:
/// ```qlang
/// let result = if condition { value1 } else { value2 };
/// ```
///
/// # Execution logic
///
/// 1. Evaluate the condition expression
/// 2. If the condition is true, evaluate and return then_branch
/// 3. Otherwise, evaluate and return else_branch (required)
#[derive(Debug, Clone)]
pub struct IfExpr {
    /// The condition
    pub condition: Box<Expression>,
    /// The value when the condition is true
    pub then_branch: Box<Expression>,
    /// The value when the condition is false
    pub else_branch: Option<Box<Expression>>,
    /// Position
    pub span: Span,
}

impl IfExpr {
    /// Creates a new if expression
    pub fn new(
        condition: Box<Expression>,
        then_branch: Box<Expression>,
        else_branch: Option<Box<Expression>>,
        span: Span,
    ) -> Self {
        IfExpr {
            condition,
            then_branch,
            else_branch,
            span,
        }
    }
}

/// Binary operator type
///
/// Ordered by precedence from lowest to highest:
/// 0. Coalesce (??)
/// 1. Or (||)
/// 2. And (&&)
/// 3. BitwiseAnd (&), BitwiseXor (^), BitwiseOr (|)
/// 4. Eq (==), NotEq (!=), Lt (<), LtEq (<=), Gt (>), GtEq (>=)
/// 5. Add (+), Sub (-)
/// 6. Mul (*), Div (/), Mod (%)
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BinaryOp {
    /// Addition +
    Add,
    /// Subtraction -
    Sub,
    /// Multiplication *
    Mul,
    /// Division /
    Div,
    /// Modulo %
    Mod,
    /// Equal to ==
    Eq,
    /// Not equal to !=
    NotEq,
    /// Less than <
    Lt,
    /// Less than or equal to <=
    LtEq,
    /// Greater than >
    Gt,
    /// Greater than or equal to >=
    GtEq,
    /// Logical AND &&
    And,
    /// Logical OR ||
    Or,
    /// Bitwise AND &
    BitwiseAnd,
    /// Bitwise OR |
    BitwiseOr,
    /// Bitwise XOR ^
    BitwiseXor,
    /// Error coalescing `??` (lowest precedence; fallback value on error)
    Coalesce,
}

impl BinaryOp {
    /// Gets the operator precedence
    ///
    /// The larger the return value, the higher the precedence.
    /// For example: multiplication has higher precedence than addition, so `2 + 3 * 4` is equivalent to `2 + (3 * 4)`
    pub fn precedence(&self) -> u8 {
        match self {
            BinaryOp::Coalesce => 5,
            BinaryOp::Or => 10,
            BinaryOp::And => 20,
            BinaryOp::BitwiseAnd => 55,
            BinaryOp::BitwiseXor => 50,
            BinaryOp::BitwiseOr => 45,
            BinaryOp::Eq | BinaryOp::NotEq => 60,
            BinaryOp::Lt | BinaryOp::LtEq | BinaryOp::Gt | BinaryOp::GtEq => 60,
            BinaryOp::Add | BinaryOp::Sub => 70,
            BinaryOp::Mul | BinaryOp::Div | BinaryOp::Mod => 80,
        }
    }
}

/// Member access expression
///
/// Syntax: `object.field`
/// Used to access the properties of an object.
///
/// # Example
///
/// ```qlang
/// let person = { name: "Alice", age: 30 };
/// println(person.name);  // "Alice"
/// ```
///
/// # Evaluation process
///
/// 1. Evaluate the object expression (obtain the object)
/// 2. Get the specified field from the object
/// 3. If the field does not exist, throw a runtime error
#[derive(Debug, Clone)]
pub struct MemberAccessExpr {
    /// The object to access
    pub object: Box<Expression>,
    /// The name of the field to access
    pub field: String,
    /// Position
    pub span: Span,
}

impl MemberAccessExpr {
    /// Creates a new member access expression
    pub fn new(object: Box<Expression>, field: String, span: Span) -> Self {
        MemberAccessExpr {
            object,
            field,
            span,
        }
    }
}

/// Index access expression
///
/// Syntax: `array[index]`
/// Used to access the elements of an array.
///
/// # Example
///
/// ```qlang
/// let arr = [1, 2, 3, 4, 5];
/// println(arr[0]);  // 1
/// println(arr[-1]); // 5 (negative indices are supported, counting from the end)
/// ```
///
/// # Evaluation process
///
/// 1. Evaluate the object expression (obtain the array)
/// 2. Evaluate the index expression (obtain the index value)
/// 3. Convert a negative index (if any)
/// 4. Check the index range
/// 5. Return the corresponding element
#[derive(Debug, Clone)]
pub struct IndexAccessExpr {
    /// The array being accessed
    pub object: Box<Expression>,
    /// The index expression
    pub index: Box<Expression>,
    /// Position
    pub span: Span,
}

impl IndexAccessExpr {
    /// Creates a new index access expression
    pub fn new(object: Box<Expression>, index: Box<Expression>, span: Span) -> Self {
        IndexAccessExpr {
            object,
            index,
            span,
        }
    }
}

/// Import expression
///
/// Syntax: `import "module_path"`
/// Used to import external modules.
///
/// # Example
///
/// ```qlang
/// import "./utils.ql";
/// let result = utils.add(1, 2);
/// ```
///
/// # Implementation notes
///
/// The import feature works together with the module system;
/// the imported module is loaded and executed, and its exported values are returned.
#[derive(Debug, Clone)]
pub struct ImportExpr {
    /// The path of the module to import
    pub path: String,
    /// Position
    pub span: Span,
}

impl ImportExpr {
    /// Creates a new import expression
    pub fn new(path: String, span: Span) -> Self {
        ImportExpr { path, span }
    }
}

/// Trait for extracting a Span
///
/// Provides a uniform Span access interface for various AST node types.
pub trait HasSpan {
    /// Gets the source position of the node
    fn span(&self) -> Span;
}

impl HasSpan for Expression {
    fn span(&self) -> Span {
        match self {
            Expression::Number(n) => n.span,
            Expression::String(s) => s.span,
            Expression::Boolean(b) => b.span,
            Expression::Null(n) => n.span,
            Expression::Identifier(i) => i.span,
            Expression::Array(a) => a.span,
            Expression::Object(o) => o.span,
            Expression::Function(f) => f.span,
            Expression::Call(c) => c.span,
            Expression::BinaryOp(b) => b.span,
            Expression::UnaryOp(u) => u.span,
            Expression::If(i) => i.span,
            Expression::MemberAccess(m) => m.span,
            Expression::IndexAccess(i) => i.span,
            Expression::Parenthesized(p) => p.span(),
            Expression::Import(i) => i.span,
            Expression::Block(b) => b.block.span,
        }
    }
}
