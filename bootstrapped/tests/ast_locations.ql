// Source metadata is not part of the normalized semantic AST shape.
import ../lexer.ql;
import ../parser.ql;
let assert = (ok, label) -> { if !ok { return std.Error.raise("AssertionFailed", label, null); }; true; };
let cases = [{"source": "missing;", "path": ["statements", 0], "start": 0, "end": 7, "line": 1, "col": 1, "endLine": 1, "endCol": 8}, {"source": "(missing);", "path": ["statements", 0], "start": 1, "end": 8, "line": 1, "col": 2, "endLine": 1, "endCol": 9}, {"source": "((missing));", "path": ["statements", 0], "start": 2, "end": 9, "line": 1, "col": 3, "endLine": 1, "endCol": 10}, {"source": "let x = -missing;", "path": ["statements", 0, "value"], "start": 8, "end": 16, "line": 1, "col": 9, "endLine": 1, "endCol": 17}, {"source": "let x = -missing;", "path": ["statements", 0, "value", "operand"], "start": 9, "end": 16, "line": 1, "col": 10, "endLine": 1, "endCol": 17}, {"source": "let x = 1 + missing * 2;", "path": ["statements", 0, "value"], "start": 8, "end": 23, "line": 1, "col": 9, "endLine": 1, "endCol": 24}, {"source": "let x = 1 + missing * 2;", "path": ["statements", 0, "value", "right", "left"], "start": 12, "end": 19, "line": 1, "col": 13, "endLine": 1, "endCol": 20}, {"source": "foo(1).bar[2]?;", "path": ["statements", 0], "start": 0, "end": 14, "line": 1, "col": 1, "endLine": 1, "endCol": 15}, {"source": "foo(1).bar[2]?;", "path": ["statements", 0, "operand", "object", "object", "callee"], "start": 0, "end": 3, "line": 1, "col": 1, "endLine": 1, "endCol": 4}, {"source": "\"中😀\";\r\n  missing = 1;", "path": ["statements", 1, "target"], "start": 9, "end": 16, "line": 2, "col": 3, "endLine": 2, "endCol": 10}, {"source": "// 文本\r  let f = (x: Missing) -> x;", "path": ["statements", 0, "value", "parameters", 0, "annotation"], "start": 20, "end": 27, "line": 2, "col": 15, "endLine": 2, "endCol": 22}, {"source": "// 文本\r  let f = (x: Missing) -> x;", "path": ["statements", 0, "value", "parameters", 0], "start": 17, "end": 27, "line": 2, "col": 12, "endLine": 2, "endCol": 22}, {"source": "let f = x -> {\n  missing;\n};", "path": ["statements", 0, "value", "body", "statements", 0], "start": 17, "end": 24, "line": 2, "col": 3, "endLine": 2, "endCol": 10}, {"source": "let f = x -> {\n  missing;\n};", "path": ["statements", 0, "value", "body"], "start": 13, "end": 27, "line": 1, "col": 14, "endLine": 3, "endCol": 2}, {"source": "let x = {missing};", "path": ["statements", 0, "value", "fields", 0, "value"], "start": 9, "end": 16, "line": 1, "col": 10, "endLine": 1, "endCol": 17}, {"source": "let x = {field: missing};", "path": ["statements", 0, "value", "fields", 0], "start": 9, "end": 23, "line": 1, "col": 10, "endLine": 1, "endCol": 24}, {"source": "let x = `中😀\${missing}`;", "path": ["statements", 0, "value", "parts", 1, "expression"], "start": 13, "end": 20, "line": 1, "col": 14, "endLine": 1, "endCol": 21}, {"source": "let f = () -> (x) -> x;", "path": ["statements", 0, "value", "body", "statements", 0], "start": 14, "end": 22, "line": 1, "col": 15, "endLine": 1, "endCol": 23}, {"source": "import (args[0]);", "path": ["statements", 0], "start": 0, "end": 16, "line": 1, "col": 1, "endLine": 1, "endCol": 17}, {"source": "import (args[0]);", "path": ["statements", 0, "pathExpression"], "start": 8, "end": 15, "line": 1, "col": 9, "endLine": 1, "endCol": 16}, {"source": "if true {\n missing;\n};", "path": ["statements", 0, "branches", 0, "body", "statements", 0], "start": 11, "end": 18, "line": 2, "col": 2, "endLine": 2, "endCol": 9}, {"source": "while false {\n missing;\n};", "path": ["statements", 0, "body", "statements", 0], "start": 15, "end": 22, "line": 2, "col": 2, "endLine": 2, "endCol": 9}, {"source": "let f = () -> { return missing; };", "path": ["statements", 0, "value", "body", "statements", 0], "start": 16, "end": 31, "line": 1, "col": 17, "endLine": 1, "endCol": 32}, {"source": "export let value = missing;", "path": ["statements", 0, "value"], "start": 19, "end": 26, "line": 1, "col": 20, "endLine": 1, "endCol": 27}];

let i = 0;
while i < cases.length {
  let test = cases[i]; let parser = Parser(Lexer(test.source).tokenize());
  parser.setSource(test.source); parser.setSourcePath("/fixtures/中 source.ql");
  let node = parser.parse(); assert(node.errors.length == 0, "valid fixture")?;
  let j = 0; while j < test.path.length { node = node[test.path[j]]; j = j + 1; };
  let p = node.location;
  assert(p.file == "/fixtures/中 source.ql", "file " + std.String.toString(i))?;
  assert(p.line == test.line && p.col == test.col, "start " + std.String.toString(i))?;
  assert(p.endLine == test.endLine && p.endCol == test.endCol, "end " + std.String.toString(i))?;
  assert(p.span.start == test.start && p.span.end == test.end, "span " + std.String.toString(i))?;
  i = i + 1;
};
let empty = ["", "\n", " \r\n\t\r\n", "// comment\n", "/* comment */\n"];
i = 0; while i < empty.length {
  let parser = Parser(Lexer(empty[i]).tokenize()); let program = parser.parse();
  assert(program.errors.length == 0 && program.statements.length == 0, "empty source")?;
  i = i + 1;
};
let blocks = ["let f = () -> {\n};", "if true {\r\n} else {\n};", "while false {\n};"];
i = 0; while i < blocks.length {
  let parser = Parser(Lexer(blocks[i]).tokenize());
  assert(parser.parse().errors.length == 0, "empty block")?;
  i = i + 1;
};
println("PASS AST locations (24 spans, 8 trivia cases)");
