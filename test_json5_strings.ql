// JSON5 string escapes
if "\x41" == "A" {
    println("PASS: \\xHH");
} else {
    println("FAIL: \\x");
}
if "A\u{42}" == "AB" && "\u0042" == "B" {
    println("PASS: \\uHHHH and \\u{...}");
} else {
    println("FAIL: \\u");
}
if "\b\f\v\0" == "\u{8}\u{C}\u{B}\0" {
    println("PASS: \\b \\f \\v \\0");
} else {
    println("FAIL: control escapes");
}
if 'single "quoted" " double' == "single \"quoted\" \" double" {
    println("PASS: single-quoted string");
} else {
    println("FAIL: single quotes");
}
if "line \
continued" == "line continued" {
    println("PASS: line continuation");
} else {
    println("FAIL: continuation");
}
