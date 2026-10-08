#!/usr/bin/env python3
"""Verify QLang parse diagnostics and rejection without executing malformed code."""
import argparse
from pathlib import Path
import subprocess
import tempfile

from run_selfhost_tests import ROOT, TIMEOUT


def check_return_scope(compiler, interpreter, work):
    message = b'return is only allowed inside a function'
    cases = [
        ('return-root-after-marker',
         'println("UNREACHABLE before"); return 1; println("UNREACHABLE after");', 1, 32),
        ('return-dead-branch',
         'if false { println("UNREACHABLE"); return 1; };', 1, 36),
        ('return-after-function',
         'let f = () -> { return 1; }; return 2;', 1, 30),
        ('return-param-annotation',
         'let f = (x: if true { return Number; } else { Number; }) -> x;', 1, 23),
        ('return-interpolation',
         'let text = "v=${if true { return 1; } else { 2; }}";', 1, 27),
    ]
    for name, source, line, col in cases:
        path = work / (name + '.ql')
        path.write_text(source)
        expected = f'{path}:{line}:{col}:'.encode()
        result = subprocess.run([compiler, '--emit-llvm', path, ROOT/'aot/runtime.ql'],
                                capture_output=True, timeout=TIMEOUT)
        assert result.returncode == 1 and not result.stdout, (name, result)
        assert b'CompileError' in result.stderr and message in result.stderr and expected in result.stderr, (name, expected, result)
        result = subprocess.run([interpreter, path], capture_output=True, timeout=TIMEOUT)
        assert result.returncode == 1 and b'ParseError' in result.stderr and message in result.stderr and expected in result.stderr, (name, expected, result)
        assert b'UNREACHABLE' not in result.stdout, (name, result.stdout)
        print('PASS compiler/core function-only return:', name, flush=True)

    # An imported module has script scope even when its import is nested in a
    # function. Its own earlier statements must not run before parse rejection.
    modules = work / 'return-modules'
    child = modules / 'bad.ql'
    child.parent.mkdir(parents=True, exist_ok=True)
    child.write_text('println("UNREACHABLE MODULE");\r\nreturn 3;')
    expected = f'{child}:2:1:'.encode()
    entries = [
        ('return-import-direct', 'import "./bad.ql"; println("UNREACHABLE ENTRY");'),
        ('return-import-from-function', 'let load = () -> { import "./bad.ql"; }; load();'),
    ]
    for name, source in entries:
        path = modules / (name + '.ql')
        path.write_text(source)
        for command, kind in (([compiler, '--emit-llvm', path, ROOT/'aot/runtime.ql'], b'CompileError'),
                              ([interpreter, path], b'ParseError')):
            result = subprocess.run(command, capture_output=True, timeout=TIMEOUT)
            assert result.returncode == 1 and kind in result.stderr, (name, kind, result)
            assert message in result.stderr and expected in result.stderr, (name, expected, result)
            if kind == b'CompileError': assert not result.stdout, (name, result.stdout)
            assert b'UNREACHABLE' not in result.stdout, (name, result.stdout)
        print('PASS compiler/core imported module return rejection:', name, flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compiler', required=True, type=Path)
    parser.add_argument('--interpreter', required=True, type=Path)
    options = parser.parse_args()
    compiler = options.compiler.resolve(); interpreter = options.interpreter.resolve()
    cases = [
        ('array', '// comment\nlet x = [1;\nprintln("UNREACHABLE");', 2, 11),
        ('call', 'println(1;\nprintln("UNREACHABLE");', 1, 10),
        ('block', 'let f = () -> {\n 1;', 2, 4),
        ('unicode', '"中😀"; let x = ;\nprintln("UNREACHABLE");', 1, 15),
        ('crlf', '// comment\r\nlet x = ;', 2, 9),
        ('interpolation', 'let x = `text ${1 + }`;', 1, 21),
        ('comment', '\n/* unclosed', 2, 1),
        ('chain', 'println("UNREACHABLE");\nlet a = 0; let b = 0;\na = b = 1;', 3, 7),
        ('chain-member', 'println("UNREACHABLE");\nlet o = {}; let b = 0;\no.x = b = 1;', 3, 9),
        ('chain-index', 'println("UNREACHABLE");\nlet a = []; let b = 0;\na[0] = b = 1;', 3, 10),
        ('chain-function', 'println("UNREACHABLE");\nlet f = () -> { a = b = 1; };', 2, 23),
        ('chain-crlf', '"中😀";\r\na =\r\n b = 1;\nprintln("UNREACHABLE");', 3, 4),
    ]
    for index, literal in enumerate(['0x', '0X', '0xg', '0x1g', '0x1.2', '0x1p2',
                                    '1e', '1e+', '1e-', '1.e', '1e++2', '1e2x',
                                    '1.2.3', '1..2', '.5.6', '12abc', '1_000', '0b10', '0o10']):
        cases.append((f'number-{index}', f'// number\nlet x = {literal};\nprintln("UNREACHABLE");', 2, 9))
    with tempfile.TemporaryDirectory(prefix='qlang-source-diagnostics-') as tmp:
        work = Path(tmp)
        for name, source, line, col in cases:
            path = work / (name + '.ql'); path.write_bytes(source.encode())
            expected = f'{path}:{line}:{col}:'.encode()
            result = subprocess.run([compiler, '--emit-llvm', path, ROOT/'aot/runtime.ql'],
                                    capture_output=True, timeout=TIMEOUT)
            assert result.returncode == 1 and not result.stdout, (name, result)
            assert b'CompileError' in result.stderr and expected in result.stderr, (name, expected, result)
            result = subprocess.run([interpreter, path], capture_output=True, timeout=TIMEOUT)
            assert result.returncode == 1 and b'ParseError' in result.stderr and expected in result.stderr, (name, expected, result)
            assert b'UNREACHABLE' not in result.stdout, (name, result.stdout)
            print('PASS compiler/core parse location:', name, flush=True)
        check_return_scope(compiler, interpreter, work)
        child = work / 'lib' / '中 file.ql'; child.parent.mkdir()
        child.write_text('// imported\n\nlet x = ;')
        entry = work / 'main.ql'; entry.write_text('import "./lib/中 file.ql"; println("UNREACHABLE");')
        expected = f'{child}:3:9:'.encode()
        result = subprocess.run([compiler, '--emit-llvm', entry, ROOT/'aot/runtime.ql'],
                                capture_output=True, timeout=TIMEOUT)
        assert result.returncode == 1 and not result.stdout and expected in result.stderr, result
        result = subprocess.run([interpreter, entry], capture_output=True, timeout=TIMEOUT)
        assert result.returncode == 1 and expected in result.stderr and b'UNREACHABLE' not in result.stdout, result
        print('PASS imported-file parse location in compiler/core', flush=True)
        # The core already supports imports in functions. Resolve at definition site.
        module = child.parent / 'factory.ql'
        module.write_text('let load = () -> { import "./中 file.ql"; }; export load;')
        entry.write_text('import "./lib/factory.ql"; load()?; println("UNREACHABLE");')
        result = subprocess.run([interpreter, entry], capture_output=True, timeout=TIMEOUT)
        assert result.returncode == 1 and expected in result.stderr and b'UNREACHABLE' not in result.stdout, result
        print('PASS core function import retains imported source location', flush=True)
        print('Parse diagnostic suite: ALL CHECKS PASS', flush=True)


if __name__ == '__main__':
    main()
