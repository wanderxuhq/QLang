// Parser for QLang - Converts tokens to AST
// Bootstrapped QLang implementation

import ./tokens.ql;
import ./ast.ql;
import ./stdlib.ql;

let Parser = (tokens) -> {
  let current = 0;

  let peek = () -> {
    if current < tokens.length {
      return tokens[current];
    } else {
      return { kind: TokenKind.Eof };
    };
  };

  let previous = () -> {
    if current > 0 {
      return tokens[current - 1];
    } else {
      return { kind: TokenKind.Eof };
    };
  };

  let advance = () -> {
    let token = peek();
    current = current + 1;
    return token;
  };

  let check = (kind) -> {
    return peek().kind == kind;
  };

  let matchToken = (kinds) -> {
    let i = 0;
    while i < kinds.length {
      if check(kinds[i]) {
        advance();
        return true;
      }
      i = i + 1;
    }
    return false;
  };

  // Check if a token kind is a keyword
  let isKeyword = (kind) -> {
    if kind == TokenKind.Let { true }
    else if kind == TokenKind.If { true }
    else if kind == TokenKind.Else { true }
    else if kind == TokenKind.While { true }
    else if kind == TokenKind.Return { true }
    else if kind == TokenKind.True { true }
    else if kind == TokenKind.False { true }
    else if kind == TokenKind.Import { true }
    else if kind == TokenKind.Export { true }
    else if kind == TokenKind.Null { true }
    else { false }
  };

  // Skip Newline tokens
  let skipNewlines = () -> {
    while check(TokenKind.Newline) {
      advance();
    }
  };

  let parse = () -> {
    let statements = [];
    while !check(TokenKind.Eof) {
      skipNewlines();
      statements[statements.length] = parseStatement();
      skipNewlines();
      // Skip stray semicolons after statements (common after if/while blocks;
      // the host tolerates them and they produce no statement)
      while check(TokenKind.Semicolon) {
        advance();
      }
    }
    return Program(statements);
  };

  let parseStatement = () -> {
    skipNewlines();
    let token = peek();

    if token.kind == TokenKind.Let {
      return parseLetStatement();
    } else if token.kind == TokenKind.If {
      return parseIfStatement();
    } else if token.kind == TokenKind.While {
      return parseWhileStatement();
    } else if token.kind == TokenKind.Return {
      return parseReturnStatement();
    } else if token.kind == TokenKind.Export {
      return parseExportStatement();
    } else {
      return parseExpressionStatement();
    };
  };

  let parseLetStatement = () -> {
    skipNewlines();
    advance(); // Skip 'let' keyword
    // Now peek() should return the identifier (variable name)
    let name = peek().value;
    advance(); // Skip the identifier

    while !check(TokenKind.Equal) && !check(TokenKind.Semicolon) && !check(TokenKind.Eof) {
      advance();
    }
    if !check(TokenKind.Equal) {
      return { type: "Error", message: "Expected '='" };
    } else {
      advance(); // Skip '='
      let value = parseExpression();
      if check(TokenKind.Semicolon) { advance(); }
      skipNewlines();
      return LetStmt(name, value);
    };
  };

  let parseIfStatement = () -> {
    skipNewlines();
    advance();
    let condition = parseExpression();
    if !check(TokenKind.LeftBrace) {
      return { type: "Error", message: "Expected '{'" };
    } else {
      // Note: do NOT advance() — parseBlock expects to consume '{' itself
      let thenBranch = parseBlock();

      let branches = [IfBranch(condition, thenBranch)];
      let elseBody = null;

      // Handle chained else if / else using a loop
      let parsingElse = true;
      while parsingElse {
        // Check if next token is Else
        if !check(TokenKind.Else) {
          parsingElse = false;
        } else {
          advance(); // consume Else
          if check(TokenKind.If) {
            // This is an else if
            let elseIfCondition = parseExpression();
            if !check(TokenKind.LeftBrace) {
              return { type: "Error", message: "Expected '{' after else if condition" };
            };
            // Do NOT advance() — parseBlock expects to consume '{' itself
            let elseIfBody = parseBlock();
            branches[branches.length] = IfBranch(elseIfCondition, elseIfBody);
            // Continue the loop to check for more else if / else
          } else {
            // This is a plain else
            if check(TokenKind.LeftBrace) {
              elseBody = parseBlock();
            };
            parsingElse = false;
          };
        };
      }

      return IfStmt(branches, elseBody);
    };
  };

  let parseWhileStatement = () -> {
    skipNewlines();
    advance();
    let condition = parseExpression();
    if !check(TokenKind.LeftBrace) {
      return { type: "Error", message: "Expected '{'" };
    } else {
      // Do NOT advance() — parseBlock expects to consume '{' itself
      let body = parseBlock();
      return WhileStmt(condition, body);
    };
  };

  let parseReturnStatement = () -> {
    skipNewlines();
    advance();
    let value = parseExpression();
    if check(TokenKind.Semicolon) { advance(); }
    skipNewlines();
    return ReturnStmt(value);
  };

  let parseExportStatement = () -> {
    skipNewlines();
    advance();
    let value = parseExpression();
    if check(TokenKind.Semicolon) { advance(); }
    skipNewlines();
    return ExportStmt(value);
  };

  let parseExpressionStatement = () -> {
    skipNewlines();
    // Assignment is only recognized in expression-statement position (the
    // assignment operator is not a binary operator in the expression grammar)
    let expr = parseAssignment();
    if check(TokenKind.Semicolon) { advance(); }
    skipNewlines();
    return expr;
  };

  let parseBlock = () -> {
    skipNewlines();
    if check(TokenKind.LeftBrace) {
      // Block with braces
      advance();
      let statements = [];
      while !check(TokenKind.RightBrace) && !check(TokenKind.Eof) {
        statements[statements.length] = parseStatement();
        skipNewlines();
        // Skip stray semicolons after statements (common after if/while blocks;
        // the host tolerates them and they produce no statement. Skip AFTER the
        // statement, not before: a leading skip would expose '}' to be consumed by an Error node)
        while check(TokenKind.Semicolon) {
          advance();
        }
      }
      if check(TokenKind.RightBrace) { advance(); }
      return Block(statements);
    } else {
      // Arrow function body without braces - parse single expression and wrap in block
      let expr = parseExpression();
      return Block([expr]);
    }
  };

  let parseExpression = () -> {
    skipNewlines();
    return parseCoalesce();
  };

  let parseAssignment = () -> {
    skipNewlines();
    let left = parseCoalesce();

    if matchToken([TokenKind.Equal]) {
      let value = parseAssignment();
      if left.type == "Identifier" {
        return AssignStmt(IdentifierExpr(left.name), value);
      } else if left.type == "MemberAccess" {
        return AssignStmt(left, value);
      } else if left.type == "IndexAccess" {
        return AssignStmt(left, value);
      } else {
        return { type: "Error", message: "Invalid assignment target" };
      }
    } else {
      return left;
    }
  };

  let parseCoalesce = () -> {
    skipNewlines();
    let left = parseOr();
    while matchToken([TokenKind.QuestionQuestion]) {
      let right = parseOr();
      left = BinaryOpExpr("??", left, right);
    }
    return left;
  };

  let parseOr = () -> {
    skipNewlines();
    let left = parseAnd();
    while matchToken([TokenKind.Or]) {
      let right = parseAnd();
      left = BinaryOpExpr("||", left, right);
    }
    return left;
  };

  let parseAnd = () -> {
    skipNewlines();
    let left = parseBitwiseOr();
    while matchToken([TokenKind.And]) {
      let right = parseBitwiseOr();
      left = BinaryOpExpr("&&", left, right);
    }
    return left;
  };

  let parseBitwiseOr = () -> {
    skipNewlines();
    let left = parseBitwiseXor();
    while matchToken([TokenKind.BitwiseOr]) {
      let right = parseBitwiseXor();
      left = BinaryOpExpr("|", left, right);
    }
    return left;
  };

  let parseBitwiseXor = () -> {
    skipNewlines();
    let left = parseBitwiseAnd();
    while matchToken([TokenKind.BitwiseXor]) {
      let right = parseBitwiseAnd();
      left = BinaryOpExpr("^", left, right);
    }
    return left;
  };

  let parseBitwiseAnd = () -> {
    skipNewlines();
    let left = parseEquality();
    while matchToken([TokenKind.BitwiseAnd]) {
      let right = parseEquality();
      left = BinaryOpExpr("&", left, right);
    }
    return left;
  };

  let parseEquality = () -> {
    skipNewlines();
    let left = parseComparison();
    let done = false;
    while !done {
      if matchToken([TokenKind.EqualEqual]) {
        let right = parseComparison();
        left = BinaryOpExpr("==", left, right);
      } else if matchToken([TokenKind.NotEqual]) {
        let right = parseComparison();
        left = BinaryOpExpr("!=", left, right);
      } else {
        done = true;
      }
    }
    return left;
  };

  let parseComparison = () -> {
    skipNewlines();
    let left = parseAddition();
    let done = false;
    while !done {
      if matchToken([TokenKind.Less]) {
        let right = parseAddition();
        left = BinaryOpExpr("<", left, right);
      } else if matchToken([TokenKind.LessEqual]) {
        let right = parseAddition();
        left = BinaryOpExpr("<=", left, right);
      } else if matchToken([TokenKind.Greater]) {
        let right = parseAddition();
        left = BinaryOpExpr(">", left, right);
      } else if matchToken([TokenKind.GreaterEqual]) {
        let right = parseAddition();
        left = BinaryOpExpr(">=", left, right);
      } else {
        done = true;
      }
    }
    return left;
  };

  let parseAddition = () -> {
    skipNewlines();
    let left = parseMultiplication();
    let done = false;
    while !done {
      if matchToken([TokenKind.Plus]) {
        let right = parseMultiplication();
        left = BinaryOpExpr("+", left, right);
      } else if matchToken([TokenKind.Minus]) {
        let right = parseMultiplication();
        left = BinaryOpExpr("-", left, right);
      } else {
        done = true;
      }
    }
    return left;
  };

  let parseMultiplication = () -> {
    skipNewlines();
    let left = parseUnary();
    let done = false;
    while !done {
      if matchToken([TokenKind.Star]) {
        let right = parseUnary();
        left = BinaryOpExpr("*", left, right);
      } else if matchToken([TokenKind.Slash]) {
        let right = parseUnary();
        left = BinaryOpExpr("/", left, right);
      } else if matchToken([TokenKind.Percent]) {
        let right = parseUnary();
        left = BinaryOpExpr("%", left, right);
      } else {
        done = true;
      }
    }
    return left;
  };

  let parseUnary = () -> {
    skipNewlines();
    if matchToken([TokenKind.Bang]) {
      let right = parseUnary();
      return UnaryOpExpr("!", right);
    } else if matchToken([TokenKind.Minus]) {
      let right = parseUnary();
      return UnaryOpExpr("-", right);
    } else {
      return parseCall();
    }
  };

  let parseCall = () -> {
    skipNewlines();
    let expr = parsePrimary();
    let done = false;
    while !done {
      if matchToken([TokenKind.LeftParen]) {
        let arguments = [];
        if !check(TokenKind.RightParen) {
          let argDone = false;
          while !argDone {
            skipNewlines();
            arguments[arguments.length] = parseExpression();
            skipNewlines();
            if matchToken([TokenKind.Comma]) {
              // continue parsing arguments
            } else {
              argDone = true;
            }
          }
        }
        if check(TokenKind.RightParen) { advance(); }
        expr = CallExpr(expr, arguments);
      } else if matchToken([TokenKind.Dot]) {
        // Get the full field name (identifier after the dot)
        let name = "";
        let token = peek();
        // Check if next token is an identifier or keyword that can be used as field name
        if token.kind == TokenKind.Identifier {
          name = token.value;
          advance();
        } else if isKeyword(token.kind) {
          // Allow keywords as field names (e.g., obj.let)
          name = token.value;
          advance();
        }
        if name != "" {
          expr = MemberAccessExpr(expr, name);
        } else {
          done = true;
        }
      } else if matchToken([TokenKind.LeftBracket]) {
        let index = parseExpression();
        if check(TokenKind.RightBracket) { advance(); }
        expr = IndexAccessExpr(expr, index);
      } else if matchToken([TokenKind.Question]) {
        expr = UnaryOpExpr("?", expr);
      } else {
        done = true;
      }
    }

    return expr;
  };

  let parsePrimary = () -> {
    skipNewlines();
    let token = peek();

    if token.kind == TokenKind.Number {
      advance();
      return NumberExpr(token.value);
    } else if token.kind == TokenKind.String {
      advance();
      return StringExpr(token.value);
    } else if token.kind == TokenKind.True {
      advance();
      return BooleanExpr(true);
    } else if token.kind == TokenKind.False {
      advance();
      return BooleanExpr(false);
    } else if token.kind == TokenKind.Null {
      advance();
      return NullExpr();
    } else if token.kind == TokenKind.Identifier {
      advance();
      return IdentifierExpr(token.value);
    } else if token.kind == TokenKind.Import {
      // import must be recognized BEFORE the isKeyword-as-identifier branch
      // below, or every import parses as IdentifierExpr("import") and the
      // statement silently becomes an expression
      advance();
      if check(TokenKind.String) {
        let path = previous().value;
        if check(TokenKind.Semicolon) { advance(); }
        return ImportExpr(path);
      } else {
        // Unquoted path (the boot sources' own convention: `import ./lib.ql`):
        // collect Dot / Slash / Identifier segments until ; newline or EOF,
        // mirroring the host parser's parse_import
        let path = "";
        while !check(TokenKind.Semicolon) && !check(TokenKind.Newline) && !check(TokenKind.Eof) {
          let t = peek();
          if t.kind == TokenKind.Dot {
            path = path + ".";
            advance();
          } else if t.kind == TokenKind.Slash {
            path = path + "/";
            advance();
          } else if t.kind == TokenKind.Identifier {
            path = path + t.value;
            advance();
          } else {
            // Unexpected token in path: consume and stop (matches host's error
            // tolerance; the interpreter raises NotImplemented on the import)
            advance();
          };
        }
        if check(TokenKind.Semicolon) { advance(); }
        return ImportExpr(path);
      };
    } else if isKeyword(token.kind) {
      // Allow keywords as identifiers (for obj.key where key is a keyword)
      advance();
      return IdentifierExpr(token.value);
    } else if token.kind == TokenKind.LeftParen {
      advance();
      // Check if this is: empty parens, expression grouping, or function params

      if check(TokenKind.RightParen) {
        // Empty parens: ()
        advance();
        if check(TokenKind.Arrow) {
          // () -> body - empty parameter function
          advance();
          let body = parseBlock();
          return FunctionExpr([], body);
        } else {
          // Just empty parens
          return { type: "Null", value: null };
        }
      } else if check(TokenKind.Identifier) {
        // Might be (name, ...) or (name) -> or just (name)
        let firstToken = peek();
        let potentialParam = firstToken.value;
        advance(); // Skip the identifier

        if check(TokenKind.Comma) {
          // This is a parameter list: (a, b, ...)
          let params = [potentialParam];
          advance(); // consume comma

          while !check(TokenKind.RightParen) && !check(TokenKind.Eof) {
            skipNewlines();
            if check(TokenKind.Identifier) {
              params[params.length] = peek().value;
              advance();
            } else if check(TokenKind.Comma) {
              advance();
            } else {
              // Unexpected token in params
            };

            if matchToken([TokenKind.Comma]) {
              // continue
            } else {
              // check if done
            };
          }

          if check(TokenKind.RightParen) { advance(); }

          if check(TokenKind.Arrow) {
            advance();
            let body = parseBlock();
            return FunctionExpr(params, body);
          } else {
            return { type: "Error", message: "Expected '->' after parameters" };
          };
        } else if check(TokenKind.RightParen) {
          // Just (name) - could be grouping or single param function
          advance();
          if check(TokenKind.Arrow) {
            // (name) -> body
            advance();
            let body = parseBlock();
            return FunctionExpr([potentialParam], body);
          } else {
            // Grouped expression: (name)
            return IdentifierExpr(potentialParam);
          };
        } else {
          // (name ...) is neither a parameter list nor (name): rewind the consumed
          // identifier and re-parse as a generic grouped expression (e.g. (x > 0 && y > 5);
          // the old code returned IdentifierExpr, leaving dangling tokens that became Error statements)
          current = current - 1;
          skipNewlines();
          let expr = parseExpression();
          skipNewlines();
          if check(TokenKind.RightParen) { advance(); }
          if check(TokenKind.Arrow) {
            // (expr) -> body - single-parameter function (when the expression is an identifier)
            advance();
            let params = [];
            if expr.type == "Identifier" {
              params[0] = expr.name;
            };
            let body = parseBlock();
            return FunctionExpr(params, body);
          };
          return expr;
        };
      } else {
        // Not an identifier at start, parse as grouped expression
        skipNewlines();
        let expr = parseExpression();
        skipNewlines();
        if check(TokenKind.RightParen) { advance(); }
        if check(TokenKind.Arrow) {
          // (expr) -> body - single param function
          advance();
          // Convert the expression to a parameter name (not ideal but works for simple cases)
          let params = [];
          if expr.type == "Identifier" {
            params[0] = expr.name;
          };
          let body = parseBlock();
          return FunctionExpr(params, body);
        };
        return expr;
      }
    } else if token.kind == TokenKind.LeftBracket {
      advance();
      let elements = [];
      if !check(TokenKind.RightBracket) {
        let elemDone = false;
        while !elemDone {
          skipNewlines();
          elements[elements.length] = parseExpression();
          skipNewlines();
          if matchToken([TokenKind.Comma]) {
            // continue parsing elements
          } else {
            elemDone = true;
          }
        }
      }
      if check(TokenKind.RightBracket) { advance(); }
      return ArrayExpr(elements);
    } else if token.kind == TokenKind.LeftBrace {
      advance();
      let fields = [];
      if !check(TokenKind.RightBrace) {
        let fieldDone = false;
        while !fieldDone {
          skipNewlines();
          // Parse field name (should be an identifier)
          if check(TokenKind.Identifier) {
            let name = peek().value;
            advance();
            // Expect : or = sign
            if check(TokenKind.Colon) { advance(); }
            else if check(TokenKind.Equal) { advance(); }
            let value = parseExpression();
            skipNewlines();
            fields[fields.length] = ObjectField(name, value);
          } else {
            // Not an identifier, might be end of object
          };

          if matchToken([TokenKind.Comma]) {
            // continue parsing fields
          } else {
            fieldDone = true;
          }
        }
      }
      if check(TokenKind.RightBrace) { advance(); }
      return ObjectExpr(fields);
    } else if token.kind == TokenKind.Arrow {
      advance();
      let body = parseBlock();
      return FunctionExpr([], body);
    } else {
      advance();
      return { type: "Error", message: "Unexpected token" };
    }
  };

  return { parse: parse, peek: peek, previous: previous, advance: advance, check: check, parseExpression: parseExpression };
};

export Parser;
