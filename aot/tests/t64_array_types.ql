// Array type family: SizedArray / TypedArray / TypedSizedArray / Tuple.
// Also pins the construction-error contract (invalid members are Error values,
// not silently accepted type values).
let T = TypedArray(Number);
println(T.check([1, 2]));
println(T.check([1, "s"]));
println(T.check([1]));
let S = SizedArray(3);
println(S.check([1, 2, 3]));
println(S.check([1, 2]));
let TS = TypedSizedArray(2, Number);
println(TS.check([1, 2]));
println(TS.check([1, "s"]));
println(TS.check([1, 2, 3]));
let TP = Tuple([Number, String]);
println(TP.check([1, "a"]));
println(TP.check([1, 2]));
println(TP.check([1]));
let O = TypedArray({ name: String });
println(O.check([{ name: "a" }]));
println(O.check([{ name: 1 }]));
println(std.Type.check(TypedArray(Object)));
println(isError(TypedArray(5)));
println(isError(TypedSizedArray(2, 5)));
println(isError(SizedArray(-1)));
println(isError(SizedArray(1.5)));
println(isError(Tuple([Number, 5])));
println(std.Type.check(T));
