let x = 3;
println("plain ${ x + 1 }!");
println('single ${x}');
println(`template ${x}`);
println(`empty:${""}:end`);
println(`nested ${ {"a": "}"}.a } ${ `inner ${x}` }`);
println("same quote ${"inside"}!");
println(`branch ${if true { "yes"; } else { "no"; }}`);
println(`call ${((v) -> { v + 1; })(x)}`);
println(`comments ${1 /* } ${ ignored */ + 2}`);
println(`line ${// } ignored
1 + 2}`);
println(`multi
${
if false { 7; } else { 8; }
}
line`);
println("array ${[1, true, null, {a: 3}]}");
println("object ${{'key': ["x", {deep: false}]}}");
println("scalars ${null}/${true}/${false}/${1.25}/${-7}");
println("function ${() -> 1}");
println("native ${std.String.length}");
let add = (a, b) -> a + b;
println("partial ${add(1)}");
println("unicode 中${'文😀'}末");
println(std.JSON.stringify("escapes \b\f\n\r\t\v\0\x41\u4e2d\u{1f600}${x}"));
println("literal \${x} dollar $ end");
println(`escaped \` and \${x}`);
println("continuation a\
b${x}");
let n = 0;
let next = () -> { n = n + 1; n; };
println("${next()}${next()?}${next()}");
println(n);
let array = [1];
let change = () -> { array[0] = 2; null; };
println("${array}|${change()}|${array}");
let f = (v: Number) -> "v=${v}";
println(f(5));
let stop = () -> "${next()}${(1 / 0)?}${next()}";
println(isError(stop()));
println(n);
let recovered = "${(1 / 0) ?? 9}";
println(recovered);
let pending;
println(std.String.includes("before ${pending} after")("Uninitialized"));
pending = null;
println("initialized ${pending}");
// Errors remain renderable values; only an explicit ? propagates them.
println(std.String.includes("${1 / 0}")("DivisionByZero"));
