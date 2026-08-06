/*!
 * QLang lexer module - token type definitions
 *
 * This module defines the token types output by the lexer.
 * Tokens are the smallest semantic units of source code, and are the output of the first step of compilation.
 *
 * # Token type hierarchy
 *
 * 1. **Literals** - tokens that directly represent values
 * 2. **Identifiers** - user-defined names such as variable names and function names
 * 3. **Keywords** - words with special meanings reserved by the language
 * 4. **Operators** - symbols that perform computations
 * 5. **Delimiters** - symbols used for grouping and separation
 * 6. **Special tokens** - newlines and the end-of-file marker
 *
 * # The role of Span
 *
 * Every token is associated with a Span that records its position in the source code:
 * - `start` - the start position of the token (character offset)
 * - `end` - the end position of the token (character offset)
 *
 * This information is very important for error reporting and debugging, allowing issues to be located precisely.
 */

/// Source code position span
///
/// A Span records the start and end positions of a contiguous region in the source code.
/// It is a half-open interval [start, end); end is not included in the interval.
///
/// # Example
///
/// If the source code is `let x = 1;`, where `let` is located at positions 0-3,
/// then Span { start: 0, end: 3 } represents this interval.
///
/// Use cases:
/// - Error location: when a syntax or runtime error occurs, the Span is used to indicate the error position
/// - Debugging information: helps developers quickly locate the problematic code
/// - Source mapping: maintains the correspondence with the source code in multi-level error reporting
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Span {
    /// Start position (inclusive), character offset starting from 0
    pub start: usize,
    /// End position (exclusive), i.e., the index of the next character
    pub end: usize,
}

impl Default for Span {
    /// Position 0:0 — used for internal calls without a source position
    fn default() -> Self {
        Span { start: 0, end: 0 }
    }
}

impl Span {
    /// Creates a new Span
    ///
    /// # Arguments
    ///
    /// - `start` - the start position index
    /// - `end` - the end position index
    ///
    /// # Example
    ///
    /// ```
    /// use qlang::token::Span;
    ///
    /// let span = Span::new(0, 3);  // represents the interval [0, 3)
    /// ```
    pub fn new(start: usize, end: usize) -> Self {
        Span { start, end }
    }

    /// Merges two Spans
    ///
    /// Creates a new Span whose range covers the union of the two original Spans.
    /// The new start position is the minimum of the two start positions,
    /// and the new end position is the maximum of the two end positions.
    ///
    /// # Example
    ///
    /// ```
    /// use qlang::token::Span;
    ///
    /// let span1 = Span::new(0, 3);
    /// let span2 = Span::new(5, 8);
    /// let merged = span1.merge(&span2);  // Span { start: 0, end: 8 }
    /// ```
    pub fn merge(&self, other: &Span) -> Span {
        Span {
            start: self.start.min(other.start),
            end: self.end.max(other.end),
        }
    }
}

/// Component of a string literal
///
/// Used to support the syntax sugar of template strings.
/// A template string consists of multiple parts, each of which can be:
/// - Literal text (Literal) - ordinary string content
/// - Interpolation - an expression inside `${...}`
///
/// # Example
///
/// For the template string `"Hello, ${name}!"`:
/// - `StringPart::Literal("Hello, ".to_string())`
/// - `StringPart::Interpolation(vec![...])` - the token sequence containing the name identifier
/// - `StringPart::Literal("!".to_string())`
#[derive(Debug, Clone, PartialEq)]
pub enum StringPart {
    /// Ordinary text part, containing no expressions
    Literal(String),
    /// Interpolation part, containing a token sequence (the expression to be parsed)
    /// Uses Vec<Token> instead of storing an Expression directly, to avoid circular dependencies
    Interpolation(Vec<Token>),
}

/// Token type enum
///
/// Enumerates all token types in the QLang language.
/// Each variant carries the additional data required by that type (such as the value of a number, the content of a string, etc.).
///
/// # Operator precedence reference
///
/// QLang operator precedence from lowest to highest:
/// 0. `??` (Coalesce) - lowest precedence
/// 1. `||` (Or)
/// 2. `&&` (And)
/// 3. `&` (BitwiseAnd) | `^` (BitwiseXor) | `|` (BitwiseOr)
/// 4. `==` `!=` `<` `<=` `>` `>=` (comparison operators)
/// 5. `+` `-` (addition and subtraction)
/// 6. `*` `/` `%` (multiplication, division, modulo) - highest precedence
#[derive(Debug, Clone, PartialEq)]
pub enum TokenKind {
    // ==================== Literals ====================
    /// Number literal, such as `42`, `3.14`, `-10`
    /// Carries the actual value as f64
    Number(f64),
    /// String literal, supports ordinary strings and template strings
    /// Carries a StringPart vector describing the parts of the string
    String(Vec<StringPart>),
    /// Boolean literal `true`
    True,
    /// Boolean literal `false`
    False,

    // ==================== Identifiers ====================
    /// Identifier (user-defined names such as variable names and function names)
    /// Carries the string content of the identifier
    Identifier(String),

    // ==================== Keywords ====================
    /// Keyword `let` - used for variable declarations
    Let,
    /// Keyword `if` - the beginning of a conditional statement
    If,
    /// Keyword `else` - the alternative branch of a conditional statement
    Else,
    /// Keyword `while` - loop statement
    While,
    /// Keyword `return` - function return value
    Return,
    /// Keyword `import` - import a module
    Import,
    /// Keyword `export` - export a module
    Export,
    /// Keyword `null` - null value
    Null,

    // ==================== Operators ====================
    /// Addition operator `+`
    Plus,
    /// Subtraction operator `-` (also unary negation)
    Minus,
    /// Multiplication operator `*`
    Star,
    /// Division operator `/`
    Slash,
    /// Modulo operator `%`
    Percent,
    /// Assignment operator `=`
    Equal,
    /// Equality comparison operator `==`
    EqualEqual,
    /// Inequality comparison operator `!=`
    NotEqual,
    /// Less-than comparison operator `<`
    Less,
    /// Less-than-or-equal comparison operator `<=`
    LessEqual,
    /// Greater-than comparison operator `>`
    Greater,
    /// Greater-than-or-equal comparison operator `>=`
    GreaterEqual,
    /// Logical AND operator `&&`
    And,
    /// Logical OR operator `||`
    Or,
    /// Bitwise AND operator `&`
    BitwiseAnd,
    /// Bitwise OR operator `|`
    BitwiseOr,
    /// Bitwise XOR operator `^`
    BitwiseXor,
    /// Arrow operator `->` - used for function parameter and return type annotations
    Arrow,
    /// Double arrow operator `=>` - used for arrow function bodies
    DoubleArrow,
    /// Logical NOT operator `!` (also bitwise NOT)
    Bang,

    // ==================== Delimiters ====================
    /// Left parenthesis `(` - function calls, expression grouping
    LeftParen,
    /// Right parenthesis `)`
    RightParen,
    /// Left brace `{` - code blocks, object literals
    LeftBrace,
    /// Right brace `}`
    RightBrace,
    /// Left bracket `[` - array literals, index access
    LeftBracket,
    /// Right bracket `]`
    RightBracket,
    /// Comma `,` - separates arguments, array elements, and object fields
    Comma,
    /// Dot `.` - member access, decimal point
    Dot,
    /// Semicolon `;` - statement terminator (optional)
    Semicolon,
    /// Colon `:` - type annotations, object field shorthand
    Colon,
    /// Question mark `?` - postfix error propagation
    Question,
    /// Double question mark `??` - error coalescing (fallback value)
    QuestionQuestion,

    // ==================== Special tokens ====================
    /// Newline - used to separate statements (a valid separator in QLang)
    Newline,
    /// End-of-file marker - indicates there are no more tokens
    Eof,
}

impl TokenKind {
    /// Checks whether the current token is a keyword
    ///
    /// Keywords are reserved words with special meanings in the language,
    /// and cannot be used as variable names or function names.
    ///
    /// # Return value
    ///
    /// - `true` - it is a keyword
    /// - `false` - it is not a keyword (it is an identifier or something else)
    ///
    /// # Example
    ///
    /// ```
    /// use qlang::token::TokenKind;
    ///
    /// assert!(TokenKind::Let.is_keyword());      // true
    /// assert!(!TokenKind::Identifier("x".to_string()).is_keyword());  // false
    /// ```
    pub fn is_keyword(&self) -> bool {
        matches!(
            self,
            TokenKind::Let
                | TokenKind::If
                | TokenKind::Else
                | TokenKind::While
                | TokenKind::Return
                | TokenKind::Import
                | TokenKind::Export
                | TokenKind::True
                | TokenKind::False
                | TokenKind::Null
        )
    }

    /// Gets the corresponding keyword token from a string
    ///
    /// Converts a string literal into the corresponding TokenKind (if it is a keyword).
    /// This is very useful for recognizing keywords during lexical analysis.
    ///
    /// # Arguments
    ///
    /// - `s` - the string to check
    ///
    /// # Return value
    ///
    /// - `Some(TokenKind)` - if the string is a keyword
    /// - `None` - if the string is not a keyword (it may be an identifier)
    ///
    /// # Example
    ///
    /// ```
    /// use qlang::token::TokenKind;
    ///
    /// assert_eq!(TokenKind::keyword_from_str("let"), Some(TokenKind::Let));
    /// assert_eq!(TokenKind::keyword_from_str("if"), Some(TokenKind::If));
    /// assert_eq!(TokenKind::keyword_from_str("myVar"), None);
    /// ```
    pub fn keyword_from_str(s: &str) -> Option<TokenKind> {
        match s {
            "let" => Some(TokenKind::Let),
            "if" => Some(TokenKind::If),
            "else" => Some(TokenKind::Else),
            "while" => Some(TokenKind::While),
            "return" => Some(TokenKind::Return),
            "import" => Some(TokenKind::Import),
            "export" => Some(TokenKind::Export),
            "true" => Some(TokenKind::True),
            "false" => Some(TokenKind::False),
            "null" => Some(TokenKind::Null),
            _ => None,
        }
    }

    /// Reverse-maps a keyword TokenKind back to a string (object keys need the original text)
    pub fn keyword_to_str(kind: &TokenKind) -> Option<&'static str> {
        match kind {
            TokenKind::Let => Some("let"),
            TokenKind::If => Some("if"),
            TokenKind::Else => Some("else"),
            TokenKind::While => Some("while"),
            TokenKind::Return => Some("return"),
            TokenKind::Import => Some("import"),
            TokenKind::Export => Some("export"),
            TokenKind::True => Some("true"),
            TokenKind::False => Some("false"),
            TokenKind::Null => Some("null"),
            _ => None,
        }
    }
}

/// Token
///
/// A token is the output unit of lexical analysis, containing:
/// - Token type (kind) - the semantic category of the token
/// - Source code position (span) - the position of the token in the source code
///
/// # Example
///
/// For the source code `let x = 1;`, the following tokens are produced:
/// ```text
/// Token { kind: TokenKind::Let, span: Span { start: 0, end: 3 } }
/// Token { kind: TokenKind::Identifier("x"), span: Span { start: 4, end: 5 } }
/// Token { kind: TokenKind::Equal, span: Span { start: 6, end: 7 } }
/// Token { kind: TokenKind::Number(1.0), span: Span { start: 8, end: 9 } }
/// Token { kind: TokenKind::Semicolon, span: Span { start: 9, end: 10 } }
/// ```
#[derive(Debug, Clone, PartialEq)]
pub struct Token {
    /// The type of the token, describing what kind of token it is
    pub kind: TokenKind,
    /// The position range of the token in the source code
    pub span: Span,
}

impl Token {
    /// Creates a new token
    ///
    /// # Arguments
    ///
    /// - `kind` - the type of the token
    /// - `span` - the position of the token in the source code
    ///
    /// # Example
    ///
    /// ```
    /// use qlang::token::{Token, TokenKind, Span};
    ///
    /// let token = Token::new(
    ///     TokenKind::Let,
    ///     Span::new(0, 3)
    /// );
    /// ```
    pub fn new(kind: TokenKind, span: Span) -> Self {
        Token { kind, span }
    }

    /// Creates an end-of-file token
    ///
    /// The end-of-file token is the last token in every token sequence,
    /// used to indicate that there is no more input to process.
    ///
    /// # Arguments
    ///
    /// - `position` - the position of the end of file
    ///
    /// # Example
    ///
    /// ```
    /// use qlang::token::Token;
    ///
    /// let eof = Token::eof(100);  // assume the file is 100 characters long
    /// ```
    pub fn eof(position: usize) -> Self {
        Token {
            kind: TokenKind::Eof,
            span: Span::new(position, position),
        }
    }
}
