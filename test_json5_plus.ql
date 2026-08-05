// JSON5 + prefix (unary plus)
if +5 == 5 {
    println("PASS: +5");
} else {
    println("FAIL: +5");
}
if +1.5 == 1.5 {
    println("PASS: +1.5");
} else {
    println("FAIL: +1.5");
}
let x = 3;
if +x == 3 {
    println("PASS: +variable");
} else {
    println("FAIL: +variable");
}
if 1 + +2 == 3 {
    println("PASS: nested +");
} else {
    println("FAIL: nested +");
}
