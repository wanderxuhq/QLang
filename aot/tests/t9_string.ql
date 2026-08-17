// M3 t9_string:std.String(3-way;host/native 逐字节一致)
// Ruling T6-E:只用 ASCII(字节长 == 字符数)
// Ruling T6-F:replace 只用单次非重叠出现(host str::replace 全量 vs native 首个)
// Ruling T6-H:柯里化成员一律 let 绑定;replace 三段全部 let 绑定
println(std.String.length("hello"));
println(std.String.length(""));
println(std.String.concat("foo", "bar"));
println(std.String.toString("xyz"));
println(std.String.trim("  x  "));
println(std.String.trim("abc"));
println(std.String.toUpperCase("hi"));
println(std.String.toLowerCase("HI"));
let si = std.String.includes("hello");
println(si("ell"));
println(si("xyz"));
let r0 = std.String.replace("hello world");
let r1 = r0("world");
println(r1("QLang"));
let r2 = std.String.replace("abc");
let r3 = r2("b");
println(r3("Z"));
let r4 = std.String.replace("abc");
let r5 = r4("x");
println(r5("Z"));
let sp = std.String.split("a,b,c");
println(sp(",").length);
let sp2 = std.String.split("x");
println(sp2(",")[0]);
let rp = std.String.repeat("ab");
println(rp(3));
let sw = std.String.startsWith("abc");
println(sw("ab"));
println(sw("bc"));
let ew = std.String.endsWith("abc");
println(ew("bc"));
println(ew("ab"));
let jn = std.String.join(["a", "b"]);
println(jn("-"));
println(std.String.at("hi", 1));
