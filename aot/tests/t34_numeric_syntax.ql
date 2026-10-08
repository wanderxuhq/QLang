// Numeric literals are exercised as source, shared by native AOT and core.
let checks = 0;
let check = (ok, label) -> { checks = checks + 1; if !ok { println("FAIL " + label); }; };
let cases = [
  [0, "0.0"],
  [42, "42.0"],
  [00012, "12.0"],
  [3.14, "3.14"],
  [.5, "0.5"],
  [5., "5.0"],
  [1.e2, "100.0"],
  [1e3, "1000.0"],
  [1E+3, "1000.0"],
  [2e-5, "2e-05"],
  [.5e+2, "50.0"],
  [0e-9999, "0.0"],
  [5e-324, "5e-324"],
  [2.2250738585072014e-308, "2.2250738585072014e-308"],
  [1.7976931348623157e308, "1.7976931348623157e+308"],
  [1e309, "Infinity"],
  [1e-9999, "0.0"],
  [0x0, "0.0"],
  [0Xff, "255.0"],
  [0x000F, "15.0"],
  [0x123456789abcdef, "8.19855292164869e+16"],
  [0x20000000000001, "9007199254740992.0"],
  [0x20000000000003, "9007199254740996.0"],
  [0x20000000000001001, "3.689348814741911e+19"],
  [0x20000000000000fff, "3.6893488147419103e+19"],
  [0x1fffffffffffff, "9007199254740991.0"],
  [0x10000000000000001, "1.8446744073709552e+19"],
  [0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff, "Infinity"],
  [0x1000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000, "Infinity"],
  [0x40000000000001, "1.8014398509481984e+16"],
  [0x40000000000002, "1.8014398509481984e+16"],
  [0x40000000000003, "1.8014398509481988e+16"],
  [0x100000000000007ffffff, "1.2089258196146292e+24"],
  [0x100000000000008000000, "1.2089258196146292e+24"],
  [0x100000000000008000001, "1.2089258196146294e+24"],
  [0x100000000000007fffffffffffffffffffffffffffffff, "1.532495540865889e+54"],
  [0x1000000000000080000000000000000000000000000000, "1.532495540865889e+54"],
  [0x1000000000000080000000000000000000000000000001, "1.5324955408658892e+54"]
];
let i = 0;
while i < cases.length {
  check(cases[i][0] == std.Number.parseFloat(cases[i][1]), "literal " + std.String.toString(i));
  i = i + 1;
};
check(+.5 == 0.5 && -0Xff == -255, "signed numeric literals");
check(1 + +2 * +3 == 7 && +-2 == -2, "unary precedence");
check(std.JSON.stringify(+(-0)) == "-0", "unary plus preserves negative zero");
check(std.JSON.stringify(-0e99999) == "-0", "literal negative zero");
check(std.JSON.stringify(-1e-9999) == "-0", "literal signed underflow");
let bad = [+true, +null, +"x", +[], +{}, +(x -> x), +Number, +println];
let names = ["Boolean", "Null", "String", "Array", "Object", "Function", "Type", "Function"];
i = 0;
while i < bad.length {
  check(isError(bad[i]) && bad[i].type == "TypeMismatch", "unary plus rejects " + names[i]);
  check(bad[i].message == "cannot apply unary plus to " + names[i] + " and Number", "unary plus diagnostic " + names[i]);
  check(bad[i].cause == null, "unary plus has no invented cause");
  i = i + 1;
};
let original = Error.raise("original"); let failure = +original;
check(failure.type == "TypeMismatch" && failure.cause.message == "original", "unary plus Error cause");
let count = 0; let once = () -> { count = count + 1; 42; };
check(+once() == 42 && count == 1, "operand evaluated once");
let stop = () -> { let x; +(x?); count = count + 1; };
check(isError(stop()) && count == 1, "explicit propagation");
// Explicit declarations remain legal; these names are not predefined.
let Infinity = 7; let NaN = 8;
check(Infinity + NaN == 15, "ordinary explicit names");
println("numeric syntax checks: " + std.String.toString(checks));
