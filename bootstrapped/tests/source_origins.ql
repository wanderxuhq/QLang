// Fixed original-source spans generated independently of the QLang mapper.
import ../lexer.ql;
import ../parser.ql;
import ../source_origins.ql;
import ../library.ql;
let assert = (ok, label) -> { if !ok { return std.Error.raise("AssertionFailed", label, null); }; true; };
let parse = (text) -> {
  let parser = Parser(Lexer(text).tokenize()); parser.setSource(text); parser.setSourcePath("<bundle>"); parser.parse();
};
let source = "let factory = () -> {\n// bundled import\r\nlet f = (x: Number) -> {\r  \"中😀\";\r\n  missing(x);\n};\n// bundled export\nlet text = `中😀\${missing}`;\rlet g = () -> (other);\n};\n";
let origins = [{"path": "stdlib/one.ql", "startLine": 2, "endLine": 7, "sourceLineStarts": [0, 25, 50, 59, 73, 76], "sourceLength": 85}, {"path": "stdlib/two.ql", "startLine": 8, "endLine": 9, "sourceLineStarts": [0, 27], "sourceLength": 49}];
let cases = [{"path": ["statements", 0, "value", "body", "statements", 0, "value", "parameters", 0, "annotation"], "file": "stdlib/one.ql", "line": 2, "col": 13, "endLine": 2, "endCol": 19, "start": 37, "end": 43}, {"path": ["statements", 0, "value", "body", "statements", 0, "value", "body", "statements", 1, "callee"], "file": "stdlib/one.ql", "line": 4, "col": 3, "endLine": 4, "endCol": 10, "start": 61, "end": 68}, {"path": ["statements", 0, "value", "body", "statements", 0, "value", "body"], "file": "stdlib/one.ql", "line": 2, "col": 24, "endLine": 5, "endCol": 2, "start": 48, "end": 74}, {"path": ["statements", 0, "value", "body", "statements", 1, "value", "parts", 1, "expression"], "file": "stdlib/two.ql", "line": 1, "col": 17, "endLine": 1, "endCol": 24, "start": 16, "end": 23}, {"path": ["statements", 0, "value", "body", "statements", 2, "value", "body", "statements", 0], "file": "stdlib/two.ql", "line": 2, "col": 16, "endLine": 2, "endCol": 21, "start": 42, "end": 47}];
let program = remapSourceLocations(parse(source), "<bundle>", origins);
assert(program.errors.length == 0, "valid bundle")?;
let i = 0;
while i < cases.length {
  let test = cases[i]; let node = program; let j = 0;
  while j < test.path.length { node = node[test.path[j]]; j = j + 1; };
  let p = node.location;
  assert(p.file == test.file && p.line == test.line && p.col == test.col, "mapped start")?;
  assert(p.endLine == test.endLine && p.endCol == test.endCol, "mapped end")?;
  assert(p.span.start == test.start && p.span.end == test.end, "original scalar span")?;
  i = i + 1;
};
assert(program.location.file == "<bundle>" && program.statements[0].location.file == "<bundle>", "synthetic wrapper range")?;
remapSourceLocations(program, "<bundle>", origins);
assert(program.statements[0].value.body.statements[0].value.parameters[0].location.file == "stdlib/one.ql", "mapping is idempotent")?;
// Original import line is longer than its generated replacement; CRLF also
// occupies two scalars. The diagnostic must use the original offset, not delta-lines.
let broken = parse("let factory = () -> {\n// bundled import\r\nlet broken = (1;\r};\n");
let errorOrigins = [{path: "stdlib/broken.ql", startLine: 2, endLine: 3, sourceLineStarts: [0, 24, 41], sourceLength: 41}];
remapSourceLocations(broken, "<bundle>", errorOrigins);
let d = broken.diagnostics[0];
assert(d.file == "stdlib/broken.ql" && d.line == 2 && d.col == 16, "parse diagnostic source")?;
assert(d.span.start == 39 && d.span.end == 40, "parse diagnostic scalar span")?;
assert(std.String.startsWith(broken.errors[0])("stdlib/broken.ql:2:16: "), "formatted parse diagnostic")?;
// Production loader applies the same remapping before compiler/core consumption.
let library = parseStandardLibrary()?; let found = false; i = 0;
let statements = library.statements[0].value.body.statements;
while i < statements.length {
  let node = statements[i];
  if node.type == "Let" && node.name == "requireString" {
    assert(node.location.file == "stdlib/string.ql" && node.location.line == 4, "production library origin")?;
    found = true;
  };
  i = i + 1;
};
assert(found, "production library declaration")?;
println("PASS bundled source origins (5 spans, wrappers, diagnostics, library)");
