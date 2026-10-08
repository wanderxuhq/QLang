#!/usr/bin/env python3
"""Independent numeric contracts, deterministic f64 boundaries, and entropy failures."""
import argparse
import json
import math
from pathlib import Path
import random
import re
import struct
import subprocess
import tempfile

from native_link import link, validate
from run_selfhost_tests import ROOT, TIMEOUT, emit


def same_bits(a, b):
    return struct.pack('>d', a) == struct.pack('>d', b)


def cases():
    rng = random.Random(20260926)
    rows = []
    def add(op, a, b, expected, tolerance=0):
        rows.append((op, str(a), str(b), expected, tolerance))
    def finite():
        while True:
            n = struct.unpack('>d', rng.getrandbits(64).to_bytes(8, 'big'))[0]
            if math.isfinite(n):
                return n
    for literal in ['5e-324', '-0', '+.5', '1.e2', '00012.5', '1e309', '-1e309',
                    '1e-9999', '-1e-9999', '  2.5\t', '\u0085-3.5\u205f']:
        add('parse', literal, 0, float(literal))
    for literal in ['', 'bad', '1tail', '1 2', '0x10', '1e', '.', '1_0', '\ufeff1']:
        add('parse', literal, 0, math.nan)
    for n in [finite() for _ in range(60)] + [0.0, -0.0, math.inf, -math.inf, math.nan]:
        add('parse', repr(n), 0, n)
    for _ in range(100):
        a, b = finite(), finite()
        if b:
            add('mod', a, b, math.fmod(a, b))
    for a, b in [(1, .1), (-4, 2), (-0.0, 3), (1e308, 3), (1e308, 5e-324),
                 (5e-324, 1e308), (3, math.inf), (math.inf, 3), (math.nan, 3)]:
        expected = math.nan if not math.isfinite(a) else math.fmod(a, b)
        add('mod', a, b, expected)
    def saturate(n):
        if math.isnan(n): return 0
        if n >= 2**63: return 2**63 - 1
        if n <= -(2**63): return -(2**63)
        return int(n)
    for n in [finite() for _ in range(40)] + [math.inf, -math.inf, math.nan, -0., 2.**63, -(2.**63)]:
        for op in ('and', 'or', 'xor'):
            a, b = saturate(n), 5
            result = {'and': a & b, 'or': a | b, 'xor': a ^ b}[op]
            add(op, n, b, float(result))
    values = [abs(finite()) for _ in range(70)] + [5e-324, 1e-308, 1e308, 0., -0., math.inf]
    for n in values:
        add('sqrt', n, 0, math.sqrt(n), 3)
    values = [finite() for _ in range(90)] + [0., -0., math.inf, -math.inf, math.nan,
              1e300, 1e308, math.pi / 2, math.pi, math.tau, math.nextafter(math.pi, 0)]
    for n in values:
        for op, fn in [('sin', math.sin), ('cos', math.cos)]:
            add(op, n, 0, fn(n) if math.isfinite(n) else math.nan, 12)
    for _ in range(90):
        a, b = 10 ** rng.uniform(-300, 300), rng.uniform(-4, 4)
        try: result = math.pow(a, b)
        except OverflowError: result = math.inf
        add('pow', a, b, result, 8)
    for _ in range(80):
        a, b = 10 ** rng.uniform(-300, 300), rng.randint(-64, 64)
        if rng.randrange(2): a = -a
        try: result = math.pow(a, b)
        except OverflowError: result = -math.inf if a < 0 and b % 2 else math.inf
        add('pow', a, b, result, 8)
    for a, b in [(1.0000000000000002, 1e15), (1.0000000000000002, -1e15),
                 (.9999999999999999, 1e15), (2, -1074), (2, -1075), (2, 1024),
                 (10, -323), (10, -324), (-2, 63), (-2, -63), (9, .5), (16, -.5)]:
        try: result = math.pow(a, b)
        except OverflowError: result = math.inf
        add('pow', a, b, result, 8)
    return rows


def check_output(output, rows, opt):
    lines = output.splitlines()
    assert len(lines) == len(rows), (opt, len(lines), len(rows), output[-1000:])
    worst = {}
    for line, (op, a, b, expected, tolerance) in zip(lines, rows):
        nan, finite, negative, literal = json.loads(line)
        label = (opt, op, a, b, line, expected)
        if math.isnan(expected):
            assert nan and not finite, label
        elif math.isinf(expected):
            assert not nan and not finite and negative == (expected < 0), label
        else:
            assert finite and not nan, label
            actual = float(literal)
            if not tolerance or expected == 0:
                assert same_bits(actual, expected), label
            else:
                error = abs(actual - expected)
                limit = math.ulp(expected) * tolerance
                assert error <= limit, (label, error, limit)
                worst[op] = max(worst.get(op, 0), error / math.ulp(expected))
    print(f'PASS -O{opt}: {len(rows)} independent numeric cases; observed max ULP errors {worst}', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compiler', required=True, type=Path)
    options = parser.parse_args()
    compiler = options.compiler.resolve()
    rows = cases()
    with tempfile.TemporaryDirectory(prefix='qlang-numeric-contracts-') as tmp:
        work = Path(tmp)
        for name in ('t25_numeric', 't26_extrema'):
            fixture = ROOT / 'aot/tests' / (name + '.ql')
            ir = work / 'contract.ll'; emit(compiler, fixture, ir)
            for opt in (0, 2):
                binary = work / f'contract-O{opt}'; link(ir, binary, opt=opt)
                out = subprocess.run([str(binary)], capture_output=True, timeout=TIMEOUT)
                assert out.returncode == 0 and not out.stderr, out
                assert out.stdout == fixture.with_suffix('.expected').read_bytes(), out.stdout
                print(f'PASS -O{opt}: {name} fixed contracts', flush=True)
        source = work / 'numbers.ql'
        source.write_text('let cases = ' + json.dumps([list(row[:3]) for row in rows]) + ''';
let i = 0;
while i < cases.length {
  let c = cases[i]; let a = std.Number.parseFloat(c[1]); let b = std.Number.parseFloat(c[2]); let n = a;
  if c[0] == "mod" { n = a % b; }
  else if c[0] == "and" { n = a & b; }
  else if c[0] == "or" { n = a | b; }
  else if c[0] == "xor" { n = a ^ b; }
  else if c[0] == "sqrt" { n = std.Math.sqrt(a); }
  else if c[0] == "sin" { n = std.Math.sin(a); }
  else if c[0] == "cos" { n = std.Math.cos(a); }
  else if c[0] == "pow" { n = std.Math.pow(a)(b); };
  println(std.JSON.stringify([std.Number.isNaN(n), std.Number.isFinite(n), n < 0, std.JSON.stringify(n)]));
  i = i + 1;
};
''')
        ir = work / 'numbers.ll'; emit(compiler, source, ir)
        for opt in (0, 2):
            binary = work / f'numbers-O{opt}'; link(ir, binary, opt=opt)
            out = subprocess.run([str(binary)], capture_output=True, timeout=TIMEOUT)
            assert out.returncode == 0 and not out.stderr, out
            check_output(out.stdout, rows, opt)
            symbols = subprocess.check_output(['llvm-nm', '-u', str(binary)], text=True)
            assert not re.search(r'\b(fmod|pow|sqrt|sin|cos|floor|ceil|round|trunc)(?:@|$)', symbols, re.M), symbols
        print('PASS no external math functions in native artifacts', flush=True)
        source = work / 'entropy.ql'
        source.write_text('let n = std.Math.random(); if isError(n) { println(n.type); } else { println(n == 0.9999999999999999); };')
        ir = work / 'entropy.ll'; emit(compiler, source, ir)
        runtime = (ROOT / 'aot/runtime.c').read_text()
        variants = {
            'short-eintr': ('static int calls; long ql_getrandom(void* buf, long count) { '
                            'if (++calls == 1) return -4; long n = count < 2 ? count : 2; '
                            'memset(buf, 255, (size_t)n); return n; }', b'true\n'),
            'error': ('long ql_getrandom(void* buf, long count) { return -5; }', b'IOError\n'),
            'empty': ('long ql_getrandom(void* buf, long count) { return 0; }', b'IOError\n'),
        }
        for name, (replacement, expected) in variants.items():
            modified, count = re.subn(r'long ql_getrandom\([^)]*\)\s*\{[^}]*\}', replacement, runtime)
            assert count == 1
            c = work / f'{name}.c'; c.write_text(modified)
            binary = work / name
            subprocess.run(['clang', '-O2', '-fuse-ld=lld', '-Wl,--threads=1', '-Wl,--export-dynamic', str(ir), str(c), '-ldl', '-o', str(binary)],
                           check=True, timeout=TIMEOUT)
            validate(ir, binary)
            out = subprocess.run([str(binary)], capture_output=True, timeout=TIMEOUT)
            assert out.returncode == 0 and not out.stderr and out.stdout == expected, (name, out)
            print('PASS entropy handling:', name, flush=True)
        print('Numeric correctness suite: ALL CHECKS PASS', flush=True)


if __name__ == '__main__':
    main()
