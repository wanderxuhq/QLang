#!/usr/bin/env python3
"""Compile and exercise the QLang interpreter without invoking the Rust runner."""
import argparse
from contextlib import nullcontext
from pathlib import Path
import subprocess
import sys
import tempfile

from run_selfhost_tests import ROOT, TIMEOUT, emit, link


def execute(binary, source, cwd=ROOT):
    return subprocess.run([str(binary), str(source)], cwd=cwd,
                          capture_output=True, timeout=TIMEOUT)


def body(result):
    assert result.returncode == 0, (result.returncode, result.stdout, result.stderr)
    assert not result.stderr, result.stderr
    start = b'Interpreting...\n'
    end = b'Execution complete.\n'
    assert start in result.stdout and result.stdout.endswith(end), result.stdout
    return result.stdout.split(start, 1)[1][:-len(end)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compiler', required=True, type=Path)
    parser.add_argument('--interpreter', type=Path, help='reuse an already built interpreter')
    parser.add_argument('--output-dir', type=Path)
    options = parser.parse_args()
    compiler = options.compiler.resolve()
    if options.output_dir:
        options.output_dir = options.output_dir.resolve()
        options.output_dir.mkdir(parents=True, exist_ok=True)
    workspace = (nullcontext(str(options.output_dir)) if options.output_dir else
                 tempfile.TemporaryDirectory(prefix='qlang-interpreter-'))
    with workspace as tmp:
        work = Path(tmp)
        interpreter = options.interpreter.resolve() if options.interpreter else work / 'interpreter'
        if not options.interpreter:
            ir = work / 'interpreter.ll'
            emit(compiler, ROOT / 'bootstrapped/run_file.ql', ir)
            link(ir, interpreter)
        subprocess.run([sys.executable, str(ROOT / 'aot/run_argument_tests.py'),
                        '--interpreter', str(interpreter)], check=True, timeout=TIMEOUT)
        for name in ['t16_functions', 't17_bootstrap', 't19_literals', 't20_native_bridge', 't21_assignments', 't22_lifetimes', 't23_inline_values', 't24_call_buffers', 't25_numeric', 't26_extrema', 't27_native_calls', 't28_objects', 't29_arrays', 't30_strings', 't31_library_loading', 't32_value_access', 't33_builtin_bindings', 't34_numeric_syntax', 't35_scoped_modules', 't36_lazy_modules', 't41_math_library', 't43_number_library', 't48_object_library', 't49_raw_object_index', 't50_raw_value_type_checks', 't51_value_access_errors', 't52_expression_return', 't53_return_boundaries', 't54_json_stringify', 't45_native_function_members', 't46_number_literal_keys', 't47_finite_number_rendering']:
            source = ROOT / 'aot/tests' / (name + '.ql')
            expected = source.with_suffix('.expected').read_bytes()
            # Run outside the repository: interpreter dependencies must be in the
            # executable, and interpreted imports resolve at the source location.
            actual = body(execute(interpreter, source, cwd=work))
            assert actual == expected, (name, actual, expected)
            print('PASS native interpreter:', name, flush=True)
        result = body(execute(interpreter, ROOT / 'demo/type_gymnastics.ql', cwd=work))
        assert b'RESULT: 419/419 asserts passed\n' in result, result
        print('PASS native interpreter: 419 type-system assertions', flush=True)
        source = ROOT / 'aot/tests/t20_native_bridge.ql'
        ir = work / 'bridge.ll'; binary = work / 'bridge'
        emit(compiler, source, ir); link(ir, binary)
        result = subprocess.run([str(binary)], capture_output=True, timeout=TIMEOUT)
        assert result.returncode == 0 and not result.stderr, result
        assert result.stdout == source.with_suffix('.expected').read_bytes(), result.stdout
        print('PASS directly compiled native bridge contract', flush=True)

        # The calling convention is metadata on function values, including aliases,
        # bound methods and returned curried closures; user closures have no name.
        metadata = work / 'metadata.ql'
        metadata.write_text('''let f = (x) -> x;
println(isError(f.name));
println(println.name);
println(std.Object.keys.name);
println(std.Number.ldexp(2).name);
println([].add.name);
println(Error.raise.name);
''')
        emit(compiler, metadata, ir); link(ir, binary)
        result = subprocess.run([str(binary)], capture_output=True, timeout=TIMEOUT)
        assert result.returncode == 0 and not result.stderr, result
        assert result.stdout == b'true\nprintln\nObject.keys\nNumber.ldexp<curried>\nArray.add\nError.raise\n', result.stdout
        print('PASS native function metadata', flush=True)

        # Dynamic imports belong to interpreted execution, including imports in
        # functions and paths relative to the function's defining module.
        modules = work / 'modules'; modules.mkdir(exist_ok=True)
        (modules / 'value.ql').write_text('export { answer: 42 };')
        (modules / 'factory.ql').write_text('let load = () -> { let m = import ./value.ql; m.answer; }; export load;')
        source = work / 'dynamic.ql'
        source.write_text('let m = import ./modules/factory.ql; println(m.load());')
        assert body(execute(interpreter, source)) == b'42\n'
        print('PASS dynamic import at function definition path', flush=True)

        cases = [
            ('uninitialized', 'let x; x;', b'Uninitialized'),
            ('propagate', 'let x; x?; println("UNREACHABLE");', b'Uninitialized'),
            ('undeclared', 'missing;', b'UndefinedVariable'),
            ('assign-undeclared', 'missing = 1; println("UNREACHABLE");', b'UndefinedVariable'),
            ('assign-hidden', 'if true { let x = 1; }; x = 2; println("UNREACHABLE");', b'UndefinedVariable'),
            ('assign-member', 'missing.field = 1; println("UNREACHABLE");', b'UndefinedVariable'),
            ('assign-index', 'missing[0] = 1; println("UNREACHABLE");', b'UndefinedVariable'),
            ('assign-uninitialized-member', 'let x; x.field = 1; println("UNREACHABLE");', b'Uninitialized'),
            ('assign-uninitialized-index', 'let x; x[0] = 1; println("UNREACHABLE");', b'Uninitialized'),
            ('parse', 'let f = (1) -> 2; println("UNREACHABLE");', b'ParseError'),
            ('error', 'Error.raise("intentional");', b'Error: intentional'),
            ('read', None, b'IOError'),
        ]
        for name, text, kind in cases:
            source = work / (name + '.ql')
            if text is not None:
                source.write_text(text)
            else:
                source.unlink(missing_ok=True)
            result = execute(interpreter, source)
            assert result.returncode == 1 and kind in result.stderr, (name, result)
            output = result.stdout.split(b'Interpreting...\n')[-1]
            assert b'UNREACHABLE\n' not in output, (name, output)
            print('PASS native interpreter error:', name, flush=True)
        for text in ['let x; x = null; x;', 'let x; x ?? null;', 'println(Null.check(null));']:
            source = work / 'success.ql'; source.write_text(text)
            body(execute(interpreter, source))
        print('PASS initialized null and handled errors', flush=True)
        print('Native interpreter suite: ALL CHECKS PASS', flush=True)


if __name__ == '__main__':
    main()
