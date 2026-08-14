// v1_factorial.ql — 递归阶乘(t7_factorial 同构 + 边界用例)。
// R14 语义核对:fact(0)=1, fact(1)=1, fact(5)=120, fact(10)=3628800。
let fact = (n) -> {
  if n == 0 {
    1;
  } else {
    n * fact(n - 1);
  };
};
println(fact(0));      // 1
println(fact(1));      // 1
println(fact(5));      // 120
println(fact(10));     // 3628800
