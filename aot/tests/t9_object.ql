// M3 t9_object:对象索引(Gap A)+ std.Object(3-way;host/native 逐字节一致)
// Ruling T5-D:只用单键对象或 .length 断言(键序发散 pre-existing)
// Ruling T5-E:只用 interned 键(字符串字面量 / __obj_keys 返回键 → 指针同一)
// 柯里化成员(hasOwn/get/merge)经 let 绑定中间闭包调用 —— qlangc emitCall 对
// 非 Identifier/MemberAccess callee 的链式调用 f(a)(b) 未支持(emitNull),绑定后走 Identifier 路径。
let o = { a: 1 };
println(o["a"]);
let k = "a";
o[k] = 9;
println(o[k]);
println(o["a"]);
println(std.Object.keys({ x: 1 }).length);
println(std.Object.keys({ x: 1 }).length == 1);
println(std.Object.values({ x: 5 }).length);
println(std.Object.values({ x: 5 })[0] == 5);
let hx = std.Object.hasOwn({ x: 1 });
println(hx("x"));
let hy = std.Object.hasOwn({ x: 1 });
println(!hy("y"));
let gx = std.Object.get({ x: 1 });
println(gx("x"));
println(std.Object.field({ x: 1 }, "x"));
let m0 = std.Object.merge({ a: 1 });
let m = m0({ p: 7 });
println(m["a"]);
println(m["p"]);
