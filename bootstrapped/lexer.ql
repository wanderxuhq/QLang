// Lexer for QLang - Tokenizes source code
// Bootstrapped QLang implementation

import ./tokens.ql;
import ./stdlib.ql;
import ./source.ql;

let Lexer = (source) -> {
  let chars = std.String.toChars(source);
  let sourceMap = SourceMap(chars);
  let pendingError = null;
  let currentIndex = 0;
  let startIndex = 0;
  let sourceLength = std.Array.length(chars);

  let advance = () -> {
    if currentIndex < sourceLength {
      let c = chars[currentIndex];
      currentIndex = currentIndex + 1;
      return c;
    } else {
      return "";
    };
  };

  let peek = () -> {
    if currentIndex < sourceLength {
      return chars[currentIndex];
    } else {
      return "";
    };
  };

  let peekNext = () -> {
    if currentIndex + 1 < sourceLength {
      return chars[currentIndex + 1];
    } else {
      return "";
    };
  };

  let isAtEnd = () -> {
    return currentIndex >= sourceLength;
  };

  let matchChar = (expected) -> {
    if peek() == expected {
      advance();
      return true;
    } else {
      return false;
    };
  };

  let skipWhitespace = () -> {
    // Outer loop: keep skipping whitespace/newlines after a comment ends
    let done = false;
    while !done {
      let c = peek();
      if c != "" && std.String.includes(" \t\r\n")(c) {
        advance();
      } else if c == "/" && peekNext() == "/" {
        // Line comment: skip to end of line (\n is consumed as whitespace by the outer loop)
        while peek() != "" && peek() != "\n" && peek() != "\r" {
          advance();
        }
      } else if c == "/" && peekNext() == "*" {
        // Block comment
        let commentStart = currentIndex;
        advance();
        advance();
        while !(peek() == "*" && peekNext() == "/") && peek() != "" {
          advance();
        }
        if peek() == "*" {
          advance();
          advance();
        } else {
          pendingError = stringError("Unterminated block comment", commentStart);
          done = true;
        }
      } else {
        done = true;
      };
    }
  };

  let isDigit = (c) -> c != "" && std.String.includes("0123456789")(c);
  let numberToken = (value) -> {
    let c = peek();
    // Never split a malformed number into successful adjacent expressions.
    if (c != "" && std.String.includes("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_0123456789")(c)) || (c == "." && (isDigit(peekNext()) || peekNext() == ".")) {
      return stringError("Invalid number literal", startIndex);
    };
    { kind: TokenKind.Number, value: value, span: { start: startIndex, end: currentIndex } };
  };
  let scanHexNumber = () -> {
    advance(); // x/X; the initial zero was already consumed
    let digits = 0; let bits = 0; let significand = 0;
    let roundBit = false; let sticky = false;
    let digit = hexDigit(peek());
    while digit >= 0 {
      advance(); digits = digits + 1;
      let weight = 8;
      while weight >= 1 {
        let bit = 0;
        if digit >= weight { bit = 1; digit = digit - weight; };
        if bits > 0 || bit != 0 {
          bits = bits + 1;
          if bits <= 53 { significand = significand * 2 + bit; }
          else if bits == 54 { roundBit = bit != 0; }
          else if bit != 0 { sticky = true; };
        };
        weight = weight / 2;
      };
      digit = hexDigit(peek());
    };
    if digits == 0 { return stringError("Expected hexadecimal digits", startIndex); };
    // Round once to binary64, ties to even. Accumulating whole hex digits in
    // a Number would lose sticky bits and can round long literals incorrectly.
    if roundBit && (sticky || significand % 2 != 0) { significand = significand + 1; };
    let shift = bits - 53;
    if shift > 1024 { significand = std.Number.parseFloat("Infinity"); }
    else { while shift > 0 { significand = significand * 2; shift = shift - 1; }; };
    numberToken(significand);
  };
  let scanNumber = () -> {
    // The first digit (or leading decimal point) was consumed by scanToken.
    if chars[startIndex] == "0" && (peek() == "x" || peek() == "X") { return scanHexNumber(); };
    while isDigit(peek()) { advance(); };
    if chars[startIndex] != "." && peek() == "." {
      advance(); while isDigit(peek()) { advance(); };
    };
    if peek() == "e" || peek() == "E" {
      advance(); if peek() == "+" || peek() == "-" { advance(); };
      if !isDigit(peek()) { return stringError("Expected exponent digits", startIndex); };
      while isDigit(peek()) { advance(); };
    };
    let numStr = ""; let i = startIndex;
    while i < currentIndex { numStr = numStr + chars[i]; i = i + 1; };
    numberToken(std.Number.parseFloat(numStr));
  };

  let stringError = (message, start) -> {
    { kind: TokenKind.Error, value: message, span: { start: start, end: currentIndex } };
  };
  let hexDigit = (c) -> {
    let digits = "0123456789abcdef"; let i = 0;
    while i < 16 { if digits[i] == c { return i; }; i = i + 1; };
    digits = "ABCDEF"; i = 0;
    while i < 6 { if digits[i] == c { return i + 10; }; i = i + 1; };
    -1;
  };
  let hex4 = (n) -> {
    let text = ""; let i = 0;
    while i < 4 { text = "0123456789abcdef"[n % 16] + text; n = (n - n % 16) / 16; i = i + 1; };
    "\\u" + text;
  };
  let scalarString = (n) -> {
    let text = "";
    if n <= 65535 { text = hex4(n); }
    else { let x = n - 65536; text = hex4(55296 + (x - x % 1024) / 1024) + hex4(56320 + x % 1024); };
    std.JSON.parse("\"" + text + "\"");
  };
  let scanString = (quote) -> {
    let start = currentIndex - 1;
    let literal = ""; let parts = [];
    while peek() != "" && peek() != quote {
      let c = advance();
      if quote != "`" && (c == "\n" || c == "\r") { return stringError("Unterminated string", start); };
      if c == "\\" {
        let e = advance();
        if e == "" { return stringError("Unterminated string", start); };
        if e == "n" { literal = literal + "\n"; }
        else if e == "t" { literal = literal + "\t"; }
        else if e == "r" { literal = literal + "\r"; }
        else if e == "\\" || e == "\"" || e == "'" || e == "$" || e == "{" || e == "}" { literal = literal + e; }
        else if quote == "`" {
          if e == "`" { literal = literal + e; } else { literal = literal + "\\" + e; };
        }
        else if e == "\n" || e == "\r" { if e == "\r" && peek() == "\n" { advance(); }; }
        else if e == "b" { literal = literal + "\b"; }
        else if e == "f" { literal = literal + "\f"; }
        else if e == "v" { literal = literal + "\v"; }
        else if e == "0" {
          if peek() != "" && std.String.includes("0123456789")(peek()) { return stringError("Invalid string escape", start); };
          literal = literal + "\0";
        }
        else if e == "x" || e == "u" {
          let braced = e == "u" && peek() == "{";
          let limit = if e == "x" { 2; } else { 4; };
          if braced { advance(); limit = 6; };
          let n = 0; let count = 0;
          while count < limit && hexDigit(peek()) >= 0 {
            n = n * 16 + hexDigit(advance()); count = count + 1;
          };
          if (braced && (count == 0 || peek() != "}")) || (!braced && count != limit) || n > 1114111 || (n >= 55296 && n <= 57343) {
            return stringError("Invalid Unicode escape", start);
          };
          if braced { advance(); };
          literal = literal + scalarString(n);
        }
        else { return stringError("Invalid string escape", start); };
      } else if c == "$" && peek() == "{" {
        advance();
        if literal != "" { parts[parts.length] = { kind: "Literal", value: literal }; literal = ""; };
        let tokens = []; let depth = 1; let closers = [TokenKind.RightBrace];
        while depth > 0 {
          let token = scanToken();
          if token.kind == TokenKind.Error { return token; };
          if token.kind == TokenKind.Eof { return stringError("Unterminated interpolation", start); };
          if token.kind == TokenKind.LeftBrace || token.kind == TokenKind.LeftParen || token.kind == TokenKind.LeftBracket {
            let close = TokenKind.RightBrace;
            if token.kind == TokenKind.LeftParen { close = TokenKind.RightParen; };
            if token.kind == TokenKind.LeftBracket { close = TokenKind.RightBracket; };
            closers[depth] = close; depth = depth + 1;
          };
          if token.kind == TokenKind.RightBrace || token.kind == TokenKind.RightParen || token.kind == TokenKind.RightBracket {
            if token.kind != closers[depth - 1] { return stringError("Mismatched interpolation delimiter", start); };
            depth = depth - 1;
          };
          if depth > 0 { tokens[tokens.length] = token; }
          else { tokens[tokens.length] = { kind: TokenKind.Eof, span: token.span, line: token.line, col: token.col, endLine: token.endLine, endCol: token.endCol }; };
        };
        parts[parts.length] = { kind: "Interpolation", tokens: tokens };
      } else { literal = literal + c; };
    };
    if peek() != quote { return stringError("Unterminated string", start); };
    advance();
    if parts.length == 0 { return { kind: TokenKind.String, value: literal, span: { start: start, end: currentIndex } }; };
    if literal != "" { parts[parts.length] = { kind: "Literal", value: literal }; };
    { kind: TokenKind.String, value: "", parts: parts, span: { start: start, end: currentIndex } };
  };

  let scanIdentifier = () -> {
    // Don't overwrite startIndex - it's already set correctly in scanToken
    while peek() != "" && std.String.includes("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")(peek()) {
      advance();
    }

    let text = "";
    let i = startIndex;
    while i < currentIndex {
      text = text + chars[i];
      i = i + 1;
    }

    let kw = kwMap;
    // Note: probing a missing key on a raw object now yields an UndefinedField
    // error value (host error-as-value), never null; detect via isError (the
    // old std.Type.of(probe) == "Error" string form broke after the type-system
    // migration — Type.of returns type values, and cross-interpreter identity
    // never matches; this site was missing from the Task 11 migration lists)
    let probe = kw[text];
    let kind = if isError(probe) {
      TokenKind.Identifier;
    } else {
      probe;
    };
    return { kind: kind, value: text, span: { start: startIndex, end: currentIndex } };
  };

  let scanTokenInner = () -> {
    skipWhitespace();
    if pendingError != null { let error = pendingError; pendingError = null; return error; };
    startIndex = currentIndex;

    if isAtEnd() {
      return { kind: TokenKind.Eof, span: { start: currentIndex, end: currentIndex } };
    }

    let c = advance();

    if c == "(" { return { kind: TokenKind.LeftParen, span: { start: startIndex, end: currentIndex } }; }
    else if c == ")" { return { kind: TokenKind.RightParen, span: { start: startIndex, end: currentIndex } }; }
    else if c == "{" { return { kind: TokenKind.LeftBrace, span: { start: startIndex, end: currentIndex } }; }
    else if c == "}" { return { kind: TokenKind.RightBrace, span: { start: startIndex, end: currentIndex } }; }
    else if c == "[" { return { kind: TokenKind.LeftBracket, span: { start: startIndex, end: currentIndex } }; }
    else if c == "]" { return { kind: TokenKind.RightBracket, span: { start: startIndex, end: currentIndex } }; }
    else if c == "," { return { kind: TokenKind.Comma, span: { start: startIndex, end: currentIndex } }; }
    else if c == "." {
      if isDigit(peek()) { return scanNumber(); };
      return { kind: TokenKind.Dot, span: { start: startIndex, end: currentIndex } };
    }
    else if c == ";" { return { kind: TokenKind.Semicolon, span: { start: startIndex, end: currentIndex } }; }
    else if c == ":" { return { kind: TokenKind.Colon, span: { start: startIndex, end: currentIndex } }; }
    else if c == "+" { return { kind: TokenKind.Plus, span: { start: startIndex, end: currentIndex } }; }
    else if c == "*" { return { kind: TokenKind.Star, span: { start: startIndex, end: currentIndex } }; }
    else if c == "%" { return { kind: TokenKind.Percent, span: { start: startIndex, end: currentIndex } }; }
    else if c == "^" { return { kind: TokenKind.BitwiseXor, span: { start: startIndex, end: currentIndex } }; }
    else if c == "/" { return { kind: TokenKind.Slash, span: { start: startIndex, end: currentIndex } }; }
    else if c == "!" {
      if matchChar("=") { return { kind: TokenKind.NotEqual, span: { start: startIndex, end: currentIndex } }; }
      else { return { kind: TokenKind.Bang, span: { start: startIndex, end: currentIndex } }; };
    }
    else if c == "=" {
      if matchChar("=") { return { kind: TokenKind.EqualEqual, span: { start: startIndex, end: currentIndex } }; }
      else if matchChar(">") { return { kind: TokenKind.Arrow, span: { start: startIndex, end: currentIndex } }; }
      else { return { kind: TokenKind.Equal, span: { start: startIndex, end: currentIndex } }; };
    }
    else if c == "<" {
      if matchChar("=") { return { kind: TokenKind.LessEqual, span: { start: startIndex, end: currentIndex } }; }
      else { return { kind: TokenKind.Less, span: { start: startIndex, end: currentIndex } }; };
    }
    else if c == ">" {
      if matchChar("=") { return { kind: TokenKind.GreaterEqual, span: { start: startIndex, end: currentIndex } }; }
      else { return { kind: TokenKind.Greater, span: { start: startIndex, end: currentIndex } }; };
    }
    else if c == "&" {
      if matchChar("&") { return { kind: TokenKind.And, span: { start: startIndex, end: currentIndex } }; }
      else { return { kind: TokenKind.BitwiseAnd, span: { start: startIndex, end: currentIndex } }; };
    }
    else if c == "|" {
      if matchChar("|") { return { kind: TokenKind.Or, span: { start: startIndex, end: currentIndex } }; }
      else { return { kind: TokenKind.BitwiseOr, span: { start: startIndex, end: currentIndex } }; };
    }
    else if c == "?" {
      if matchChar("?") { return { kind: TokenKind.QuestionQuestion, span: { start: startIndex, end: currentIndex } }; }
      else { return { kind: TokenKind.Question, span: { start: startIndex, end: currentIndex } }; };
    }
    else if c == "-" {
      if matchChar(">") { return { kind: TokenKind.Arrow, span: { start: startIndex, end: currentIndex } }; }
      else { return { kind: TokenKind.Minus, span: { start: startIndex, end: currentIndex } }; };
    }
    else if c == "\"" || c == "'" || c == "`" { return scanString(c); }
    else if std.String.includes("0123456789")(c) { return scanNumber(); }
    else if std.String.includes("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_")(c) { return scanIdentifier(); }
    else { return { kind: TokenKind.Error, value: "Unexpected character: " + c, span: { start: startIndex, end: currentIndex } }; };
  };

  let scanToken = () -> {
    let token = scanTokenInner();
    let start = sourceMap.position(token.span.start);
    let end = sourceMap.position(token.span.end);
    token.line = start.line; token.col = start.col;
    token.endLine = end.line; token.endCol = end.col;
    token;
  };

  let tokenize = () -> {
    let tokens = [];
    let done = false;
    while !done {
      let token = scanToken();
      tokens[tokens.length] = token;
      if token.kind == TokenKind.Eof || token.kind == TokenKind.Error { done = true; }
    }
    return tokens;
  };

  return { tokenize: tokenize, peek: peek, advance: advance, isAtEnd: isAtEnd, scanToken: scanToken };
};

export Lexer;
