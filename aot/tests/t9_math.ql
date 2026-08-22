// M3 t9_math:std.Math(3-way;HOST/NATIVE/BOOT 逐字节一致)
// 白名单纪律(Ruling T7-C~G):完美平方 sqrt、小非负整数指数 pow、2 参 max/min、
// 无 random(host 真随机)、无 PI/E(__itoa 预算发散)、sin/cos 只用 0。
// 柯里化 pow 一律 let 绑定首参(链式 f(a)(b) 在 native emitCall 返回 nullbox —— pre-existing)。
// tq7 探针(14 行,brief Step 2 逐字)
println(std.Math.abs(-5));
println(std.Math.floor(3.9));
println(std.Math.ceil(3.1));
println(std.Math.round(2.5));
println(std.Math.round(-2.5));
println(std.Math.trunc(2.9));
println(std.Math.sqrt(16));
println(std.Math.sqrt(0));
let pw = std.Math.pow(2);
println(pw(5));
let p0 = std.Math.pow(3);
println(p0(0));
println(std.Math.sin(0));
println(std.Math.cos(0));
println(std.Math.max(3, 7));
println(std.Math.min(3, 7));
// 扩展判别(host 单独验证后加入;全部白名单内)
println(std.Math.abs(0));
println(std.Math.abs(-3.5));
println(std.Math.abs(7));
println(std.Math.floor(-3.5));
println(std.Math.floor(5));
println(std.Math.ceil(-3.5));
println(std.Math.ceil(4));
println(std.Math.round(3));
println(std.Math.round(2.4));
println(std.Math.round(-2.4));
println(std.Math.trunc(-2.9));
println(std.Math.trunc(7));
println(std.Math.sqrt(25));
println(std.Math.sqrt(1));
let pw2 = std.Math.pow(2);
let pw3 = std.Math.pow(3);
let pw10 = std.Math.pow(10);
let pwz = std.Math.pow(0);
println(pw2(1));
println(pw2(4));
println(pw2(10));
println(pw3(2));
println(pw10(2));
println(pwz(0));
println(pwz(1));
println(std.Math.max(-3, -7));
println(std.Math.min(-3, -7));
println(std.Math.max(2.5, 2));
println(std.Math.sin(0));
println(std.Math.cos(0));
