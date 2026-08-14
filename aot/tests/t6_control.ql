let n = 10;
let acc = 0;
while n > 0 {
  acc = acc + n;
  n = n - 1;
};
println(acc);              // 55

let a = 0;
let b = 5;
println(true && a == 0);   // true
println(false && 1 / 0);   // false(短路,1/0 不求值)
println(true || 1 / 0);    // true(短路)
println(b > 0 && b < 10);  // true

if 7 % 2 == 1 {
  println(1);              // 1
} else {
  println(2);
};
