// v1_shortcircuit.ql — 短路真值表(t6 短路用例)。
// R14 语义核对(逐行):
//   true && a==0            = true
//   false && 1/0            = false(&& 短路,右操作数不求值)
//   true  || 1/0            = true (|| 短路,右操作数不求值)
//   b>0 && b<10             = true
//   a>0 && (b>0 && a>0)     = false(A 假,&& 短路不求右;右嵌套 phi)
//   a==0 || (1/0 > 0)       = true (A 真,|| 短路不求右;右嵌套 phi)
let a = 0;
let b = 5;
println(true && a == 0);          // true
println(false && 1 / 0);          // false(短路,1/0 不求值)
println(true || 1 / 0);           // true(短路)
println(b > 0 && b < 10);         // true
println(a > 0 && (b > 0 && a > 0));  // false
println(a == 0 || (1 / 0 > 0));      // true
