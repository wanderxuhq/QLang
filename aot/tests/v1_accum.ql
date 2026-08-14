// v1_accum.ql — 循环累加和(函数体 let + while 累加)。
// R14 语义核对:sum(0)=0, sum(1)=1, sum(10)=55, sum(100)=5050。
let sum = (n) -> {
  let a = 0;
  let i = 1;
  while i <= n {
    a = a + i;
    i = i + 1;
  };
  a;
};
println(sum(0));      // 0
println(sum(1));      // 1
println(sum(10));     // 55
println(sum(100));    // 5050
