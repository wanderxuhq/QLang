#!/usr/bin/env python3
"""Build a native QLang compiler; optionally verify its self-compilation fixed point."""
import argparse
from contextlib import nullcontext
import os
from pathlib import Path
import subprocess
import tempfile

from native_link import link as checked_link

ROOT = Path(__file__).resolve().parent.parent
QLANG = Path(os.environ.get('QLANG', ROOT / 'target/release/qlang')).resolve()
TIMEOUT = int(os.environ.get('TEST_TIMEOUT', '600'))
RUNTIME = ROOT / 'aot/runtime.ql'
COMPILER = ROOT / 'aot/qlangc.ql'

def run(command, **kwargs):
    result = subprocess.run([str(x) for x in command], cwd=ROOT, timeout=TIMEOUT, **kwargs)
    if result.returncode:
        raise RuntimeError(f'command failed ({result.returncode}): {command[0]}')
    return result

def link(ir, binary):
    checked_link(ir, binary, timeout=TIMEOUT)

def emit(compiler, source, ir):
    with ir.open('wb') as output:
        run([compiler, '--emit-llvm', source, RUNTIME], stdout=output)

def bootstrap(ir, binary):
    with ir.open('wb') as output:
        run([QLANG, COMPILER, COMPILER.read_text(), COMPILER, RUNTIME.read_text()], stdout=output)
    link(ir, binary)

def check_program(compiler, source, expected, work, name):
    ir = work / (name + '.ll'); binary = work / name
    emit(compiler, source, ir)
    link(ir, binary)
    result = run([binary], capture_output=True)
    assert result.stdout == expected, (name, result.stdout, result.stderr)
    print('PASS native compiler:', name, flush=True)

def check_assert_fatal(compiler, work):
    source = work / 'assert-fatal.ql'
    source.write_text('println("before");\nassert(false, "boom");\nprintln("after");\n')
    ir = work / 'assert-fatal.ll'; binary = work / 'assert-fatal'
    emit(compiler, source, ir); link(ir, binary)
    # A fatal contract violation exits 1 by design; do not use run(), which
    # treats any nonzero status as an infrastructure failure.
    result = subprocess.run([str(binary)], capture_output=True, timeout=TIMEOUT)
    assert result.returncode == 1, (result.returncode, result.stdout, result.stderr)
    assert result.stdout == b'before\n', result.stdout
    assert b'AssertionFailed: boom' in result.stderr, result.stderr
    print('PASS native compiler: assert(false) is a fatal contract violation', flush=True)

def check_rejections(compiler, work):
    for name, text in [('undeclared', 'println(missing);'),
                       ('private-runtime-read', 'println(__arr_add);'),
                       ('private-runtime-assign', '__arr_add = 1;'),
                       ('unbound-Type', 'println(Type);'),
                       ('missing-module', 'import "./missing.ql";'),
                       ('invalid-parameter', 'let f = (1) -> 2;')]:
        source = work / (name + '.ql'); source.write_text(text)
        result = subprocess.run([str(compiler), '--emit-llvm', str(source), str(RUNTIME)],
                                cwd=ROOT, capture_output=True, timeout=TIMEOUT)
        assert result.returncode == 1 and b'CompileError' in result.stderr, (name, result.returncode, result.stderr)
        assert not result.stdout, (name, 'emitted IR on failure')
        print('PASS native compiler rejection:', name, flush=True)
    source = work / 'empty.ql'; source.write_text('')
    runtime = work / 'incomplete-runtime.ql'; runtime.write_text('let args = [];')
    result = subprocess.run([str(compiler), '--emit-llvm', str(source), str(runtime)],
                            cwd=ROOT, capture_output=True, timeout=TIMEOUT)
    assert result.returncode == 1 and b'CompileError' in result.stderr and not result.stdout, result
    print('PASS native compiler rejection: incomplete runtime', flush=True)

def check_return_scope_rejections(compiler, work):
    message = b'return is only allowed inside a function'

    def reject(name, text, mode='--emit-llvm', source_path=None, diagnostic_path=None):
        source = source_path or (work / (name + '.ql'))
        source.parent.mkdir(parents=True, exist_ok=True)
        source.write_text(text)
        result = subprocess.run([str(compiler), mode, str(source), str(RUNTIME)],
                                cwd=ROOT, capture_output=True, timeout=TIMEOUT)
        assert result.returncode == 1 and not result.stdout, (name, result)
        assert b'CompileError' in result.stderr and message in result.stderr, (name, result.stderr)
        origin = diagnostic_path or source
        assert f'{origin}:1:1:'.encode() in result.stderr, (name, origin, result.stderr)
        print('PASS native compiler rejection:', name, flush=True)

    # Script top level and --emit-module both have module/script scope even
    # though imported modules are internally emitted through a factory.
    reject('return-top-level', 'return 1;')
    reject('return-emit-module', 'return 1;', '--emit-module')

    # Import discovery also walks imports placed in function bodies. A module's
    # own top level remains script scope when loaded from a user function.
    modules = work / 'return-modules'
    bad_module = modules / 'bad.ql'
    bad_module.parent.mkdir(parents=True, exist_ok=True)
    bad_module.write_text('return 2;')
    reject('return-import-direct', 'import "./bad.ql";', source_path=modules / 'direct.ql',
           diagnostic_path=bad_module)
    reject('return-import-from-function',
           'let load = () -> { import "./bad.ql"; }; load();',
           source_path=modules / 'from-function.ql', diagnostic_path=bad_module)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compiler', type=Path, help='reuse an already built stage-1 compiler')
    parser.add_argument('--self', action='store_true', help='also build stages 2/3 and require identical emitted IR')
    parser.add_argument('--output-dir', type=Path, help='retain generated compilers and IR in this directory')
    options = parser.parse_args()
    if options.output_dir:
        options.output_dir = options.output_dir.resolve()
        options.output_dir.mkdir(parents=True, exist_ok=True)
    workspace = nullcontext(str(options.output_dir)) if options.output_dir else tempfile.TemporaryDirectory(prefix='qlang-selfhost-')
    with workspace as tmp:
        work = Path(tmp)
        stage1 = options.compiler.resolve() if options.compiler else work / 'stage1'
        if not options.compiler:
            bootstrap(work / 'stage1.ll', stage1)
        check_rejections(stage1, work)
        source = ROOT / 'aot/tests/t16_functions.ql'
        expected = source.with_suffix('.expected').read_bytes()
        check_program(stage1, source, expected, work, 'functions')
        literals = ROOT / 'aot/tests/t19_literals.ql'
        check_program(stage1, literals, literals.with_suffix('.expected').read_bytes(), work, 'literals')
        check_program(stage1, ROOT / 'bootstrapped/tests/function_ast.ql',
                      b'PASS function AST contracts (15 valid, 10 invalid)\n', work, 'frontend')
        check_program(stage1, ROOT / 'bootstrapped/tests/diagnostics.ql',
                      b'PASS source diagnostics (39 invalid, 15 valid)\n', work, 'source-diagnostics')
        return_scope = ROOT / 'bootstrapped/tests/return_scope.ql'
        check_program(stage1, return_scope,
                      return_scope.with_suffix('.expected').read_bytes(), work, 'return-scope-frontend')
        check_program(stage1, ROOT / 'bootstrapped/tests/ast_locations.ql',
                      b'PASS AST locations (24 spans, 8 trivia cases)\n', work, 'ast-locations')
        check_program(stage1, ROOT / 'bootstrapped/tests/source_origins.ql',
                      b'PASS bundled source origins (5 spans, wrappers, diagnostics, library)\n', work, 'source-origins')
        check_program(stage1, ROOT / 'bootstrapped/tests/numeric_syntax.ql',
                      b'PASS numeric syntax frontend (38 valid, 19 invalid)\n', work, 'numeric-syntax-frontend')
        values = ROOT / 'aot/tests/t23_inline_values.ql'
        check_program(stage1, values, values.with_suffix('.expected').read_bytes(), work, 'inline-values')
        calls = ROOT / 'aot/tests/t24_call_buffers.ql'
        check_program(stage1, calls, calls.with_suffix('.expected').read_bytes(), work, 'call-buffers')
        numeric = ROOT / 'aot/tests/t25_numeric.ql'
        check_program(stage1, numeric, numeric.with_suffix('.expected').read_bytes(), work, 'numeric')
        extrema = ROOT / 'aot/tests/t26_extrema.ql'
        check_program(stage1, extrema, extrema.with_suffix('.expected').read_bytes(), work, 'extrema')
        native_calls = ROOT / 'aot/tests/t27_native_calls.ql'
        check_program(stage1, native_calls, native_calls.with_suffix('.expected').read_bytes(), work, 'native-calls')
        objects = ROOT / 'aot/tests/t28_objects.ql'
        check_program(stage1, objects, objects.with_suffix('.expected').read_bytes(), work, 'objects')
        arrays = ROOT / 'aot/tests/t29_arrays.ql'
        check_program(stage1, arrays, arrays.with_suffix('.expected').read_bytes(), work, 'arrays')
        strings = ROOT / 'aot/tests/t30_strings.ql'
        check_program(stage1, strings, strings.with_suffix('.expected').read_bytes(), work, 'portable-strings')
        libraries = ROOT / 'aot/tests/t31_library_loading.ql'
        check_program(stage1, libraries, libraries.with_suffix('.expected').read_bytes(), work, 'library-loading')
        access = ROOT / 'aot/tests/t32_value_access.ql'
        check_program(stage1, access, access.with_suffix('.expected').read_bytes(), work, 'value-access')
        bindings = ROOT / 'aot/tests/t33_builtin_bindings.ql'
        check_program(stage1, bindings, bindings.with_suffix('.expected').read_bytes(), work, 'builtin-bindings')
        syntax = ROOT / 'aot/tests/t34_numeric_syntax.ql'
        check_program(stage1, syntax, syntax.with_suffix('.expected').read_bytes(), work, 'numeric-syntax')
        modules = ROOT / 'aot/tests/t35_scoped_modules.ql'
        check_program(stage1, modules, modules.with_suffix('.expected').read_bytes(), work, 'scoped-modules')
        lazy = ROOT / 'aot/tests/t36_lazy_modules.ql'
        check_program(stage1, lazy, lazy.with_suffix('.expected').read_bytes(), work, 'lazy-modules')
        math = ROOT / 'aot/tests/t41_math_library.ql'
        check_program(stage1, math, math.with_suffix('.expected').read_bytes(), work, 'portable-math-base')
        number = ROOT / 'aot/tests/t43_number_library.ql'
        check_program(stage1, number, number.with_suffix('.expected').read_bytes(), work, 'portable-number')
        members = ROOT / 'aot/tests/t45_native_function_members.ql'
        check_program(stage1, members, members.with_suffix('.expected').read_bytes(), work, 'native-function-members')
        for name in ['t46_number_literal_keys', 't47_finite_number_rendering', 't48_object_library', 't49_raw_object_index', 't50_raw_value_type_checks', 't51_value_access_errors', 't52_expression_return', 't53_return_boundaries', 't54_json_stringify', 't55_return_types', 't56_result_annotations', 't57_assert', 't58_direct_calls', 't59_inline_pure', 't60_raw_direct', 't61_known_safe']:
            fixture = ROOT / 'aot/tests' / (name + '.ql')
            check_program(stage1, fixture, fixture.with_suffix('.expected').read_bytes(), work, name)
        check_assert_fatal(stage1, work)
        check_return_scope_rejections(stage1, work)
        if options.self:
            second = work / 'stage2.ll'; third = work / 'stage3.ll'; stage2 = work / 'stage2'
            emit(stage1, COMPILER, second)
            link(second, stage2)
            emit(stage2, COMPILER, third)
            assert second.read_bytes() == third.read_bytes(), 'stage 2/3 LLVM IR differs'
            print('PASS self-compilation: stage 2/3 LLVM IR identical', flush=True)
            check_program(stage2, source, expected, work, 'stage2-functions')
        print('Selfhost suite: ALL REQUESTED CHECKS PASS')

if __name__ == '__main__':
    main()
