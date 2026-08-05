// Lexer for QLang - Tokenizes source code
// Bootstrapped QLang implementation

import ./tokens.ql;
import ./stdlib.ql;

let Lexer = (source) -> {
  let chars = std.String.toChars(source);
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
        advance();
        advance();
        while !(peek() == "*" && peekNext() == "/") && peek() != "" {
          advance();
        }
        if peek() == "*" {
          advance();
          advance();
        }
      } else {
        done = true;
      };
    }
  };

  let scanNumber = () -> {
    // Don't overwrite startIndex - it's already set correctly in scanToken
    // and advance() was already called on the first digit
    let hasDecimal = false;
    let done = false;

    while !done {
      let c = peek();
      // Check for end of input first to avoid includes("") returning true
      if c == "" {
        done = true;
      } else if std.String.includes("0123456789")(c) {
        advance();
      } else if c == "." {
        if hasDecimal { done = true; }
        hasDecimal = true;
        advance();
      } else {
        done = true;
      };
    }

    let numStr = "";
    let i = startIndex;
    while i < currentIndex {
      numStr = numStr + chars[i];
      i = i + 1;
    }

    let value = std.Number.parseFloat(numStr);
    return { kind: TokenKind.Number, value: value, span: { start: startIndex, end: currentIndex } };
  };

  let scanString = (quote) -> {
    // Note: scanToken already consumed the opening quote, so we must NOT advance()
    // here again (it would drop the first character of the string)
    startIndex = currentIndex;
    let currentLiteral = "";

    while peek() != "" && peek() != quote {
      let c = advance();
      if c == "\\" {
        let next = peek();
        if next != "" {
          advance();
          // Handle escape sequences using nested if-else (not else if as expression)
          let escaped = if next == "n" {
            "\n"
          } else {
            if next == "t" {
              "\t"
            } else {
              if next == "r" {
                "\r"
              } else {
                if next == "\\" {
                  "\\"
                } else {
                  if next == "\"" {
                    "\""
                  } else {
                    if next == "'" {
                      "'"
                    } else {
                      next
                    }
                  }
                }
              }
            }
          };
          currentLiteral = currentLiteral + escaped;
        }
      } else {
        currentLiteral = currentLiteral + c;
      };
    }

    if peek() == quote { advance(); }

    return { kind: TokenKind.String, value: currentLiteral, span: { start: startIndex, end: currentIndex } };
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
    // error value (host error-as-value), never null; detect via std.Type.of
    let probe = kw[text];
    let kind = if std.Type.of(probe) == "Error" {
      TokenKind.Identifier;
    } else {
      probe;
    };
    return { kind: kind, value: text, span: { start: startIndex, end: currentIndex } };
  };

  let scanToken = () -> {
    skipWhitespace();
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
    else if c == "." { return { kind: TokenKind.Dot, span: { start: startIndex, end: currentIndex } }; }
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
    else if c == "\"" || c == "'" { return scanString(c); }
    else if std.String.includes("0123456789")(c) { return scanNumber(); }
    else if std.String.includes("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_")(c) { return scanIdentifier(); }
    else { return { kind: TokenKind.Error, value: "Unexpected character: " + c, span: { start: startIndex, end: currentIndex } }; };
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
