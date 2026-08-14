// v1_fib.ql — 双递归斐波那契(t7_fib 同构 + 边界用例)。
// R14 语义核对:fib(0)=0, fib(1)=1, fib(5)=5, fib(10)=55。
let fib = (n) -> {
  if n < 2 {
    n;
  } else {
    fib(n - 1) + fib(n - 2);
  };
};
println(fib(0));      // 0
println(fib(1));      // 1
println(fib(5));      // 5
println(fib(10));     // 55
