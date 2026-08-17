// M3 t9_array:std.Array(3-way;host/native 逐字节一致)
// Ruling T6-H:柯里化成员一律 let 绑定首参(链式 f(a)(b) 在 native emitNull 丢弃)
// Ruling T6-A:toString 格式 = [1, 2, 3](host JS 风格,", " 分隔)
// Ruling T6-J:reverse 返回新数组,原数组不变
// Ruling T6-C:indexOf/includes 数字元素依赖 __op_eq 的 NUMBER 分支
let a = [1, 2, 3];
println(a.length);
let pu = std.Array.push(a);
pu(4);
println(a.length);
let inc = std.Array.includes(a);
println(inc(2));
println(inc(9));
let jo = std.Array.join(a);
println(jo("-"));
let io = std.Array.indexOf(a);
println(io(3));
println(io(99));
let rr = std.Array.reverse([1, 2, 3]);
println(rr.length);
let s = [1, 2, 3];
let rv = std.Array.reverse(s);
println(s[0]);
println(rv[0]);
println(std.Array.toString([1, 2, 3]));
println(std.Array.toString([]));
let p = std.Array.pop(a);
println(p());
println(a.length);
println(std.Array.at([7, 8], 1));
let ad = std.Array.add([5]);
ad(6);
let rm = std.Array.remove([5, 6, 7]);
rm(0);
let g = std.Array.get([9, 8]);
println(g(0));
let c0 = std.Array.concat([1, 2]);
let c = c0([3]);
println(c.length);
println(c[0]);
println(c[2]);
