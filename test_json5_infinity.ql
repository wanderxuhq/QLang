// JSON5 Infinity / NaN literals
if Infinity > 1e308 {
    println("PASS: Infinity");
} else {
    println("FAIL: Infinity");
}
if -Infinity < -1e308 {
    println("PASS: -Infinity");
} else {
    println("FAIL: -Infinity");
}
if NaN != NaN {
    println("PASS: NaN");
} else {
    println("FAIL: NaN");
}
let Infinity = 5;  // shadowable, consistent with JS
if Infinity == 5 {
    println("PASS: shadow Infinity");
} else {
    println("FAIL: shadow");
}
