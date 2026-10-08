// Compare compiled literals and parseFloat against independently parsed text.
// Fractions must not pass through the general display formatter in LLVM IR.
let cases = [
  [3.14159, "3.14159"],
  [0.12345678912345678, "0.12345678912345678"],
  [1.0000000000000002, "1.0000000000000002"],
  [4503599627370495.5, "4503599627370495.5"],
  [0.00000000000000000001, "0.00000000000000000001"],
  [100000000000000000000, "100000000000000000000"],
  [9007199254740993, "9007199254740993"],
  [0.1, "0.1"]
];
let i = 0;
while i < cases.length {
  let entry = cases[i]; let exact = std.JSON.parse(entry[1])?;
  println(entry[0] == exact);
  println(std.Number.parseFloat(entry[1]) == exact);
  i = i + 1;
};
