/*!
 * QLang lexer module
 *
 * This module implements the QLang lexer.
 * Lexical analysis is the first step of compilation; it converts the source code string into a sequence of tokens (Token).
 *
 * # How it works
 *
 * The lexer scans the source code characters one by one with a character iterator:
 * 1. Skip whitespace and comments
 * 2. Determine the token type based on the current character
 * 3. Collect the character sequence of a complete token
 * 4. Create the corresponding Token structure
 *
 * # Token type recognition
 *
 * - Single-character tokens: `(`, `)`, `{`, `}`, `[`, `]`, `,`, `.`, `;`, `:` etc. are recognized directly
 * - Two-character tokens: `==`, `!=`, `<=`, `>=`, `&&`, `||`, `->` etc. require peeking at the next character
 * - Numbers: start with a digit, then collect consecutive digits and decimal points
 * - Identifiers: start with a letter or underscore, then collect consecutive letters, digits, and underscores
 * - Strings: support `"`, `'`, and backticks (template strings)
 *
 * # Special handling
 *
 * - Newlines are recognized as valid Newline tokens (QLang allows newlines as statement separators)
 * - Template strings support `${...}` interpolation syntax
 * - Supports line comments `//` and block comments `/* */`
 */

// Import token module types
use crate::token::{Span, StringPart, Token, TokenKind};
// Re-export LexerError from the error module
pub use crate::error::LexerError;

/// Lexer
///
/// The core struct that converts source code into a token sequence.
///
/// # Field descriptions
///
/// - `source`: reference to the raw source code string
/// - `chars`: character iterator with peek support for lookahead
/// - `start`: start position of the token currently being parsed
/// - `current`: the current character position being processed
///
/// # Usage example
///
/// ```rust
/// use qlang::lexer::Lexer;
///
/// let source = "let x = 42;";
/// let mut lexer = Lexer::new(source);
/// let tokens = lexer.tokenize().unwrap();
/// ```
pub struct Lexer<'a> {
    /// Raw source code
    source: &'a str,
    /// Character iterator with position information, supports peek
    chars: std::iter::Peekable<std::str::CharIndices<'a>>,
    /// Start position of the current token
    start: usize,
    /// Current character position (the end position of the last processed character)
    current: usize,
}

impl<'a> Lexer<'a> {
    /// Creates a new lexer
    ///
    /// # Arguments
    ///
    /// - `source`: the source code string to analyze
    ///
    /// # Implementation details
    ///
    /// - Uses `char_indices()` to get each character and its position index
    /// - Uses `peekable()` to support lookahead of the next character
    pub fn new(source: &'a str) -> Self {
        Lexer {
            source,
            chars: source.char_indices().peekable(),
            start: 0,
            current: 0,
        }
    }

    /// Performs lexical analysis, converting the source code into a token sequence
    ///
    /// This is the public API of the Lexer; call this method to start the analysis.
    ///
    /// # Execution steps
    ///
    /// 1. Create an empty token vector
    /// 2. Loop until end of file:
    ///    a. Skip whitespace and comments
    ///    b. Set the start position of the current token
    ///    c. Parse a single token
    ///    d. Add it to the token list
    /// 3. Add the end-of-file token (Eof)
    /// 4. Return all tokens
    ///
    /// # Return value
    ///
    /// - `Ok(Vec<Token>)`: success, returns the token sequence
    /// - `Err(LexerError)`: failure, returns a lexical error
    pub fn tokenize(&mut self) -> Result<Vec<Token>, LexerError> {
        // Store all parsed tokens
        let mut tokens = Vec::new();

        // Main loop: keep parsing until end of file
        while !self.is_at_end() {
            // Skip whitespace, comments, and newlines
            self.skip_whitespace_and_comments()?;
            // Check again whether we are at the end (in case there is only whitespace)
            if self.is_at_end() {
                break;
            }

            // Record the start position of the current token
            self.start = self.current;
            // Parse a single token and add it to the list
            let token = self.scan_token()?;
            tokens.push(token);
        }

        // Add the end-of-file token
        tokens.push(Token::eof(self.current));

        Ok(tokens)
    }

    /// Parses a single token
    ///
    /// Dispatches to different parse methods based on the current character type.
    /// This is the core dispatch logic of the lexer.
    ///
    /// # Processing logic
    ///
    /// 1. Get the current character
    /// 2. Match according to the character type:
    ///    - Single character: create the corresponding token directly
    ///    - Two characters: peek at the next character to decide
    ///    - Number: call number()
    ///    - Identifier: call identifier()
    ///    - String: call string() or template_string()
    ///    - Newline: create a Newline token
    /// 3. Return an error for unknown characters
    fn scan_token(&mut self) -> Result<Token, LexerError> {
        // Get the current character; return Eof if already at the end
        let c = match self.advance() {
            Some(c) => c,
            None => return Ok(Token::eof(self.current)),
        };

        // Dispatch to different handlers based on the character type
        match c {
            // ==================== Single-character tokens ====================
            // Left parenthesis: (
            '(' => self.make_token(TokenKind::LeftParen),
            // Right parenthesis: )
            ')' => self.make_token(TokenKind::RightParen),
            // Left brace: {
            '{' => self.make_token(TokenKind::LeftBrace),
            // Right brace: }
            '}' => self.make_token(TokenKind::RightBrace),
            // Left bracket: [
            '[' => self.make_token(TokenKind::LeftBracket),
            // Right bracket: ]
            ']' => self.make_token(TokenKind::RightBracket),
            // Comma: ,
            ',' => self.make_token(TokenKind::Comma),
            // Dot: . (leading decimal point .5 or member access)
            '.' => {
                if matches!(self.peek(), Some(c) if c.is_ascii_digit()) {
                    self.number()
                } else {
                    self.make_token(TokenKind::Dot)
                }
            }
            // Semicolon: ;
            ';' => self.make_token(TokenKind::Semicolon),
            // Colon: :
            ':' => self.make_token(TokenKind::Colon),
            // Plus: +
            '+' => self.make_token(TokenKind::Plus),
            // Star: *
            '*' => self.make_token(TokenKind::Star),
            // Percent: %
            '%' => self.make_token(TokenKind::Percent),
            // Bitwise XOR: ^
            '^' => self.make_token(TokenKind::BitwiseXor),

            // ==================== Two-character operators ====================
            // Minus or arrow: - or ->
            '-' => {
                if self.match_char('>') {
                    // ->
                    self.make_token(TokenKind::Arrow)
                } else {
                    // -
                    self.make_token(TokenKind::Minus)
                }
            }
            '/' => self.make_token(TokenKind::Slash),
            // Equal or equal-equal: = or ==
            '=' => {
                if self.match_char('=') {
                    // ==
                    self.make_token(TokenKind::EqualEqual)
                } else {
                    // =
                    self.make_token(TokenKind::Equal)
                }
            }
            // Bang: ! or !=
            '!' => {
                if self.match_char('=') {
                    // !=
                    self.make_token(TokenKind::NotEqual)
                } else {
                    // !
                    self.make_token(TokenKind::Bang)
                }
            }
            // Less than: < or <=
            '<' => {
                if self.match_char('=') {
                    // <=
                    self.make_token(TokenKind::LessEqual)
                } else {
                    // <
                    self.make_token(TokenKind::Less)
                }
            }
            // Greater than: > or >=
            '>' => {
                if self.match_char('=') {
                    // >=
                    self.make_token(TokenKind::GreaterEqual)
                } else {
                    // >
                    self.make_token(TokenKind::Greater)
                }
            }
            // And: & or &&
            '&' => {
                if self.match_char('&') {
                    // &&
                    self.make_token(TokenKind::And)
                } else {
                    // &
                    self.make_token(TokenKind::BitwiseAnd)
                }
            }
            // Or: | or ||
            '|' => {
                if self.match_char('|') {
                    // ||
                    self.make_token(TokenKind::Or)
                } else {
                    // |
                    self.make_token(TokenKind::BitwiseOr)
                }
            }
            // Question mark: ? or ??
            '?' => {
                if self.match_char('?') {
                    // ??
                    self.make_token(TokenKind::QuestionQuestion)
                } else {
                    // ?
                    self.make_token(TokenKind::Question)
                }
            }

            // ==================== Strings ====================
            // Double quote or single quote: ordinary string
            '"' | '\'' => self.string(c),
            // Backtick: template string (supports interpolation)
            '`' => self.template_string(),

            // ==================== Numbers ====================
            // Starting with 0-9: parse a number literal
            '0'..='9' => self.number(),

            // ==================== Identifiers and keywords ====================
            // Starting with a letter or underscore: parse an identifier or keyword
            c if c.is_alphabetic() || c == '_' => self.identifier(),

            // ==================== Newlines ====================
            '\n' | '\r' => {
                self.skip_newline_chars();
                self.make_token(TokenKind::Newline)
            }

            // ==================== Error handling ====================
            // Unknown character
            _ => Err(LexerError::UnexpectedCharacter(c, self.current)),
        }
    }

    /// Parses an ordinary string literal
    ///
    /// Supports escape sequences: `\n`, `\t`, `\r`, `\"`, `\'`, `\\`, `\$`, `\{`, `\}`
    ///
    /// Supports `${expr}` interpolation (consistent with template strings; `\$` can be escaped to a literal `$`).
    ///
    /// # Execution steps
    ///
    /// 1. Initialize the parts vector and the current literal string
    /// 2. Loop reading characters until the closing quote is encountered:
    ///    - Escape character: handle the escape sequence
    ///    - Ordinary character: append to the current literal
    /// 3. If there is an accumulated literal, add it to parts
    /// 4. Return a String-type Token
    ///
    /// # Arguments
    ///
    /// - `quote`: the quote character (`"` or `'`)
    fn string(&mut self, quote: char) -> Result<Token, LexerError> {
        // Store the parts of the string
        let mut parts = Vec::new();
        // The literal text currently being accumulated
        let mut current_literal = String::new();
        // Whether the closing quote was encountered
        let mut terminated = false;

        // Loop reading the string content
        while let Some(c) = self.peek() {
            // Encountered the closing quote, exit the loop
            if c == quote {
                self.advance();
                terminated = true;
                break;
            }

            // Bare newlines are not allowed inside strings (JSON5 requirement; a line continuation requires \ + newline)
            if c == '\n' || c == '\r' {
                return Err(LexerError::UnterminatedString(self.start));
            }

            // Handle escape sequences
            if c == '\\' {
                self.advance();
                match self.peek() {
                    None => return Err(LexerError::UnterminatedString(self.start)),
                    Some('\n') => {
                        // Backslash line continuation: consume the newline
                        self.advance();
                    }
                    Some('\r') => {
                        // Line continuation (CRLF case): consume \r and an optional \n
                        self.advance();
                        if self.peek() == Some('\n') {
                            self.advance();
                        }
                    }
                    Some(escaped) => {
                        self.advance();
                        let escaped_char = match escaped {
                            // JSON5 standard escapes
                            'b' => '\u{0008}',
                            'f' => '\u{000C}',
                            'n' => '\n',
                            'r' => '\r',
                            't' => '\t',
                            'v' => '\u{000B}',
                            '\'' => '\'',
                            '"' => '"',
                            '\\' => '\\',
                            // \0 must not be followed by a digit
                            '0' => {
                                if matches!(self.peek(), Some(c) if c.is_ascii_digit()) {
                                    return Err(LexerError::InvalidString(self.start));
                                }
                                '\0'
                            }
                            // QLang extension: interpolation marker escapes
                            '$' | '{' | '}' => escaped,
                            // Hexadecimal escape
                            'x' => self.read_hex_escape(2)?,
                            'u' => {
                                if self.peek() == Some('{') {
                                    self.advance();
                                    self.read_codepoint_escape()?
                                } else {
                                    self.read_hex_escape(4)?
                                }
                            }
                            // Unknown escape: JSON5 requires an error (the old behavior kept the \x text as-is)
                            _ => return Err(LexerError::InvalidString(self.start)),
                        };
                        current_literal.push(escaped_char);
                    }
                }
            } else if c == '$' {
                // Detect the start of interpolation: ${ (consistent with template strings)
                let dollar_pos = self.current;
                self.advance(); // consume $

                if self.peek() == Some('{') {
                    self.advance(); // consume {

                    // Save the current literal to parts
                    if !current_literal.is_empty() {
                        parts.push(StringPart::Literal(current_literal.clone()));
                        current_literal.clear();
                    }

                    // Collect the tokens inside the interpolation (shares the same implementation as template strings)
                    let interp_tokens = self.collect_interpolation_tokens(dollar_pos)?;

                    // Add the interpolation tokens to parts
                    parts.push(StringPart::Interpolation(interp_tokens));
                } else {
                    // No {, so $ is just an ordinary character
                    current_literal.push('$');
                }
            } else {
                // Ordinary character: consume and append to the current literal
                self.advance();
                current_literal.push(c);
            }
        }

        // Unterminated: no quote was encountered before EOF
        if !terminated {
            return Err(LexerError::UnterminatedString(self.start));
        }

        // If there is an accumulated literal, add it to parts
        if !current_literal.is_empty() {
            parts.push(StringPart::Literal(current_literal));
        }

        // Empty string case: add an empty literal
        if parts.is_empty() {
            parts.push(StringPart::Literal(String::new()));
        }

        // Create and return a String-type Token
        Ok(Token {
            kind: TokenKind::String(parts),
            span: Span::new(self.start, self.current),
        })
    }

    /// Reads count hexadecimal digits (2 for \xHH, 4 for \uHHHH)
    fn read_hex_escape(&mut self, count: usize) -> Result<char, LexerError> {
        let mut value: u32 = 0;
        for _ in 0..count {
            match self.peek() {
                Some(c) if c.is_ascii_hexdigit() => {
                    value = value * 16 + c.to_digit(16).unwrap();
                    self.advance();
                }
                _ => return Err(LexerError::InvalidString(self.start)),
            }
        }
        char::from_u32(value).ok_or(LexerError::InvalidString(self.start))
    }

    /// Reads \u{...}: 1-6 hexadecimal code points, until }
    fn read_codepoint_escape(&mut self) -> Result<char, LexerError> {
        let mut value: u32 = 0;
        let mut digits = 0;
        while let Some(c) = self.peek() {
            if c == '}' {
                break;
            }
            if c.is_ascii_hexdigit() && digits < 6 {
                value = value * 16 + c.to_digit(16).unwrap();
                digits += 1;
                self.advance();
            } else {
                return Err(LexerError::InvalidString(self.start));
            }
        }
        if digits == 0 || self.peek() != Some('}') {
            return Err(LexerError::InvalidString(self.start));
        }
        self.advance(); // }
        char::from_u32(value).ok_or(LexerError::InvalidString(self.start))
    }

    /// Parses a template string
    ///
    /// Template strings are wrapped in backticks and support `${expr}` interpolation.
    /// The code inside the interpolation is lexed into a token sequence, which is processed later by the Parser.
    ///
    /// # Syntax example
    ///
    /// ```qlang
    /// let name = "Alice";
    /// "Hello, ${name}!"  // result: "Hello, Alice!"
    /// ```
    ///
    /// # Execution steps
    ///
    /// 1. Initialize parts and current_literal
    /// 2. Loop reading characters until the closing backtick is encountered:
    ///    - Escape sequences: handle (same as string)
    ///    - `$` followed by `{`: start interpolation
    ///      - Save the current literal
    ///      - Recursively collect the tokens inside the interpolation (handling nested braces)
    ///      - Add the interpolation tokens to parts
    ///    - Ordinary characters: append to current_literal
    /// 3. Return a String-type Token
    fn template_string(&mut self) -> Result<Token, LexerError> {
        let mut parts = Vec::new();
        let mut current_literal = String::new();

        while let Some(&(_, c)) = self.chars.peek() {
            // Encountered the closing backtick, exit
            if c == '`' {
                self.advance();
                break;
            }

            // Handle escape sequences (same as ordinary strings)
            if c == '\\' {
                self.advance();
                if let Some(&(_, escaped)) = self.chars.peek() {
                    self.advance();
                    let escaped_char = match escaped {
                        'n' => '\n',
                        't' => '\t',
                        'r' => '\r',
                        '"' => '"',
                        '\'' => '\'',
                        '\\' => '\\',
                        '$' => '$',
                        '{' => '{',
                        '}' => '}',
                        _ => {
                            current_literal.push('\\');
                            escaped
                        }
                    };
                    current_literal.push(escaped_char);
                }
            }
            // Detect the start of interpolation: ${
            else if c == '$' {
                let dollar_pos = self.current;
                self.advance(); // consume $

                if let Some(&(_, '{')) = self.chars.peek() {
                    self.advance(); // consume {

                    // Save the current literal to parts
                    if !current_literal.is_empty() {
                        parts.push(StringPart::Literal(current_literal.clone()));
                        current_literal.clear();
                    }

                    // Collect the tokens inside the interpolation
                    let interp_tokens = self.collect_interpolation_tokens(dollar_pos)?;

                    // Add the interpolation tokens to parts
                    parts.push(StringPart::Interpolation(interp_tokens));
                } else {
                    // No {, so $ is just an ordinary character
                    current_literal.push('$');
                }
            } else {
                // Ordinary character
                self.advance();
                current_literal.push(c);
            }
        }

        // Save the final literal
        if !current_literal.is_empty() {
            parts.push(StringPart::Literal(current_literal));
        }

        Ok(Token {
            kind: TokenKind::String(parts),
            span: Span::new(self.start, self.current),
        })
    }

    /// Collects the token sequence inside a `${...}` interpolation expression
    ///
    /// Precondition: the `$` and `{` characters have already been consumed.
    ///
    /// # Responsibilities
    ///
    /// 1. Track the brace nesting depth (supports nesting such as `${{"a": 1}.a}`)
    /// 2. Handle backslash escapes inside the interpolation (as String literal tokens)
    /// 3. Hand the remaining characters to scan_interpolation_token for collection
    ///
    /// # Known limitations
    ///
    /// scan_interpolation_token cannot handle quoted strings inside the interpolation;
    /// template strings and ordinary strings (`"..."`/`'...'`) share this limitation in their interpolation.
    fn collect_interpolation_tokens(&mut self, dollar_pos: usize) -> Result<Vec<Token>, LexerError> {
        // Collect the tokens inside the interpolation
        let mut interp_tokens = Vec::new();
        let mut brace_count = 1; // track brace nesting

        while let Some(&(_, c)) = self.chars.peek() {
            if c == '{' {
                brace_count += 1;
                self.advance();
            } else if c == '}' {
                brace_count -= 1;
                self.advance();
                if brace_count == 0 {
                    break; // interpolation ended
                }
            } else if c == '\\' {
                // Handle escapes inside the interpolation
                self.advance();
                if let Some(&(_, escaped)) = self.chars.peek() {
                    self.advance();
                    interp_tokens.push(Token::new(
                        TokenKind::String(vec![StringPart::Literal(
                            format!("\\{}", escaped),
                        )]),
                        Span::new(dollar_pos, self.current),
                    ));
                }
            } else {
                // Collect a single token inside the interpolation
                interp_tokens.push(self.scan_interpolation_token()?);
            }
        }

        Ok(interp_tokens)
    }

    /// Parses a token inside a template string interpolation
    ///
    /// The syntax inside the interpolation is similar to the main syntax, but simpler (template strings do not need to be handled).
    /// This is a simplified version of scan_token.
    fn scan_interpolation_token(&mut self) -> Result<Token, LexerError> {
        self.start = self.current;

        let c = match self.advance() {
            Some(c) => c,
            None => return Ok(Token::eof(self.current)),
        };

        match c {
            '(' => self.make_token(TokenKind::LeftParen),
            ')' => self.make_token(TokenKind::RightParen),
            '{' => self.make_token(TokenKind::LeftBrace),
            '}' => self.make_token(TokenKind::RightBrace),
            '[' => self.make_token(TokenKind::LeftBracket),
            ']' => self.make_token(TokenKind::RightBracket),
            ',' => self.make_token(TokenKind::Comma),
            ':' => self.make_token(TokenKind::Colon),
            '+' => self.make_token(TokenKind::Plus),
            '-' => {
                if self.match_char('>') {
                    self.make_token(TokenKind::Arrow)
                } else {
                    self.make_token(TokenKind::Minus)
                }
            }
            '*' => self.make_token(TokenKind::Star),
            '/' => self.make_token(TokenKind::Slash),
            '%' => self.make_token(TokenKind::Percent),
            '=' => {
                if self.match_char('=') {
                    self.make_token(TokenKind::EqualEqual)
                } else {
                    self.make_token(TokenKind::Equal)
                }
            }
            '!' => {
                if self.match_char('=') {
                    self.make_token(TokenKind::NotEqual)
                } else {
                    self.make_token(TokenKind::Bang)
                }
            }
            '<' => {
                if self.match_char('=') {
                    self.make_token(TokenKind::LessEqual)
                } else {
                    self.make_token(TokenKind::Less)
                }
            }
            '>' => {
                if self.match_char('=') {
                    self.make_token(TokenKind::GreaterEqual)
                } else {
                    self.make_token(TokenKind::Greater)
                }
            }
            '&' => {
                if self.match_char('&') {
                    self.make_token(TokenKind::And)
                } else {
                    self.make_token(TokenKind::BitwiseAnd)
                }
            }
            '|' => {
                if self.match_char('|') {
                    self.make_token(TokenKind::Or)
                } else {
                    self.make_token(TokenKind::BitwiseOr)
                }
            }
            '?' => {
                if self.match_char('?') {
                    self.make_token(TokenKind::QuestionQuestion)
                } else {
                    self.make_token(TokenKind::Question)
                }
            }
            '0'..='9' => self.number(),
            c if c.is_alphabetic() || c == '_' => self.identifier(),
            _ => Err(LexerError::UnexpectedCharacter(c, self.current)),
        }
    }

    /// Parses a number literal
    ///
    /// Supports integers and decimals:
    /// - `42` - integer
    /// - `3.14` - decimal
    /// - `.5` - leading decimal point
    /// - `5.` - trailing decimal point
    ///
    /// # Execution steps
    ///
    /// 1. Set the decimal point flag to false
    /// 2. Loop collecting digits and decimal points:
    ///    - Digit: continue
    ///    - Decimal point: set the flag and continue (but multiple decimal points are not allowed)
    ///    - Other: exit
    /// 3. Extract the number string from the source
    /// 4. Parse it as f64
    fn number(&mut self) -> Result<Token, LexerError> {
        // Hexadecimal: 0x / 0X (integers only; the JSON5 spec states hex has no fraction/exponent part)
        // Note: scan_token has already consumed the first character, so check the source at start for '0' and use peek for x/X
        if self.source.as_bytes().get(self.start) == Some(&b'0')
            && matches!(self.peek(), Some('x') | Some('X'))
        {
            self.advance(); // x
            let hex_digits_start = self.current;
            while matches!(self.peek(), Some(c) if c.is_ascii_hexdigit()) {
                self.advance();
            }
            if self.current == hex_digits_start {
                // Standalone 0x / 0X
                return Err(LexerError::InvalidNumber(self.start));
            }
            let hex_str = &self.source[hex_digits_start..self.current];
            let value = i64::from_str_radix(hex_str, 16)
                .map_err(|_| LexerError::InvalidNumber(self.start))?;
            return Ok(Token {
                kind: TokenKind::Number(value as f64),
                span: Span::new(self.start, self.current),
            });
        }

        // Decimal: optional leading/trailing decimal point (.5, 5., 5.5), optional exponent (e/E ± digits)
        while matches!(self.peek(), Some(c) if c.is_ascii_digit()) {
            self.advance();
        }
        if self.peek() == Some('.') {
            self.advance();
            while matches!(self.peek(), Some(c) if c.is_ascii_digit()) {
                self.advance();
            }
        }
        if matches!(self.peek(), Some('e') | Some('E')) {
            self.advance();
            if matches!(self.peek(), Some('+') | Some('-')) {
                self.advance();
            }
            let exp_digits_start = self.current;
            while matches!(self.peek(), Some(c) if c.is_ascii_digit()) {
                self.advance();
            }
            if self.current == exp_digits_start {
                // No digits after the exponent (e.g. `1e`)
                return Err(LexerError::InvalidNumber(self.start));
            }
        }

        let num_str = &self.source[self.start..self.current];
        let value: f64 = num_str
            .parse()
            .map_err(|_| LexerError::InvalidNumber(self.start))?;
        Ok(Token {
            kind: TokenKind::Number(value),
            span: Span::new(self.start, self.current),
        })
    }

    /// Parses an identifier or keyword
    ///
    /// Identifier rules: start with a letter or underscore; subsequent characters can be letters, digits, or underscores.
    ///
    /// # Execution steps
    ///
    /// 1. Loop collecting identifier characters
    /// 2. Extract the identifier text
    /// 3. Check whether it is a keyword (let, if, while, etc.)
    /// 4. Create the corresponding Token
    fn identifier(&mut self) -> Result<Token, LexerError> {
        // Collect identifier characters
        while let Some(&(_, c)) = self.chars.peek() {
            if c.is_alphanumeric() || c == '_' {
                self.advance();
            } else {
                break;
            }
        }

        // Extract the identifier text
        let text = &self.source[self.start..self.current];

        // Check whether it is a keyword
        if let Some(kind) = TokenKind::keyword_from_str(text) {
            Ok(Token {
                kind,
                span: Span::new(self.start, self.current),
            })
        } else {
            // Ordinary identifier
            Ok(Token {
                kind: TokenKind::Identifier(text.to_string()),
                span: Span::new(self.start, self.current),
            })
        }
    }

    /// Skips whitespace and comments
    ///
    /// Supports:
    /// - Whitespace: spaces, tabs, carriage returns
    /// - Line comments: `// ...` up to the end of the line
    /// - Block comments: `/* ... */` anywhere
    fn skip_whitespace_and_comments(&mut self) -> Result<(), LexerError> {
        loop {
            match self.peek() {
                // Whitespace: consume and continue
                Some(' ') | Some('\t') | Some('\r') => {
                    self.advance();
                }
                // Slash: may be a comment
                Some('/') => {
                    if self.peek_next() == Some('/') {
                        // Line comment: consume until a newline or end of file
                        while let Some(&(_, c)) = self.chars.peek() {
                            if c == '\n' || c == '\r' {
                                break;
                            }
                            self.advance();
                        }
                    } else if self.peek_next() == Some('*') {
                        // Block comment
                        self.advance(); // consume /
                        self.advance(); // consume *
                        // Find */
                        while !(self.peek() == Some('*') && self.peek_next() == Some('/')) {
                            if self.is_at_end() {
                                return Err(LexerError::UnterminatedBlockComment(self.start));
                            }
                            self.advance();
                        }
                        self.advance(); // consume *
                        self.advance(); // consume /
                    } else {
                        // A lone slash, not a comment
                        break;
                    }
                }
                // Other characters, stop
                _ => break,
            }
        }
        Ok(())
    }

    /// Skips consecutive newline characters
    fn skip_newline_chars(&mut self) {
        while let Some(&(_, c)) = self.chars.peek() {
            if c == '\n' || c == '\r' {
                self.advance();
            } else {
                break;
            }
        }
    }

    // ==================== Character iterator helper methods ====================

    /// Advances to the next character and returns it
    ///
    /// # Return value
    ///
    /// - `Some(char)`: success, returns the next character
    /// - `None`: already at the end
    fn advance(&mut self) -> Option<char> {
        if let Some((i, c)) = self.chars.next() {
            // Update current to the index of the next character (taking UTF-8 character length into account)
            self.current = i + c.len_utf8();
            Some(c)
        } else {
            None
        }
    }

    /// Peeks at the current character (without consuming it)
    fn peek(&mut self) -> Option<char> {
        self.chars.peek().map(|&(_, c)| c)
    }

    /// Peeks at the next character (without consuming it)
    ///
    /// Requires cloning the iterator, so it is relatively expensive
    fn peek_next(&self) -> Option<char> {
        let mut iter = self.chars.clone();
        iter.next();
        iter.next().map(|(_, c)| c)
    }

    /// Checks for and consumes the specified character
    ///
    /// # Arguments
    ///
    /// - `expected`: the expected character
    ///
    /// # Return value
    ///
    /// - `true`: the current character matches and has been consumed
    /// - `false`: no match, not consumed
    fn match_char(&mut self, expected: char) -> bool {
        if self.peek() == Some(expected) {
            self.advance();
            true
        } else {
            false
        }
    }

    /// Checks whether the end of the source code has been reached
    fn is_at_end(&self) -> bool {
        self.current >= self.source.len()
    }

    /// Creates a token for the current span
    ///
    /// Uses the start and current positions to create a Span
    fn make_token(&self, kind: TokenKind) -> Result<Token, LexerError> {
        Ok(Token {
            kind,
            span: Span::new(self.start, self.current),
        })
    }
}
