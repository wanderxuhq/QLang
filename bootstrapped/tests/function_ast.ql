// Contract tests for the QLang parser. Expected ASTs do not come from Rust.
import ../lexer.ql;
import ../parser.ql;
import ../ast.ql;

let assert = (condition, label) -> {
  if !condition { return std.Error.raise("AssertionFailed", label, null); };
  true;
};
// Source metadata is intentionally spelling-dependent; semantic AST shape is not.
let semanticKeys = (node) -> {
  let all = std.Object.keys(node); let keys = []; let i = 0;
  while i < all.length {
    if all[i] != "location" { keys[keys.length] = all[i]; };
    i = i + 1;
  };
  keys;
};
let equal = (a, b) -> {
  if AnyArray.check(a) {
    if !AnyArray.check(b) || a.length != b.length { return false; };
    let i = 0;
    while i < a.length {
      if !equal(a[i], b[i]) { return false; };
      i = i + 1;
    };
    return true;
  };
  if AnyObject.check(a) {
    if !AnyObject.check(b) { return false; };
    let keys = semanticKeys(a);
    if keys.length != semanticKeys(b).length { return false; };
    let i = 0;
    while i < keys.length {
      if !equal(a[keys[i]], b[keys[i]] ) { return false; };
      i = i + 1;
    };
    return true;
  };
  a == b;
};
let parse = (source) -> {
  let parser = Parser(Lexer(source).tokenize());
  parser.setSource(source);
  parser.parse();
};
let expression = (source) -> {
  let program = parse(source);
  assert(program.errors.length == 0, "parse: " + source)?;
  assert(program.statements.length == 1, "statement count: " + source)?;
  program.statements[0];
};
let x = IdentifierExpr("x");
let add = BinaryOpExpr("+", x, NumberExpr(1));
let single = FunctionExpr([Parameter("x", null)], Block([add]));
assert(equal(expression("x -> x + 1;")?, single), "bare parameter AST")?;
assert(equal(expression("(x) -> x + 1;")?, single), "parenthesized parameter AST")?;
assert(equal(expression("x -> { x + 1; };")?, single), "block body AST")?;
assert(equal(expression("(x -> x + 1);")?, single), "grouped function AST")?;
let zero = FunctionExpr([], Block([NumberExpr(1)]));
assert(equal(expression("-> 1;")?, zero), "bare zero-argument AST")?;
assert(equal(expression("() -> 1;")?, zero), "parenthesized zero-argument AST")?;
let nested = FunctionExpr([Parameter("x", null)], Block([
  FunctionExpr([Parameter("y", null)], Block([BinaryOpExpr("+", x, IdentifierExpr("y"))]))
]));
assert(equal(expression("x -> y -> x + y;")?, nested), "nested function AST")?;
assert(equal(expression("(x) -> (y) -> x + y;")?, nested), "nested parenthesized AST")?;
assert(equal(expression("(x + 1);")?, add), "ordinary grouping")?;
assert(equal(expression("(x, y,) -> x + y;")?, expression("(x, y) -> x + y;")?), "trailing comma")?;
assert(equal(expression("(x,\ny\n) -> x + y;")?, expression("(x, y) -> x + y;")?), "multiline parameters")?;
let invalid = ["(1) -> 2;", "(x + 1) -> 2;", "(x, 1) -> x;", "(x, y z) -> x;", "(x,,y) -> x;", "(x, y);", "(x, y -> x;"];
let i = 0;
while i < invalid.length {
  assert(parse(invalid[i]).errors.length > 0, "reject: " + invalid[i])?;
  i = i + 1;
};
println("PASS function AST contracts (11 valid, 7 invalid)");
