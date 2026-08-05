// Import test: all three export forms must work
import "test_lib_a.ql";
if exported_value == 42 {
    println("PASS: export let value");
} else {
    println("FAIL: export let value");
}
if add(2, 3) == 5 {
    println("PASS: export let function");
} else {
    println("FAIL: export let function");
}
if multiply(6, 7) == 42 {
    println("PASS: export { f } shorthand");
} else {
    println("FAIL: export { f } shorthand");
}
