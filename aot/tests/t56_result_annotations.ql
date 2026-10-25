// Result/Option annotations and the annotation-check success protocol.
// A check that accepts an Error must store it (Err is a value), not propagate it.
let z = 0;
let e = 1 / z;

let anyValue: Any = e;
println(anyValue.type);
let resultValue: std.Result(Number) = e;
println(resultValue.type);

// The two engines wrap/propagate failed annotation checks differently today, so
// this fixture asserts the portable fact (an Error was produced), not its kind.
let fail = () -> { let numberValue: Number = e; numberValue; };
println(isError(fail()));

let reassign = () -> { let numberValue: Number = 1; numberValue = e; numberValue; };
println(isError(reassign()));

println(std.Option(Number).check(5));
println(std.Option(Number).check(null));
println(std.Option(Number).check("x"));

let propagate = (): std.Result(Number) -> { let w = 0; let value = (1 / w)?; value; };
println(propagate().type);

// Migration period: an unannotated function may still use `?`; an Option-annotated
// function is accepted by the parser (Option-specific `?` semantics come later).
let legacy = () -> { let w = 0; let value = (1 / w)?; value; };
println(legacy().type);
let optionPropagate = (): std.Option(Number) -> { let w = 0; let value = (1 / w)?; value; };
println(optionPropagate().type);
