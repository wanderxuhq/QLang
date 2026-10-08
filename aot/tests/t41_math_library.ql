let MathLibrary = std.Math;
let checks = 0;
let check = (ok, label) -> {
  checks = checks + 1;
  if !ok { println("FAIL " + label); };
};
let cases = [
  [0, 0, 0, 0, 0, 0],
  [0.1, 0.1, 0, 0, 1, 0],
  [-0.1, 0.1, 0, -1, 0, 0],
  [0.5, 0.5, 0, 0, 1, 1],
  [-0.5, 0.5, 0, -1, 0, -1],
  [2.5, 2.5, 2, 2, 3, 3],
  [-2.5, 2.5, -2, -3, -2, -3],
  [2.4999999999999996, 2.4999999999999996, 2, 2, 3, 2],
  [-2.4999999999999996, 2.4999999999999996, -2, -3, -2, -2],
  [2.5000000000000004, 2.5000000000000004, 2, 2, 3, 3],
  [-2.5000000000000004, 2.5000000000000004, -2, -3, -2, -3],
  [4503599627370495.5, 4503599627370495.5, 4503599627370495, 4503599627370495, 4503599627370496, 4503599627370496],
  [-4503599627370495.5, 4503599627370495.5, -4503599627370495, -4503599627370496, -4503599627370495, -4503599627370496],
  [4503599627370496, 4503599627370496, 4503599627370496, 4503599627370496, 4503599627370496, 4503599627370496],
  [-4503599627370496, 4503599627370496, -4503599627370496, -4503599627370496, -4503599627370496, -4503599627370496],
  [9007199254740992, 9007199254740992, 9007199254740992, 9007199254740992, 9007199254740992, 9007199254740992],
  [-9007199254740992, 9007199254740992, -9007199254740992, -9007199254740992, -9007199254740992, -9007199254740992],
  [5e-324, 5e-324, 0, 0, 1, 0],
  [-5e-324, 5e-324, 0, -1, 0, 0]
];
let methods = [MathLibrary.abs, MathLibrary.trunc, MathLibrary.floor, MathLibrary.ceil, MathLibrary.round];
let names = ["abs", "trunc", "floor", "ceil", "round"];
let i = 0;
while i < cases.length {
  let row = cases[i]; let j = 0;
  while j < methods.length {
    check(methods[j](row[0]) == row[j + 1], names[j]); j = j + 1;
  };
  i = i + 1;
};
let negativeZero = std.JSON.stringify(-0);
let positiveZero = std.JSON.stringify(0);
check(negativeZero != positiveZero, "zero-sign oracle distinguishes signs");
check(std.JSON.stringify(MathLibrary.abs(-0)) == positiveZero, "abs clears zero sign");
i = 1;
while i < methods.length {
  check(std.JSON.stringify(methods[i](-0)) == negativeZero, "preserve negative zero");
  check(std.JSON.stringify(methods[i](0)) == positiveZero, "preserve positive zero");
  i = i + 1;
};
check(std.JSON.stringify(MathLibrary.trunc(-0.1)) == negativeZero, "trunc negative fraction");
check(std.JSON.stringify(MathLibrary.ceil(-0.1)) == negativeZero, "ceil negative fraction");
check(std.JSON.stringify(MathLibrary.round(-0.1)) == negativeZero, "round negative fraction");
let invalid = ["1", null, true, [], {}, (x) -> x];
i = 0;
while i < methods.length {
  let j = 0;
  while j < invalid.length {
    let result = methods[i](invalid[j]);
    check(result.type == "TypeMismatch", "argument type");
    check(result.message == "Math." + names[i] + " expects Number", "argument message");
    j = j + 1;
  };
  check(methods[i](Error.raise("input")).type == "TypeMismatch", "Error argument remains rejected");
  check(methods[i](1, 2).type == "ArityMismatch", "excess arguments");
  check(methods[i]()(2.5) == methods[i](2.5), "ordinary partial application");
  i = i + 1;
};
check(MathLibrary.PI == 3.141592653589793 && MathLibrary.E == 2.718281828459045, "constants");
check(isError(std.Math.abs.name), "default Math is an ordinary QLang function");
println("portable Math base checks: " + std.String.toString(checks));
