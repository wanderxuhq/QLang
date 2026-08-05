#!/usr/bin/env python3
"""Differential testing: run the same QLang source through the Rust host
interpreter, the bootstrapped interpreter, and (as an independent reference)
Node.js/V8; results must be identical.

The host and boot implementations are not independent (boot runs on the host),
so a third reference is needed to validate the host itself. QLang semantics are
JS-flavored, so for the overlapping subset the same program runs under V8.

Safe cases (neither side errors or crashes) run in one batch per process; risky
cases (either side may error or crash) run in isolated processes, capturing
exit codes and stderr. Error values are compared through norm_err(), which
canonicalizes the two implementations' different error renderings and strips
position info (the boot AST carries no spans). The Node.js section is skipped
if `node` is not on PATH.

Usage: python3 difftest.py
"""
import glob
import json
import os
import re
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
CARGO = ["cargo", "run", "--quiet", "--"]
BOOT_IMPORT = "import ./bootstrapped/main.ql;"

# Banner lines printed by the bootstrapped runSource (host-side println); filtered out for diffing
BANNER = re.compile(
    r"^(Bootstrapped QLang interpreter|====|Running:|Lexing|Generated|Parsing|"
    r"Parsed|Interpreting|Execution complete)")

# Error-value semantics (host Tasks 1-5, boot Tasks 6-9): erroring expressions
# produce error VALUES, and the two implementations render them differently:
#   - host: disp() receives an error value and its argument check rejects it
#     (user functions never accept error arguments), so println renders the
#     multi-line diagnostic "<Kind>: <msg> (at line L, col C)" plus a
#     "  └─ caused by:" chain;
#   - boot: its wrapped error values flow through disp() and render as "?Error";
#   - an unhandled top-level `?` makes the host exit 1 with the diagnostic on
#     stderr, while the boot prints "Kind: msg" (std.Error.toString, which has
#     no positions) and keeps going.
# norm_err() canonicalizes all of these renderings to ERROR_TOKEN before
# comparing, and strips "(at line L, col C)" because the boot AST carries no
# spans (boot line/col differ from host even for identical diagnostics).
ERROR_TOKEN = "<Error>"
_ERR_DIAG_LINE = re.compile(r"^[A-Za-z]+: .+")
_TOP_LEVEL_DIAG = re.compile(r"^[A-Za-z]+: .+ \(at line \d+, col \d+\)")


def norm_err(v, cid=None, stderr=""):
    """Canonicalize one side's rendered output for comparison.

    Steps: strip the 'cid=' prefix kept by isolated runs, then collapse
    error renderings (host diagnostic / boot std.Error.toString / boot
    "?Error" / host top-level stderr diagnostic) to ERROR_TOKEN, then strip
    position info. Non-error values pass through unchanged.
    """
    if cid and v.startswith(cid + "="):
        v = v[len(cid) + 1:]
    # Host top-level exit: unhandled error → exit 1 + diagnostic on stderr
    if stderr and _TOP_LEVEL_DIAG.match(stderr):
        return ERROR_TOKEN
    # Rendered error diagnostic (host) or std.Error.toString line (boot)
    if _ERR_DIAG_LINE.match(v):
        return ERROR_TOKEN
    v = re.sub(r" \(at line \d+, col \d+\)", "", v)
    # Boot rendering of a wrapped error value
    if v == "?Error":
        return ERROR_TOKEN
    return v

# ---------------- Cases ----------------

# Safe cases: both sides complete normally and produce a printable scalar
SAFE_CASES = [
    ("c01", "1 + 2 * 3;"),
    ("c02", "(1 + 2) * 3;"),
    ("c03", "10 / 4;"),
    ("c04", "10 % 3;"),
    ("c05", "-5 + 3;"),
    ("c06", "!true;"),
    ("c07", "!0;"),
    ("c08", "1 < 2;"),
    ("c09", "2 <= 2;"),
    ("c10", "3 > 4;"),
    ("c11", "5 & 3;"),
    ("c12", "5 | 3;"),
    ("c13", "5 ^ 3;"),
    ("c14", '"ab" + "cd";'),
    ("c15", '"abc".length;'),
    ("c16", '"abc"[1];'),
    ("c17", '"héllo".length;'),
    ("c18", '"a" == "a";'),
    ("c19", '"a" != "b";'),
    ("c20", "1 == 1;"),
    ("c21", '1 == "1";'),
    ("c22", "null == null;"),
    ("c23", "null != null;"),
    ("c24", "true == true;"),
    ("c25", "if 0 { 1 } else { 2 };"),
    ("c26", 'if "" { 1 } else { 2 };'),
    ("c27", "if null { 1 } else { 2 };"),
    ("c28", "let x = 3; x + 1;"),
    ("c29", "let x = 3; x = 5; x;"),
    ("c30", "let add = (a, b) -> a + b; add(3, 4);"),
    ("c31", "let f = (x) -> { x * 2; }; f(5);"),
    ("c32", "let fact = (n) -> { if n <= 1 { return 1; }; n * fact(n - 1); }; fact(6);"),
    ("c33", "let f = (x) -> (y) -> x + y; f(3)(4);"),
    ("c34", "let mk = (x) -> () -> x + 1; let f = mk(41); f();"),
    ("c35", "let i = 0; let acc = 0; while i < 5 { acc = acc + i; i = i + 1; }; acc;"),
    ("c36", "[1, 2, 3][1];"),
    ("c37", "let a = []; a[a.length] = 5; a[0];"),
    ("c38", "[1, 2][-1];"),
    ("c39", "[1, 2, 3].length;"),
    ("c41", "[[1, 2], [3, 4]][1][0];"),
    ("c42", "true && false;"),
    ("c43", "true || false;"),
    ("c44", "1 && 2;"),
    ("c45", "0 || 5;"),
    ("c46", '"" || "x";'),
    ("c47", "1 < 2 == true;"),
    ("c48", "2 + 3 * 4 - 10 / 2;"),
    ("c49", 'let s = "a\\nb"; s.length;'),
    ("c50", '"x".length == 1;'),
    ("c51", "let o = { a: 1 }; o;"),
    ("c52", "[];"),
    ("c53", "let o = { a: 1 }; let p = o; p == o;"),
    ("c54", "let f = () -> 42; f();"),
    ("c56", "let o = { a: 1, b: 2 }; o;"),       # whole object: types must match
    # ---- error-value semantics: `?` / `??` / isError / error read zone ----
    # (last expressions are scalars; the error values themselves stay inside
    # runSource, so both sides render the same scalar)
    ("e01", 'let f = () -> { Error("boom") }; isError(f());'),
    ("e02", 'let f = () -> { Error("boom") }; f() ?? "fallback";'),
    ("e03", 'let f = () -> { Error("boom") }; let x = f() ?? 42; x;'),
    ("e04", 'Error("a").type;'),
    ("e05", 'Error("a").message;'),
    ("e06", 'let e = Error("outer", Error("inner")); e.cause.message;'),
    ("e07", "isError(42);"),
    ('e08', 'isError(Error("x"));'),
    ("e09", 'let f = () -> { let e = Error("boom"); e ?; }; let r = f(); isError(r);'),
    ("e10", 'let f = () -> { let e = Error("boom"); e ?; }; let r = f(); r.message;'),
    ("e11", 'let f = () -> { let e = Error("boom"); e ?; }; let r = f(); r.cause;'),
    ("e12", 'let f = () -> { let e = Error("boom"); e ?; }; let g = () -> { let r = f(); r ?; }; isError(g());'),
    ("e13", 'let f = () -> { 1 / 0 }; let r = f(); r.type;'),
    ("e14", 'let f = () -> { [1][5] }; let r = f(); r.type;'),
    ("e15", 'let o = {}; let r = o.x; r.type;'),
    ('e16', 'let o = {}; let r = o["x"]; r.type;'),
    ("e17", 'let f = () -> { Error("a", Error("b", Error("c"))) }; let e = f(); e.cause.cause.message;'),
    ("e18", 'let f = () -> { let e = Error("boom"); e ?; }; let r = f() ?? "ok"; r;'),
    ("e19", 'let f = () -> { Error("boom") }; let x = 1 + f(); x.type;'),
    ("e20", 'let f = () -> { Error("boom") }; let g = (e) -> { e.message }; let r = g(f()); isError(r);'),
    # e21: assert the error KIND of a top-level recursion-guard error (r28 in
    # RISKY_CASES only compares that both sides error; this one checks the kind
    # is StackOverflow on both sides — the bare self-call stays under both the
    # boot guard (~45 levels) and the host guard (300), so neither stack blows)
    ("e21", "let f = (n) -> f(n - 1); let r = f(10000); r.type;"),
]

# Complex cases: multi-feature combinations (recursion / closure mutation / higher-order
# functions / nested objects and arrays / currying / string processing), run in isolation
COMPLEX_CASES = [
    # Recursion + multiple base cases
    ("x01", "let fib = (n) -> { if n <= 1 { return n; }; fib(n - 1) + fib(n - 2); }; fib(10);"),
    # Closure variable mutation (differential testing found the old doAssign never walked the parent chain; counters stayed 0)
    ("x02", "let makeCounter = () -> { let count = 0; () -> { count = count + 1; count; }; }; let c = makeCounter(); c(); c(); let v = c(); v;"),
    # Higher-order function: map
    ("x03", "let map = (arr, f) -> { let out = []; let i = 0; while i < arr.length { out[out.length] = f(arr[i]); i = i + 1; }; out; }; let dbl = (x) -> x * 2; let r = map([1, 2, 3], dbl); r[0] + r[1] + r[2];"),
    # Aggregate function
    ("x04", "let sum = (arr) -> { let acc = 0; let i = 0; while i < arr.length { acc = acc + arr[i]; i = i + 1; }; acc; }; sum([1, 2, 3, 4, 5]);"),
    # Deeply nested objects + string comparison
    ("x05", "let cfg = { db: { host: \"localhost\", port: 5432 }, app: { name: \"test\", debug: true } }; let r = 0; if cfg.db.host == \"localhost\" { r = cfg.db.port; }; r;"),
    # Object containing arrays
    ("x06", "let m = { rows: [[1, 2], [3, 4]], cols: [5, 6] }; m.rows[1][0] + m.cols[0];"),
    # Mutating elements of an array of objects
    ("x07", "let people = [{ name: \"a\", age: 20 }, { name: \"b\", age: 30 }]; people[0].age = 25; people[0].age + people[1].age;"),
    # String filtering loop
    ("x08", "let s = \"hello world\"; let acc = \"\"; let i = 0; while i < s.length { if s[i] != \" \" { acc = acc + s[i]; }; i = i + 1; }; acc.length;"),
    # String reversal
    ("x09", "let rev = (s) -> { let out = \"\"; let i = s.length - 1; while i >= 0 { out = out + s[i]; i = i - 1; }; out; }; rev(\"abcde\");"),
    # Triple-level currying
    ("x10", "let add3 = (a) -> (b) -> (c) -> a + b + c; add3(1)(2)(3);"),
    # Closure factory
    ("x11", "let mul = (a) -> (b) -> a * b; let dbl = mul(2); let tpl = mul(3); dbl(5) + tpl(5);"),
    # Complex boolean chain
    ("x12", "let x = 5; let y = 10; (x > 0 && y > 5) || (x < 0 && y < 5);"),
    # Nested while loops
    ("x13", "let total = 0; let i = 0; while i < 3 { let j = 0; while j < 4 { total = total + 1; j = j + 1; }; i = i + 1; }; total;"),
    # Recursion + strings
    ("x14", "let len = (s, i) -> { if i >= s.length { return 0; }; 1 + len(s, i + 1); }; len(\"hello\", 0);"),
    # Factory returning objects + array of objects
    ("x15", "let makePoint = (x, y) -> { { x: x, y: y }; }; let dist2 = (p) -> p.x * p.x + p.y * p.y; let pts = [makePoint(3, 4), makePoint(1, 2)]; dist2(pts[0]) + dist2(pts[1]);"),
    # Even/odd accumulation in a loop
    ("x16", "let arr = [1, 2, 3, 4, 5, 6]; let evens = 0; let odds = 0; let i = 0; while i < arr.length { if arr[i] % 2 == 0 { evens = evens + arr[i]; } else { odds = odds + arr[i]; }; i = i + 1; }; evens + odds;"),
    # Object mutated through a function
    ("x17", "let setAge = (p, a) -> { p.age = a; p.age; }; let p = { name: \"x\", age: 1 }; setAge(p, 42);"),
    # Number-to-string concatenation in a loop
    ("x18", "let s = \"\"; let i = 0; while i < 3 { s = s + std.Number.toString(i); i = i + 1; }; s;"),
    # Function composition
    ("x19", "let compose = (f, g) -> (x) -> f(g(x)); let inc = (x) -> x + 1; let dbl = (x) -> x * 2; compose(inc, dbl)(5);"),
    # Object accumulator (min/max/sum)
    ("x20", "let stats = { min: 999, max: -999, sum: 0 }; let arr = [4, 2, 7, 1, 5]; let i = 0; while i < arr.length { let v = arr[i]; if v < stats.min { stats.min = v; }; if v > stats.max { stats.max = v; }; stats.sum = stats.sum + v; i = i + 1; }; stats.min + stats.max + stats.sum;"),
    # Early return from inside a while loop
    ("x21", "let firstEven = (arr) -> { let i = 0; while i < arr.length { if arr[i] % 2 == 0 { return arr[i]; }; i = i + 1; }; -1; }; firstEven([1, 3, 5, 8, 9]);"),
    # Deep recursion (each boot level costs ~6 host call frames; host guard 300 → boot limit ~50 levels)
    ("x22", "let f = (n) -> { if n == 0 { return 0; }; f(n - 1) + n; }; f(40);"),
    # Array reversal
    ("x23", "let reverse = (arr) -> { let out = []; let i = arr.length - 1; while i >= 0 { out[out.length] = arr[i]; i = i - 1; }; out; }; let r = reverse([1, 2, 3]); r[0] + r[1] + r[2];"),
    # String indexing + object fields
    ("x24", "let s = \"abc\"; let o = { first: s[0], rest: s.length - 1 }; o.first + std.Number.toString(o.rest);"),
    # Multiply-add currying
    ("x25", "let f = (a) -> (b) -> (c) -> a * b + c; f(2)(3)(4);"),
]

# Risky cases: either side may error or crash; run per-process, compare value/exit code/stderr.
# Under error-value semantics the erroring expressions below produce error
# VALUES that escape to disp(): the host renders the multi-line diagnostic and
# the boot renders "?Error" — norm_err() canonicalizes both, so the error cases
# MATCH by construction (the old r07/r09-r13/r18/r20/r21 diverged exactly on
# this rendering and were replaced by r22-r33; r14 was a host parser
# limitation — `o.let` — and was dropped).
#   r19: partial application returns a curried function (no error)
RISKY_CASES = [
    ("r01", "let o = { a: 1 }; o.a;"),
    ("r02", "let o = { a: 1, b: 2 }; o.a + o.b;"),
    ("r03", "let o = { a: { b: 3 } }; o.a.b;"),
    ("r04", "let o = { a: 1 }; o.a = 5; o.a;"),
    ("r05", 'let o = { a: 1 }; o["a"];'),
    ("r06", 'let o = { a: 1 }; o["b"] = 2; o["b"];'),
    ("r08", "let a = [{ x: 1 }, { x: 2 }]; a[1].x;"),
    ("r15", "let s = \"ab\"; s[0] + s[1];"),
    ("r16", "let o = { a: 1 }; o.a == 1;"),
    ("r17", 'let o = { a: 1 }; o["a"] == 1;'),
    ("r19", "let f = (a, b) -> a + b; f(1);"),   # curried function on both sides
    # ---- error-value cases: both sides produce error values ----
    ("r22", "1 / 0;"),                           # DivisionByZero
    ("r23", "0 / 0;"),                           # DivisionByZero
    ("r24", "[1, 2][-3];"),                      # IndexOutOfBounds (neg wrap)
    ("r25", '"abc"[-4];'),                       # IndexOutOfBounds (neg wrap)
    ("r27", 'let f = () -> { let e = Error("boom"); e ?; }; f();'),  # ? stops at the function boundary
    # r28: recursion shape matters — the recursion guards fire at different
    # host-frame costs on each side. If-block tail recursion
    # (`if n > 0 { f(n - 1) }`) blows the host stack inside the boot
    # interpreter before the boot guard (45 levels) or the host guard (300)
    # fires, and the return-style shape (`f(n - 1) + n`) blows the host stack
    # before the host guard fires on the HOST side. The bare self-call stays
    # under both guards, so both sides yield a StackOverflow error value.
    ("r28", "let f = (n) -> f(n - 1); f(10000);"),   # StackOverflow
    ("r29", "let o = {}; o.x;"),                 # UndefinedField
    ("r30", 'let o = {}; o["x"];'),              # UndefinedField (obj["x"] missing → error, not JS undefined)
    ("r31", '1 + "a";'),                         # TypeMismatch
    ("r32", 'let f = () -> { Error("boom") }; let g = (e) -> { e.message }; g(f());'),  # arg rejection
    ("r33", 'let f = () -> { Error("boom") }; f() + 1;'),  # op on error value
    # Task 4 ledger: `??` catches only Value::Error, NOT the UserError signal
    # raised by `?` — so `(Error("boom") ?) ?? 42` propagates to top level
    # (host: exit 1 + diagnostic on stderr; boot: flow "Error" +
    # std.Error.toString diagnostic on stdout). Both are canonicalized to
    # ERROR_TOKEN with kind "err" by diff_case.
    ("r34", '(Error("boom") ?) ?? 42;'),
]

# Node.js reference cases: (cid, js_src). js_src is a faithful JavaScript translation
# of the QLang case; None means the QLang source is valid JS verbatim. Translation
# rules: `->` → `=>`, `if/while cond` → `if/while (cond)`, block-bodied arrows get an
# explicit `return`, `==`/`!=` → `===`/`!==` (QLang equality is type-strict, i.e. JS
# strict equality), `std.Number.toString(x)` → `String(x)`. Cases where QLang
# deliberately diverges from JS (negative index wrapping, error channels) are excluded.
# The error-value cases (e01-e21, r22-r34) are NOT here: QLang returns error values
# where JS throws, and a missing obj["x"] yields an UndefinedField error value in
# QLang vs `undefined` in JS — an intentional divergence (no NODE_CASES entry uses
# bracket access on objects, so none needed removing).
NODE_CASES = [
    # ---- Safe batch: pure expressions, valid JS verbatim (js_src=None) ----
    ("c01", None), ("c02", None), ("c03", None), ("c04", None), ("c05", None),
    ("c06", None), ("c07", None), ("c08", None), ("c09", None), ("c10", None),
    ("c11", None), ("c12", None), ("c13", None), ("c14", None), ("c15", None),
    ("c16", None), ("c17", None), ("c18", '"a" === "a";'), ("c19", '"a" !== "b";'),
    ("c20", "1 === 1;"), ("c21", '1 === "1";'), ("c22", "null === null;"),
    ("c23", "null !== null;"), ("c24", "true === true;"),
    ("c28", None), ("c29", None), ("c36", None), ("c37", None), ("c39", None),
    ("c41", None), ("c42", None), ("c43", None), ("c44", None), ("c45", None),
    ("c46", None), ("c47", "1 < 2 === true;"), ("c48", None), ("c49", None),
    ("c50", '"x".length === 1;'), ("c51", None), ("c52", None),
    ("c53", "let o = { a: 1 }; let p = o; p === o;"), ("c56", None),
    # ---- if / while / arrows need JS syntax (note: a ';' after every '}' keeps the
    #      last_expr split working, and JS if/while are statements, so the final
    #      expression is printed via a trailing variable) ----
    ("c25", "let r; if (0) { r = 1; } else { r = 2; }; r;"),
    ("c26", 'let r; if ("") { r = 1; } else { r = 2; }; r;'),
    ("c27", "let r; if (null) { r = 1; } else { r = 2; }; r;"),
    ("c30", "let add = (a, b) => a + b; add(3, 4);"),
    ("c31", "let f = (x) => { return x * 2; }; f(5);"),
    ("c32", "let fact = (n) => { if (n <= 1) { return 1; } return n * fact(n - 1); }; fact(6);"),
    ("c33", "let f = (x) => (y) => x + y; f(3)(4);"),
    ("c34", "let mk = (x) => () => x + 1; let f = mk(41); f();"),
    ("c35", "let i = 0; let acc = 0; while (i < 5) { acc = acc + i; i = i + 1; }; acc;"),
    ("c54", "let f = () => 42; f();"),
    # ---- Complex cases ----
    ("x01", "let fib = (n) => { if (n <= 1) { return n; } return fib(n - 1) + fib(n - 2); }; fib(10);"),
    ("x02", "let makeCounter = () => { let count = 0; return () => { count = count + 1; return count; }; }; let c = makeCounter(); c(); c(); let v = c(); v;"),
    ("x03", "let map = (arr, f) => { let out = []; let i = 0; while (i < arr.length) { out[out.length] = f(arr[i]); i = i + 1; } return out; }; let dbl = (x) => x * 2; let r = map([1, 2, 3], dbl); r[0] + r[1] + r[2];"),
    ("x04", "let sum = (arr) => { let acc = 0; let i = 0; while (i < arr.length) { acc = acc + arr[i]; i = i + 1; } return acc; }; sum([1, 2, 3, 4, 5]);"),
    ("x05", "let cfg = { db: { host: \"localhost\", port: 5432 }, app: { name: \"test\", debug: true } }; let r = 0; if (cfg.db.host === \"localhost\") { r = cfg.db.port; }; r;"),
    ("x06", "let m = { rows: [[1, 2], [3, 4]], cols: [5, 6] }; m.rows[1][0] + m.cols[0];"),
    ("x07", "let people = [{ name: \"a\", age: 20 }, { name: \"b\", age: 30 }]; people[0].age = 25; people[0].age + people[1].age;"),
    ("x08", "let s = \"hello world\"; let acc = \"\"; let i = 0; while (i < s.length) { if (s[i] !== \" \") { acc = acc + s[i]; }; i = i + 1; }; acc.length;"),
    ("x09", "let rev = (s) => { let out = \"\"; let i = s.length - 1; while (i >= 0) { out = out + s[i]; i = i - 1; } return out; }; rev(\"abcde\");"),
    ("x10", "let add3 = (a) => (b) => (c) => a + b + c; add3(1)(2)(3);"),
    ("x11", "let mul = (a) => (b) => a * b; let dbl = mul(2); let tpl = mul(3); dbl(5) + tpl(5);"),
    ("x12", "let x = 5; let y = 10; (x > 0 && y > 5) || (x < 0 && y < 5);"),
    ("x13", "let total = 0; let i = 0; while (i < 3) { let j = 0; while (j < 4) { total = total + 1; j = j + 1; }; i = i + 1; }; total;"),
    ("x14", "let len = (s, i) => { if (i >= s.length) { return 0; } return 1 + len(s, i + 1); }; len(\"hello\", 0);"),
    ("x15", "let makePoint = (x, y) => { return { x: x, y: y }; }; let dist2 = (p) => p.x * p.x + p.y * p.y; let pts = [makePoint(3, 4), makePoint(1, 2)]; dist2(pts[0]) + dist2(pts[1]);"),
    ("x16", "let arr = [1, 2, 3, 4, 5, 6]; let evens = 0; let odds = 0; let i = 0; while (i < arr.length) { if (arr[i] % 2 === 0) { evens = evens + arr[i]; } else { odds = odds + arr[i]; }; i = i + 1; }; evens + odds;"),
    ("x17", "let setAge = (p, a) => { p.age = a; return p.age; }; let p = { name: \"x\", age: 1 }; setAge(p, 42);"),
    ("x18", "let s = \"\"; let i = 0; while (i < 3) { s = s + String(i); i = i + 1; }; s;"),
    ("x19", "let compose = (f, g) => (x) => f(g(x)); let inc = (x) => x + 1; let dbl = (x) => x * 2; compose(inc, dbl)(5);"),
    ("x20", "let stats = { min: 999, max: -999, sum: 0 }; let arr = [4, 2, 7, 1, 5]; let i = 0; while (i < arr.length) { let v = arr[i]; if (v < stats.min) { stats.min = v; }; if (v > stats.max) { stats.max = v; }; stats.sum = stats.sum + v; i = i + 1; }; stats.min + stats.max + stats.sum;"),
    ("x21", "let firstEven = (arr) => { let i = 0; while (i < arr.length) { if (arr[i] % 2 === 0) { return arr[i]; } i = i + 1; } return -1; }; firstEven([1, 3, 5, 8, 9]);"),
    ("x22", "let f = (n) => { if (n === 0) { return 0; } return f(n - 1) + n; }; f(40);"),
    ("x23", "let reverse = (arr) => { let out = []; let i = arr.length - 1; while (i >= 0) { out[out.length] = arr[i]; i = i - 1; } return out; }; let r = reverse([1, 2, 3]); r[0] + r[1] + r[2];"),
    ("x24", "let s = \"abc\"; let o = { first: s[0], rest: s.length - 1 }; o.first + String(o.rest);"),
    ("x25", "let f = (a) => (b) => (c) => a * b + c; f(2)(3)(4);"),
]



def host_disp():
    return (
        "let disp = (v) -> {\n"
        '  if v == null { "null" }\n'
        '  else if std.Type.of(v) == "Number" { std.Number.toString(v) }\n'
        '  else if std.Type.of(v) == "String" { v }\n'
        '  else if std.Type.of(v) == "Boolean" { if v { "true" } else { "false" } }\n'
        '  else { "?" + std.Type.of(v) };\n'
        "};\n"
    )


def boot_disp():
    return (
        "let disp = (w) -> {\n"
        '  if w == null { "null" }\n'
        '  else if w.type == "Number" { std.Number.toString(w.value) }\n'
        '  else if w.type == "String" { w.value }\n'
        '  else if w.type == "Boolean" { if w.value { "true" } else { "false" } }\n'
        '  else if w.type == "Null" { "null" }\n'
        '  else { "?" + w.type };\n'
        "};\n"
    )


def last_expr(source):
    """Take the last expression of the source (last non-empty segment split on ";")."""
    parts = [p.strip() for p in source.split(";") if p.strip()]
    return parts[-1]


def write_host_suite(path, cases):
    lines = [host_disp()]
    for cid, src in cases:
        # Write the source verbatim (split-rejoin would break if/while block structure),
        # then println the last expression
        lines.append(src)
        lines.append('println("%s=" + disp(%s));' % (cid, last_expr(src)))
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


def write_boot_suite(path, cases):
    lines = [BOOT_IMPORT, "", boot_disp(), ""]
    lines.append("let cases = [")
    for _, src in cases:
        lines.append("  " + json.dumps(src) + ",")
    lines.append("];")
    lines.append("let names = [")
    for cid, _ in cases:
        lines.append('  "%s",' % cid)
    lines.append("];")
    lines.append("let i = 0;")
    lines.append("while i < cases.length {")
    lines.append("  let r = runSource(cases[i], names[i]);")
    lines.append("  let w = r.value;")
    lines.append('  println(names[i] + "=" + disp(w));')
    lines.append("  i = i + 1;")
    lines.append("}")
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


def write_host_one(path, cid, src):
    lines = [host_disp()]
    # Write the source verbatim (split-rejoin would break if/while block structure)
    lines.append(src)
    lines.append('println("%s=" + disp(%s));' % (cid, last_expr(src)))
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


def write_boot_one(path, cid, src):
    lines = [BOOT_IMPORT, "", boot_disp(), ""]
    lines.append('let r = runSource(%s, "one");' % json.dumps(src))
    lines.append("let w = r.value;")
    lines.append('println("%s=" + disp(w));' % cid)
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


def node_disp():
    """JS version of disp: renders values exactly like the host's std.Type.of labels."""
    return (
        "let disp = (v) => {\n"
        "  if (v === null) { return \"null\"; }\n"
        "  let t = typeof v;\n"
        "  if (t === \"number\") { return String(v); }\n"
        "  if (t === \"string\") { return v; }\n"
        "  if (t === \"boolean\") { return v ? \"true\" : \"false\"; }\n"
        '  if (Array.isArray(v)) { return "?Array"; }\n'
        '  return "?Object";\n'
        "};\n"
    )


def write_node_one(path, cid, js_src):
    lines = [node_disp()]
    # Same convention as the host suite: source verbatim, then print the last expression
    lines.append(js_src)
    lines.append('console.log("%s=" + disp(%s));' % (cid, last_expr(js_src)))
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


def run_node(path):
    """Run the JS file with node; returns (exit_code, stdout_lines, stderr)."""
    p = subprocess.run(["node", path], cwd=ROOT, capture_output=True, text=True, timeout=120)
    return p.returncode, p.stdout.splitlines(), p.stderr.strip()


def value_only(v):
    """Strip the 'cid=' prefix: batch results store bare values, isolated runs keep it."""
    return v.split("=", 1)[1] if "=" in v else v


def node_check(cid, host_res, boot_res, node_res, seen):
    """Three-way comparison: host and boot must both match the independent V8 reference."""
    hc, hout, herr = host_res
    bc, bout, berr = boot_res
    nc, nout, nerr = node_res
    hval = value_only(hout[0]) if hout else "ERR"
    bval = value_only(bout[0]) if bout else "ERR"
    nval = value_only(nout[0]) if nout else "ERR"
    hkind = "ok" if hc == 0 and hout else ("ERR" if herr else "NO-OUT")
    bkind = "ok" if bc == 0 and bout else ("ERR" if berr else "NO-OUT")
    nkind = "ok" if nc == 0 and nout else ("ERR" if nerr else "NO-OUT")
    if hval == nval and bval == nval and hkind == nkind and bkind == nkind:
        print("  NODE %s: host %s boot %s node %s ✔" % (cid, hval, bval, nval))
        return
    seen.append(cid)
    print("  NODE-DIFF %s: host[%s] %r  boot[%s] %r  node[%s] %r"
          % (cid, hkind, hval, bkind, bval, nkind, nval))
    if hkind == "ERR" and herr:
        print("        host stderr: %s" % herr.splitlines()[-1])
    if bkind == "ERR" and berr:
        print("        boot stderr: %s" % berr.splitlines()[-1])
    if nkind == "ERR" and nerr:
        for line in nerr.splitlines()[:3]:
            print("        node stderr: %s" % line)


def run(path):
    """Run the file with cargo run; returns (exit_code, stdout_lines, stderr)."""
    p = subprocess.run(CARGO + [path], cwd=ROOT, capture_output=True, text=True, timeout=120)
    out = [l for l in p.stdout.splitlines() if BANNER.match(l) is None]
    return p.returncode, out, p.stderr.strip()


def diff_case(cid, host_res, boot_res, seen):
    hc, hout, herr = host_res
    bc, bout, berr = boot_res
    hval = hout[0] if hout else "ERR"
    bval = bout[0] if bout else "ERR"
    hkind = "ok" if hc == 0 and hout else ("ERR" if herr else "NO-OUT")
    bkind = "ok" if bc == 0 and bout else ("ERR" if berr else "NO-OUT")
    hval_n = norm_err(hval, cid, herr)
    bval_n = norm_err(bval, cid, berr)
    # Both sides rendered an error value (diagnostic vs "?Error" vs top-level
    # exit): exit codes/kinds differ by construction in that case (host exits 1
    # on an unhandled top-level `?`, boot prints its diagnostic and exits 0),
    # so collapse the kind once the value canonicalizes to the error token.
    hkind_n = "err" if hval_n == ERROR_TOKEN else hkind
    bkind_n = "err" if bval_n == ERROR_TOKEN else bkind
    if hval_n == bval_n and hkind_n == bkind_n:
        print("  MATCH %s: %s" % (cid, hval_n))
        return
    seen.append(cid)
    print("  DIFF  %s: host[%s] %r  boot[%s] %r" % (cid, hkind, hval, bkind, bval))
    if hkind == "ERR" and herr:
        print("        host stderr: %s" % herr.splitlines()[-1])
    if bkind == "ERR" and berr:
        print("        boot stderr: %s" % berr.splitlines()[-1])


def main():
    tmp = ROOT  # imports resolve relative to the file, so generated files must live in the repo root
    for old in glob.glob(os.path.join(ROOT, "_df_*.ql")) + glob.glob(os.path.join(ROOT, "_df_*.js")):
        os.remove(old)
    divergences = []
    hres = {}
    bres = {}

    # ---- Safe batch: host suite + bootstrapped suite ----
    host_suite = os.path.join(tmp, "_df_host.ql")
    boot_suite = os.path.join(tmp, "_df_boot.ql")
    write_host_suite(host_suite, SAFE_CASES)
    write_boot_suite(boot_suite, SAFE_CASES)

    print("=== Safe cases batch ===")
    h = run(host_suite)
    b = run(boot_suite)
    # Skip non-'cid=' lines (a boot case ending in a bare error value now has
    # runSource print a "Kind: msg" diagnostic line before its "cid=" line)
    hmap = {}
    for l in h[1]:
        if "=" in l:
            k, v = l.split("=", 1)
            hmap[k] = v
    bmap = {}
    for l in b[1]:
        if "=" in l:
            k, v = l.split("=", 1)
            bmap[k] = v
    for cid, _ in SAFE_CASES:
        hres[cid] = (0, [hmap.get(cid, "")], "")
        bres[cid] = (0, [bmap.get(cid, "")], "")
        diff_case(cid, hres[cid], bres[cid], divergences)

    # ---- Risky cases: run per-process ----
    print("=== Risky cases (isolated) ===")
    for cid, src in RISKY_CASES:
        hp, bp = os.path.join(tmp, "_df_" + cid + "_h.ql"), os.path.join(tmp, "_df_" + cid + "_b.ql")
        write_host_one(hp, cid, src)
        write_boot_one(bp, cid, src)
        hres[cid] = run(hp)
        bres[cid] = run(bp)
        diff_case(cid, hres[cid], bres[cid], divergences)

    # ---- Complex cases: run per-process ----
    print("=== Complex cases (isolated) ===")
    for cid, src in COMPLEX_CASES:
        hp, bp = os.path.join(tmp, "_df_" + cid + "_h.ql"), os.path.join(tmp, "_df_" + cid + "_b.ql")
        write_host_one(hp, cid, src)
        write_boot_one(bp, cid, src)
        hres[cid] = run(hp)
        bres[cid] = run(bp)
        diff_case(cid, hres[cid], bres[cid], divergences)

    # ---- Node.js reference: independent third implementation (V8) ----
    print("=== Node.js reference (V8) ===")
    if shutil.which("node") is None:
        print("  node not found on PATH; skipping (install with nvm: nvm install --lts)")
    else:
        src_of = dict(SAFE_CASES + COMPLEX_CASES + RISKY_CASES)
        for cid, js_src in NODE_CASES:
            if js_src is None:
                js_src = src_of[cid]  # the QLang source is valid JS verbatim
            np = os.path.join(tmp, "_df_node_%s.js" % cid)
            write_node_one(np, cid, js_src)
            nr = run_node(np)
            if cid not in hres or cid not in bres:
                hp, bp = os.path.join(tmp, "_df_" + cid + "_h.ql"), os.path.join(tmp, "_df_" + cid + "_b.ql")
                write_host_one(hp, cid, src_of[cid])
                write_boot_one(bp, cid, src_of[cid])
                hres[cid] = run(hp)
                bres[cid] = run(bp)
            node_check(cid, hres[cid], bres[cid], nr, divergences)

    print()
    # Clean up generated temp files (also excluded by .gitignore, double safety)
    for f in glob.glob(os.path.join(ROOT, "_df_*.ql")) + glob.glob(os.path.join(ROOT, "_df_*.js")):
        os.remove(f)
    if divergences:
        print("%d divergences: %s" % (len(divergences), ", ".join(divergences)))
        sys.exit(1)
    print("All identical ✔")


if __name__ == "__main__":
    main()
