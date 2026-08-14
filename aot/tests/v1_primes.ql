// v1_primes.ql — 素数判定(函数体顶层 let + while + 内联余数)。
// R14 语义核对:isPrime(2)=true, isPrime(17)=true, isPrime(100)=false, isPrime(1)=false。
// 注:brief 示例把 let i/ok 放在 else 分支内 → 触发 v1「分支内 let 不支持」
// (AOT 报 undefined → while 读垃圾 → 死循环)。重构为函数体顶层 let,语义等价
// (n<2 时先置 ok=false;循环体对 n<2 不执行)。见 task-8-report deviations。
let isPrime = (n) -> {
  let i = 2;
  let ok = true;
  if n < 2 {
    ok = false;
  };
  while i * i <= n {
    if n % i == 0 {
      ok = false;
    };
    i = i + 1;
  };
  ok;
};
println(isPrime(2));    // true
println(isPrime(17));   // true
println(isPrime(100));  // false
println(isPrime(1));    // false
