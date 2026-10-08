// Inline scalars must survive value slots, heap container growth and calls.
let id = (x) -> x;
let uninitialized;
println(uninitialized.type);
uninitialized = null;
println(Null.check(uninitialized));
println(std.Type.of(0) == Number);
println(std.Type.of(false) == Boolean);
let scalar: Number;
scalar = 7;
let copy = scalar;
scalar = 8;
println(copy); println(scalar);

let shared = { value: 1 };
let values = [0, false, null, -0, shared, id, Error.raise("retained")];
let i = 0;
while i < 100 { values.add(i + 0.5); i = i + 1; };
shared.value = 42;
println(values[0]); println(values[1]); println(Null.check(values[2]));
println(std.JSON.stringify(values[3]));
println(values[4].value); println(values[5](12)); println(values[6].message);
println(values[106]);
values.remove(0);
println(values[0]); println(Null.check(values[1]));
println(values[105]);

let fields = { zero: 0, boolean: false, nothing: null, object: shared, fn: id };
i = 0;
while i < 100 { fields["field" + std.String.toString(i)] = i + 0.25; i = i + 1; };
println(fields.zero); println(fields.boolean); println(Null.check(fields.nothing));
println(fields.object.value); println(fields.fn(13)); println(fields.field99);
let sum = 0; i = 0;
while i < 100 { sum = sum + fields["field" + std.String.toString(i)]; i = i + 1; };
println(sum);

let hold = (number, boolean, nothing) -> () -> [number, boolean, nothing];
let saved = hold(-0, false, null);
println(std.JSON.stringify(saved()));
let special = ["5e-324", "-0.0", "1.7976931348623157e308"];
i = 0;
while i < special.length {
  let n = id(std.JSON.parse(special[i]));
  let box = { value: n }; let array = [box.value];
  println(n == std.JSON.parse(std.JSON.stringify(array[0])));
  i = i + 1;
};
let inner = Error.raise("inner");
let outer = inner + 1;
println(outer.type); println(outer.cause.message);
// Source coordinates vary by engine; this fixture checks their scalar ABI.
// Exact native/core provenance is covered by t38/t39.
println(Number.check(inner.line)); println(Number.check(inner.col)); println(Null.check(inner.cause));
