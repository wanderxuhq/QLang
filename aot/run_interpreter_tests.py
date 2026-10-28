#!/usr/bin/env python3
"""Compile and exercise the QLang interpreter without invoking the Rust runner."""
import argparse
import os
from concurrent.futures import ThreadPoolExecutor, as_completed
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



def _use_stdlib_object(compiler):
    """Compile the fixed runtime/stdlib prefix once and link it per fixture.

    Every fixture otherwise re-emits ~180k IR lines of runtime+stdlib and asks
    `clang -O2` to optimise them again. `stdlib_split.build_stdlib` caches the
    object by (compiler, runtime, bundle) hash, so a gate run pays for it once.
    """
    try:
        from stdlib_split import build_stdlib
        object_path, _symbols = build_stdlib(compiler)
        # The object supplies the library at link time, so the compiler must emit the
        # user part only (`--emit-llvm-split`); exporting just QLANG_STDLIB_OBJECT
        # leaves the emitter monolithic and every runtime/stdlib symbol is defined
        # twice (duplicate `__panic_exit` / `.strbox7` at link time).
        os.environ['QLANG_STDLIB_OBJECT'] = str(object_path)
        os.environ['QLANG_STDLIB_SYMBOLS'] = str(object_path.with_name('symbols.tsv'))
        interface = object_path.with_name('interface.txt')
        if interface.exists():
            os.environ['QLANG_STDLIB_INTERFACE'] = str(interface)
    except Exception as error:  # pragma: no cover - fall back to the monolithic link
        print(f'note: precompiled stdlib unavailable ({error}); linking monolithically', flush=True)
        os.environ.pop('QLANG_STDLIB_OBJECT', None)
        os.environ.pop('QLANG_STDLIB_SYMBOLS', None)
        os.environ.pop('QLANG_STDLIB_INTERFACE', None)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compiler', required=True, type=Path)
    parser.add_argument('--interpreter', type=Path, help='reuse an already built interpreter')
    parser.add_argument('--output-dir', type=Path)
    parser.add_argument('--jobs', type=int, default=1, help='fixtures to interpret in parallel (default 1)')
    options = parser.parse_args()
    compiler = options.compiler.resolve()
    _use_stdlib_object(compiler)
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
        def check_one(name):
            source = ROOT / 'aot/tests' / (name + '.ql')
            expected = source.with_suffix('.expected').read_bytes()
            # Run outside the repository: interpreter dependencies must be in the
            # executable, and interpreted imports resolve at the source location.
            actual = body(execute(interpreter, source, cwd=work))
            assert actual == expected, (name, actual, expected)
            print('PASS native interpreter:', name, flush=True)

        interpreter_fixtures = [
            't16_functions', 't17_bootstrap', 't19_literals', 't20_native_bridge',
            't21_assignments', 't22_lifetimes', 't23_inline_values', 't24_call_buffers',
            't25_numeric', 't26_extrema', 't27_native_calls', 't28_objects', 't29_arrays',
            't30_strings', 't31_library_loading', 't32_value_access', 't33_builtin_bindings',
            't34_numeric_syntax', 't35_scoped_modules', 't36_lazy_modules', 't41_math_library',
            't43_number_library', 't48_object_library', 't49_raw_object_index',
            't50_raw_value_type_checks', 't51_value_access_errors', 't52_expression_return',
            't53_return_boundaries', 't54_json_stringify', 't55_return_types',
            't56_result_annotations', 't57_assert', 't58_direct_calls', 't59_inline_pure',
            't60_raw_direct', 't61_known_safe', 't62_leaf_calls',
            't45_native_function_members', 't46_number_literal_keys',
            't47_finite_number_rendering',
        ]
        if options.jobs <= 1:
            for name in interpreter_fixtures:
                check_one(name)
        else:
            with ThreadPoolExecutor(max_workers=options.jobs) as pool:
                futures = [pool.submit(check_one, name) for name in interpreter_fixtures]
                for future in as_completed(futures):
                    future.result()
        assert_source = work / 'assert-fatal.ql'
        assert_source.write_text('println("before");\nassert(false, "boom");\nprintln("after");\n')
        result = execute(interpreter, assert_source, cwd=work)
        assert result.returncode == 1, (result.returncode, result.stdout, result.stderr)
        assert b'before\n' in result.stdout and b'after\n' not in result.stdout, result.stdout
        assert b'AssertionFailed: boom' in result.stderr, result.stderr
        print('PASS native interpreter: assert(false) is a fatal contract violation', flush=True)
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
            # Reading a not-definitely-initialized binding is a frontend error now.
            ('uninitialized', 'let x; x;', b'reading uninitialized variable: x'),
            ('propagate', 'let x; x?; println("UNREACHABLE");', b'reading uninitialized variable: x'),
            ('undeclared', 'missing;', b'UndefinedVariable'),
            ('assign-undeclared', 'missing = 1; println("UNREACHABLE");', b'UndefinedVariable'),
            ('assign-hidden', 'if true { let x = 1; }; x = 2; println("UNREACHABLE");', b'UndefinedVariable'),
            ('assign-member', 'missing.field = 1; println("UNREACHABLE");', b'UndefinedVariable'),
            ('assign-index', 'missing[0] = 1; println("UNREACHABLE");', b'UndefinedVariable'),
            ('assign-uninitialized-member', 'let x; x.field = 1; println("UNREACHABLE");', b'reading uninitialized variable: x'),
            ('assign-uninitialized-index', 'let x; x[0] = 1; println("UNREACHABLE");', b'reading uninitialized variable: x'),
            ('parse', 'let f = (1) -> 2; println("UNREACHABLE");', b'ParseError'),
            ('error', 'Error.raise("intentional");', b'Error: intentional'),
            # `??` does not make a read of a not-yet-initialized binding legal.
            ('coalesce-uninitialized', 'let x; x ?? null;', b'reading uninitialized variable: x'),
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
        for text in ['let x; x = null; x;', 'println(Null.check(null));']:
            source = work / 'success.ql'; source.write_text(text)
            body(execute(interpreter, source))
        print('PASS initialized null and handled errors', flush=True)
        print('Native interpreter suite: ALL CHECKS PASS', flush=True)


if __name__ == '__main__':
    main()
