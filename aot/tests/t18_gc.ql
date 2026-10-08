// Live closures, aliases, cycles and large buffers must survive temporary churn.
let cycle = { value: 42 }; cycle.self = cycle;
let alias = cycle;
let retained = [];
let make = (value) -> { let box = { value: value }; (extra) -> box.value + extra; };
let buffer = std.String.repeat("abcd")(20000);
let grown = []; let same = grown; let n = 0;
while n < 20000 { grown[grown.length] = n; n = n + 1; };
grown.remove(0); grown.add(77);
let i = 0;
while i < 20000 {
  let trash = [i, { text: "temporary " + std.Number.toString(i) }];
  if i % 4000 == 0 { retained.add(make(i)); };
  i = i + 1;
};
println(alias == cycle);
println(cycle.self.self.value);
println(buffer.length);
println(buffer[79999]);
let total = 0; let j = 0;
while j < retained.length { total = total + retained[j](1); j = j + 1; };
println(total);
println(retained[2](7));
println(same.length);
println(same[0]);
println(same[19999]);
