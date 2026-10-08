let NumberLibrary = std.Number;
let checks = 0;
let check = (ok, label) -> {
  checks = checks + 1;
  if !ok { return std.Error.raise("AssertionFailed", label, null); };
  null;
};
let invalid = ["", " ", "+", "-", ".", "1e", "1e+", "1tail", "1 2", "0x10", "1_0", "1.2.3", "\ufeff1"];
let i = 0;
while i < invalid.length {
  check(NumberLibrary.isNaN(NumberLibrary.parseFloat(invalid[i])), "reject malformed complete input")?; i = i + 1;
};
let other = [null, true, 1, [], {}, (x) -> x]; i = 0;
while i < other.length {
  check(NumberLibrary.isNaN(NumberLibrary.parseFloat(other[i])), "non-string parser argument")?;
  if i != 2 {
    check(!NumberLibrary.isNaN(other[i]), "predicate non-number")?;
    check(!NumberLibrary.isFinite(other[i]), "finite predicate non-number")?;
  };
  i = i + 1;
};
check(NumberLibrary.isFinite(0), "finite zero")?;
check(NumberLibrary.isFinite(5e-324), "finite tiny")?;
check(NumberLibrary.isFinite(1.7976931348623157e308), "finite maximum")?;
check(!NumberLibrary.isNaN(0), "valid zero")?;
check(std.JSON.stringify(NumberLibrary.parseFloat("-0")) == "-0", "negative zero exact")?;
check(NumberLibrary.parseFloat()("2.5") == 2.5, "parser partial")?;
check(NumberLibrary.isFinite()(2), "finite predicate partial")?;
let methods = [NumberLibrary.parseFloat, NumberLibrary.isFinite, NumberLibrary.isNaN]; i = 0;
while i < methods.length {
  check(methods[i](1, 2).type == "ArityMismatch", "excess arity")?;
  let original = Error.raise("input"); let error = methods[i](original);
  check(error.type == "TypeMismatch", "Error argument policy")?;
  // Error causes can be inspected through their plain message field. Comparing
  // the Error objects themselves would itself produce an Error, so identity is
  // intentionally outside this assertion's claim.
  check(error.cause.message == original.message, "Error cause message")?;
  let partial = methods[i]();
  if i == 0 {
    check(partial("2.5") == 2.5, "parser partial application succeeds")?;
  } else if i == 1 {
    check(partial(2) == true, "finite partial application succeeds")?;
  } else {
    check(partial(2) == false, "isNaN partial application succeeds")?;
  };
  check(partial(1, 2).type == "ArityMismatch", "partial excess arity")?;
  error = partial(original);
  check(error.type == "TypeMismatch", "partial Error argument policy")?;
  i = i + 1;
};
let spaces = "\t\n\u000b\f\r                  　";
i = 0;
while i < spaces.length {
  check(NumberLibrary.parseFloat(spaces[i] + "12.5" + spaces[i]) == 12.5, "Unicode whitespace")?; i = i + 1;
};
check(isError(std.Number.parseFloat.name), "default parser is ordinary QLang")?;
check(isError(std.Number.isFinite.name), "default finite predicate is ordinary QLang")?;
check(isError(std.Number.isNaN.name), "default numeric predicate is ordinary QLang")?;
let savedTrim = std.String.trim;
std.String.trim = (text) -> "999";
check(std.Number.parseFloat(" 2.5 ") == 2.5, "parser captures private String dependency")?;
std.String.trim = savedTrim;
println("portable Number checks: " + std.String.toString(checks));
let inputs = ["0", "-0", "+0", "00.000", "-0e999999", "1", "-1", "+.5", "1.", "1.e2", "00012.50", "1e-9999", "-1e-9999", "5e-324", "-5e-324", "1e-323", "2.4703282292062327e-324", "2.4703282292062328e-324", "2.225073858507201e-308", "2.2250738585072014e-308", "2.2250738585072016e-308", "1.7976931348623157e308", "-1.7976931348623157e308", "9007199254740991", "9007199254740992", "9007199254740993", "9007199254740995", "1.00000000000000011102230246251565404236316680908203125", "1.00000000000000033306690738754696212708950042724609375", "0.999999999999999944488848768742172978818416595458984375", "0.1000000000000000055511151231257827021181583404541015625", " \t2.5\r\n", "-3.5 ", "4.2595102415593856e-14", "1.669748647282941e+78", "4.0066257313948205e-160", "4.484343475471625e-213", "6.191507009024805e+190", "4.073544082350898e+137", "6.141630625838925e-177", "2.1685549646148274e-221", "-2.043672174504931e+45", "1.3967164107663285e+266", "209962.91156196743", "2.57895285582781e-144", "-4.2624452026471486e+95", "-135602211287.47337", "-1.269336992061271e+259", "-1.075534664488182e-166"];
let expected = [0.0, -0.0, 0.0, 0.0, -0.0, 1.0, -1.0, 0.5, 1.0, 100.0, 12.5, 0.0, -0.0, 5e-324, -5e-324, 1e-323, 0.0, 5e-324, 2.225073858507201e-308, 2.2250738585072014e-308, 2.2250738585072014e-308, 1.7976931348623157e+308, -1.7976931348623157e+308, 9007199254740991.0, 9007199254740992.0, 9007199254740992.0, 9007199254740996.0, 1.0, 1.0000000000000004, 1.0, 0.1, 2.5, -3.5, 4.2595102415593856e-14, 1.669748647282941e+78, 4.0066257313948205e-160, 4.484343475471625e-213, 6.191507009024805e+190, 4.073544082350898e+137, 6.141630625838925e-177, 2.1685549646148274e-221, -2.043672174504931e+45, 1.3967164107663285e+266, 209962.91156196743, 2.57895285582781e-144, -4.2624452026471486e+95, -135602211287.47337, -1.269336992061271e+259, -1.075534664488182e-166];
i = 0;
while i < inputs.length {
  let actual = std.Number.parseFloat(inputs[i]);
  check(actual == expected[i], "independent decimal rounding oracle")?;
  check(std.JSON.stringify(actual) == std.JSON.stringify(expected[i]), "exact zero sign and rounded value")?;
  i = i + 1;
};
check(checks == 181, "expected total Number check count")?;
println("portable Number total checks: " + std.String.toString(checks));
