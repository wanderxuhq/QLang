// v1_recursion.ql — 递归深度计数。
// R14 语义核对:depth(0)=0, depth(1)=1, depth(10)=10, depth(20)=20。
// 注:brief 示例 depth(100) 在 boot 侧(解释器套解释器)宿主栈溢出
// (实测 depth 25 即 overflow,20 安全),取 boot 可承受的最大深度 20。
// 见 task-8-report deviations。
let depth = (n) -> {
  if n == 0 {
    0;
  } else {
    1 + depth(n - 1);
  };
};
println(depth(0));      // 0
println(depth(1));      // 1
println(depth(10));     // 10
println(depth(20));     // 20
