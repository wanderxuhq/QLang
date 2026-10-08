// Repeated partials from one call site must own distinct argument snapshots.
let pair = (a, b) -> a + b;
let bind = (x) -> pair(x);
let saved = []; let i = 0;
while i < 40 { saved.add(bind(i)); i = i + 1; };
println(saved[0](100)); println(saved[17](100)); println(saved[39](100));
println(saved[17](200));
println(pair()(7, 8));
println(saved[0]().type); println(saved[0](1, 2).type);

// A captured argument list owns values, preserving shared object identity.
let shared = { n: 10 };
let field = (object, add) -> object.n + add;
let bound = field(shared);
shared.n = 30;
println(bound(2));
let capture = (value) -> () -> value;
let kept = capture(shared);
capture({ n: 99 });
println(kept() == shared);

// Calls at one loop site may dispatch to different function policies.
let identity = (value) -> value;
let checked = (value: Number) -> value + 1;
let calls = [identity, checked, Number.check, isError];
i = 0;
while i < calls.length { println(calls[i](4)); i = i + 1; };
let partialChecked = ((a: Number, b: Number) -> a + b)(3);
println(partialChecked(5)); println(partialChecked("bad").type);

// Nested calls and recursion must not overwrite still-live outer arguments.
let combine = (a, b, c) -> a * 100 + b * 10 + c;
let order = 0;
let next = () -> { order = order + 1; order; };
println(combine(next(), identity(next()), next()));
let recurse = (n, original) -> if n == 0 { original } else { recurse(n - 1, original) + n };
println(recurse(20, 1));
let tooDeep = (n) -> tooDeep(n + 1);
println(tooDeep(0).type); println(checked(9));

// Variable-arity Error construction consumes the argument wrapper immediately.
let inner = Error.raise("inner");
let error = Error.raise("outer", inner);
Error.raise("noise");
println(error.message); println(error.cause.message == inner.message);
let rejected = pair(inner, next());
println(rejected.type); println(rejected.cause.message == inner.message); println(order);

// A heap argument and escaped closure remain live through allocation churn.
let retain = (object, other) -> {
  let j = 0;
  while j < 1000 { let trash = { text: "temporary " + std.String.toString(j) }; j = j + 1; };
  () -> object.n + other.n;
};
let result = retain({ n: 20 }, { n: 22 });
println(result());
println(saved[17](100)); println(bound(2));
