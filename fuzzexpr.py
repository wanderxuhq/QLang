#!/usr/bin/env python3
"""Random expression differential testing with a Python oracle.

Generates random expression trees (fully parenthesized, so the parse tree is
forced) and computes the expected value in Python using IEEE-754 f64
arithmetic — the same semantics as the host's f64 values. Every expression
runs through both the Rust host interpreter and the bootstrapped interpreter;
all three (host, boot, oracle) must agree. This covers operator semantics
(arithmetic, bitwise, comparisons, &&/|| operand-returning, unary, string
ops, array indexing/length) at scale, including edge cases like float
division, fmod on negatives, and empty-string/array truthiness.

Under error-value semantics (host Tasks 1-5, boot Tasks 6-9), x/0 and x%0 are
DivisionByZero error VALUES instead of IEEE inf/NaN, so the generator now also
produces zero divisors. The Python oracle returns an ERR_DIV marker for those,
and error operands poison any op that touches them (QLang wraps them in a new
error whose cause chain still contains DivisionByZero). All three sides' error
renderings — the oracle marker, the host's multi-line diagnostic, the boot's
"?Error" — canonicalize to a single token (difftest.ERROR_TOKEN) before
comparison, the same convention difftest uses for its error cases.

Also generates unparenthesized operator chains whose expected grouping follows
the language's precedence table (src/ast.rs): with the Pratt parser there,
`a OP1 b OP2 c` groups left iff precedence(OP1) >= precedence(OP2). This
checks both parsers' precedence and associativity handling.

Usage: python3 fuzzexpr.py [--seed N] [--count N] [--depth N]
"""
import argparse
import glob
import json
import math
import os
import random
import sys

import difftest  # reuse run(), write_host_suite(), write_boot_suite()

ROOT = os.path.dirname(os.path.abspath(__file__))

NUMS = [0.0, 1.0, 2.0, 3.0, 5.0, 7.0, 10.0, 0.5, 2.5]
STRS = ["", "a", "b", "ab", "abc", "héllo"]

# Python-oracle marker for a DivisionByZero error value (QLang: x/0 and x%0
# produce a DivisionByZero error value; no more IEEE inf/NaN). fmt() renders
# it and norm() canonicalizes it to difftest.ERROR_TOKEN, exactly like the
# host's diagnostic and the boot's "?Error".
ERR_DIV = "ERR:DivisionByZero"


def num_lit(n):
    """QLang number literal text (integers print without a fraction part)."""
    return str(int(n)) if n.is_integer() else repr(n)


def truthy(v):
    """QLang truthiness (host is_truthy): falsy = null, false, 0, "", []."""
    if v is None or v is False:
        return False
    if isinstance(v, float):
        return v != 0.0
    if isinstance(v, str):
        return v != ""
    if isinstance(v, list):
        return len(v) != 0
    return True


def fmt(v):
    """Render a value the way the host's disp does (std.Number.toString etc.)."""
    if v == ERR_DIV:
        return ERR_DIV  # error marker; norm() canonicalizes to ERROR_TOKEN
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, float):
        if v == 0.0:
            return "0"  # normalize -0.0 (IEEE products with zero operands can be -0.0)
        if v.is_integer():
            return str(int(v))
        return repr(v)
    if isinstance(v, str):
        return v
    return "?Array"


def same_type_eq(a, b):
    """QLang == is type-strict (like JS ===): numbers/strings/bools/null by
    value, arrays by reference (two distinct literals are never equal)."""
    if a is None or isinstance(a, bool):
        return type(a) is type(b) and a == b
    if isinstance(a, float):
        return isinstance(b, float) and a == b
    if isinstance(a, str):
        return isinstance(b, str) and a == b
    return False


def gen_num(depth, rng):
    """(text, value): value is a float, or ERR_DIV when the expression is a
    DivisionByZero error value (x/0, x%0, or any op on one)."""
    if depth <= 0 or rng.random() < 0.45:
        n = rng.choice(NUMS)
        return num_lit(n), n
    k = rng.random()
    if k < 0.5:
        op = rng.choice(["+", "-", "*", "/", "%"])
        a, b = gen_num(depth - 1, rng), gen_num(depth - 1, rng)
        # ev() returns ERR_DIV for a zero divisor (DivisionByZero error value
        # on the QLang side; the old loop that dodged b == 0.0 is gone) and
        # poisons any op touching an error operand, matching QLang's
        # "op on error value -> new error" rule. fmod matches Rust's
        # truncated remainder.
        v = ev(op, a[1], b[1])
        if isinstance(v, float) and v == 0.0:
            v = 0.0
        return "(%s %s %s)" % (a[0], op, b[0]), v
    if k < 0.72:
        a = gen_num(depth - 1, rng)
        if a[1] == ERR_DIV:
            return "(-%s)" % a[0], ERR_DIV  # unary minus on an error -> error
        if a[1] == 0.0:
            return a[0], a[1]  # avoid -0.0 rendering edge
        return "(-%s)" % a[0], -a[1]
    if k < 0.9:
        op = rng.choice(["&", "|", "^"])
        a, b = gen_int(depth - 1, rng), gen_int(depth - 1, rng)
        v = {"&": lambda x, y: x & y, "|": lambda x, y: x | y, "^": lambda x, y: x ^ y}[op](a[1], b[1])
        return "(%s %s %s)" % (a[0], op, b[0]), float(v)
    # length or index of an array of numbers
    arr = [gen_num(depth - 1, rng) for _ in range(rng.randint(1, 3))]
    text = "[" + ", ".join(x[0] for x in arr) + "]"
    if rng.random() < 0.5:
        i = rng.randrange(len(arr))
        return "%s[%d]" % (text, i), arr[i][1]
    return "%s.length" % text, float(len(arr))


def gen_int(depth, rng):
    """(text, value): value is a non-negative Python int (small)."""
    if depth <= 0 or rng.random() < 0.6:
        n = rng.randint(0, 31)
        return str(n), n
    op = rng.choice(["&", "|", "^"])
    a, b = gen_int(depth - 1, rng), gen_int(depth - 1, rng)
    v = {"&": lambda x, y: x & y, "|": lambda x, y: x | y, "^": lambda x, y: x ^ y}[op](a[1], b[1])
    return "(%s %s %s)" % (a[0], op, b[0]), v


def gen_str(depth, rng):
    """(text, value): value is always a str (concat builds up sub-strings)."""
    if depth <= 0 or rng.random() < 0.55:
        s = rng.choice(STRS)
        return json.dumps(s, ensure_ascii=False), s
    a, b = gen_str(depth - 1, rng), gen_str(depth - 1, rng)
    return "(%s + %s)" % (a[0], b[0]), a[1] + b[1]


def gen_any(depth, rng):
    """(text, value): value may be float, str, bool, None, list, or ERR_DIV."""
    if depth <= 0 or rng.random() < 0.3:
        k = rng.random()
        if k < 0.35:
            n = rng.choice(NUMS)
            return num_lit(n), n
        if k < 0.6:
            s = rng.choice(STRS)
            return json.dumps(s, ensure_ascii=False), s
        if k < 0.8:
            return ("true", True) if rng.random() < 0.5 else ("false", False)
        return ("null", None)
    k = rng.random()
    if k < 0.4:  # arithmetic: numbers, or string concat
        if rng.random() < 0.75:
            return gen_num(depth, rng)
        a, b = gen_str(depth - 1, rng), gen_str(depth - 1, rng)
        return "(%s + %s)" % (a[0], b[0]), a[1] + b[1]
    if k < 0.46:
        return gen_num(depth, rng)  # includes bitwise / array length / number index
    if k < 0.56:  # comparisons on numbers
        op = rng.choice(["<", "<=", ">", ">="])
        a, b = gen_num(depth - 1, rng), gen_num(depth - 1, rng)
        if a[1] == ERR_DIV or b[1] == ERR_DIV:
            return "(%s %s %s)" % (a[0], op, b[0]), ERR_DIV  # comparison on an error -> error
        v = {"<": lambda x, y: x < y, "<=": lambda x, y: x <= y,
             ">": lambda x, y: x > y, ">=": lambda x, y: x >= y}[op](a[1], b[1])
        return "(%s %s %s)" % (a[0], op, b[0]), v
    if k < 0.68:  # == / != (type-strict, like JS ===)
        op = "==" if rng.random() < 0.5 else "!="
        a, b = gen_any(depth - 1, rng), gen_any(depth - 1, rng)
        if a[1] == ERR_DIV or b[1] == ERR_DIV:
            return "(%s %s %s)" % (a[0], op, b[0]), ERR_DIV  # == / != on an error -> error
        eq = same_type_eq(a[1], b[1])
        return "(%s %s %s)" % (a[0], op, b[0]), (eq if op == "==" else not eq)
    if k < 0.76:  # && / || return an operand (JS semantics)
        op = "&&" if rng.random() < 0.5 else "||"
        a, b = gen_any(depth - 1, rng), gen_any(depth - 1, rng)
        # An error on the left is an error before any short-circuit. The
        # right side only matters when it is actually evaluated (e.g.
        # "abc" || (1/0) is "abc": the truthy left short-circuits and the
        # error is never computed) — the operand-returning formula below
        # already picks b[1] exactly when QLang evaluates it.
        if a[1] == ERR_DIV:
            return "(%s %s %s)" % (a[0], op, b[0]), ERR_DIV  # && / || on an error -> error
        v = (b[1] if truthy(a[1]) else a[1]) if op == "&&" else (a[1] if truthy(a[1]) else b[1])
        return "(%s %s %s)" % (a[0], op, b[0]), v
    if k < 0.84:  # unary
        if rng.random() < 0.5:
            a = gen_num(depth - 1, rng)
            if a[1] == ERR_DIV:
                return "(-%s)" % a[0], ERR_DIV  # unary minus on an error -> error
            if a[1] == 0.0:
                return a[0], a[1]  # avoid -0.0 rendering edge
            return "(-%s)" % a[0], -a[1]
        a = gen_any(depth - 1, rng)
        # ! on an error value is false (errors are truthy), so no ERR_DIV
        # special case needed here
        return "(!%s)" % a[0], not truthy(a[1])
    if k < 0.89:  # ?? fallback: a DivisionByZero error value is caught by the fallback
        a = gen_num(depth - 1, rng)
        b = gen_any(depth - 1, rng)
        v = b[1] if a[1] == ERR_DIV else a[1]  # ?? only catches error values
        return "(%s ?? %s)" % (a[0], b[0]), v
    if k < 0.93:  # array: index / length / bare (bare arrays only feed == or &&)
        arr = [gen_any(depth - 1, rng) for _ in range(rng.randint(1, 3))]
        text = "[" + ", ".join(x[0] for x in arr) + "]"
        vals = [x[1] for x in arr]
        r2 = rng.random()
        if r2 < 0.4:
            i = rng.randrange(len(vals))
            return "%s[%d]" % (text, i), vals[i]
        if r2 < 0.7:
            return "%s.length" % text, float(len(vals))
        return text, vals
    # string index / length on literals
    s = rng.choice(STRS)
    text = json.dumps(s, ensure_ascii=False)
    if s and rng.random() < 0.5:
        i = rng.randrange(len(s))
        return "%s[%d]" % (text, i), s[i]
    return "%s.length" % text, float(len(s))


# Precedence table from src/ast.rs (higher binds tighter):
#   || 10, && 20, | 45, ^ 50, & 55, == != < <= > >= 60, + - 70, * / % 80
# Bitwise order & > ^ > | matches JS/C/Python (and the bootstrapped parser).
# Pratt parsing (right operand parsed at prec+1) groups `a OP1 b OP2 c` as
# (a OP1 b) OP2 c iff prec(OP1) >= prec(OP2), else a OP1 (b OP2 c).
# Only combinations whose result stays a printable scalar are included.
CHAIN_CASES = [
    # (op1, op2, 'L' = ((a op1 b) op2 c), 'R' = (a op1 (b op2 c)))
    ("-", "-", "L"), ("+", "+", "L"), ("*", "*", "L"), ("/", "/", "L"), ("%", "%", "L"),
    ("+", "*", "R"), ("-", "*", "R"), ("*", "+", "L"), ("*", "-", "L"),
    ("+", "-", "L"), ("-", "+", "L"), ("*", "/", "L"), ("/", "*", "L"),
    ("%", "*", "L"), ("+", "%", "R"), ("-", "%", "R"),
    ("&", "+", "R"), ("|", "+", "R"), ("^", "+", "R"),
    ("|", "&", "R"), ("^", "|", "L"), ("&", "^", "L"), ("|", "^", "R"), ("^", "&", "R"),
    ("==", "+", "R"), ("<", "+", "R"),
    ("&&", "||", "L"), ("||", "&&", "R"),
    ("==", "&&", "L"), ("<", "&&", "L"),
]


def ev(op, a, b):
    """Evaluate one binary op in Python with QLang semantics.

    x/0 and x%0 are DivisionByZero error values on the QLang side, so this
    returns the ERR_DIV marker for a zero divisor (Python's ZeroDivisionError
    would otherwise crash the oracle). An error operand poisons any further
    op: QLang wraps it in a new error whose cause chain still contains
    DivisionByZero, and both renderings normalize to the same token.
    """
    if a == ERR_DIV or b == ERR_DIV:
        return ERR_DIV
    if op == "/" or op == "%":
        if b == 0.0:
            return ERR_DIV
    if op == "+":
        return a + b
    if op == "-":
        return a - b
    if op == "*":
        return a * b
    if op == "/":
        return a / b
    if op == "%":
        return math.fmod(a, b)
    if op == "&":
        return float(int(a) & int(b))
    if op == "|":
        return float(int(a) | int(b))
    if op == "^":
        return float(int(a) ^ int(b))
    if op == "&&":
        return b if truthy(a) else a
    if op == "||":
        return a if truthy(a) else b
    if op == "==":
        return a == b
    if op == "<":
        return a < b
    raise ValueError("unknown op %r" % op)


def chain_case(op1, op2, group, rng):
    """Unparenthesized `a OP1 b OP2 c`; expected value from the hardcoded grouping."""
    if op1 in "/%" or op2 in "/%":
        a, b, c = rng.randint(1, 9), rng.randint(1, 9), rng.randint(1, 9)
    elif op1 in "&|^" or op2 in "&|^":
        a, b, c = rng.randint(1, 31), rng.randint(1, 31), rng.randint(1, 31)
    else:
        a, b, c = rng.randint(1, 99), rng.randint(1, 99), rng.randint(1, 99)
    text = "%d %s %d %s %d" % (a, op1, b, op2, c)
    if group == "L":
        v = ev(op2, ev(op1, float(a), float(b)), float(c))
    else:
        v = ev(op1, float(a), ev(op2, float(b), float(c)))
    if isinstance(v, float) and v == 0.0:
        v = 0.0
    return text, v


def norm(v):
    """Canonicalize one side's rendered output before comparison.

    The oracle's ERR_DIV marker, the host's multi-line error diagnostic, and
    the boot's "?Error" all collapse to difftest.ERROR_TOKEN; normal values
    pass through unchanged. This is the same convention as difftest.norm_err
    (which also strips "(at line L, col C)" position info, since the boot AST
    carries no spans).
    """
    if v == ERR_DIV:
        return difftest.ERROR_TOKEN
    return difftest.norm_err(v)


_ERR_CAUSE_LINE = "  └─ caused by: "  # diagnostic continuation line (host to_string)


def parse_out(lines, cases, boot=False):
    """Map each case's cid to its rendered output from a batch run.

    Output appears in case order and every case produces exactly one segment:
    a 'cid=value' line, or — for a case whose expression is an error value —
    a multi-line diagnostic whose 'cid=' prefix is swallowed by the error
    chain (the host prints "TypeMismatch: cannot apply addition ..." followed
    by "  └─ caused by: ..." lines). Split the stream into segments (a
    'cid=' line or a diagnostic first line starts one; "  └─ caused by:"
    lines continue it) and assign the i-th segment to the i-th case, so
    consecutive erroring cases are attributed correctly.

    On the boot side, runSource additionally prints a top-level diagnostic
    ("Kind: msg" plus "  └─ caused by:" continuations) for any case whose last
    expression is an error value — those lines are NOT case segments and are
    dropped (boot=True), so the positional mapping stays aligned.
    """
    segments = []
    for l in lines:
        if boot and (l.startswith(_ERR_CAUSE_LINE) or difftest._ERR_DIAG_LINE.match(l)):
            continue
        if l.startswith(_ERR_CAUSE_LINE) and segments:
            segments[-1].append(l)
        else:
            segments.append([l.split("=", 1)[1] if "=" in l else l])
    out = {}
    for i, (cid, _src, _val) in enumerate(cases):
        out[cid] = "\n".join(segments[i]) if i < len(segments) else ""
    return out


def main():
    ap = argparse.ArgumentParser(description="Random expression differential testing with a Python oracle")
    ap.add_argument("--seed", type=int, default=1, help="RNG seed (default 1)")
    ap.add_argument("--count", type=int, default=300, help="random tree cases (default 300)")
    ap.add_argument("--depth", type=int, default=3, help="max expression depth (default 3)")
    args = ap.parse_args()

    rng = random.Random(args.seed)
    cases = []
    for i in range(args.count):
        text, val = gen_any(args.depth, rng)
        cases.append(("ge%04d" % i, text, val))
    for j, (op1, op2, group) in enumerate(CHAIN_CASES):
        for k in range(3):
            text, val = chain_case(op1, op2, group, rng)
            cases.append(("ch%03d" % (j * 3 + k), text, val))

    host_path = os.path.join(ROOT, "_df_fuzz_host.ql")
    boot_path = os.path.join(ROOT, "_df_fuzz_boot.ql")
    difftest.write_host_suite(host_path, [(cid, src) for cid, src, _ in cases])
    difftest.write_boot_suite(boot_path, [(cid, src) for cid, src, _ in cases])

    h = difftest.run(host_path)
    b = difftest.run(boot_path)
    hmap = parse_out(h[1], cases)
    bmap = parse_out(b[1], cases, boot=True)

    print("=== Random expressions (seed %d, %d tree + %d chain cases) ==="
          % (args.seed, args.count, len(cases) - args.count))
    bad = 0
    for cid, src, val in cases:
        exp = fmt(val)
        hv = hmap.get(cid, "<no output>")
        bv = bmap.get(cid, "<no output>")
        exp_n, hv_n, bv_n = norm(exp), norm(hv), norm(bv)
        if hv_n != exp_n or bv_n != exp_n:
            bad += 1
            print("FAIL %s: %s" % (cid, src))
            print("  oracle %s  host %s  boot %s" % (exp_n, hv_n, bv_n))
    for f in glob.glob(os.path.join(ROOT, "_df_fuzz_*.ql")):
        os.remove(f)
    if bad:
        print("%d mismatches (seed %d)" % (bad, args.seed))
        sys.exit(1)
    print("All %d expressions match (host = boot = oracle) ✔" % len(cases))


if __name__ == "__main__":
    main()
