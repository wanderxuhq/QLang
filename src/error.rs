/*!
 * QLang error handling module
 *
 * This module defines all error types of the QLang language.
 * Errors are divided into three levels: lexical analysis errors, syntax analysis errors, and runtime errors.
 */

use crate::token::{Span, Token};
use thiserror::Error;

/// Lexical analysis error
///
/// Errors that occur during the lexical analysis phase (converting the source code into a token sequence).
/// For example: illegal characters, unterminated strings, invalid number formats, etc.
///
/// # Common errors
///
/// - `UnexpectedCharacter` - encountered an unrecognizable character
/// - `UnterminatedString` - a string without a closing quote
/// - `UnterminatedBlockComment` - a block comment without a closing marker
/// - `InvalidNumber` - invalid number format
/// - `UnexpectedEof` - the file ended unexpectedly
#[derive(Debug, Error)]
pub enum LexerError {
    /// Encountered an unexpected character
    #[error("Unexpected character '{0}' at position {1}")]
    UnexpectedCharacter(char, usize),

    /// Unterminated string
    #[error("Unterminated string starting at position {0}")]
    UnterminatedString(usize),

    /// Unterminated block comment
    #[error("Unterminated block comment starting at position {0}")]
    UnterminatedBlockComment(usize),

    /// Invalid number
    #[error("Invalid number at position {0}")]
    InvalidNumber(usize),

    /// Invalid escape sequence
    #[error("Invalid escape sequence in string starting at position {0}")]
    InvalidString(usize),

    /// The file ended unexpectedly
    #[error("Unexpected end of file")]
    UnexpectedEof,
}

/// Syntax analysis error
///
/// Errors that occur during the syntax analysis phase (converting a token sequence into an AST).
/// For example: unexpected tokens, missing expected tokens, syntax structure errors, etc.
///
/// # Common errors
///
/// - `UnexpectedToken` - encountered an unexpected token
/// - `Expected` - expected a specific type of token but got another type
/// - `ExpectedIdentifier` - expected an identifier but got something else
/// - `InvalidAssignTarget` - invalid assignment target
/// - `InvalidParameter` - invalid function parameter
/// - `EmptyParentheses` - empty parentheses (not allowed)
/// - `InvalidImportPath` - invalid import path
/// - `ExpectedImportPath` - expected an import path
#[derive(Debug, Error)]
pub enum ParseError {
    /// Unexpected token
    #[error("Unexpected token: {0:?}")]
    UnexpectedToken(Token),

    /// Missing expected token
    #[error("Expected {0}, got {1:?}")]
    Expected(String, Token),

    /// Expected an identifier
    #[error("Expected identifier, got {0:?}")]
    ExpectedIdentifier(Token),

    /// Invalid assignment target
    #[error("Invalid assignment target at {0:?}")]
    InvalidAssignTarget(Span),

    /// Invalid function parameter
    #[error("Invalid parameter at {0:?}")]
    InvalidParameter(Span),

    /// Empty parentheses
    #[error("Empty parentheses at {0:?}")]
    EmptyParentheses(Span),

    /// Invalid import path
    #[error("Invalid import path at {0:?}")]
    InvalidImportPath(Span),

    /// Expected an import path
    #[error("Expected import path at {0:?}")]
    ExpectedImportPath(Span),

    /// The file ended unexpectedly
    #[error("Unexpected end of file")]
    UnexpectedEof,
}

/// Runtime error
///
/// Errors that occur during the interpretation/execution phase.
/// For example: undefined variables, type mismatches, index out of bounds, etc.
///
/// # Common errors
///
/// - `UndefinedVariable` - using an undefined variable
/// - `UndefinedField` - accessing a field that does not exist on an object
/// - `TypeMismatch` - type mismatch
/// - `NotCallable` - attempting to call a non-callable value
/// - `ArityMismatch` - mismatch in the number of arguments
/// - `IndexOutOfBounds` - array index out of bounds
/// - `DivisionByZero` - division by zero
#[derive(Debug, Error)]
pub enum RuntimeError {
    /// Undefined variable
    #[error("Undefined variable: '{0}'")]
    UndefinedVariable(String),

    /// Undefined field
    #[error("Undefined field: '{0}' on object")]
    UndefinedField(String),

    /// Type mismatch (unary operation)
    #[error("Type error: cannot '{operation}' on value of type '{value_type}'")]
    TypeMismatch {
        operation: String,
        value_type: String,
    },

    /// Type mismatch (binary operation)
    #[error("Type error: cannot apply '{operation}' between '{left_type}' and '{right_type}'")]
    TypeMismatchBinOp {
        operation: String,
        left_type: String,
        right_type: String,
    },

    /// Not callable
    #[error("Type error: cannot call '{0}' (only functions can be called)")]
    NotCallable(String),

    /// Mismatch in the number of arguments
    #[error("Type error: expected {expected} arguments, got {got}")]
    ArityMismatch { expected: usize, got: usize },

    /// Cannot be indexed
    #[error("Type error: cannot index into value of type '{found}' (only arrays can be indexed)")]
    CannotIndex { found: String },

    /// Index out of bounds
    #[error("Index out of bounds: {0} (array length is {1})")]
    IndexOutOfBounds(usize, usize),

    /// Not an object type
    #[error("Type error: cannot access field on value of type '{found}' (expected object)")]
    NotAnObject { found: String },

    /// IO error
    #[error("IO error: {0}")]
    IoError(String),

    /// Division by zero
    #[error("Division by zero")]
    DivisionByZero,

    /// Stack overflow
    #[error("Stack overflow: maximum recursion depth exceeded")]
    StackOverflow,

    /// Custom runtime error
    #[error("Runtime error: {0}")]
    Custom(String),
}

/// Unified QLang error type
///
/// Unifies errors from all levels into a single enum,
/// using the `#[from]` attribute for automatic conversion.
///
/// # Usage example
///
/// ```rust
/// use qlang::error::QLangError;
///
/// let result: Result<(), QLangError> = Ok(());
/// match result {
///     Ok(value) => println!("Result: {:?}", value),
///     Err(QLangError::LexerError(e)) => println!("Lexer error: {:?}", e),
///     Err(QLangError::ParseError(e)) => println!("Parse error: {:?}", e),
///     Err(QLangError::RuntimeError(e)) => println!("Runtime error: {:?}", e),
/// }
/// ```
#[derive(Debug, Error)]
pub enum QLangError {
    /// Lexical analysis error
    #[error("Lexer error: {0}")]
    LexerError(#[from] LexerError),

    /// Syntax analysis error
    #[error("Parse error: {0}")]
    ParseError(#[from] ParseError),

    /// Runtime error
    #[error("Runtime error: {0}")]
    RuntimeError(#[from] RuntimeError),
}

/// Source code location
///
/// Used for error reporting and debugging information.
/// Records the file, line number, and column number.
#[derive(Debug, Clone)]
pub struct SourceLocation {
    /// File name
    pub file: String,
    /// Line number (starting from 1)
    pub line: usize,
    /// Column number (starting from 1)
    pub column: usize,
}

impl SourceLocation {
    /// Creates a source location from a character offset
    ///
    /// Computes the line and column numbers based on the offset.
    ///
    /// # Arguments
    ///
    /// - `source` - the source code text
    /// - `offset` - the character offset
    ///
    /// # Example
    ///
    /// ```
    /// use qlang::error::SourceLocation;
    ///
    /// let source = "line1\nline2\nline3";
    /// let loc = SourceLocation::from_offset(source, 10);  // offset 10 is within "line2"
    /// assert_eq!(loc.line, 2);
    /// ```
    pub fn from_offset(source: &str, offset: usize) -> Self {
        let mut line = 1;
        let mut column = 1;

        for (i, c) in source.chars().enumerate() {
            if i >= offset {
                break;
            }
            if c == '\n' {
                line += 1;
                column = 1;
            } else {
                column += 1;
            }
        }

        SourceLocation {
            file: "<unknown>".to_string(),
            line,
            column,
        }
    }
}

/// Formats a lexical error (with source code context)
///
/// Produces compiler-like error output, including:
/// - The error message
/// - The file position (file:line:column)
/// - The source code line
/// - The error position indicator (^ characters)
///
/// # Output example
///
/// ```text
/// error: Unexpected character '@' at position 5
///   --> test.ql:1:6
///    |
///  1 | let x @ 5;
///    |      ^
/// ```
pub fn format_lexer_error(source: &str, message: &str, span: &Span) -> String {
    let loc = SourceLocation::from_offset(source, span.start);

    // Find the start and end positions of the current line
    let line_start = source[..span.start].rfind('\n').map(|i| i + 1).unwrap_or(0);
    let line_end = source[span.start..]
        .find('\n')
        .map(|i| span.start + i)
        .unwrap_or(source.len());
    let line_content = &source[line_start..line_end];

    let pointer_offset = span.start - line_start;
    let pointer_len = (span.end - span.start).max(1);

    format!(
        "error: {}\n  --> {}:{}:{}\n   |\n{:>3} | {}\n   | {}{}\n",
        message,
        loc.file,
        loc.line,
        loc.column,
        loc.line,
        line_content,
        " ".repeat(pointer_offset),
        "^".repeat(pointer_len)
    )
}

/// Formats a syntax analysis error (with source code context)
pub fn format_parse_error(source: &str, message: &str, span: &Span) -> String {
    let loc = SourceLocation::from_offset(source, span.start);

    let line_start = source[..span.start].rfind('\n').map(|i| i + 1).unwrap_or(0);
    let line_end = source[span.start..]
        .find('\n')
        .map(|i| span.start + i)
        .unwrap_or(source.len());
    let line_content = &source[line_start..line_end];

    let pointer_offset = span.start - line_start;
    let pointer_len = (span.end - span.start).max(1);

    format!(
        "error: {}\n  --> {}:{}:{}\n   |\n{:>3} | {}\n   | {}{}\n",
        message,
        loc.file,
        loc.line,
        loc.column,
        loc.line,
        line_content,
        " ".repeat(pointer_offset),
        "^".repeat(pointer_len)
    )
}

/// Formats a runtime error (with source code context)
pub fn format_runtime_error(source: &str, message: &str, span: &Span) -> String {
    let loc = SourceLocation::from_offset(source, span.start);

    let line_start = source[..span.start].rfind('\n').map(|i| i + 1).unwrap_or(0);
    let line_end = source[span.start..]
        .find('\n')
        .map(|i| span.start + i)
        .unwrap_or(source.len());
    let line_content = &source[line_start..line_end];

    let pointer_offset = span.start - line_start;
    let pointer_len = (span.end - span.start).max(1);

    format!(
        "error: {}\n  --> {}:{}:{}\n   |\n{:>3} | {}\n   | {}{}\n",
        message,
        loc.file,
        loc.line,
        loc.column,
        loc.line,
        line_content,
        " ".repeat(pointer_offset),
        "^".repeat(pointer_len)
    )
}

/// Gets a friendly type name
///
/// Converts internal type names into user-friendly display names.
/// For example: "Number" -> "number"
///
/// # Return value mapping
///
/// - "Number" -> "number"
/// - "String" -> "string"
/// - "Boolean" -> "boolean"
/// - "Array" -> "array"
/// - "Object" -> "object"
/// - "Function" -> "function"
/// - "Void" -> "void"
/// - Other -> lowercase form
pub fn friendly_type_name(ty: &str) -> String {
    match ty {
        "Number" => "number".to_string(),
        "String" => "string".to_string(),
        "Boolean" => "boolean".to_string(),
        "Array" => "array".to_string(),
        "Object" => "object".to_string(),
        "Function" => "function".to_string(),
        "Void" => "void".to_string(),
        _ => ty.to_string().to_lowercase(),
    }
}
