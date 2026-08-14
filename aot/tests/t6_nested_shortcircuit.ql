// T6 Fix Round 1 regression guard:right-nested short-circuit (&&/|| B 侧自身是短路)。
// Critical-1 复现用例(B 侧 phi 前驱此前硬编码 lEvalB → "PHI node entries do not match predecessors!")。
// 变量:a=3, b=2, c=0, d=1。三端 expected:
//   false / true / true / true / true / 0 / 0
let a = 3;
let b = 2;
let c = 0;
let d = 1;

// 1. && 右操作数是短路(A 真,须求值右短路):true && (true && false) = false
println(a > 0 && (b > 0 && c > 0));
// 2. || 右操作数是短路(A 真,短路不求值右):true
println(a > 0 || (b > 0 && c > 0));
// 3. || 右操作数是短路(A 假,须求值右短路):false || (true && true) = true
println(c > 0 || (a > 0 && b > 0));
// 4. && 右操作数是 ||(双层):true && (false || true) = true
println(a > 0 && (c > 0 || b > 0));
// 5. 左+右都是短路 ||(A 侧短路 + B 侧短路):(false && true) || (true && true) = true
println((c > 0 && d > 0) || (a > 0 && b > 0));
// 6. if 条件右嵌套:true && (true && false) = false → else 分支
if a > 0 && (b > 0 && c > 0) {
  println(1);
} else {
  println(0);
};
// 7. while 条件右嵌套:w 递减到 0 后 b>0 && w>0 = false → 退出
let w = 2;
while a > 0 && (b > 0 && w > 0) {
  w = w - 1;
};
println(w);
