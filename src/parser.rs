/*!
 * QLang parser module
 *
 * This module implements QLang's parser (Parser).
 * The parser's responsibility is to convert the token sequence produced by the lexer (Token) into an abstract syntax tree (AST).
 *
 * # Workflow
 *
 * 1. The Parser receives the token list produced by the lexer
 * 2. Starting from the first token, parse one by one according to QLang grammar rules
 * 3. Build the corresponding AST node tree
 * 4. Return the complete Program node
 *
 * # Core methods
 *
 * - parse() - program entry point, parses the entire source file
 * - parse_statement() - parses a single statement
 * - parse_expression() - parses an expression (with operator precedence)
 * - parse_primary() - parses a primary expression (literals, identifiers, etc.)
 *
 * # Parsing techniques
 *
 * - Recursive descent parsing - each grammar rule corresponds to a parse function
 * - Precedence climbing - handles binary operator precedence
 * - Predictive parsing - decides which parse rule to use based on the current token
 */

use crate::ast::*;
use crate::token::{Span, Token, TokenKind};
use crate::error::ParseError;

/// The parser
///
/// Core struct, containing:
/// - tokens: the token sequence to be parsed
/// - current: index of the current parse position
/// - source: the original source code (used for error reporting and string interpolation parsing)
pub struct Parser {
    /// The token sequence, obtained from the lexer
    tokens: Vec<Token>,
    /// Index of the current parse position, pointing to the next token to be processed
    current: usize,
    /// The original source code string
    source: String,
}

impl Parser {
    /// Creates a new parser
    ///
    /// # Parameters
    ///
    /// - `tokens`: the token sequence output by the lexer
    /// - `source`: the original source code
    pub fn new(tokens: Vec<Token>, source: String) -> Self {
        // Ensure the token sequence ends with EOF: the normal tokenize() path already appends EOF,
        // but the token list produced by string interpolation (see Lexer::collect_interpolation_tokens)
        // does not append EOF. Without EOF, peek() would panic with an out-of-bounds access when going past the end.
        let tokens = match tokens.last() {
            Some(t) if t.kind == TokenKind::Eof => tokens,
            _ => {
                let mut tokens = tokens;
                let pos = tokens.last().map(|t| t.span.end).unwrap_or(0);
                tokens.push(Token::eof(pos));
                tokens
            }
        };
        Parser { tokens, current: 0, source }
    }

    /// Parse entry point - parses the token sequence into a complete program
    ///
    /// This is the public API of the Parser; external callers call this method to start parsing.
    /// Parsing process:
    /// 1. Record the start position
    /// 2. Loop parsing statements until end of file
    /// 3. Create a Program node and return it
    ///
    /// # Example
    ///
    /// ```rust
    /// use qlang::lexer::Lexer;
    /// use qlang::parser::Parser;
    ///
    /// let source = "let x = 1;";
    /// let tokens = Lexer::new(source).tokenize().unwrap();
    /// let mut parser = Parser::new(tokens, source.to_string());
    /// let program = parser.parse().unwrap();
    /// ```
    pub fn parse(&mut self) -> Result<Program, ParseError> {
        // Record the start position of the program
        let start = self.current_span().start;
        // Store the parsed statements
        let mut statements = Vec::new();

        // Loop parsing statements until end of file
        while !self.is_at_end() {
            // Skip blank lines between statements
            self.skip_newlines();
            // Check again whether we are at the end (to guard against the case of only blank lines)
            if self.is_at_end() {
                break;
            }
            // Parse a single statement and add it to the list
            statements.push(self.parse_statement()?);
            // Consume the statement terminator (semicolon or newline)
            self.consume_statement_end()?;
        }

        // Record the end position of the program
        let end = self.previous().span.end;

        // Create and return the Program node
        Ok(Program::new(statements, Span::new(start, end)))
    }

    /// Parses a single statement
    ///
    /// A statement is a syntactic construct that does not produce a value, used to control program flow.
    /// Based on the current token type, dispatch to different parse functions.
    ///
    /// # Supported statement types
    ///
    /// - `let` - variable declaration statement
    /// - `if` - conditional statement
    /// - `while` - loop statement
    /// - `return` - return statement
    /// - `export` - export statement
    /// - others - expression statement or assignment statement
    fn parse_statement(&mut self) -> Result<Statement, ParseError> {
        self.skip_newlines();

        // Return an error early at end of file
        if self.is_at_end() {
            return Err(ParseError::UnexpectedEof);
        }

        // Dispatch to the corresponding parse function based on the current token type
        match &self.peek().kind {
            // Variable declaration: let x = 10;
            TokenKind::Let => self.parse_let_statement(),
            // if can be parsed as a statement or an expression, depending on the context
            // Here it is parsed as an expression, letting the interpreter decide whether the return value is needed
            TokenKind::If => self.parse_if_as_statement(),
            // Loop statement: while cond { ... }
            TokenKind::While => self.parse_while_statement(),
            // Return statement: return value;
            TokenKind::Return => self.parse_return_statement(),
            // Export statement: export value;
            TokenKind::Export => self.parse_export_statement(),
            // Else cannot start a statement on its own; it always attaches to an if
            // If it appears alone, that is a syntax error
            TokenKind::Else => Err(ParseError::UnexpectedToken(self.peek().clone())),
            _ => self.parse_expression_or_assignment(),
        }
    }

    fn statement_needs_end(stmt: &Statement) -> bool {
        // A semicolon after a while block is also tolerated (consume_statement_end consumes it optionally,
        // consistent with the bootstrapped interpreter/JS semantics); if is wrapped into an
        // Expression statement via parse_if_as_statement, and its terminator is consumed by the expression statement path
        !matches!(stmt, Statement::If(_))
    }

    /// Parses a let statement: `let name = value;`
    ///
    /// Grammar rules:
    /// ```qlang
    /// let x = 10;
    /// let fn = () -> { ... };
    /// let add = (a, b) -> a + b;
    /// let x: Type = 10;  // type annotation (reserved)
    /// ```
    ///
    /// Parsing steps:
    /// 1. Consume the `let` keyword
    /// 2. Parse the variable name
    /// 3. Optionally parse a type annotation
    /// 4. Parse the value after the equals sign (may be a plain value or a function definition)
    fn parse_let_statement(&mut self) -> Result<Statement, ParseError> {
        // Record the position of the let keyword
        let start = self.current_span().start;
        // Consume the 'let' keyword
        self.advance();

        // Parse the variable name (identifier)
        let name = self.expect_identifier()?;

        // Optional type annotation: let x: Number = 10;
        // The annotation is a full expression, evaluated to obtain a type value (runtime assertion)
        let type_annotation = if self.match_token(&TokenKind::Colon) {
            Some(self.parse_expression()?)
        } else {
            None
        };

        if self.match_token(&TokenKind::Equal) {
            // Plain assignment: let name = value
            // value can be any expression, including a function expression (a, b) -> ...
            let value = self.parse_expression()?;
            let end = value.span().end;
            let mut stmt = LetStmt::new(name, Some(value), Span::new(start, end));
            stmt.type_annotation = type_annotation;
            Ok(Statement::Let(stmt))
        } else if self.match_token(&TokenKind::Semicolon) {
            // Declaration without initializer: let name; / let name: T;
            let end = self.previous().span.end; // the semicolon's end position (per the existing span API in parser.rs)
            let mut stmt = LetStmt::new(name, None, Span::new(start, end));
            stmt.type_annotation = type_annotation;
            Ok(Statement::Let(stmt))
        } else {
            // let must be followed by = or ;
            Err(ParseError::Expected("= or ;".to_string(), self.peek().clone()))
        }
    }

    /// Parses an if statement
    ///
    /// Grammar rules:
    /// ```qlang
    /// if cond1 { ... }
    /// else if cond2 { ... }
    /// else { ... }
    /// ```
    ///
    /// Parsing steps:
    /// 1. Consume the if keyword
    /// Parses if as a statement
    ///
    /// Parses if as an expression, then wraps it into a Statement::Expression.
    /// This allows if to be used as an expression (returning a value) or as a statement (ignoring the return value).
    fn parse_if_as_statement(&mut self) -> Result<Statement, ParseError> {
        // Parse it as an expression
        let expr = self.parse_if_expression()?;
        // Wrap it into an expression statement
        Ok(Statement::Expression(expr))
    }

    /// Parses a while loop statement
    ///
    /// Grammar rules:
    /// ```qlang
    /// while condition {
    ///     // loop body
    /// }
    /// ```
    fn parse_while_statement(&mut self) -> Result<Statement, ParseError> {
        let start = self.current_span().start;
        // Consume the 'while' keyword
        self.advance();

        // Parse the loop condition
        let condition = self.parse_expression()?;
        // Skip newlines
        self.skip_newlines();
        // Parse the loop body block
        let body = self.parse_block()?;
        let end = body.span.end;

        // Create a WhileStmt node
        Ok(Statement::While(WhileStmt::new(condition, body, Span::new(start, end))))
    }

    /// Parses a return statement
    ///
    /// Grammar rules:
    /// ```qlang
    /// return expression;
    /// ```
    fn parse_return_statement(&mut self) -> Result<Statement, ParseError> {
        let start = self.current_span().start;
        // Consume the 'return' keyword
        self.advance();

        // Parse the return value expression
        let value = self.parse_expression()?;
        let end = value.span().end;

        // Create a ReturnStmt node
        Ok(Statement::Return(ReturnStmt::new(value, Span::new(start, end))))
    }

    /// Parses an export statement
    ///
    /// Grammar rules:
    /// ```qlang
    /// export expression;         // exports an expression (identifier or object literal)
    /// export let name = value;   // exports by name
    /// ```
    fn parse_export_statement(&mut self) -> Result<Statement, ParseError> {
        let start = self.current_span().start;
        // Consume the 'export' keyword
        self.advance();

        // export let name = value;
        if self.match_token(&TokenKind::Let) {
            let name = self.expect_identifier()?;
            self.expect(&TokenKind::Equal)?;
            let value = self.parse_expression()?;
            let end = value.span().end;
            return Ok(Statement::Export(ExportStmt::new(
                Some(name),
                value,
                Span::new(start, end),
            )));
        }

        // Parse the expression to be exported
        let value = self.parse_expression()?;
        let end = value.span().end;

        // Create an ExportStmt node
        Ok(Statement::Export(ExportStmt::new(None, value, Span::new(start, end))))
    }

    /// Parses an expression or assignment statement
    ///
    /// This is a statement-level parse function.
    /// If the expression is followed by =, it is parsed as an assignment statement;
    /// otherwise it is parsed as an expression statement.
    fn parse_expression_or_assignment(&mut self) -> Result<Statement, ParseError> {
        // First parse the expression
        let expr = self.parse_expression()?;

        // Check whether an equals sign immediately follows (assignment)
        if self.match_token(&TokenKind::Equal) {
            // Parse the expression on the right side of the assignment
            let value = self.parse_expression()?;
            // Convert the expression into an assignment target
            let target = self.expression_to_assign_target(expr)?;
            // Create the span of the statement
            let span = Span::new(target.span.start, value.span().end);

            // Create the assignment statement
            Ok(Statement::Assign(AssignStmt {
                target,
                value,
                span,
            }))
        } else {
            // No equals sign, treat it as an expression statement
            Ok(Statement::Expression(expr))
        }
    }

    /// Parses an expression (entry function)
    ///
    /// An expression is a syntactic construct that produces a value.
    /// Simply invokes the precedence-climbing parser.
    fn parse_expression(&mut self) -> Result<Expression, ParseError> {
        // Start parsing from the lowest precedence
        self.parse_binary_expression(0)
    }

    /// Parses binary expressions using the precedence-climbing method
    ///
    /// # Precedence-climbing algorithm
    ///
    /// 1. First parse the left operand (calls parse_unary)
    /// 2. Loop checking the current operator:
    ///    - If the operator precedence < the minimum precedence, stop
    ///    - Otherwise, consume the operator and recursively parse the right operand
    ///    - Build a new binary expression
    /// 3. Return the final result
    ///
    /// # Advantages
    ///
    /// - All operators can be handled in a single pass
    /// - Correctly handles operator precedence and associativity
    /// - Concise code
    ///
    /// # Example
    ///
    /// Parsing `1 + 2 * 3`:
    /// - First parse the left operand: 1
    /// - Encounter +, precedence (10) >= min (0), continue
    /// - Recursively parse the right operand, min raised to 11
    /// - At *, precedence (80) < min (11)? No, continue
    /// - Finally build: 1 + (2 * 3)
    fn parse_binary_expression(&mut self, min_precedence: u8) -> Result<Expression, ParseError> {
        // Parse the left operand (unary expression)
        let mut left = self.parse_unary()?;

        // Loop over the operators
        while let Some(op) = self.current_binary_op() {
            // Get the precedence of the current operator
            let precedence = op.precedence();
            // Stop if the precedence is lower than the minimum precedence
            if precedence < min_precedence {
                break;
            }

            // Consume the operator token
            self.advance();
            // Recursively parse the right operand, raising the minimum precedence to the current precedence + 1
            // This correctly handles left associativity
            let right = self.parse_binary_expression(precedence + 1)?;

            // Compute the new span
            let span = Span::new(left.span().start, right.span().end);

            // Build the binary expression and update left
            left = Expression::BinaryOp(BinaryOpExpr::new(op, Box::new(left), Box::new(right), span));
        }

        Ok(left)
    }

    /// Parses a unary expression
    ///
    /// Unary operators include:
    /// - `!` logical NOT
    /// - `-` negation
    ///
    /// Note: negation needs special handling because `-` is also the binary subtraction operator.
    fn parse_unary(&mut self) -> Result<Expression, ParseError> {
        // Check whether it is the ! operator
        if self.match_token(&TokenKind::Bang) {
            // Recursively parse the operand
            let operand = self.parse_unary()?;
            // Compute the span
            let span = Span::new(self.previous().span.start, operand.span().end);
            // Return the UnaryOp expression
            Ok(Expression::UnaryOp(UnaryOpExpr::new(UnaryOp::Not, Box::new(operand), span)))
        }
        // Check whether it is the - operator
        else if self.match_token(&TokenKind::Minus) {
            // Recursively parse the operand
            let operand = self.parse_unary()?;
            let span = Span::new(self.previous().span.start, operand.span().end);
            Ok(Expression::UnaryOp(UnaryOpExpr::new(UnaryOp::Neg, Box::new(operand), span)))
        }
        // Check whether it is the + operator (unary plus, JSON5)
        else if self.match_token(&TokenKind::Plus) {
            // Recursively parse the operand
            let operand = self.parse_unary()?;
            let span = Span::new(self.previous().span.start, operand.span().end);
            Ok(Expression::UnaryOp(UnaryOpExpr::new(UnaryOp::Plus, Box::new(operand), span)))
        } else {
            // Not a unary operator, parse a postfix expression
            self.parse_postfix()
        }
    }

    /// Parses an if expression
    ///
    /// Used for if in expression contexts (e.g., in template string interpolation).
    /// The difference from an if statement is that each branch of an if expression must be an expression.
    ///
    /// Syntax:
    /// ```qlang
    /// if cond { then_expr } else { else_expr }
    /// ```
    fn parse_if_expression(&mut self) -> Result<Expression, ParseError> {
        let start = self.current_span().start;
        // Consume the 'if' keyword
        self.advance();

        // Parse the condition
        let condition = self.parse_expression()?;
        self.skip_newlines();

        // Parse the then branch
        let then_branch = if self.check(&TokenKind::LeftBrace) {
            // Parse the block
            let block = self.parse_block()?;
            // Extract it as an expression
            self.extract_block_expression(&block, start)?
        } else {
            // Single expression as the then branch
            self.parse_expression()?
        };

        // Parse the else branch
        // Note: there may be newlines between } and else (Newline is a valid separator), so they must be skipped first
        self.skip_newlines();
        let else_branch = if self.match_token(&TokenKind::Else) {
            self.skip_newlines();
            if self.check(&TokenKind::LeftBrace) {
                // else block
                let block = self.parse_block()?;
                Some(Box::new(self.extract_block_expression(&block, start)?))
            } else if self.check(&TokenKind::If) {
                // else if
                Some(Box::new(self.parse_if_expression()?))
            } else {
                // Single expression as the else branch
                Some(Box::new(self.parse_expression()?))
            }
        } else {
            None
        };

        // Compute the end position
        let end = else_branch.as_ref()
            .map(|b| b.span().end)
            .unwrap_or_else(|| then_branch.span().end);

        // Create an IfExpr node
        Ok(Expression::If(IfExpr::new(
            Box::new(condition),
            Box::new(then_branch),
            else_branch,
            Span::new(start, end),
        )))
    }

    /// Extracts the final expression value from a block
    ///
    /// Used to convert a block into an expression.
    /// When a block is used as an expression, all statements are executed and the value of the last statement is returned.
    fn extract_block_expression(&mut self, block: &Block, _start: usize) -> Result<Expression, ParseError> {
        // Return a BlockExpr; the interpreter executes all statements in the block
        // and uses the value of the last statement as the value of the whole block
        Ok(Expression::Block(BlockExpr::new(block.clone())))
    }

    /// Parses a postfix expression
    ///
    /// Postfix operators include:
    /// - Function call: `fn(args)`
    /// - Member access: `obj.field`
    /// - Index access: `arr[index]`
    /// - Error propagation: `expr?`
    ///
    /// These operators associate from left to right, so they are handled in a loop.
    fn parse_postfix(&mut self) -> Result<Expression, ParseError> {
        // First parse a primary expression
        let mut expr = self.parse_primary()?;

        // Loop over all postfix operators
        loop {
            if self.match_token(&TokenKind::LeftParen) {
                // Function call
                expr = self.parse_call(expr)?;
            } else if self.match_token(&TokenKind::Dot) {
                // Member access
                // Parse the field name
                let field = self.expect_identifier()?;
                // Compute the span
                let span = Span::new(expr.span().start, self.previous().span.end);
                // Create a MemberAccessExpr
                expr = Expression::MemberAccess(MemberAccessExpr::new(
                    Box::new(expr),
                    field,
                    span,
                ));
            } else if self.match_token(&TokenKind::LeftBracket) {
                // Index access
                // Parse the index expression
                let index = self.parse_expression()?;
                // Consume the right bracket
                self.expect(&TokenKind::RightBracket)?;
                // Compute the span
                let span = Span::new(expr.span().start, self.previous().span.end);
                // Create an IndexAccessExpr
                expr = Expression::IndexAccess(IndexAccessExpr::new(
                    Box::new(expr),
                    Box::new(index),
                    span,
                ));
            } else if self.match_token(&TokenKind::Question) {
                // Postfix error propagation `?`
                // Compute the span (covers the whole expression through the `?` token)
                let span = Span::new(expr.span().start, self.previous().span.end);
                // Create a UnaryOpExpr with the Propagate operator
                expr = Expression::UnaryOp(UnaryOpExpr::new(
                    UnaryOp::Propagate,
                    Box::new(expr),
                    span,
                ));
            } else {
                // No more postfix operators, exit the loop
                break;
            }
        }

        Ok(expr)
    }

    /// Parses a primary expression
    ///
    /// A primary expression is the smallest expression unit that cannot be decomposed further, including:
    /// - Numeric literals: `42`, `3.14`
    /// - String literals: `"hello"`
    /// - Booleans: `true`, `false`
    /// - Null: `null`
    /// - Identifiers: `x`, `myFunction`
    /// - Parenthesized expressions: `(expr)`
    /// - Arrays: `[1, 2, 3]`
    /// - Objects: `{name = "Alice"}`
    /// - Functions: `() -> { ... }`
    /// - Imports: `import "module"`
    fn parse_primary(&mut self) -> Result<Expression, ParseError> {
        // Clone the current token (since it will be consumed later)
        let token = self.peek().clone();

        match &token.kind {
            // Numeric literal
            TokenKind::Number(n) => {
                let value = *n;  // copy the numeric value
                self.advance();  // consume the numeric token
                // Create the number expression
                Ok(Expression::Number(NumberExpr::new(value, token.span)))
            }

            // String literal
            TokenKind::String(parts) => {
                // Parse the parts of the string
                let expr_parts = self.parse_string_parts(parts)?;
                self.advance();  // consume the string token
                Ok(Expression::String(StringExpr::new(expr_parts, token.span)))
            }

            // Boolean true
            TokenKind::True => {
                self.advance();
                Ok(Expression::Boolean(BooleanExpr::new(true, token.span)))
            }

            // Boolean false
            TokenKind::False => {
                self.advance();
                Ok(Expression::Boolean(BooleanExpr::new(false, token.span)))
            }

            // Null value null
            TokenKind::Null => {
                self.advance();
                Ok(Expression::Null(NullExpr::new(token.span)))
            }

            // Identifier
            TokenKind::Identifier(name) => {
                let name = name.clone();  // clone the name
                let start = self.current_span().start;
                self.advance();  // consume the identifier

                // Check whether it is an arrow function (single-parameter shorthand syntax)
                if self.match_token(&TokenKind::Arrow) {
                    return self.parse_single_param_function(name, start);
                }

                // Plain identifier reference
                Ok(Expression::Identifier(IdentifierExpr::new(name, token.span)))
            }

            // Left paren - may be a grouping expression or a function definition
            TokenKind::LeftParen => {
                self.advance();  // consume the left paren

                // Several possibilities:
                // 1. () - zero-parameter function
                // 2. (expr) - grouping expression
                // 3. (params) -> { ... } - multi-parameter function
                // 4. (expr, expr, ...) - multiple expressions (used for currying)

                // Check whether it is an empty paren
                if self.check(&TokenKind::RightParen) {
                    self.advance();  // consume the right paren
                    // Check whether it is an arrow function: () -> body
                    if self.match_token(&TokenKind::Arrow) {
                        return self.parse_function_body(Vec::new(), token.span.start);
                    }
                    // A bare () is not a valid expression
                    return Err(ParseError::Expected("expression".to_string(), self.peek().clone()));
                }

                // Try to parse as a parameter list or an expression
                let first = self.parse_expression()?;

                // Parameter type annotation: `(a: Type, ...) -> ...` (only identifier parameters can carry an annotation)
                let mut annotation: Option<Expression> = None;
                if matches!(first, Expression::Identifier(_)) && self.check(&TokenKind::Colon) {
                    self.advance();
                    annotation = Some(self.parse_expression()?);
                }

                // Check whether it is multi-parameter (comma-separated)
                // With an annotation, force the parameter path (so (x: T) is not silently treated as a grouping)
                let is_param_list = self.check(&TokenKind::Comma)
                    || (self.check(&TokenKind::RightParen) && self.peek_next_is_arrow())
                    || annotation.is_some();
                if is_param_list {
                    // This is a function parameter list
                    let mut params = vec![self.expression_to_parameter_annotated(first, annotation)?];

                    // Continue parsing comma-separated parameters
                    while self.match_token(&TokenKind::Comma) {
                        let param_expr = self.parse_expression()?;
                        let mut ann = None;
                        if matches!(param_expr, Expression::Identifier(_)) && self.check(&TokenKind::Colon) {
                            self.advance();
                            ann = Some(self.parse_expression()?);
                        }
                        params.push(self.expression_to_parameter_annotated(param_expr, ann)?);
                    }

                    // Consume the right paren
                    self.expect(&TokenKind::RightParen)?;
                    // Check for the arrow
                    if self.match_token(&TokenKind::Arrow) {
                        return self.parse_function_body(params, token.span.start);
                    }
                    return Err(ParseError::Expected("->".to_string(), self.peek().clone()));
                }

                // Consume the right paren
                self.expect(&TokenKind::RightParen)?;

                // Check whether an arrow follows the paren (function definition)
                if self.match_token(&TokenKind::Arrow) {
                    let params = vec![self.expression_to_parameter_annotated(first, None)?];
                    return self.parse_function_body(params, token.span.start);
                }

                // Plain grouping expression
                Ok(Expression::Parenthesized(Box::new(first)))
            }

            // Left brace - may be an object literal or a block
            TokenKind::LeftBrace => {
                // Delegate to parse_brace_body
                self.parse_brace_body()
            }

            // Left bracket - array literal
            TokenKind::LeftBracket => {
                self.parse_array()
            }

            // Import expression
            TokenKind::Import => {
                self.parse_import()
            }

            // if expression
            TokenKind::If => self.parse_if_expression(),

            // Other unexpected tokens
            _ => Err(ParseError::UnexpectedToken(token)),
        }
    }

    /// Parses the parts of a string
    ///
    /// Strings may contain interpolation expressions, e.g.:
    /// ```qlang
    /// "Hello, ${name}!"
    /// ```
    ///
    /// The lexer returns a list of StringPart,
    /// and the interpolation parts need to be converted into expressions.
    fn parse_string_parts(&self, parts: &Vec<crate::token::StringPart>) -> Result<Vec<StringPart>, ParseError> {
        // Iterate over each part
        parts.iter().map(|p| {
            match p {
                // Literal part, copy directly
                crate::token::StringPart::Literal(s) => Ok(StringPart::Literal(s.clone())),
                // Interpolation part, needs to be parsed into an expression
                crate::token::StringPart::Interpolation(tokens) => {
                    // Create a new parser for the interpolation content
                    let mut parser = Parser::new(tokens.clone(), self.source.clone());
                    // Parse it into an expression
                    let expr = parser.parse_expression()?;
                    // Wrap it as an Interpolation
                    Ok(StringPart::Interpolation(Box::new(expr)))
                }
            }
        }).collect()
    }

    /// Parses a single-parameter arrow function (shorthand syntax)
    ///
    /// Syntax: `name -> body`
    /// This is shorthand for ` (name) -> body `
    fn parse_single_param_function(&mut self, name: String, start: usize) -> Result<Expression, ParseError> {
        // Create the parameter list
        let params = vec![Parameter::new(name)];
        // Parse the function body
        self.parse_function_body(params, start)
    }

    /// Parses a function body
    ///
    /// The function body can be:
    /// 1. A block: `{ stmt1; stmt2; return value; }`
    /// 2. A single expression: `expr`
    ///
    /// If it is a single expression, it is automatically wrapped as `return expr;`
    fn parse_function_body(&mut self, parameters: Vec<Parameter>, start: usize) -> Result<Expression, ParseError> {
        // Determine whether it is a block or a single expression
        let body = if self.check(&TokenKind::LeftBrace) {
            // Block
            self.parse_block()?
        } else {
            // Single expression, needs to be wrapped as a return statement
            let expr = self.parse_expression()?;
            let end = expr.span().end;
            // Create a block containing a single return statement
            Block::new(
                vec![Statement::Return(crate::ast::ReturnStmt::new(expr, Span::new(start, end)))],
                Span::new(start, end),
            )
        };
        let end = body.span.end;

        // Create the function expression
        Ok(Expression::Function(FunctionExpr::new(
            parameters,
            body,
            Span::new(start, end),
        )))
    }

    /// Parses a block
    ///
    /// A block is a sequence of statements surrounded by braces:
    /// ```qlang
    /// {
    ///     statement1;
    ///     statement2;
    /// }
    /// ```
    ///
    /// A block creates a new scope.
    fn parse_block(&mut self) -> Result<Block, ParseError> {
        // Record the start position of the block
        let start = self.current_span().start;
        // Consume the left brace
        self.expect(&TokenKind::LeftBrace)?;

        // Store the statements in the block
        let mut statements = Vec::new();
        // Skip newlines after the opening brace
        self.skip_newlines();

        // Loop parsing statements until the right brace is reached
        while !self.check(&TokenKind::RightBrace) && !self.is_at_end() {
            // Parse a single statement
            let stmt = self.parse_statement()?;
            // Determine whether a terminator is needed
            let needs_end = Self::statement_needs_end(&stmt);
            // Add it to the statement list
            statements.push(stmt);

            // Only consume the terminator for statements that need one
            if needs_end {
                self.consume_statement_end()?;
            }

            // Skip newlines between statements
            self.skip_newlines();
        }

        // Consume the right brace
        self.expect(&TokenKind::RightBrace)?;
        // Record the end position
        let end = self.previous().span.end;

        // Create and return the Block node
        Ok(Block::new(statements, Span::new(start, end)))
    }

    /// Parses the content after a brace
    ///
    /// This is a key point of QLang syntax: a brace can represent either a block or an object literal.
    /// The decision is based on the first non-whitespace token after the brace.
    ///
    /// # Decision rules
    ///
    /// If the brace is followed by one of the following tokens, it is a block:
    /// - Operators: -, !, +
    /// - Opening brackets: {, [, (
    /// - Keywords (not followed by a colon): let, if, while, return, export, import, true, false, null
    ///   (a keyword followed by `:` is an object key, e.g. `{ if: 1 }`)
    ///
    /// In all other cases (identifier, string, number) it is an object literal.
    ///
    /// # Example
    ///
    /// ```qlang
    /// // block
    /// let x = { let a = 1; let b = 2; a + b; }
    ///
    /// // object literal (JSON5)
    /// let obj = { name: "Alice", age: 30 }
    /// ```
    fn parse_brace_body(&mut self) -> Result<Expression, ParseError> {
        // Get the index after the current left brace
        let next_idx = self.current + 1;

        // If there is no token after the brace, treat it as an empty object
        if next_idx >= self.tokens.len() {
            return self.parse_object();
        }

        // Find the first non-newline token after the brace
        let mut first_real_idx = next_idx;
        while first_real_idx < self.tokens.len()
            && matches!(self.tokens[first_real_idx].kind, TokenKind::Newline)
        {
            first_real_idx += 1;
        }

        // If there are only newlines, treat it as an empty object
        if first_real_idx >= self.tokens.len() {
            return self.parse_object();
        }

        // Get the kind of the first non-whitespace token
        let first_real_kind = &self.tokens[first_real_idx].kind;

        // Decide whether it is a block or an object literal based on the first token
        let is_code_block = match first_real_kind {
            // Operator or nested opening bracket -> block
            TokenKind::Minus | TokenKind::Bang | TokenKind::Plus
            | TokenKind::LeftBrace | TokenKind::LeftBracket | TokenKind::LeftParen => true,
            // Identifier -> object literal
            TokenKind::Identifier(_) => false,
            // Keyword: a following colon means an object key ({ if: 1 }), otherwise it is a block ({ if c {...} }, { true })
            kind if kind.is_keyword() => {
                !matches!(
                    self.tokens.get(first_real_idx + 1).map(|t| &t.kind),
                    Some(&TokenKind::Colon)
                )
            }
            // String/number key -> object literal ({"a b": 1}, {0: 1})
            TokenKind::Number(_) | TokenKind::String(_) => false,
            // Everything else -> object literal
            _ => false,
        };

        // Choose the parse path based on the decision
        if is_code_block {
            // Parse as a block expression
            let block = self.parse_block()?;
            // Convert it to an expression
            self.extract_block_expression(&block, block.span.start)
        } else {
            // Parse as an object literal
            self.parse_object()
        }
    }

    /// Parses an object literal
    ///
    /// Grammar rules (JSON5):
    /// ```qlang
    /// { key: value, ... }
    /// { key }  // shorthand: { key = key } (identifier keys only, QLang extension)
    /// { a: 1, }  // trailing commas supported
    /// ```
    fn parse_object(&mut self) -> Result<Expression, ParseError> {
        let start = self.current_span().start;
        // Consume the left brace
        self.expect(&TokenKind::LeftBrace)?;
        self.skip_newlines();

        // Store the field list
        let mut fields = Vec::new();

        // Loop parsing fields until the right brace
        while !self.check(&TokenKind::RightBrace) && !self.is_at_end() {
            // Parse the key (identifier / keyword / string / number)
            let key = self.parse_object_key()?;
            let key_was_identifier = matches!(self.previous().kind, TokenKind::Identifier(_));
            self.skip_newlines();

            // Colon-separated value, or shorthand (identifier keys only)
            let value = if self.match_token(&TokenKind::Colon) {
                self.skip_newlines();
                Some(self.parse_expression()?)
            } else if key_was_identifier
                && (self.check(&TokenKind::Comma) || self.check(&TokenKind::RightBrace))
            {
                // Shorthand: { name } is equivalent to { name: name } (QLang extension, relied on by export { f })
                None
            } else {
                // Missing colon (the = form is deprecated; string/number keys cannot use shorthand)
                return Err(ParseError::Expected(":".to_string(), self.peek().clone()));
            };
            fields.push(ObjectField::new(key, value));

            self.skip_newlines();
            // Handle the comma separator (trailing commas supported)
            if self.check(&TokenKind::Comma) {
                self.advance();
            } else if !self.check(&TokenKind::RightBrace) {
                self.expect(&TokenKind::Comma)?;
            }
            self.skip_newlines();
        }

        // Consume the right brace
        self.expect(&TokenKind::RightBrace)?;
        let end = self.previous().span.end;

        // Create the object expression
        Ok(Expression::Object(ObjectExpr::new(fields, Span::new(start, end))))
    }

    /// Parses a JSON5 object key
    ///
    /// Supports four kinds of keys: identifiers, keywords, strings (plain literals only), numbers
    fn parse_object_key(&mut self) -> Result<String, ParseError> {
        let token = self.peek().clone();
        match &token.kind {
            TokenKind::Identifier(name) => {
                self.advance();
                Ok(name.clone())
            }
            TokenKind::Number(n) => {
                self.advance();
                Ok(n.to_string())
            }
            TokenKind::String(parts) => {
                // The key must be a plain literal (interpolation not allowed)
                let mut key = String::new();
                for part in parts {
                    match part {
                        crate::token::StringPart::Literal(lit) => key.push_str(lit),
                        crate::token::StringPart::Interpolation(_) => {
                            return Err(ParseError::Expected("plain string key".to_string(), token));
                        }
                    }
                }
                self.advance();
                Ok(key)
            }
            kind if kind.is_keyword() => {
                self.advance();
                Ok(TokenKind::keyword_to_str(kind).unwrap().to_string())
            }
            _ => Err(ParseError::Expected("object key".to_string(), token)),
        }
    }

    /// Parses an array literal
    ///
    /// Grammar rules:
    /// ```qlang
    /// [element1, element2, element3]
    /// [1, 2, 3, ]  // trailing comma supported
    /// ```
    fn parse_array(&mut self) -> Result<Expression, ParseError> {
        let start = self.current_span().start;
        // Consume the left bracket
        self.expect(&TokenKind::LeftBracket)?;
        self.skip_newlines();

        // Store the element list
        let mut elements = Vec::new();

        // Loop parsing elements until the right bracket
        while !self.check(&TokenKind::RightBracket) && !self.is_at_end() {
            // Parse the element expression
            elements.push(self.parse_expression()?);

            self.skip_newlines();
            // Handle the comma separator
            if self.check(&TokenKind::Comma) {
                self.advance();
            } else if !self.check(&TokenKind::RightBracket) {
                self.expect(&TokenKind::Comma)?;
            }
            self.skip_newlines();
        }

        // Consume the right bracket
        self.expect(&TokenKind::RightBracket)?;
        let end = self.previous().span.end;

        // Create the array expression
        Ok(Expression::Array(ArrayExpr::new(elements, Span::new(start, end))))
    }

    /// Parses a function call
    ///
    /// Grammar rules:
    /// ```qlang
    /// callee(arg1, arg2, arg3)
    /// ```
    fn parse_call(&mut self, callee: Expression) -> Result<Expression, ParseError> {
        // Record the start position of the call expression
        let start = callee.span().start;
        // Skip possible leading newlines (newlines before arguments are allowed)
        self.skip_newlines();

        // Store the argument list
        let mut arguments = Vec::new();

        // If it is not an empty argument list, loop parsing arguments
        if !self.check(&TokenKind::RightParen) {
            loop {
                // Parse the argument expression
                arguments.push(self.parse_expression()?);
                // If there is a comma, continue parsing the next argument
                if !self.match_token(&TokenKind::Comma) {
                    break;
                }
                self.skip_newlines();
            }
        }

        // Consume the right paren
        self.expect(&TokenKind::RightParen)?;
        let end = self.previous().span.end;

        // Create the call expression
        Ok(Expression::Call(CallExpr::new(
            Box::new(callee),
            arguments,
            Span::new(start, end),
        )))
    }

    /// Parses an import statement
    ///
    /// Grammar rules:
    /// ```qlang
    /// import "path/to/module.ql"
    /// import ./lib.ql
    /// ```
    fn parse_import(&mut self) -> Result<Expression, ParseError> {
        let start = self.current_span().start;
        // Consume the 'import' keyword
        self.expect(&TokenKind::Import)?;

        // Try to read the import path
        let path = match &self.peek().kind {
            // String literal path
            TokenKind::String(parts) => {
                // Only single-part strings are supported (no interpolation)
                if parts.len() == 1 {
                    if let crate::token::StringPart::Literal(s) = &parts[0] {
                        s.clone()
                    } else {
                        return Err(ParseError::ExpectedImportPath(self.current_span()));
                    }
                } else {
                    return Err(ParseError::ExpectedImportPath(self.current_span()));
                }
            }
            // Non-string path (e.g. ./lib, ../utils)
            _ => {
                // Collect the path segments
                let mut path_parts = Vec::new();
                // Loop collecting until a semicolon, newline, or end of file
                while !self.is_at_end()
                    && !self.check(&TokenKind::Semicolon)
                    && !self.check(&TokenKind::Newline)
                {
                    let token = self.peek().clone();
                    match &token.kind {
                        // Identifier: a path component
                        TokenKind::Identifier(name) => {
                            path_parts.push(name.clone());
                            self.advance();
                        }
                        // Dot: for relative paths ./ or ../
                        TokenKind::Dot => {
                            path_parts.push(".".to_string());
                            self.advance();
                        }
                        // Slash: path separator
                        TokenKind::Slash => {
                            path_parts.push("/".to_string());
                            self.advance();
                        }
                        // Minus: may be a hyphen within the path
                        TokenKind::Minus => {
                            path_parts.push("-".to_string());
                            self.advance();
                        }
                        // Other characters are invalid
                        _ => {
                            return Err(ParseError::ExpectedImportPath(self.current_span()));
                        }
                    }
                }
                // Join the path segments
                path_parts.join("")
            }
        };

        // Consume the path token
        self.advance();
        let end = self.previous().span.end;

        // Create the import expression
        Ok(Expression::Import(ImportExpr::new(path, Span::new(start, end))))
    }

    /// Converts an expression into an assignment target
    ///
    /// Used when parsing assignment statements to determine the target location of the assignment.
    /// Supports:
    /// - Simple variables: `x`
    /// - Member access: `obj.field`
    /// - Index access: `arr[index]`
    /// - Nested combinations: `obj.arr[0].field`
    fn expression_to_assign_target(&self, expr: Expression) -> Result<AssignTarget, ParseError> {
        match expr {
            // Simple identifier
            Expression::Identifier(id) => {
                let mut target = AssignTarget::new(id.name);
                target.span = id.span;
                Ok(target)
            }
            // Member access
            Expression::MemberAccess(ma) => {
                // Recursively process the object part
                let mut target = self.expression_to_assign_target(*ma.object)?;
                // Add the field accessor
                target.accessors.push(Accessor::Field(ma.field));
                target.span.end = ma.span.end;
                Ok(target)
            }
            // Index access
            Expression::IndexAccess(ia) => {
                let mut target = self.expression_to_assign_target(*ia.object)?;
                target.accessors.push(Accessor::Index(ia.index));
                target.span.end = ia.span.end;
                Ok(target)
            }
            // Other expressions cannot be assignment targets
            _ => Err(ParseError::InvalidAssignTarget(expr.span())),
        }
    }

    /// Converts an expression into a function parameter
    ///
    /// Currently only identifiers are supported as parameters.
    fn expression_to_parameter(&self, expr: Expression) -> Result<Parameter, ParseError> {
        match expr {
            Expression::Identifier(id) => Ok(Parameter::new(id.name)),
            _ => Err(ParseError::InvalidParameter(expr.span())),
        }
    }

    /// Converts an expression into a function parameter, attaching its type annotation
    fn expression_to_parameter_annotated(
        &mut self,
        expr: Expression,
        annotation: Option<Expression>,
    ) -> Result<Parameter, ParseError> {
        let mut param = self.expression_to_parameter(expr)?;
        param.type_annotation = annotation;
        Ok(param)
    }

    /// Gets the binary operator for the current token
    ///
    /// If the current token is a binary operator, returns the corresponding BinaryOp enum value;
    /// otherwise returns None.
    fn current_binary_op(&self) -> Option<BinaryOp> {
        match &self.peek().kind {
            TokenKind::Plus => Some(BinaryOp::Add),
            TokenKind::Minus => Some(BinaryOp::Sub),
            TokenKind::Star => Some(BinaryOp::Mul),
            TokenKind::Slash => Some(BinaryOp::Div),
            TokenKind::Percent => Some(BinaryOp::Mod),
            TokenKind::EqualEqual => Some(BinaryOp::Eq),
            TokenKind::NotEqual => Some(BinaryOp::NotEq),
            TokenKind::Less => Some(BinaryOp::Lt),
            TokenKind::LessEqual => Some(BinaryOp::LtEq),
            TokenKind::Greater => Some(BinaryOp::Gt),
            TokenKind::GreaterEqual => Some(BinaryOp::GtEq),
            TokenKind::And => Some(BinaryOp::And),
            TokenKind::Or => Some(BinaryOp::Or),
            TokenKind::QuestionQuestion => Some(BinaryOp::Coalesce),
            TokenKind::BitwiseAnd => Some(BinaryOp::BitwiseAnd),
            TokenKind::BitwiseOr => Some(BinaryOp::BitwiseOr),
            TokenKind::BitwiseXor => Some(BinaryOp::BitwiseXor),
            _ => None,
        }
    }

    // ==================== Token navigation helper methods ====================

    /// Advances to the next token
    ///
    /// Returns the previous token (used to obtain position information).
    /// If already at the end of the file, does nothing.
    fn advance(&mut self) -> Token {
        if !self.is_at_end() {
            self.current += 1;
        }
        self.previous().clone()
    }

    /// Looks at the current token (without consuming it)
    fn peek(&self) -> &Token {
        &self.tokens[self.current]
    }

    /// Gets the previous token
    fn previous(&self) -> &Token {
        &self.tokens[self.current.saturating_sub(1)]
    }

    /// Checks whether the end of the file has been reached
    fn is_at_end(&self) -> bool {
        matches!(self.peek().kind, TokenKind::Eof)
    }

    /// Checks whether the current token is of the specified kind
    fn check(&self, kind: &TokenKind) -> bool {
        // Use discriminant comparison to avoid the need to fully match TokenKind enum variants
        std::mem::discriminant(&self.peek().kind) == std::mem::discriminant(kind)
    }

    /// Matches and consumes a token of the specified kind
    ///
    /// If the current token is of the specified kind, consumes it and returns true;
    /// otherwise does not consume it and returns false.
    fn match_token(&mut self, kind: &TokenKind) -> bool {
        if self.check(kind) {
            self.advance();
            true
        } else {
            false
        }
    }

    /// Expects a token of the specified kind
    ///
    /// If the current token is of the specified kind, consumes and returns it;
    /// otherwise returns a parse error.
    fn expect(&mut self, kind: &TokenKind) -> Result<Token, ParseError> {
        if self.check(kind) {
            Ok(self.advance())
        } else {
            Err(ParseError::Expected(
                format!("{:?}", kind),
                self.peek().clone(),
            ))
        }
    }

    /// Expects an identifier
    ///
    /// The current token must be of type Identifier, otherwise an error is returned.
    fn expect_identifier(&mut self) -> Result<String, ParseError> {
        match &self.peek().kind {
            TokenKind::Identifier(name) => {
                let name = name.clone();
                self.advance();
                Ok(name)
            }
            _ => Err(ParseError::ExpectedIdentifier(self.peek().clone())),
        }
    }

    fn skip_newlines(&mut self) {
        while !self.is_at_end() && self.check(&TokenKind::Newline) {
            self.advance();
        }
    }

    fn consume_statement_end(&mut self) -> Result<(), ParseError> {
        if self.match_token(&TokenKind::Semicolon) ||
           self.match_token(&TokenKind::Newline) ||
           self.is_at_end() {
            Ok(())
        } else {
            // A missing terminator is also allowed for some statements (such as if/while)
            Ok(())
        }
    }

    /// Gets the span of the current token
    fn current_span(&self) -> Span {
        self.peek().span
    }

    /// Checks whether the next token is an arrow
    ///
    /// Used to determine whether `(expr)` is a grouping expression or a function parameter list.
    fn peek_next_is_arrow(&self) -> bool {
        if self.current + 1 >= self.tokens.len() {
            false
        } else {
            self.tokens[self.current + 1].kind == TokenKind::Arrow
        }
    }
}
