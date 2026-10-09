let calls = 0;
let f = (a, b) -> { calls = calls + 1; a + b; };
println(f(2, 3));
let partial = f(4);
println(calls);
println(partial(5));
println(partial(6));
println(f()(7, 8));
// Excess arguments to a statically known local function are now a frontend
// error (see bootstrapped/tests/diagnostics.ql), so this case no longer runs.
println(partial().type);
println(partial(1, 2).type);
println(calls);
let triple = (a, b, c) -> a + b + c;
println(triple(1)(2).type);
println(triple(1)(2, 3));

let effects = 0;
let tick = () -> { effects = effects + 1; 1; };
let error = std.Error.raise("Original", "bad", null);
let rejected = f(error, tick());
println(rejected.type);
println(rejected.cause.type);
println(effects);
println(calls);
let methods = { apply: f, add: (v) -> v + 1, remove: (v) -> v - 1 };
println(methods.apply(error, tick()).type);
println([f][0](error, tick()).type);
println((if true { f; } else { f; })(error, tick()).type);
println(effects);
println(calls);
println(methods.add(8));
println(methods.remove(8));
let __ordinary = (v) -> { calls = calls + 1; v; };
println(__ordinary(error).type);
println(calls);

println((42)().type);
println((null)().type);
println((true)().type);
println(("text")().type);
println(([])().type);
println(({})().type);
println(error().type);
println((42)(tick()).type);
println(effects);
let lookup = 0;
let choose = () -> { lookup = lookup + 1; f; };
println(choose()(3, 4));
println(lookup);

let same = f;
let other = (a, b) -> a + b;
println(f == same);
println(f == other);
let make = () -> () -> 1;
println(make() == make());
let factory = make();
println(factory == factory);
println(partial == partial);
println(f(4) == f(4));
println(Function.check(Number));
println(Function.check(f));

let diagnostic = isError;
println(diagnostic(error));
let checker = Number.check;
println(checker(error));
let typeof = std.Type.of;
println(typeof(error) == Error);
let stringify = std.JSON.stringify;
println(stringify(error).type);
println(Function.check(std.String.length()));
println(std.String.length("x", "y").type);
println(Function.check(std.String.includes("abc")()));
println(std.String.includes(error).type);
println(std.String.includes("abc")(error).type);
println(isError().type);
println(println().type);

let array = [];
let add = array.add;
add(1);
(array).add(2);
println(std.JSON.stringify(array));
println(add().type);
println(add(error).type);
println(array.length);
let remove = array.remove;
remove(0);
println(std.JSON.stringify(array));

let recurse = (n) -> recurse(n + 1);
println(recurse(0).type);
println(f(8, 9));

let secondError = std.Error.raise("Second", "later", null);
println(f(error, secondError).cause.type);
println(partial(error).type);
println(partial(error).cause.type);
println(Array(Number).check(error).type);
println(Object({a: Number}).check(error).type);
println(isError(Array(Number).check()));
println(isError(Object({a: Number}).check()));
println(Function.check(add));

// Duplicate parameter names share one binding; the last argument wins.
let duplicate = (x, x) -> x;
println(duplicate(1, 2));
