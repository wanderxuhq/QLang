// Keys with equal contents must have equal hashes, regardless of allocation.
let o = { ab: 7 };
let dynamic = "a" + "b";
println(o[dynamic] ?? -1);
o[dynamic] = 9;
println(o.ab);
println(std.Object.keys(o).length);
o[""] = 13;
println(o[""]);
let i = 0;
while i < 12 {
  o["key" + std.Number.toString(i)] = i;
  i = i + 1;
};
println(o["key11"] ?? -1);
println(o["a" + "b"] ?? -1);
println(o[""] ?? -1);
println(std.Object.keys(o).length);
println(o["missing"] ?? "absent");

// A keyword following a dot remains a member name, not an if expression.
o["if"] = 23;
println(o.if);
