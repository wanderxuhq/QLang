// M3 t9_number:std.Number + __itoa 分数渲染(3-way;host/native 逐字节一致)
// Ruling T5-F:只用可精确表示的二进制分数(2.5/0.125/42/1)
println(std.Number.toString(10/4));
println(std.Number.toString(1/8));
println(std.Number.toString(42));
println(std.Number.toString(1));
println(std.Number.toString(0));
println(std.Number.toString(-2));
println(std.Number.toString(-2.5));
println(std.Number.isNaN(5));
println(std.Number.isNaN("x"));
println(std.Number.isFinite(5));
println(std.Number.isFinite(0));
println(std.Number.parseFloat(" 42.5 "));
println(std.Number.parseFloat("12") == 12);
println(std.Number.parseFloat(" -3.25 ") == -3.25);
