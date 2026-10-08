// Language indexing and function members, independent of std.Array wrappers.
let checks = 0;
let check = (ok, label) -> { checks = checks + 1; if !ok { println("FAIL " + label); }; };
let nan = std.Number.parseFloat("NaN"); let inf = std.Number.parseFloat("inf");
let a = [10, 20]; let s = "中😀";
let invalid = [0.5, -0.5, nan, inf, -inf, 2, -3]; let i = 0;
while i < invalid.length {
  let index = invalid[i];
  check(a[index].type == "IndexOutOfBounds", "Array invalid numeric index");
  check(s[index].type == "IndexOutOfBounds", "String invalid numeric index");
  i = i + 1;
};
let f = (x) -> x;
invalid = [null, true, "0", [], {}, f]; i = 0;
while i < invalid.length {
  let index = invalid[i];
  check(a[index].type == "CannotIndex", "Array nonnumeric index");
  check(s[index].type == "TypeMismatch", "String nonnumeric index");
  i = i + 1;
};
check(a[0] == 10, "Array positive index");
check(a[-1] == 20, "Array negative index");
check(s[-1] == "😀", "String scalar index");
let original = Error.raise("stored"); let values = [original, f];
let retrieved = values[0];
check(isError(retrieved) && retrieved.message == "stored", "stored Error remains a value");
check(values[1] == f && values[1](7) == 7, "stored function remains callable");
check(isError(f.name), "ordinary function has no native name");
check(isError(f.type), "function representation tag is private");
check(isError(f.params), "function parameters are private");
check(isError(f.body), "function body is private");
check(isError(f.env), "function closure environment is private");
check(a.add.name == "Array.add", "native bound method metadata");
println("value access checks: " + std.String.toString(checks));
