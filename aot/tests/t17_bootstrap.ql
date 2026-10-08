// Module code may be reused, while namespace objects and closures stay fresh.
let original = std.String.toString;
std.String.toString = (value) -> "caller";
let first = import ./modules/std_namespace.ql;
// Import explicitly exports std, so restore the caller namespace separately.
let firstStd = std;
let second = import ./modules/std_namespace.ql;
println(first.original(42));
println(second.original(42));
println(first.std == second.std);
println(first.std.String == second.std.String);
println(first.std.String.toString == second.std.String.toString);
println(firstStd.extra);
println(original(true));
println(original(null));
println(original(42) == "42");
println(original([1, 2]) == "[1, 2]");
println(std.Type.of(Number) == std.Type);
