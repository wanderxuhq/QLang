// Expected hexadecimal values were calculated from exact integers, independently
// of the QLang lexer. Decimal conversion is the existing Number contract.
import ../lexer.ql;
import ../parser.ql;
import ../tokens.ql;
let assert = (ok, label) -> {
  if !ok { return std.Error.raise("AssertionFailed", label, null); }; true;
};
let parse = (text) -> {
  let p = Parser(Lexer(text).tokenize()); p.setSource(text); p.setSourcePath("numbers.ql"); p.parse();
};
let cases = [
  ["0", "0.0"],
  ["42", "42.0"],
  ["00012", "12.0"],
  ["3.14", "3.14"],
  [".5", "0.5"],
  ["5.", "5.0"],
  ["1.e2", "100.0"],
  ["1e3", "1000.0"],
  ["1E+3", "1000.0"],
  ["2e-5", "2e-05"],
  [".5e+2", "50.0"],
  ["0e-9999", "0.0"],
  ["5e-324", "5e-324"],
  ["2.2250738585072014e-308", "2.2250738585072014e-308"],
  ["1.7976931348623157e308", "1.7976931348623157e+308"],
  ["1e309", "Infinity"],
  ["1e-9999", "0.0"],
  ["0x0", "0.0"],
  ["0Xff", "255.0"],
  ["0x000F", "15.0"],
  ["0x123456789abcdef", "8.19855292164869e+16"],
  ["0x20000000000001", "9007199254740992.0"],
  ["0x20000000000003", "9007199254740996.0"],
  ["0x20000000000001001", "3.689348814741911e+19"],
  ["0x20000000000000fff", "3.6893488147419103e+19"],
  ["0x1fffffffffffff", "9007199254740991.0"],
  ["0x10000000000000001", "1.8446744073709552e+19"],
  ["0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", "Infinity"],
  ["0x1000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000", "Infinity"],
  ["0x40000000000001", "1.8014398509481984e+16"],
  ["0x40000000000002", "1.8014398509481984e+16"],
  ["0x40000000000003", "1.8014398509481988e+16"],
  ["0x100000000000007ffffff", "1.2089258196146292e+24"],
  ["0x100000000000008000000", "1.2089258196146292e+24"],
  ["0x100000000000008000001", "1.2089258196146294e+24"],
  ["0x100000000000007fffffffffffffffffffffffffffffff", "1.532495540865889e+54"],
  ["0x1000000000000080000000000000000000000000000000", "1.532495540865889e+54"],
  ["0x1000000000000080000000000000000000000000000001", "1.5324955408658892e+54"]
];
let i = 0;
while i < cases.length {
  let text = cases[i][0]; let tokens = Lexer(text).tokenize();
  assert(tokens.length == 2 && tokens[0].kind == TokenKind.Number, "numeric token: " + text)?;
  assert(tokens[0].span.start == 0 && tokens[0].span.end == text.length, "numeric span: " + text)?;
  assert(tokens[0].value == std.Number.parseFloat(cases[i][1]), "numeric value: " + text)?;
  let p = parse(text + ";");
  assert(p.errors.length == 0 && p.statements.length == 1, "numeric parse: " + text)?;
  assert(p.statements[0].type == "Number" && p.statements[0].value == tokens[0].value, "numeric AST: " + text)?;
  i = i + 1;
};
let invalid = ["0x", "0X", "0xg", "0x1g", "0x1.2", "0x1p2", "1e", "1e+", "1e-", "1.e", "1e++2", "1e2x", "1.2.3", "1..2", ".5.6", "12abc", "1_000", "0b10", "0o10"];
i = 0;
while i < invalid.length {
  let text = "// comment\r\nlet n = " + invalid[i] + ";";
  let p = parse(text);
  assert(p.diagnostics.length > 0, "reject: " + invalid[i])?;
  let error = p.diagnostics[0];
  assert(error.file == "numbers.ql" && error.line == 2 && error.col == 9, "number error location: " + invalid[i])?;
  i = i + 1;
};
let p = parse("+.5; -0xFF; +(-2); 1 + +2;");
assert(p.errors.length == 0 && p.statements.length == 4, "unary expressions")?;
assert(p.statements[0].type == "UnaryOp" && p.statements[0].operator == "+" && p.statements[0].operand.value == 0.5, "unary plus AST")?;
assert(p.statements[1].operator == "-" && p.statements[1].operand.value == 255, "signed hex AST")?;
assert(p.statements[2].operand.operator == "-", "nested unary AST")?;
assert(p.statements[3].right.operator == "+", "binary and unary precedence")?;
let names = parse("Infinity; NaN;");
assert(names.statements[0].type == "Identifier" && names.statements[1].type == "Identifier", "names stay ordinary identifiers")?;
println("PASS numeric syntax frontend (38 valid, 19 invalid)");
