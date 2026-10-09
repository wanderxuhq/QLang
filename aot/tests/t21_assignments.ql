// Fixed contracts for both QLang AST consumers. Failed writes return from the
// current function without executing subsequent statements or mutating targets.
// uninitialized-field / uninitialized-index: reading a member/index write's
// receiver is now a frontend error, so those two cases are no longer runtime
// contracts (covered by the frontend diagnostic fixture).
// null-field
let attempt = () -> { let x = null; x.field = 1; println("UNREACHABLE"); };
println(attempt().type);
// number-field
let attempt = () -> { let x = 42; x.field = 1; println("UNREACHABLE"); };
println(attempt().type);
// null-index
let attempt = () -> { let x = null; x[0] = 1; println("UNREACHABLE"); };
println(attempt().type);
// string-index
let attempt = () -> { let x = "abc"; x[0] = 1; println("UNREACHABLE"); };
println(attempt().type);
// array-far
let attempt = () -> { let x = [1]; x[2] = 1; println("UNREACHABLE"); };
println(attempt().type);
// array-negative
let attempt = () -> { let x = [1]; x[-2] = 1; println("UNREACHABLE"); };
println(attempt().type);
// array-fraction
let attempt = () -> { let x = [1]; x[0.5] = 1; println("UNREACHABLE"); };
println(attempt().type);
// array-string
let attempt = () -> { let x = [1]; x["0"] = 1; println("UNREACHABLE"); };
println(attempt().type);
// array-bool
let attempt = () -> { let x = [1]; x[true] = 1; println("UNREACHABLE"); };
println(attempt().type);
// object-bool
let attempt = () -> { let x = {}; x[true] = 1; println("UNREACHABLE"); };
println(attempt().type);
// object-null
let attempt = () -> { let x = {}; x[null] = 1; println("UNREACHABLE"); };
println(attempt().type);
// object-array
let attempt = () -> { let x = {}; x[[]] = 1; println("UNREACHABLE"); };
println(attempt().type);
// missing-parent
let attempt = () -> { let x = {}; x.missing.field = 1; println("UNREACHABLE"); };
println(attempt().type);
// failed-index: an uninitialized index is now a frontend error, so this case is
// covered by the frontend diagnostic fixture instead.
// protected-field
let attempt = () -> { Number.check = (v) -> false; println("UNREACHABLE"); };
println(attempt().type);
// protected-index
let attempt = () -> { let alias = Error; alias["raise"] = null; println("UNREACHABLE"); };
println(attempt().type);
// protected-type
let attempt = () -> { std.Type.of(Number).of = null; println("UNREACHABLE"); };
println(attempt().type);
// array-inf
let attempt = () -> { let x = [1]; let inf = std.JSON.parse("1e308") * 10; x[inf] = 1; println("UNREACHABLE"); };
println(attempt().type);
// array-nan
let attempt = () -> { let x = [1]; let inf = std.JSON.parse("1e308") * 10; x[inf - inf] = 1; println("UNREACHABLE"); };
println(attempt().type);
println(Number.check(42));
println(Error.check(Error.raise("still callable")));
let order = "";
let target = [0];
let rhs = () -> { order = order + "V"; 7; };
let receiver = () -> { order = order + "O"; target; };
let index = () -> { order = order + "I"; 0; };
receiver()[index()] = rhs();
println(order);
println(target[0]);
order = "";
let failedReceiver = () -> { order = order + "O"; let missing = null; missing.field; };
let attempt = () -> { failedReceiver()[index()] = rhs(); println("UNREACHABLE"); };
println(attempt().type);
println(order);
order = "";
let stopRhs = () -> { order = order + "V"; Error.raise("stop"); };
let attempt = () -> { receiver()[index()] = stopRhs()?; println("UNREACHABLE"); };
println(attempt().type);
println(order);
order = "";
let failedIndex = () -> { order = order + "I"; Error.raise("index"); };
let attempt = () -> { receiver()[failedIndex()] = rhs(); println("UNREACHABLE"); };
println(attempt().message);
println(order);
println(target[0]);
let values = [1, 2];
let alias = values;
values[-1] = 3;
values[values.length] = 4;
println(alias[1]);
println(alias[2]);
let object = { nested: [{ value: 1 }] };
object.nested[0].value = 8;
println(object.nested[0].value);
object[12] = "numeric key";
println(object["12"]);
println(object[12]);
let stored = Error.raise("stored value");
object.error = stored;
values[0] = stored;
println(object.error.message);
println(values[0].message);
let custom = std.Type.make((v) -> true);
custom.check = (v) -> false;
println(custom.check(1));
Number.extra = 6;
println(Number.extra);
let probe = () -> { while true { if true { let x = []; x[1] = 2; }; }; };
println(probe().type);
