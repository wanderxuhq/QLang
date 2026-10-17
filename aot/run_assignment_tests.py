#!/usr/bin/env python3
"""Check aggregate assignment contracts with a native QLang compiler."""
import argparse
from contextlib import nullcontext
from pathlib import Path
import subprocess
import tempfile

from run_selfhost_tests import ROOT, TIMEOUT, emit, link

CASES = [
    # A same-body read of an uninitialized binding is a *frontend* error now
    # (`reading uninitialized variable`), so those cases moved to
    # run_semantic_diagnostic_tests.py. The runtime channel is still covered by
    # `uninitialized-through-call` below (the read crosses a function boundary).
    ('uninitialized-through-call', 'let x; let f = () -> x; f().field = 1;', 'Uninitialized'),
    ('null-field', 'let x = null; x.field = 1;', 'NotAnObject'),
    ('number-field', 'let x = 42; x.field = 1;', 'NotAnObject'),
    ('null-index', 'let x = null; x[0] = 1;', 'CannotIndex'),
    ('string-index', 'let x = "abc"; x[0] = 1;', 'CannotIndex'),
    ('array-far', 'let x = [1]; x[2] = 1;', 'IndexOutOfBounds'),
    ('array-negative', 'let x = [1]; x[-2] = 1;', 'IndexOutOfBounds'),
    ('array-fraction', 'let x = [1]; x[0.5] = 1;', 'IndexOutOfBounds'),
    ('array-string', 'let x = [1]; x["0"] = 1;', 'CannotIndex'),
    ('object-bool', 'let x = {}; x[true] = 1;', 'CannotIndex'),
    ('object-array', 'let x = {}; x[[]] = 1;', 'CannotIndex'),
    ('missing-parent', 'let x = {}; x.missing.field = 1;', 'UndefinedField'),
    ('protected-field', 'Number.check = (v) -> false;', 'Custom'),
    ('protected-index', 'let alias = Error; alias["raise"] = null;', 'Custom'),
    ('loop', 'while true { if true { let x = []; x[1] = 2; }; };', 'IndexOutOfBounds'),
]


def check_interpreter(interpreter, work):
    from run_interpreter_tests import body
    source = ROOT / 'aot/tests/t21_assignments.ql'
    def run(source):
        return subprocess.run([str(interpreter), str(source)], cwd=ROOT,
                              capture_output=True, timeout=TIMEOUT)
    result = run(source)
    assert body(result) == source.with_suffix('.expected').read_bytes(), result
    print('PASS native interpreter assignment contract', flush=True)
    for name, code, kind in CASES:
        source = work / ('core-' + name + '.ql')
        source.write_text(code + '\nprintln("UNREACHABLE");\n')
        result = run(source)
        assert result.returncode == 1 and kind.encode() in result.stderr, (name, result)
        assert b'UNREACHABLE' not in result.stdout, (name, result.stdout)
    print('PASS native interpreter: 17 top-level assignment failures', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compiler', required=True, type=Path)
    parser.add_argument('--output-dir', type=Path)
    parser.add_argument('--interpreter', type=Path, help='also check a native core interpreter')
    options = parser.parse_args()
    compiler = options.compiler.resolve()
    if options.output_dir:
        options.output_dir = options.output_dir.resolve()
        options.output_dir.mkdir(parents=True, exist_ok=True)
    workspace = (nullcontext(str(options.output_dir)) if options.output_dir else
                 tempfile.TemporaryDirectory(prefix='qlang-assignment-'))
    with workspace as tmp:
        work = Path(tmp)

        def build(source, name):
            ir = work / (name + '.ll'); binary = work / name
            emit(compiler, source, ir); link(ir, binary)
            return binary

        def run(binary, *args):
            return subprocess.run([str(binary), *args], cwd=ROOT,
                                  capture_output=True, timeout=TIMEOUT)

        source = ROOT / 'aot/tests/t21_assignments.ql'
        result = run(build(source, 'assignments'))
        assert result.returncode == 0 and not result.stderr, result
        assert result.stdout == source.with_suffix('.expected').read_bytes(), result.stdout
        print('PASS assignment contracts: failure boundaries, order, aliases and successful writes', flush=True)

        source = work / 'exits.ql'
        source.write_text('\n'.join('if args[0] == "' + name + '" { ' + code + ' };'
                                    for name, code, _ in CASES) + '\nprintln("UNREACHABLE");\n')
        binary = build(source, 'exits')
        for name, _, kind in CASES:
            result = run(binary, name)
            assert result.returncode == 1 and kind.encode() in result.stderr, (name, result)
            assert not result.stdout, (name, result.stdout)
            print('PASS top-level assignment error:', name, flush=True)

        module = work / 'failed-module.ql'
        module.write_text('export { leaked: 99 }; let a = []; a[1] = 2; println("UNREACHABLE");')
        source = work / 'imports.ql'
        source.write_text('let leaked = 7; let m = import ./failed-module.ql; println(m.type); println(leaked);')
        result = run(build(source, 'imports'))
        assert result.returncode == 0 and not result.stderr, result
        assert result.stdout == b'IndexOutOfBounds\n7\n', result.stdout
        print('PASS failed module assignment does not publish exports', flush=True)
        if options.interpreter:
            check_interpreter(options.interpreter.resolve(), work)
        print('Assignment suite: ALL CHECKS PASS', flush=True)


if __name__ == '__main__':
    main()
