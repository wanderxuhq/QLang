/*!
 * QLang - a dynamically typed programming language interpreter
 *
 * This module provides a complete interpreter implementation for the QLang programming language, including the following core components:
 *
 * # Architecture overview
 *
 * The QLang interpreter follows the classic compiler/interpreter architecture:
 * 1. **Lexer** - converts source code into a sequence of tokens
 * 2. **Parser** - converts the token sequence into an abstract syntax tree (AST)
 * 3. **Interpreter** - directly executes the AST to produce results
 *
 * # Language features
 *
 * - Dynamic type system
 * - Functional programming support (arrow functions, closures, currying)
 * - Object-oriented features (object literals, member access)
 * - Control flow (if-else, while loops)
 * - Code blocks as expressions
 * - Negative array index support
 * - Template strings
 * - Module import/export
 *
 * # Usage example
 *
 * ```rust
 * use qlang::Interpreter;
 *
 * let mut interpreter = Interpreter::new();
 * let result = interpreter.run_source("let x = 1 + 2; println(x);", "repl".to_string());
 * ```
 */

/// Token module - converts source code into a sequence of tokens
///
/// Lexical analysis is the first step of compilation; it identifies the basic syntactic units (tokens) in the source code.
/// For example, the source code `let x = 1;` is decomposed into the tokens: `let`, `x`, `=`, `1`, `;`.
pub mod token;

/// Lexer module - implements the conversion from source code to tokens
///
/// The Lexer scans the source code with a character iterator, recognizing:
/// - keywords (let, if, while, return, etc.)
/// - identifiers (variable names, function names)
/// - literals (numbers, strings, booleans)
/// - operators (+, -, *, /, ==, &&, etc.)
/// - delimiters (parentheses, braces, brackets, etc.)
pub mod lexer;

/// Abstract syntax tree module - defines the program's intermediate representation
///
/// The AST is a tree-shaped representation of the program structure; each node represents a syntactic construct:
/// - expression nodes: numbers, strings, function calls, binary operations, etc.
/// - statement nodes: variable declarations, assignments, conditional statements, loops, etc.
///
/// The AST is the bridge between lexical analysis and interpreted execution, making the program structure easier to analyze and process.
pub mod ast;

/// Parser module - converts a token sequence into an AST
///
/// The Parser uses recursive descent parsing to organize the token sequence into meaningful syntactic structures.
/// It follows QLang's grammar rules and builds the corresponding AST node tree.
pub mod parser;

/// Value system module - defines the runtime data types
///
/// The Value enum represents all runtime value types supported by QLang:
/// - Number - backed by Rust's f64 type
/// - String - backed by Rust's String type
/// - Boolean - true and false
/// - Null - represents "nothing" or "undefined"
/// - Array - a dynamically sized collection of elements
/// - Object - a mapping of key-value pairs
/// - Function - an executable unit of code
pub mod value;

/// Environment module - manages variable bindings and scopes
///
/// Environment uses a HashMap to store the mapping from variable names to values,
/// supporting nested scopes (lexical scoping) and implementing closures.
pub mod environment;

/// Interpreter module - executes the AST to produce results
///
/// The Interpreter is QLang's core execution engine:
/// - receives the token sequence from the Lexer
/// - receives the AST from the Parser
/// - traverses the AST and executes each node
/// - manages the call stack and scopes
pub mod interpreter;

/// Error handling module - defines all possible error types
///
/// QLang's error system is divided into three layers:
/// - LexerError - lexical analysis errors (illegal characters, unterminated strings, etc.)
/// - ParseError - parsing errors (unexpected tokens, missing expected tokens, etc.)
/// - RuntimeError - runtime errors (undefined variables, type mismatches, etc.)
pub mod error;

/// Standard library module - built-in functions and objects
///
/// The standard library provides commonly used built-in functions and objects:
/// - std.Array - array operations (length, push, pop, indexOf, etc.)
/// - std.Object - object operations (keys, get, etc.)
/// - std.String - string operations (length, includes, toUpperCase, etc.)
/// - std.Number - number operations (isFinite, isNaN, parseFloat, etc.)
/// - std.Math - math functions (sqrt, abs, pow, max, PI, etc.)
pub mod stdlib;

/// Re-exports the commonly used public API
///
/// These types are the interfaces most frequently used by users:
/// - Interpreter - the main interpreter type
/// - QLangError - the unified error type
/// - RuntimeError - the runtime error type
pub use interpreter::Interpreter;
pub use error::QLangError;
pub use value::RuntimeError;
