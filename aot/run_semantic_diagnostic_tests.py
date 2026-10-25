#!/usr/bin/env python3
"""Check exact source attribution for compiler failures after successful parsing."""
import argparse
from pathlib import Path
import subprocess
import tempfile
from run_selfhost_tests import ROOT, TIMEOUT


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compiler', required=True, type=Path)
    options = parser.parse_args(); compiler = options.compiler.resolve()
    usage = subprocess.run([compiler], capture_output=True, timeout=TIMEOUT)
    expected_usage = b'CompileError: usage: qlangc --emit-llvm|--emit-module source.ql runtime.ql\n'
    assert usage.returncode == 1 and not usage.stdout and usage.stderr == expected_usage, usage
    print('PASS compiler usage diagnostic has no implementation frames', flush=True)
    cases = [
        ('unicode-read', '"中😀";\r\n  println((missing));', None, 2, 12, 'undeclared name: missing'),
        ('assignment', 'let f = () -> {\n  unknown = 3;\n};', None, 2, 3, 'assignment to undeclared name: unknown'),
        ('dependency', 'import "./lib.ql";', '\nlet f = () -> {\n  println(missing);\n};', 3, 11, 'undeclared name: missing'),
        ('import-site', '\n  import "./absent.ql";', None, 2, 3, None),
        ('uninitialized-field', 'let x; x.field = 1;', None, 1, 8, 'reading uninitialized variable: x'),
        ('uninitialized-index', 'let x = []; let index; x[index] = 1;', None, 1, 26, 'reading uninitialized variable: index'),
        ('annotation-literal', 'let bad: Number = "x";', None, 1, 1,
         'type mismatch: value of type String does not match the annotated type Number'),
        ('propagate-number', 'let f = (): Number -> {\n  let z = 0;\n  let v = (1 / z)?;\n  v;\n};',
         None, 3, 18, '? requires a Result or Option return type'),
        ('propagate-string', 'let f = (): String -> {\n  let z = 0;\n  let v = (1 / z)?;\n  v;\n};',
         None, 3, 18, '? requires a Result or Option return type'),
    ]
    with tempfile.TemporaryDirectory(prefix='qlang-semantic-diagnostics-') as tmp:
        work = Path(tmp)
        for name, text, dependency, line, col, message in cases:
            source = work/(name+'.ql'); source.write_bytes(text.encode())
            if dependency is not None: (work/'lib.ql').write_text(dependency)
            result = subprocess.run([compiler, '--emit-llvm', source, ROOT/'aot/runtime.ql'],
                                    capture_output=True, timeout=TIMEOUT)
            origin = work/'lib.ql' if dependency is not None else source
            prefix = f'{origin}:{line}:{col}: '.encode()
            assert result.returncode == 1 and not result.stdout, result
            assert b'CompileError' in result.stderr and prefix in result.stderr, result
            if message: assert message.encode() in result.stderr, result
            assert b'/aot/qlangc.ql:' not in result.stderr, result.stderr
            assert b'/bootstrapped/' not in result.stderr, result.stderr
            print('PASS compiler source diagnostic:', name, flush=True)
    print('Semantic compiler diagnostic suite: ALL CHECKS PASS', flush=True)


if __name__ == '__main__':
    main()
