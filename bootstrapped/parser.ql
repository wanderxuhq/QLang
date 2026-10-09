// Parser for QLang - Converts tokens to AST
// Bootstrapped QLang implementation

import ./tokens.ql;
import ./ast.ql;
import ./stdlib.ql;

let Parser = (tokens) -> {
  let current = 0;
  // Return belongs to a lexical function body, not a block or module factory.
  let insideFunction = false;
  let setFunctionContext = (inside) -> { insideFunction = inside; };
  let errors = []; let diagnostics = [];
  let sourcePath = "<source>";
  let setSourcePath = (path) -> {
    if path != null && path != "" { sourcePath = path; };
  };
  let parseErrorAt = (message, token) -> {
    let line = if isError(token.line) { 1; } else { token.line; };
    let col = if isError(token.col) { 1; } else { token.col; };
    let span = if isError(token.span) { {start: 0, end: 0}; } else { token.span; };
    let endLine = if isError(token.endLine) { line; } else { token.endLine; };
    let endCol = if isError(token.endCol) { col + span.end - span.start; } else { token.endCol; };
    let diagnostic = {message: message, file: sourcePath, line: line, col: col, endLine: endLine, endCol: endCol, span: span};
    diagnostics[diagnostics.length] = diagnostic;
    let text = sourcePath + ":" + std.String.toString(line) + ":" + std.String.toString(col) + ": " + message;
    errors[errors.length] = text;
    { type: "Error", message: text, diagnostic: diagnostic };
  };
  let parseError = (message) -> parseErrorAt(message, peek());
  let sourceChars = [];
  let sourceText = "";
  let setSource = (source) -> { sourceText = source; sourceChars = std.String.toChars(source); };

  let peek = () -> {
    if current < tokens.length {
      return tokens[current];
    } else {
      if tokens.length > 0 {
        let last = tokens[tokens.length - 1];
        return { kind: TokenKind.Eof, line: last.endLine, col: last.endCol, span: {start: last.span.end, end: last.span.end} };
      };
      return { kind: TokenKind.Eof, line: 1, col: 1, span: {start: 0, end: 0} };
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

  // Preserve semantic-node positions through grouping and syntax lowering.
  // Token offsets and columns already count Unicode scalars, including CRLF.
  let locateBetween = (node, first, last) -> {
    node.location = {file: sourcePath, line: first.line, col: first.col,
      endLine: last.endLine, endCol: last.endCol,
      span: {start: first.span.start, end: last.span.end}};
    node;
  };
  let locate = (node, first) -> {
    let i = current - 1;
    while i > 0 && tokens[i].kind == TokenKind.Newline { i = i - 1; };
    let last = if i >= 0 { tokens[i]; } else { first; };
    locateBetween(node, first, last);
  };
  let nodeStart = (node) -> {
    let point = node.location;
    if isError(point) { peek(); } else { point; };
  };
  let locateMissing = (node, first) -> {
    if isError(node.location) { return locate(node, first); };
    node;
  };

  let locatedParameter = (name, annotation, token) -> {
    let last = if annotation == null { token; } else { nodeStart(annotation); };
    locateBetween(Parameter(name, annotation), token, last);
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

  // ---- Definite assignment (frontend, shared by both engines) ----------------
  // QLang requires a binding to be initialized before it is read. A read of a
  // binding that is not definitely initialized at that point is a compile error
  // rather than a runtime Uninitialized value. Names that appear inside a nested
  // function are exempt (an over-approximation of captured names): such a read is
  // deferred and may legitimately happen after the outer binding is assigned, so
  // the emitter keeps its runtime check for those.
  let daError = (node, message) -> {
    let point = null;
    if !isError(node.location) { point = node.location; };
    let line = 0; let col = 0;
    if point != null { line = point.line; col = point.col; };
    let text = sourcePath + ":" + std.String.toString(line) + ":" + std.String.toString(col) + ": " + message;
    errors[errors.length] = text;
    diagnostics[diagnostics.length] = {message: message, file: sourcePath, line: line, col: col, endLine: line, endCol: col, span: {start: 0, end: 0}};
  };
  let isNode = (v) -> !isError(v.type);
  // Generic walk over AST nodes; the callback may stop descent by returning false.
  let daWalk = (node, fn) -> {
    if node == null || !isNode(node) { return null; };
    if fn(node) == false { return null; };
    let keys = std.Object.keys(node);
    let i = 0;
    while i < keys.length {
      let v = node[keys[i]];
      if isNode(v) { daWalk(v, fn); }
      else if AnyArray.check(v) { let j = 0; while j < v.length { if isNode(v[j]) { daWalk(v[j], fn); }; j = j + 1; }; };
      i = i + 1;
    };
  };
  let daCopyMap = (m) -> {
    let out = {}; let keys = std.Object.keys(m); let i = 0;
    while i < keys.length { out[keys[i]] = m[keys[i]]; i = i + 1; };
    out;
  };
  let daState = (declared, initialized) -> { { declared: declared, initialized: initialized, terminated: false }; };
  let daCopyState = (st) -> { { declared: st.declared, initialized: daCopyMap(st.initialized), terminated: st.terminated }; };
  let daEscaped = (range) -> {
    let escaped = {};
    let i = 0;
    while i < range.length {
      daWalk(range[i], (node) -> {
        if node.type == "Function" {
          daWalk(node.body, (inner) -> { if inner.type == "Identifier" { escaped[inner.name] = true; }; true; });
        };
        true;
      });
      i = i + 1;
    };
    escaped;
  };
  let daCheckExpr = (node, st, escaped) -> {
    if node == null || !isNode(node) { return null; };
    if node.type == "Function" {
      // Nested function: check its own locals; outer reads are deferred.
      checkFunctionBody(node);
      return null;
    };
    if node.type == "Identifier" {
      let name = node.name;
      if !isError(st.declared[name]) && st.initialized[name] != true && escaped[name] != true {
        daError(node, "reading uninitialized variable: " + name);
      };
      return null;
    };
    // Recurse into every child node (expressions, containers, blocks embedded in
    // expressions) so reads anywhere in an expression are checked.
    let keys = std.Object.keys(node);
    let i = 0;
    while i < keys.length {
      let v = node[keys[i]];
      if isNode(v) { daCheckExpr(v, st, escaped); }
      else if AnyArray.check(v) { let j = 0; while j < v.length { if isNode(v[j]) { daCheckExpr(v[j], st, escaped); }; j = j + 1; }; };
      i = i + 1;
    };
    null;
  };
  let checkStatements = (statements, st, escaped) -> {
    let i = 0;
    while i < statements.length {
      if !st.terminated { checkStatement(statements[i], st, escaped); };
      i = i + 1;
    };
  };
  let checkStatement = (node, st, escaped) -> {
    if node.type == "Let" {
      if node.value != null { daCheckExpr(node.value, st, escaped); st.declared[node.name] = true; st.initialized[node.name] = true; }
      else { st.declared[node.name] = true; st.initialized[node.name] = false; };
      null;
    } else if node.type == "Assign" {
      daCheckExpr(node.value, st, escaped);
      if node.target.type == "Identifier" {
        // Assigning only initializes a binding that this body declared with let.
        // An outer/module binding stays outside this body's analysis (its reads
        // are deferred, and an assignment to an undeclared name is a separate
        // frontend error).
        if !isError(st.declared[node.target.name]) { st.initialized[node.target.name] = true; };
      } else { daCheckExpr(node.target, st, escaped); };
      null;
    } else if node.type == "If" {
      let i = 0; let alive = []; let any = false;
      while i < node.branches.length {
        let branch = node.branches[i];
        daCheckExpr(branch.condition, st, escaped);
        let b = daCopyState(st);
        if branch.body.type == "Block" { checkStatements(branch.body.statements, b, escaped); } else { checkStatement(branch.body, b, escaped); };
        if !b.terminated { alive[alive.length] = b.initialized; any = true; };
        i = i + 1;
      };
      if node.elseBody != null {
        let e = daCopyState(st);
        if node.elseBody.type == "Block" { checkStatements(node.elseBody.statements, e, escaped); } else { checkStatement(node.elseBody, e, escaped); };
        if !e.terminated { alive[alive.length] = e.initialized; any = true; };
      } else { alive[alive.length] = st.initialized; any = true; };
      // Merge: initialized after the join only if initialized on every live path.
      // Each live branch state already reflects the incoming state, so the join
      // is the conjunction over the live paths.
      let merged = {};
      let names = std.Object.keys(st.declared); let n = 0;
      while n < names.length {
        let name = names[n]; let value = true;
        let k = 0;
        while k < alive.length { if alive[k][name] != true { value = false; }; k = k + 1; };
        merged[name] = value;
        n = n + 1;
      };
      st.initialized = merged;
      if !any { st.terminated = true; };
      null;
    } else if node.type == "While" {
      daCheckExpr(node.condition, st, escaped);
      // Analyze the body once (reporting errors inside it) but never propagate
      // its assignments: a body assignment is not definite after the loop.
      let b = daCopyState(st);
      if node.body.type == "Block" { checkStatements(node.body.statements, b, escaped); } else { checkStatement(node.body, b, escaped); };
      null;
    } else if node.type == "Return" {
      if node.value != null { daCheckExpr(node.value, st, escaped); };
      st.terminated = true;
      null;
    } else if node.type == "Export" {
      if node.value != null { daCheckExpr(node.value, st, escaped); };
      null;
    } else { daCheckExpr(node, st, escaped); null; };
  };
  let checkFunctionBody = (fn) -> {
    let declared = {}; let initialized = {};
    let i = 0;
    while i < fn.parameters.length { declared[fn.parameters[i].name] = true; initialized[fn.parameters[i].name] = true; i = i + 1; };
    let st = daState(declared, initialized);
    let escaped = daEscaped([fn.body, fn.parameters]);
    if fn.body.type == "Block" { checkStatements(fn.body.statements, st, escaped); } else { checkStatement(fn.body, st, escaped); };
  };
  let checkDefiniteAssignment = (statements) -> {
    let st = daState({}, {});
    let escaped = daEscaped(statements);
    checkStatements(statements, st, escaped);
  };

  let parse = () -> {
    let statements = [];
    while !check(TokenKind.Eof) {
      skipNewlines();
      if !check(TokenKind.Eof) { statements[statements.length] = parseStatement(); };
      skipNewlines();
      // Skip stray semicolons after statements (common after if/while blocks;
      // the host tolerates them and they produce no statement)
      while check(TokenKind.Semicolon) {
        advance();
      }
    }
    let program = Program(statements);
    if tokens.length > 0 { locateBetween(program, tokens[0], tokens[tokens.length - 1]); };
    checkDefiniteAssignment(statements);
    program.errors = errors; program.diagnostics = diagnostics;
    return program;
  };

  let parseStatement = () -> {
    skipNewlines(); let first = peek();
    locateMissing(parseStatementInner(), first);
  };
  let parseStatementInner = () -> {
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

  let parseAnnotation = () -> {
    let start = peek().span.start;
    let ann = parseExpression();
    let end = previous().span.end;
    let text = "";
    if end <= sourceChars.length {
      let i = start;
      while i < end { text = text + sourceChars[i]; i = i + 1; };
    } else { text = "?"; };
    ann.annotationText = text;
    ann;
  };

  let parseLetStatement = () -> {
    skipNewlines();
    advance(); // Skip 'let' keyword
    if !check(TokenKind.Identifier) { return parseError("Expected variable name"); };
    let name = peek().value;
    advance(); // Skip the identifier

    // Optional type annotation: let x: Number = 10; — the annotation is a full
    // expression (evaluated to a type value at runtime; checking is Task 11)
    let annotation = null;
    if check(TokenKind.Colon) {
      advance();
      annotation = parseAnnotation();
    }

    if check(TokenKind.Equal) {
      advance(); // Skip '='
      let value = parseExpression();
      if check(TokenKind.Semicolon) { advance(); }
      skipNewlines();
      return LetStmt(name, value, annotation);
    } else if check(TokenKind.Semicolon) {
      // Declaration without initializer: let x; / let x: T;
      advance();
      skipNewlines();
      return LetStmt(name, null, annotation);
    } else {
      return parseError("Expected '=' or ';' after declaration");
    };
  };

  let parseIfStatement = () -> {
    skipNewlines();
    advance();
    let condition = parseExpression();
    if !check(TokenKind.LeftBrace) {
      return parseError("Expected '{'");
    } else {
      // Note: do NOT advance() — parseBlock expects to consume '{' itself
      let thenBranch = parseBlock();

      let branches = [locate(IfBranch(condition, thenBranch), nodeStart(condition))];
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
            advance(); // consume If — parseExpression expects the condition next
            // This is an else if
            let elseIfCondition = parseExpression();
            if !check(TokenKind.LeftBrace) {
              return parseError("Expected '{' after else if condition");
            };
            // Do NOT advance() — parseBlock expects to consume '{' itself
            let elseIfBody = parseBlock();
            branches[branches.length] = locate(IfBranch(elseIfCondition, elseIfBody), nodeStart(elseIfCondition));
            // Continue the loop to check for more else if / else
          } else {
            // This is a plain else
            if check(TokenKind.LeftBrace) {
              elseBody = parseBlock();
            } else { return parseError("Expected '{' after else"); };
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
      return parseError("Expected '{'");
    } else {
      // Do NOT advance() — parseBlock expects to consume '{' itself
      let body = parseBlock();
      return WhileStmt(condition, body);
    };
  };

  let parseReturnStatement = () -> {
    skipNewlines();
    let keyword = advance();
    let invalidContext = null;
    if !insideFunction {
      invalidContext = parseErrorAt("return is only allowed inside a function", keyword);
    };
    // Consume the complete statement even on a scope error so parsing progresses.
    let value = parseExpression();
    if check(TokenKind.Semicolon) { advance(); }
    skipNewlines();
    if invalidContext != null { return invalidContext; };
    return ReturnStmt(value);
  };

  let parseExportStatement = () -> {
    skipNewlines();
    advance();
    let name = null;
    if check(TokenKind.Let) {
      advance();
      if !check(TokenKind.Identifier) { return parseError("Expected export name"); };
      name = advance().value;
      if !check(TokenKind.Equal) { return parseError("Expected '=' in named export"); };
      advance();
    };
    let value = parseExpression();
    if check(TokenKind.Semicolon) { advance(); }
    skipNewlines();
    let result = ExportStmt(value); result.name = name; result;
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
    skipNewlines(); let first = peek();
    if check(TokenKind.LeftBrace) {
      // Block with braces
      advance();
      let statements = [];
      while !check(TokenKind.RightBrace) && !check(TokenKind.Eof) {
        skipNewlines();
        if !check(TokenKind.RightBrace) && !check(TokenKind.Eof) { statements[statements.length] = parseStatement(); };
        skipNewlines();
        // Skip stray semicolons after statements (common after if/while blocks;
        // the host tolerates them and they produce no statement. Skip AFTER the
        // statement, not before: a leading skip would expose '}' to be consumed by an Error node)
        while check(TokenKind.Semicolon) {
          advance();
        }
      }
      if !matchToken([TokenKind.RightBrace]) { return parseError("Expected '}' after block"); };
      return locate(Block(statements), first);
    } else {
      // Arrow function body without braces - parse single expression and wrap in block
      let expr = parseExpression();
      return locate(Block([expr]), first);
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
      let assignmentToken = previous();
      // Assignment is a statement, so its right side must be an expression.
      let value = parseExpression();
      if check(TokenKind.Equal) {
        let error = parseErrorAt("Chained assignment is not allowed", peek());
        // Consume the remaining chain without constructing nested Assign nodes.
        while matchToken([TokenKind.Equal]) { parseExpression(); };
        return error;
      };
      if left.type == "Identifier" {
        return AssignStmt(left, value);
      } else if left.type == "MemberAccess" {
        return AssignStmt(left, value);
      } else if left.type == "IndexAccess" {
        return AssignStmt(left, value);
      } else {
        return parseErrorAt("Invalid assignment target", assignmentToken);
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
      left = locate(BinaryOpExpr("??", left, right), nodeStart(left));
    }
    return left;
  };

  let parseOr = () -> {
    skipNewlines();
    let left = parseAnd();
    while matchToken([TokenKind.Or]) {
      let right = parseAnd();
      left = locate(BinaryOpExpr("||", left, right), nodeStart(left));
    }
    return left;
  };

  let parseAnd = () -> {
    skipNewlines();
    let left = parseBitwiseOr();
    while matchToken([TokenKind.And]) {
      let right = parseBitwiseOr();
      left = locate(BinaryOpExpr("&&", left, right), nodeStart(left));
    }
    return left;
  };

  let parseBitwiseOr = () -> {
    skipNewlines();
    let left = parseBitwiseXor();
    while matchToken([TokenKind.BitwiseOr]) {
      let right = parseBitwiseXor();
      left = locate(BinaryOpExpr("|", left, right), nodeStart(left));
    }
    return left;
  };

  let parseBitwiseXor = () -> {
    skipNewlines();
    let left = parseBitwiseAnd();
    while matchToken([TokenKind.BitwiseXor]) {
      let right = parseBitwiseAnd();
      left = locate(BinaryOpExpr("^", left, right), nodeStart(left));
    }
    return left;
  };

  let parseBitwiseAnd = () -> {
    skipNewlines();
    let left = parseEquality();
    while matchToken([TokenKind.BitwiseAnd]) {
      let right = parseEquality();
      left = locate(BinaryOpExpr("&", left, right), nodeStart(left));
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
        left = locate(BinaryOpExpr("==", left, right), nodeStart(left));
      } else if matchToken([TokenKind.NotEqual]) {
        let right = parseComparison();
        left = locate(BinaryOpExpr("!=", left, right), nodeStart(left));
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
        left = locate(BinaryOpExpr("<", left, right), nodeStart(left));
      } else if matchToken([TokenKind.LessEqual]) {
        let right = parseAddition();
        left = locate(BinaryOpExpr("<=", left, right), nodeStart(left));
      } else if matchToken([TokenKind.Greater]) {
        let right = parseAddition();
        left = locate(BinaryOpExpr(">", left, right), nodeStart(left));
      } else if matchToken([TokenKind.GreaterEqual]) {
        let right = parseAddition();
        left = locate(BinaryOpExpr(">=", left, right), nodeStart(left));
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
        left = locate(BinaryOpExpr("+", left, right), nodeStart(left));
      } else if matchToken([TokenKind.Minus]) {
        let right = parseMultiplication();
        left = locate(BinaryOpExpr("-", left, right), nodeStart(left));
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
        left = locate(BinaryOpExpr("*", left, right), nodeStart(left));
      } else if matchToken([TokenKind.Slash]) {
        let right = parseUnary();
        left = locate(BinaryOpExpr("/", left, right), nodeStart(left));
      } else if matchToken([TokenKind.Percent]) {
        let right = parseUnary();
        left = locate(BinaryOpExpr("%", left, right), nodeStart(left));
      } else {
        done = true;
      }
    }
    return left;
  };

  let parseUnary = () -> {
    skipNewlines(); let first = peek();
    if matchToken([TokenKind.Bang]) {
      let right = parseUnary();
      return locate(UnaryOpExpr("!", right), first);
    } else if matchToken([TokenKind.Minus]) {
      let right = parseUnary();
      return locate(UnaryOpExpr("-", right), first);
    } else if matchToken([TokenKind.Plus]) {
      let right = parseUnary();
      return locate(UnaryOpExpr("+", right), first);
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
        if !matchToken([TokenKind.RightParen]) { return parseError("Expected ')' after arguments"); };
        expr = locate(CallExpr(expr, arguments), nodeStart(expr));
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
          expr = locate(MemberAccessExpr(expr, name), nodeStart(expr));
        } else {
          return parseError("Expected member name after '.'");
        }
      } else if matchToken([TokenKind.LeftBracket]) {
        let index = parseExpression();
        if !matchToken([TokenKind.RightBracket]) { return parseError("Expected ']' after index"); };
        expr = locate(IndexAccessExpr(expr, index), nodeStart(expr));
      } else if matchToken([TokenKind.Question]) {
        expr = locate(UnaryOpExpr("?", expr), nodeStart(expr));
      } else {
        done = true;
      }
    }

    return expr;
  };

  // Every arrow spelling lowers to the same Function / Parameter / Block AST.
  let parseFunctionBody = (params) -> {
    // Parameters/annotations were parsed in the defining outer context.
    let outerContext = insideFunction;
    insideFunction = true;
    let body = parseBlock();
    insideFunction = outerContext;
    FunctionExpr(params, body);
  };

  let parsePrimary = () -> {
    skipNewlines(); let first = peek();
    locateMissing(parsePrimaryInner(), first);
  };
  let parsePrimaryInner = () -> {
    skipNewlines();
    let token = peek();

    if token.kind == TokenKind.Number {
      advance();
      return NumberExpr(token.value);
    } else if token.kind == TokenKind.String {
      advance();
      if isError(token.parts) { return StringExpr(token.value); };
      let parts = []; let i = 0;
      while i < token.parts.length {
        let part = token.parts[i];
        if part.kind == "Literal" { parts[parts.length] = part; }
        else {
          let inner = Parser(part.tokens);
          // Interpolation is evaluated in its enclosing lexical context.
          inner.setFunctionContext(insideFunction);
          inner.setSource(sourceText); inner.setSourcePath(sourcePath);
          let expr = inner.parseExpression();
          if inner.getErrors().length > 0 {
            let diagnostic = inner.getDiagnostics()[0];
            return parseErrorAt(diagnostic.message, diagnostic);
          };
          if !inner.check(TokenKind.Eof) { return parseErrorAt("Expected one interpolation expression", inner.peek()); };
          parts[parts.length] = { kind: "Interpolation", expression: expr };
        };
        i = i + 1;
      };
      return { type: "String", value: "", parts: parts };
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
      if matchToken([TokenKind.Arrow]) {
        return parseFunctionBody([locatedParameter(token.value, null, token)]);
      };
      return IdentifierExpr(token.value);
    } else if token.kind == TokenKind.Import {
      advance();
      if matchToken([TokenKind.LeftParen]) {
        let pathExpression = parseExpression()?;
        if !matchToken([TokenKind.RightParen]) { return parseError("Expected ')' after dynamic import path"); };
        return { type: "Import", pathExpression: pathExpression };
      };
      if check(TokenKind.String) {
        let pathToken = advance();
        if !isError(pathToken.parts) { return parseErrorAt("Import path must be a literal string", pathToken); };
        if pathToken.value == "" { return parseErrorAt("Empty import path", pathToken); };
        return ImportExpr(pathToken.value);
      };
      let path = ""; let end = peek().span.start;
      // Unquoted paths are contiguous tokens, so the next source line remains a statement.
      let done = false;
      while !done && !check(TokenKind.Eof) {
        let t = peek();
        if t.span.start != end { done = true; }
        else if t.kind == TokenKind.Dot || t.kind == TokenKind.Slash || t.kind == TokenKind.Minus || t.kind == TokenKind.Identifier {
          if t.kind == TokenKind.Dot { path = path + "."; }
          else if t.kind == TokenKind.Slash { path = path + "/"; }
          else if t.kind == TokenKind.Minus { path = path + "-"; }
          else { path = path + t.value; };
          end = t.span.end; advance();
        } else { done = true; };
      };
      if path == "" { return parseError("Expected import path"); };
      return ImportExpr(path);
    } else if token.kind == TokenKind.If {
      return parseIfStatement();
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
          return parseFunctionBody([]);
        } else {
          // Just empty parens
          return { type: "Null", value: null };
        }
      } else if check(TokenKind.Identifier) {
        // Might be (name, ...) or (name) -> or just (name)
        let firstToken = peek();
        let potentialParam = firstToken.value;
        advance(); // Skip the identifier

        // Parameter type annotations: `(a: Type, ...) -> ...` (only identifier parameters can carry annotations;
        // the annotation is a full expression, evaluated to a type value — checking is Task 11)
        let annotation = null;
        if check(TokenKind.Colon) {
          advance();
          annotation = parseAnnotation();
        }

        // With an annotation, force the parameter-list path (avoiding (x: T) being silently treated as grouping)
        if annotation != null || check(TokenKind.Comma) {
          // This is a parameter list: (a, b, ...) / (a: T, b: U, ...)
          let params = [locatedParameter(potentialParam, annotation, firstToken)];
          skipNewlines();
          while matchToken([TokenKind.Comma]) {
            skipNewlines();
            if !check(TokenKind.RightParen) {
              if !check(TokenKind.Identifier) { return parseError("Expected parameter name"); };
              let paramToken = advance(); let paramName = paramToken.value;
              let ann = null;
              if matchToken([TokenKind.Colon]) { ann = parseAnnotation(); };
              params[params.length] = locatedParameter(paramName, ann, paramToken);
              skipNewlines();
            };
          };
          if !matchToken([TokenKind.RightParen]) { return parseError("Expected ')' after parameters"); };
          if !matchToken([TokenKind.Arrow]) { return parseError("Expected '->' after parameters"); };
          return parseFunctionBody(params);
        } else if check(TokenKind.RightParen) {
          // Just (name) - could be grouping or single param function
          advance();
          if check(TokenKind.Arrow) {
            // (name) -> body
            advance();
            return parseFunctionBody([locatedParameter(potentialParam, null, firstToken)]);
          } else {
            // Grouped expression: (name)
            return locateBetween(IdentifierExpr(potentialParam), firstToken, firstToken);
          };
        } else {
          // (name ...) is neither a parameter list nor (name): rewind the consumed
          // identifier and re-parse as a generic grouped expression (e.g. (x > 0 && y > 5);
          // the old code returned IdentifierExpr, leaving dangling tokens that became Error statements)
          current = current - 1;
          skipNewlines();
          let expr = parseExpression();
          skipNewlines();
          if !matchToken([TokenKind.RightParen]) { return parseError("Expected ')' after expression"); };
          if check(TokenKind.Arrow) {
            advance();
            if expr.type != "Identifier" { return parseError("Expected parameter name before '->'"); };
            return parseFunctionBody([locatedParameter(expr.name, null, nodeStart(expr))]);
          };
          return expr;
        };
      } else {
        // Not an identifier at start, parse as grouped expression
        skipNewlines();
        let expr = parseExpression();
        skipNewlines();
        if !matchToken([TokenKind.RightParen]) { return parseError("Expected ')' after expression"); };
        if check(TokenKind.Arrow) {
          advance();
          if expr.type != "Identifier" { return parseError("Expected parameter name before '->'"); };
          return parseFunctionBody([locatedParameter(expr.name, null, nodeStart(expr))]);
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
      if !matchToken([TokenKind.RightBracket]) { return parseError("Expected ']' after array"); };
      return ArrayExpr(elements);
    } else if token.kind == TokenKind.LeftBrace {
      advance();
      let fields = [];
      while !check(TokenKind.RightBrace) && !check(TokenKind.Eof) {
        let key = peek();
        if key.kind != TokenKind.Identifier && key.kind != TokenKind.String && key.kind != TokenKind.Number && !isKeyword(key.kind) {
          advance(); return parseErrorAt("Expected object key", key);
        };
        if !isError(key.parts) { advance(); return parseErrorAt("Object keys must be literal strings", key); };
        advance();
        let name = key.value;
        if key.kind == TokenKind.Number { name = std.Number.toString(name); };
        let value = null;
        if matchToken([TokenKind.Colon]) { value = parseExpression(); }
        else if key.kind == TokenKind.Identifier && (check(TokenKind.Comma) || check(TokenKind.RightBrace)) { value = locateBetween(IdentifierExpr(name), key, key); }
        else { return parseError("Expected ':' after object key"); };
        fields[fields.length] = locate(ObjectField(name, value), key);
        if check(TokenKind.Eof) { return parseError("Expected '}'"); };
        if !matchToken([TokenKind.Comma]) && !check(TokenKind.RightBrace) { return parseError("Expected ',' in object"); };
      };
      if !matchToken([TokenKind.RightBrace]) { return parseError("Expected '}'"); };
      return ObjectExpr(fields);
    } else if token.kind == TokenKind.Arrow {
      advance();
      return parseFunctionBody([]);
    } else {
      advance();
      if token.kind == TokenKind.Error { return parseErrorAt(token.value, token); };
      return parseErrorAt("Unexpected token: " + token.kind, token);
    }
  };

  return { parse: parse, getErrors: () -> errors, getDiagnostics: () -> diagnostics, setSource: setSource, setSourcePath: setSourcePath, setFunctionContext: setFunctionContext, peek: peek, previous: previous, advance: advance, check: check, parseExpression: parseExpression };
};

export Parser;
