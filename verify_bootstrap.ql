// Verify real execution semantics of the bootstrapped interpreter: runSource returns
// { flow, value: { type, value } }. Results are printed via RUST println and asserted.
import ./bootstrapped/main.ql;

let check = (name, actual, expected) -> {
  let at = std.Type.of(actual);
  if at == "Number" {
    if actual == expected {
      println("PASS " + name);
    } else {
      println("FAIL " + name + ": got " + std.Number.toString(actual) + " expected " + std.Number.toString(expected));
    };
  } else if at == "Boolean" || at == "String" {
    if actual == expected {
      println("PASS " + name);
    } else {
      println("FAIL " + name + ": got " + std.String.toString(actual) + " expected " + std.String.toString(expected));
    };
  } else {
    println("FAIL " + name + ": got type " + at);
  };
};

// 1. Arithmetic + precedence
let r1 = runSource("1 + 2 * 3;", "t1");
check("arithmetic precedence", r1.value.value, 7);

// 2. Variable definition and reference
let r2 = runSource("let x = 5; x + 1;", "t2");
check("variables", r2.value.value, 6);

// 3. if/else branches
let r3 = runSource("let x = 5; if x > 3 { x * 2 } else { 0 }", "t3");
check("if else", r3.value.value, 10);
let r4 = runSource("let x = 1; if x > 3 { x * 2 } else { 0 }", "t4");
check("if else branch 2", r4.value.value, 0);

// 4. while loop accumulation
let r5 = runSource("let i = 0; let sum = 0; while i < 5 { sum = sum + i; i = i + 1; } sum;", "t5");
check("while loop", r5.value.value, 10);

// 5. Function call
let r6 = runSource("let add = (a, b) -> a + b; add(3, 4);", "t6");
check("function call", r6.value.value, 7);

// 6. Closure capture
let r7 = runSource("let mk = (x) -> () -> x + 1; let f = mk(41); f();", "t7");
check("closure", r7.value.value, 42);

// 7. Recursion (the bootstrapped parser has no if-expressions; use blocks + return)
let r8 = runSource("let fact = (n) -> { if n <= 1 { return 1; } else { return n * fact(n - 1); }; }; fact(5);", "t8");
check("recursion", r8.value.value, 120);

// 8. Array append and indexing
let r9 = runSource("let a = []; a[a.length] = 1; a[a.length] = 2; a[0] + a[1];", "t9");
check("array append index", r9.value.value, 3);

// 9. return statement
let r10 = runSource("let f = (n) -> { if n < 0 { return 0; }; n * 2; }; f(-5) + f(5);", "t10");
check("return", r10.value.value, 10);

// 10. String concatenation (differential testing found the old code rendered wrappers as object JSON)
let r11 = runSource('"ab" + "cd";', "t11");
check("string concat", r11.value.value, "abcd");

// 11. String length (char count, not bytes)
let r12 = runSource('"abc".length;', "t12");
check("string length", r12.value.value, 3);
let r12b = runSource('"héllo".length;', "t12b");
check("string length unicode", r12b.value.value, 5);

// 12. String indexing (Unicode-safe, negative indices, out-of-bounds → null)
let r13 = runSource('"abc"[1];', "t13");
check("string index", r13.value.value, "b");
let r13b = runSource('"abc"[-1];', "t13b");
check("string negative index", r13b.value.value, "c");

// 13. Escape characters
let r14 = runSource('"a\\nb".length;', "t14");
check("string escapes", r14.value.value, 3);

// 14. null / Boolean equality (differential testing found the old valuesEqual missing branches)
let r15 = runSource("null == null;", "t15");
check("null equality", r15.value.value, true);
let r15b = runSource("true == true;", "t15b");
check("boolean equality", r15b.value.value, true);

// 15. && / || short-circuit returning the operand (differential testing found the old code returned null)
let r16 = runSource("1 && 2;", "t16");
check("and", r16.value.value, 2);
let r16b = runSource("0 || 5;", "t16b");
check("or", r16b.value.value, 5);

// 16. Object field access / nesting / assignment (differential testing found the old obj.fields crashed)
let r17 = runSource("let o = { a: 1 }; o.a;", "t17");
check("object field", r17.value.value, 1);
let r17b = runSource("let o = { a: { b: 3 } }; o.a.b;", "t17b");
check("object nested", r17b.value.value, 3);
let r17c = runSource("let o = { a: 1 }; o.a = 5; o.a;", "t17c");
check("object assign", r17c.value.value, 5);

// 17. Object index read/write (JS obj[key] semantics)
let r18 = runSource('let o = { a: 1 }; o["b"] = 2; o["b"] + o["a"];', "t18");
check("object index", r18.value.value, 3);

// 18. Mixed objects and arrays
let r19 = runSource("let a = [{ x: 1 }, { x: 2 }]; a[1].x;", "t19");
check("objects in arrays", r19.value.value, 2);

// 19. Currying (partial application, matching the host)
let r20 = runSource("let f = (a, b) -> a + b; f(1)(2);", "t20");
check("currying", r20.value.value, 3);

// 20. Stray semicolons after if/while blocks (differential testing found the old parser produced Error statements that polluted results)
let r21 = runSource("if 0 { 1 } else { 2 };", "t21");
check("trailing semicolon", r21.value.value, 2);

// 21. Combined string concatenation + indexing
let r22 = runSource('let s = "abc"; let acc = ""; let i = 0; while i < s.length { acc = acc + s[i]; i = i + 1; }; acc;', "t22");
check("string iteration", r22.value.value, "abc");

// 22. Bitwise operator precedence
let r23 = runSource("(5 & 3) + (5 | 3) + (5 ^ 3);", "t23");
check("bitwise", r23.value.value, 14);

// 23. Closure variable mutation (differential testing found the old doAssign never walked the parent chain; counters stayed 0)
let r24 = runSource("let makeCounter = () -> { let count = 0; () -> { count = count + 1; count; }; }; let c = makeCounter(); c(); c(); let v = c(); v;", "t24");
check("closure mutation", r24.value.value, 3);

// 24. Native function calls + string concatenation (differential testing found native args/results were unwrapped)
let r25 = runSource('let s = ""; let i = 0; while i < 3 { s = s + std.Number.toString(i); i = i + 1; }; s;', "t25");
check("native call concat", r25.value.value, "012");

// 25. Object accumulator (object fields mutated inside a loop)
let r26 = runSource("let stats = { min: 999, max: -999, sum: 0 }; let arr = [4, 2, 7, 1, 5]; let i = 0; while i < arr.length { let v = arr[i]; if v < stats.min { stats.min = v; }; if v > stats.max { stats.max = v; }; stats.sum = stats.sum + v; i = i + 1; }; stats.min + stats.max + stats.sum;", "t26");
check("object accumulator", r26.value.value, 27);

// 26. Deep recursion (each boot level costs ~6 host call frames; host guard 300 → boot limit ~50 levels)
let r27 = runSource("let f = (n) -> { if n == 0 { return 0; }; f(n - 1) + n; }; f(40);", "t27");
check("deep recursion", r27.value.value, 820);

println("verify_bootstrap done");
