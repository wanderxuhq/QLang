//! Lexer for QLang - tokenizes source code

use crate::token::{Span, StringPart, Token, TokenKind};

/// Lexer that tokenizes QLang source code
pub struct Lexer<'a> {
    source: &'a str,
    chars: std::iter::Peekable<std::str::CharIndices<'a>>,
    start: usize,
    current: usize,
}

impl<'a> Lexer<'a> {
    /// Create a new lexer for the given source
    pub fn new(source: &'a str) -> Self {
        Lexer {
            source,
            chars: source.char_indices().peekable(),
            start: 0,
            current: 0,
        }
    }

    /// Tokenize the entire source code
    pub fn tokenize(&mut self) -> Result<Vec<Token>, LexerError> {
        let mut tokens = Vec::new();

        while !self.is_at_end() {
            self.skip_whitespace_and_comments()?;
            if self.is_at_end() {
                break;
            }

            self.start = self.current;
            let token = self.scan_token()?;
            tokens.push(token);
        }

        tokens.push(Token::eof(self.current));

        Ok(tokens)
    }

    /// Scan a single token
    fn scan_token(&mut self) -> Result<Token, LexerError> {
        let c = match self.advance() {
            Some(c) => c,
            None => return Ok(Token::eof(self.current)),
        };

        match c {
            // Single character tokens
            '(' => self.make_token(TokenKind::LeftParen),
            ')' => self.make_token(TokenKind::RightParen),
            '{' => self.make_token(TokenKind::LeftBrace),
            '}' => self.make_token(TokenKind::RightBrace),
            '[' => self.make_token(TokenKind::LeftBracket),
            ']' => self.make_token(TokenKind::RightBracket),
            ',' => self.make_token(TokenKind::Comma),
            '.' => self.make_token(TokenKind::Dot),
            ';' => self.make_token(TokenKind::Semicolon),
            ':' => self.make_token(TokenKind::Colon),
            '+' => self.make_token(TokenKind::Plus),
            '*' => self.make_token(TokenKind::Star),
            '%' => self.make_token(TokenKind::Percent),
            '^' => self.make_token(TokenKind::BitwiseXor),
            '\!' => {
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

            // Strings
            '"' | '\'' => self.string(c),
            '`' => self.template_string(),

            // Numbers
            '0'..='9' => self.number(),

            // Identifiers and keywords
            c if c.is_alphabetic() || c == '_' => self.identifier(),

            // Newline
            '\n' | '\r' => {
                self.skip_newline_chars();
                self.make_token(TokenKind::Newline)
            }

            _ => Err(LexerError::UnexpectedCharacter(c, self.current)),
        }
    }

    /// Parse a string literal
    fn string(&mut self, quote: char) -> Result<Token, LexerError> {
        let mut parts = Vec::new();
        let mut current_literal = String::new();

        while let Some(&(_, c)) = self.chars.peek() {
            if c == quote {
                self.advance();
                break;
            }

            if c == '\\' {
                // Escape sequence
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
            } else {
                self.advance();
                current_literal.push(c);
            }
        }

        if !current_literal.is_empty() {
            parts.push(StringPart::Literal(current_literal));
        }

        if parts.is_empty() {
            // Empty string
            parts.push(StringPart::Literal(String::new()));
        }

        Ok(Token {
            kind: TokenKind::String(parts),
            span: Span::new(self.start, self.current),
        })
    }

    /// Parse a template string with ${...} interpolation
    fn template_string(&mut self) -> Result<Token, LexerError> {
        let mut parts = Vec::new();
        let mut current_literal = String::new();

        while let Some(&(_, c)) = self.chars.peek() {
            if c == '`' {
                self.advance();
                break;
            }

            if c == '\\' {
                // Escape sequence
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
            } else if c == '$' {
                // Check for interpolation
                let dollar_pos = self.current;
                self.advance(); // consume $

                if let Some(&(_, '{')) = self.chars.peek() {
                    self.advance(); // consume {

                    // Save current literal
                    if !current_literal.is_empty() {
                        parts.push(StringPart::Literal(current_literal.clone()));
                        current_literal.clear();
                    }

                    // Tokenize the interpolation content
                    let mut interp_tokens = Vec::new();
                    let mut brace_count = 1;

                    while let Some(&(_, c)) = self.chars.peek() {
                        if c == '{' {
                            brace_count += 1;
                            self.advance();
                        } else if c == '}' {
                            brace_count -= 1;
                            self.advance();
                            if brace_count == 0 {
                                break;
                            }
                        } else if c == '\\' {
                            // Handle escape in interpolation
                            self.advance();
                            if let Some(&(_, escaped)) = self.chars.peek() {
                                self.advance();
                                interp_tokens.push(Token::new(
                                    TokenKind::StringPart(vec![StringPart::Literal(
                                        format!("\\{}", escaped),
                                    )]),
                                    Span::new(dollar_pos, self.current),
                                ));
                            }
                        } else {
                            // Simple tokenization for interpolation
                            interp_tokens.push(self.scan_interpolation_token()?);
                        }
                    }

                    parts.push(StringPart::Interpolation(interp_tokens));
                } else {
                    current_literal.push('$');
                }
            } else {
                self.advance();
                current_literal.push(c);
            }
        }

        if !current_literal.is_empty() {
            parts.push(StringPart::Literal(current_literal));
        }

        Ok(Token {
            kind: TokenKind::String(parts),
            span: Span::new(self.start, self.current),
        })
    }

    /// Scan a single token inside template interpolation
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
            '0'..='9' => self.number(),
            c if c.is_alphabetic() || c == '_' => self.identifier(),
            _ => Err(LexerError::UnexpectedCharacter(c, self.current)),
        }
    }

    /// Parse a number literal
    fn number(&mut self) -> Result<Token, LexerError> {
        let mut has_decimal = false;

        while let Some(&(_, c)) = self.chars.peek() {
            if c.is_ascii_digit() {
                self.advance();
            } else if c == '.' {
                if has_decimal {
                    break;
                }
                has_decimal = true;
                self.advance();
            } else {
                break;
            }
        }

        let num_str = &self.source[self.start..self.current];
        let value: f64 = num_str.parse().map_err(|_| LexerError::InvalidNumber(self.start))?;

        Ok(Token {
            kind: TokenKind::Number(value),
            span: Span::new(self.start, self.current),
        })
    }

    /// Parse an identifier or keyword
    fn identifier(&mut self) -> Result<Token, LexerError> {
        while let Some(&(_, c)) = self.chars.peek() {
            if c.is_alphanumeric() || c == '_' {
                self.advance();
            } else {
                break;
            }
        }

        let text = &self.source[self.start..self.current];

        // Check if it's a keyword
        if let Some(kind) = TokenKind::keyword_from_str(text) {
            Ok(Token {
                kind,
                span: Span::new(self.start, self.current),
            })
        } else {
            Ok(Token {
                kind: TokenKind::Identifier(text.to_string()),
                span: Span::new(self.start, self.current),
            })
        }
    }

    /// Skip whitespace and comments
    fn skip_whitespace_and_comments(&mut self) -> Result<(), LexerError> {
        loop {
            match self.peek() {
                Some(' ') | Some('\t') | Some('\r') => {
                    self.advance();
                }
                Some('/') => {
                    if self.peek_next() == Some('/') {
                        // Line comment - skip until newline or end
                        while let Some(&(_, c)) = self.chars.peek() {
                            if c == '\n' || c == '\r' {
                                break;
                            }
                            self.advance();
                        }
                    } else if self.peek_next() == Some('*') {
                        // Block comment
                        self.advance(); // consume '/'
                        self.advance(); // consume '*'
                        while !(self.peek() == Some('*') && self.peek_next() == Some('/')) {
                            if self.is_at_end() {
                                return Err(LexerError::UnterminatedBlockComment(self.start));
                            }
                            self.advance();
                        }
                        self.advance(); // consume '*'
                        self.advance(); // consume '/'
                    } else {
                        break;
                    }
                }
                _ => break,
            }
        }
        Ok(())
    }

    /// Skip newline characters
    fn skip_newline_chars(&mut self) {
        while let Some(&(_, c)) = self.chars.peek() {
            if c == '\n' || c == '\r' {
                self.advance();
            } else {
                break;
            }
        }
    }

    /// Advance and return the character
    fn advance(&mut self) -> Option<char> {
        if let Some((i, c)) = self.chars.next() {
            self.current = i + c.len_utf8();
            Some(c)
        } else {
            None
        }
    }

    /// Peek at the current character
    fn peek(&self) -> Option<char> {
        self.chars.peek().map(|&(_, c)| c)
    }

    /// Peek at the next character
    fn peek_next(&self) -> Option<char> {
        let mut iter = self.chars.clone();
        iter.next();
        iter.next().map(|(_, c)| c)
    }

    /// Check if current character matches expected
    fn match_char(&mut self, expected: char) -> bool {
        if self.peek() == Some(expected) {
            self.advance();
            true
        } else {
            false
        }
    }

    /// Check if at end of input
    fn is_at_end(&self) -> bool {
        self.current >= self.source.len()
    }

    /// Create a token with the current span
    fn make_token(&self, kind: TokenKind) -> Result<Token, LexerError> {
        Ok(Token {
            kind,
            span: Span::new(self.start, self.current),
        })
    }
}

/// Lexer error types
#[derive(Debug, thiserror::Error)]
pub enum LexerError {
    #[error("Unexpected character '{0}' at position {1}")]
    UnexpectedCharacter(char, usize),

    #[error("Unterminated string starting at position {0}")]
    UnterminatedString(usize),

    #[error("Unterminated block comment starting at position {0}")]
    UnterminatedBlockComment(usize),

    #[error("Invalid number at position {0}")]
    InvalidNumber(usize),

    #[error("Unexpected end of file")]
    UnexpectedEof,
}

