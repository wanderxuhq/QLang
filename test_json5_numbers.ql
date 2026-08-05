// JSON5 number literals
let hex = 0xFF;
let hex2 = 0x10;
let dot_lead = .5;
let dot_trail = 5.;
let exp = 1e30;
let exp_neg = 1.5e-3;

if hex == 255 && hex2 == 16 {
    println("PASS: hex");
} else {
    println("FAIL: hex " + std.Number.toString(hex));
}
if dot_lead == 0.5 && dot_trail == 5 {
    println("PASS: leading/trailing dot");
} else {
    println("FAIL: dot forms");
}
if exp == 1000000000000000000000000000000 && exp_neg == 0.0015 {
    println("PASS: exponent");
} else {
    println("FAIL: exponent");
}
