// M3 t9_error:错误值构造与探测(3-way;字符串比较语义 T2 后补测)
let e = __err("TestKind", "hello");
println(__isError(e));
println(!__isError(42));
let c = __err("C", "cause");
let e2 = __err("K", "m");
println(e2);
