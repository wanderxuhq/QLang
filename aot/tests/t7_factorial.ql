let fact = (n) -> {
  if n == 0 {
    1;
  } else {
    n * fact(n - 1);
  };
};
println(fact(5));      // 120
println(fact(10));     // 3628800
