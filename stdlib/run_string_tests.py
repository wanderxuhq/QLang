#!/usr/bin/env python3
"""Validate the same portable QLang String source on LLVM and the QLang core."""
import argparse
import hashlib
import json
from pathlib import Path
import random
import subprocess
import sys
import tempfile
import unicodedata

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'aot'))
from native_link import link
from run_selfhost_tests import emit, TIMEOUT
from run_interpreter_tests import body


def execute(binary, *args):
    return subprocess.run([str(binary), *map(str, args)], capture_output=True, timeout=TIMEOUT)


def unicode_oracle():
    assert unicodedata.unidata_version == '15.1.0', 'oracle requires pinned Unicode 15.1 Python data'
    changed = [chr(cp) for cp in range(0x110000)
               if not 0xD800 <= cp <= 0xDFFF and
               (chr(cp).upper() != chr(cp) or chr(cp).lower() != chr(cp))]
    # Cover every scalar with a nonidentity upper/lower mapping, independently
    # of the generated UCD tables, plus context-sensitive sigma sequences.
    inputs = ['|'.join(changed[i:i+64]) for i in range(0, len(changed), 64)]
    rng = random.Random(3015)
    alphabet = ['A', 'Σ', 'σ', '\u0345', '\u0301', "'", '.', ' ', '中', 'İ', 'ß', '\u200d']
    inputs += [''.join(rng.choice(alphabet) for _ in range(12)) for _ in range(120)]
    inputs += ['AΣ\u0345', '\u0345Σ', "A'Σ'A", 'ΑΣ\u0301', 'AΣ\u200d', 'AΣ\u200dA']
    ws = '\t\n\v\f\r \u0085\u00a0\u1680\u2000\u2001\u2002\u2003\u2004\u2005\u2006\u2007\u2008\u2009\u200a\u2028\u2029\u202f\u205f\u3000'
    trim_inputs = [c + '中 ' + c for c in ws] + ['\u200bx\ufeff', '', ws, ' a \t b ']
    source = 'let inputs = ' + json.dumps(inputs, ensure_ascii=False) + ';\n'
    source += 'let i = 0; while i < inputs.length { println(std.String.toUpperCase(inputs[i])); println(std.String.toLowerCase(inputs[i])); i = i + 1; };\n'
    source += 'let trims = ' + json.dumps(trim_inputs, ensure_ascii=False) + ';\ni = 0; while i < trims.length { println(std.String.trim(trims[i])); i = i + 1; };\n'
    expected = ''.join(s.upper() + '\n' + s.lower() + '\n' for s in inputs)
    expected += ''.join(s.strip(ws) + '\n' for s in trim_inputs)
    return source, expected.encode(), len(changed), len(inputs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compiler', required=True, type=Path)
    parser.add_argument('--interpreter', required=True, type=Path)
    args = parser.parse_args()
    compiler = args.compiler.resolve(); interpreter = args.interpreter.resolve()
    # Prevent accidental reintroduction of the backend boundary into the library.
    source = (ROOT / 'stdlib/string.ql').read_text()
    for forbidden in ('ql_mem_', 'readU64', 'writeU64', 'ql_alloc', 'std.String.', 'std.Math.'):
        assert forbidden not in source, forbidden
    with tempfile.TemporaryDirectory(prefix='qlang-portable-string-') as tmp:
        work = Path(tmp)
        fixture = ROOT / 'aot/tests/t30_strings.ql'
        expected = fixture.with_suffix('.expected').read_bytes()
        ir = work / 'strings.ll'; emit(compiler, fixture, ir)
        for opt in (0, 2):
            binary = work / f'strings-O{opt}'; link(ir, binary, opt=opt)
            result = execute(binary)
            assert result.returncode == 0 and not result.stderr and result.stdout == expected, result
            print(f'PASS -O{opt}: 193 portable String contracts', flush=True)
        actual = body(execute(interpreter, fixture))
        assert actual == expected, actual
        print('PASS native QLang interpreter: same 193 portable String contracts', flush=True)

        oracle, expected, changed, cases = unicode_oracle()
        fixture = work / 'unicode.ql'; fixture.write_text(oracle)
        ir = work / 'unicode.ll'; emit(compiler, fixture, ir)
        for opt in (0, 2):
            binary = work / f'unicode-O{opt}'; link(ir, binary, opt=opt)
            result = execute(binary)
            assert result.returncode == 0 and not result.stderr, result
            assert result.stdout == expected, (len(result.stdout), len(expected), hashlib.sha256(result.stdout).hexdigest())
            print(f'PASS -O{opt}: independent Unicode oracle, {changed} mapped scalars / {cases} strings', flush=True)
        actual = body(execute(interpreter, fixture))
        assert actual == expected, (len(actual), len(expected))
        print('PASS native QLang interpreter: independent Unicode oracle', flush=True)

        failures = work / 'errors.ql'
        failures.write_text('if args[0] == "receiver" { std.String.trim(42)?; };\n'
            'if args[0] == "repeat" { std.String.repeat("x")(0.5)?; };\n'
            'if args[0] == "limit" { std.String.repeat("x")(16777217)?; };\n'
            'if args[0] == "index" { std.String.at("x", 2)?; };\n'
            'println("UNREACHABLE");\n')
        ir = work / 'errors.ll'; emit(compiler, failures, ir)
        for opt in (0, 2):
            binary = work / f'errors-O{opt}'; link(ir, binary, opt=opt)
            for name, kind in [('receiver', b'TypeMismatch'), ('repeat', b'RangeError'), ('limit', b'RangeError'), ('index', b'IndexOutOfBounds')]:
                result = execute(binary, name)
                assert result.returncode == 1 and not result.stdout and kind in result.stderr, (name, result)
            print(f'PASS -O{opt}: unhandled library errors report and exit, without crashing', flush=True)
        print('Portable String suite: ALL CHECKS PASS', flush=True)


if __name__ == '__main__':
    main()
