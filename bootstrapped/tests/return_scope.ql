// Parser-only contract for function-scoped ReturnStmt validation.
// The snippets are parsed as source strings; no snippet is compiled or run.
import ../lexer.ql;
import ../parser.ql;

let checks = 0;
let assert = (ok, label) -> {
  checks = checks + 1;
  if !ok { return std.Error.raise("AssertionFailed", label, null); };
  null;
};
let parse = (source, path) -> {
  let parser = Parser(Lexer(source).tokenize());
  parser.setSource(source);
  parser.setSourcePath(path);
  { parser: parser, program: parser.parse() };
};
let returnMessage = "return is only allowed inside a function";

// Return belongs to an enclosing function body, including nested statements.
let valid = [
  "let f = () -> { return 1; };",
  "let outer = () -> { let inner = () -> { return 2; }; inner(); };",
  "let outer = () -> { let f = (x: if true { return Number; } else { Number; }) -> x; Number; };",
  "let f = () -> { let text = \"v=\${if true { return 3; } else { 4; }}\"; 5; };",
  "let f = () -> { let text = \"v=\${(() -> { return 6; })()}\"; let g = () -> { return 7; }; g(); };",
  "let obj = {return: 1}; let text = \"return\"; obj.return == 1;"
];
let i = 0;
while i < valid.length {
  let result = parse(valid[i], "/fixtures/valid" + std.String.toString(i) + ".ql");
  assert(result.program.errors.length == 0, "accept valid source " + std.String.toString(i))?;
  i = i + 1;
};

// All script/module top-level forms below are rejected, including control-flow
// blocks and expression positions. A function nested in an interpolation must
// restore the surrounding top-level context before the following Return.
let invalid = [
  "return 1;",
  "if true { return 1; };",
  "while false { return 1; };",
  "let value = if true { return 1; } else { 2; };",
  "let f = (x: if true { return Number; } else { Number; }) -> x;",
  "let f = () -> { return 1; }; return 2;",
  "let text = \"v=\${if true { return 1; } else { 2; }}\";",
  "let text = \"v=\${(() -> { return 1; })()}\"; return 2;"
];
i = 0;
while i < invalid.length {
  let path = "/fixtures/invalid" + std.String.toString(i) + ".ql";
  let result = parse(invalid[i], path);
  assert(result.program.errors.length > 0, "reject top-level Return source " + std.String.toString(i))?;
  let diagnostic = result.program.diagnostics[0];
  assert(diagnostic.file == path, "diagnostic file " + std.String.toString(i))?;
  assert(std.String.includes(diagnostic.message)(returnMessage), "diagnostic message " + std.String.toString(i))?;
  i = i + 1;
};

// Only a value-bearing return is grammar-supported; this remains an ordinary
// parse error and must not be reported as a function-scope violation.
let bare = parse("let f = () -> { return; };", "/fixtures/bare.ql");
assert(bare.program.errors.length > 0, "bare return still requires a value")?;
assert(!std.String.includes(bare.program.diagnostics[0].message)(returnMessage), "bare return keeps parse diagnostic")?;

// Unicode scalars and CRLF are counted in the original source coordinates.
let positionedSource = "let label = \"中😀\";\r\nreturn 9;";
let positionedPath = "/fixtures/中😀.ql";
let positioned = parse(positionedSource, positionedPath);
assert(positioned.program.errors.length > 0, "reject CRLF top-level return")?;
let location = positioned.program.diagnostics[0];
assert(location.file == positionedPath, "Unicode diagnostic file")?;
assert(location.line == 2 && location.col == 1, "CRLF return line and column")?;
assert(location.span.start == 19 && location.span.end == 25, "Unicode CRLF return token span")?;
assert(std.String.includes(location.message)(returnMessage), "Unicode return scope diagnostic")?;

println("PASS function return scope (" + std.String.toString(checks) + " assertions, 6 valid / 9 scope-rejected + bare-return grammar)");
