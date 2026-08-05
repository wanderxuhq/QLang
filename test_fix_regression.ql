// Regression tests for the review fixes

// 1. Double-evaluation: block ending with expression statement must evaluate once
let side_effects = 0;
let bump = () -> { side_effects = side_effects + 1; };
let h = () -> { bump(); };          // function body ends with expression statement
h();
if side_effects == 1 {
    println("PASS: function body expr evaluated once");
} else {
    println("FAIL: function body expr evaluated " + side_effects + " times");
}

if true { bump(); }                 // if-block ending with expression statement
if side_effects == 2 {
    println("PASS: if-block expr evaluated once");
} else {
    println("FAIL: if-block expr evaluated " + side_effects + " times");
}

let i = 0;
while i < 3 { bump(); i = i + 1; }  // loop body ending with expression statement
if side_effects == 5 {
    println("PASS: while-body expr evaluated once per iteration");
} else {
    println("FAIL: while-body expr evaluated " + side_effects + " times");
}

// 2. Negative index
let arr = [10, 20, 30];
if arr[-1] == 30 && arr[-2] == 20 {
    println("PASS: negative index read");
} else {
    println("FAIL: negative index read: " + arr[-1]);
}
arr[-1] = 99;
if arr[2] == 99 {
    println("PASS: negative index write");
} else {
    println("FAIL: negative index write");
}

// 3. Short-circuit
let short_ok = false && undefinedVar;
let short_ok2 = true || undefinedVar;
if short_ok == false && short_ok2 == true {
    println("PASS: short-circuit && and ||");
} else {
    println("FAIL: short-circuit");
}

// 4. export does not terminate program
export let exported_value = 42;
println("PASS: execution continues after export");
