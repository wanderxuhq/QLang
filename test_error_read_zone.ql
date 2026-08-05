// Error read zone through the bootstrapped interpreter: user code reads
// e.type / e.message / e.cause / e.line / e.col on error VALUES without
// crashing, mirroring the host's error_read_zone (interpreter.rs). Run with:
//   cargo run --quiet -- test_error_read_zone.ql
// (host runner, same convention as verify_bootstrap.ql — the import below is
// resolved by the host).
//
// NOTE: this file cannot run via `bootstrapped/run_file.ql` (nested boot):
// the bootstrapped interpreter has no module loader, so `import` in nested
// code raises NotImplemented (it used to be a silent no-op, which left
// runSource undefined and corrupted every check to Void with no diagnostic).
// Making nested imports work requires the boot parser to parse its own
// sources (it currently cannot — see task-9-report.md), a separate
// self-hosting milestone.
//
// line/col VALUES are NOT asserted (the boot wraps errors created inside its
// own source, so positions are interpreter-internal and differ from the host's
// source positions by design — std.Error.toString is position-free for this
// reason); only the guaranteed parts (kind/message/cause chain) are compared.
import ./bootstrapped/main.ql;

let check = (name, actual, expected) -> {
  let at = std.Type.of(actual);
  if at == "String" {
    if actual == expected {
      println("PASS " + name);
    } else {
      println("FAIL " + name + ": got " + actual + " expected " + expected);
    };
  } else if at == "Number" {
    if actual == expected {
      println("PASS " + name);
    } else {
      println("FAIL " + name + ": got " + std.Number.toString(actual) + " expected " + std.Number.toString(expected));
    };
  } else {
    println("FAIL " + name + ": got type " + at);
  };
};

// 1. err.type → kind
let r1 = runSource("let e = 1 / 0; e.type;", "z1");
check("err.type kind", r1.value.value, "DivisionByZero");

// 2. err.message → message text
let r2 = runSource("let e = 1 / 0; e.message;", "z2");
check("err.message", r2.value.value, "division by zero");

// 3. err.cause on an uncaused error → null
let r3 = runSource("let e = 1 / 0; let c = e.cause; if c == null { \"null\" } else { \"err\" };", "z3");
check("err.cause none", r3.value.value, "null");

// 4. err["message"] — index access enters the read zone too
let r4 = runSource("let e = 1 / 0; e[\"message\"];", "z4");
check("err index message", r4.value.value, "division by zero");

// 5. Cause chain: raise with a cause, then read through .cause
let r5 = runSource("let a = std.Error.raise(\"Inner\", \"boom\", null); let b = std.Error.raise(\"Outer\", \"wrap\", a); b.type + \">\" + b.cause.type + \">\" + b.cause.message;", "z5");
check("err cause chain", r5.value.value, "Outer>Inner>boom");

// 6. b.cause.cause → null (no deeper cause)
let r6 = runSource("let a = std.Error.raise(\"Inner\", \"boom\", null); let b = std.Error.raise(\"Outer\", \"wrap\", a); let d = b.cause.cause; if d == null { \"null\" } else { \"err\" };", "z6");
check("err cause end", r6.value.value, "null");

// 7. e.line / e.col are readable NUMBERS (values differ between host and boot
// by design — the boot wraps errors at its own source positions)
let r7 = runSource("let e = 1 / 0; e.line + 1;", "z7");
check("err line is number", std.Type.of(r7.value.value), "Number");
let r8 = runSource("let e = 1 / 0; e.col;", "z8");
check("err col is number", std.Type.of(r8.value.value), "Number");

// 8. std.Error.toString renders kind + message + cause chain (no positions);
//    `?` at the top level surfaces the raw error value (flow: "Error")
let r9 = runSource("let a = std.Error.raise(\"Inner\", \"boom\", null); let b = std.Error.raise(\"Outer\", \"wrap\", a); b ? b;", "z9");
check("Error.toString cause chain", std.Error.toString(r9.value.value), "Outer: wrap\n  └─ caused by: Inner: boom");
let r10 = runSource("let e = 1 / 0; e ? e;", "z10");
check("Error.toString plain", std.Error.toString(r10.value.value), "DivisionByZero: division by zero");
