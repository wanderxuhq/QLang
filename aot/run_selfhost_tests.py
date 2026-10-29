#!/usr/bin/env python3
"""Build a native QLang compiler; optionally verify its self-compilation fixed point."""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
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
    # 快路径:标准库对象 + QLang 链接器(opt/llc/ld.lld + 静态字符串校验)。
    # 没有对象(单模块 IR,里面已含 runtime)或工具没构建时,回落到 Python 校验链接。
    tool = ROOT / 'target' / 'tools' / 'link'
    object_path = os.environ.get('QLANG_STDLIB_OBJECT')
    if tool.exists() and object_path:
        command = [str(tool), str(ir), '-o', str(binary), '--stdlib-object', object_path]
        strings = Path(object_path).with_name('strings.tsv')
        stdlib_ir = Path(object_path).with_name('stdlib.ll')
        if strings.exists():
            command += ['--stdlib-ir', str(strings)]
        elif stdlib_ir.exists():
            command += ['--stdlib-ir', str(stdlib_ir)]
        result = subprocess.run(command, capture_output=True, text=True)
        if result.returncode != 0:
            raise RuntimeError(f'qlang link failed for {ir}:\n{result.stdout}{result.stderr}')
        return
    checked_link(ir, binary, timeout=TIMEOUT)

def emit(compiler, source, ir):
    # When a precompiled stdlib object is available the compiler emits the user
    # module only (`--emit-llvm-split`); the object supplies everything else.
    symbols = os.environ.get('QLANG_STDLIB_SYMBOLS')
    mod = os.environ.get('QLANG_STDLIB_MOD')
    args = [compiler, '--emit-llvm-split' if symbols else '--emit-llvm', source, RUNTIME]
    if symbols:
        args.append(symbols)
        # `-` = analyse the standard library from source (A/B control path).
        args.append(mod if mod else '-')
    with ir.open('wb') as output:
        run(args, stdout=output)

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


def run_program_tasks(compiler, tasks, work, jobs):
    """Compile+link+run independent fixtures, optionally in parallel.

    Each fixture owns its own `<name>.ll` / `<name>` inside `work`, so the tasks
    are independent; `native_link` already links into a private temp dir. Keep
    `--jobs 1` as the default so a plain run behaves exactly like before.
    """
    if jobs <= 1:
        for source, expected, name in tasks:
            check_program(compiler, source, expected, work, name)
        return
    with ThreadPoolExecutor(max_workers=jobs) as pool:
        futures = [pool.submit(check_program, compiler, source, expected, work, name)
                   for source, expected, name in tasks]
        for future in as_completed(futures):
            future.result()


def _bootstrap_tools(compiler):
    """Build target/tools/{stdlib,build,link,verify}（shell + clang，不用 Python）。"""
    script = ROOT / 'aot' / 'bootstrap.sh'
    if (ROOT / 'target' / 'tools' / 'stdlib').exists():
        return
    mode = '--self' if (ROOT / 'target' / 'tools' / 'link').exists() else '--compiler'
    command = [str(script), mode, str(compiler)] if mode == '--compiler' else [str(script), '--self', '--compiler', str(compiler)]
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError((result.stdout + result.stderr).strip()[-400:])

def _use_stdlib_object(compiler):
    """Compile the fixed runtime/stdlib prefix once and link it per fixture.

    Every fixture otherwise re-emits ~180k IR lines of runtime+stdlib and asks
    `clang -O2` to optimise them again. The object is cached by
    (compiler, runtime, bundle) hash, so a gate run pays for it once.

    Prefer the QLang builder (`target/tools/stdlib`), which produces the same
    four artifacts as `aot/stdlib_split.py`; keep the Python builder as the
    fallback for checkouts without a toolchain.
    """
    object_path = None
    try:
        _bootstrap_tools(compiler)
        result = subprocess.run([str(ROOT / 'target' / 'tools' / 'stdlib'), '--compiler', str(compiler)],
                                capture_output=True, text=True)
        if result.returncode != 0:
            raise RuntimeError((result.stdout + result.stderr).strip()[-400:])
        object_path = Path(result.stdout.strip().splitlines()[-1])
    except Exception as error:  # pragma: no cover - fall back to the Python builder
        print(f'note: QLang stdlib builder unavailable ({error}); using stdlib_split.py', flush=True)
        object_path = None
    if object_path is not None:
        os.environ['QLANG_STDLIB_OBJECT'] = str(object_path)
        os.environ['QLANG_STDLIB_SYMBOLS'] = str(object_path.with_name('symbols.tsv'))
        mod = object_path.with_name('mod.ql')
        if mod.exists():
            os.environ['QLANG_STDLIB_MOD'] = str(mod)
        return
    try:
        from stdlib_split import build_stdlib
        object_path, _symbols = build_stdlib(compiler)
        os.environ['QLANG_STDLIB_OBJECT'] = str(object_path)
        os.environ['QLANG_STDLIB_SYMBOLS'] = str(object_path.with_name('symbols.tsv'))
        mod = object_path.with_name('mod.ql')
        if mod.exists():
            os.environ['QLANG_STDLIB_MOD'] = str(mod)
        try:
            _bootstrap_tools(compiler)
        except Exception as error:  # pragma: no cover
            print(f'note: QLang toolchain unavailable ({error}); linking with native_link.py', flush=True)
    except Exception as error:  # pragma: no cover - fall back to the monolithic link
        print(f'note: precompiled stdlib unavailable ({error}); linking monolithically', flush=True)
        os.environ.pop('QLANG_STDLIB_OBJECT', None)
        os.environ.pop('QLANG_STDLIB_SYMBOLS', None)
        os.environ.pop('QLANG_STDLIB_MOD', None)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compiler', type=Path, help='reuse an already built stage-1 compiler')
    parser.add_argument('--self', action='store_true', help='also build stages 2/3 and require identical emitted IR')
    parser.add_argument('--output-dir', type=Path, help='retain generated compilers and IR in this directory')
    parser.add_argument('--jobs', type=int, default=1, help='fixtures to build in parallel (default 1)')
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
        _use_stdlib_object(stage1)
        check_rejections(stage1, work)
        source = ROOT / 'aot/tests/t16_functions.ql'
        expected = source.with_suffix('.expected').read_bytes()
        tasks = []
        tasks.append((source, expected, 'functions'))
        literals = ROOT / 'aot/tests/t19_literals.ql'
        tasks.append((literals, literals.with_suffix('.expected').read_bytes(), 'literals'))
        tasks.append((ROOT / 'bootstrapped/tests/function_ast.ql', b'PASS function AST contracts (15 valid, 10 invalid)\n', 'frontend'))
        tasks.append((ROOT / 'bootstrapped/tests/diagnostics.ql', b'PASS source diagnostics (39 invalid, 15 valid)\n', 'source-diagnostics'))
        return_scope = ROOT / 'bootstrapped/tests/return_scope.ql'
        tasks.append((return_scope, return_scope.with_suffix('.expected').read_bytes(), 'return-scope-frontend'))
        tasks.append((ROOT / 'bootstrapped/tests/ast_locations.ql', b'PASS AST locations (24 spans, 8 trivia cases)\n', 'ast-locations'))
        tasks.append((ROOT / 'bootstrapped/tests/source_origins.ql', b'PASS bundled source origins (5 spans, wrappers, diagnostics, library)\n', 'source-origins'))
        tasks.append((ROOT / 'bootstrapped/tests/numeric_syntax.ql', b'PASS numeric syntax frontend (38 valid, 19 invalid)\n', 'numeric-syntax-frontend'))
        values = ROOT / 'aot/tests/t23_inline_values.ql'
        tasks.append((values, values.with_suffix('.expected').read_bytes(), 'inline-values'))
        calls = ROOT / 'aot/tests/t24_call_buffers.ql'
        tasks.append((calls, calls.with_suffix('.expected').read_bytes(), 'call-buffers'))
        numeric = ROOT / 'aot/tests/t25_numeric.ql'
        tasks.append((numeric, numeric.with_suffix('.expected').read_bytes(), 'numeric'))
        extrema = ROOT / 'aot/tests/t26_extrema.ql'
        tasks.append((extrema, extrema.with_suffix('.expected').read_bytes(), 'extrema'))
        native_calls = ROOT / 'aot/tests/t27_native_calls.ql'
        tasks.append((native_calls, native_calls.with_suffix('.expected').read_bytes(), 'native-calls'))
        objects = ROOT / 'aot/tests/t28_objects.ql'
        tasks.append((objects, objects.with_suffix('.expected').read_bytes(), 'objects'))
        arrays = ROOT / 'aot/tests/t29_arrays.ql'
        tasks.append((arrays, arrays.with_suffix('.expected').read_bytes(), 'arrays'))
        strings = ROOT / 'aot/tests/t30_strings.ql'
        tasks.append((strings, strings.with_suffix('.expected').read_bytes(), 'portable-strings'))
        libraries = ROOT / 'aot/tests/t31_library_loading.ql'
        tasks.append((libraries, libraries.with_suffix('.expected').read_bytes(), 'library-loading'))
        access = ROOT / 'aot/tests/t32_value_access.ql'
        tasks.append((access, access.with_suffix('.expected').read_bytes(), 'value-access'))
        bindings = ROOT / 'aot/tests/t33_builtin_bindings.ql'
        tasks.append((bindings, bindings.with_suffix('.expected').read_bytes(), 'builtin-bindings'))
        syntax = ROOT / 'aot/tests/t34_numeric_syntax.ql'
        tasks.append((syntax, syntax.with_suffix('.expected').read_bytes(), 'numeric-syntax'))
        modules = ROOT / 'aot/tests/t35_scoped_modules.ql'
        tasks.append((modules, modules.with_suffix('.expected').read_bytes(), 'scoped-modules'))
        lazy = ROOT / 'aot/tests/t36_lazy_modules.ql'
        tasks.append((lazy, lazy.with_suffix('.expected').read_bytes(), 'lazy-modules'))
        math = ROOT / 'aot/tests/t41_math_library.ql'
        tasks.append((math, math.with_suffix('.expected').read_bytes(), 'portable-math-base'))
        number = ROOT / 'aot/tests/t43_number_library.ql'
        tasks.append((number, number.with_suffix('.expected').read_bytes(), 'portable-number'))
        members = ROOT / 'aot/tests/t45_native_function_members.ql'
        tasks.append((members, members.with_suffix('.expected').read_bytes(), 'native-function-members'))
        for name in ['t46_number_literal_keys', 't47_finite_number_rendering', 't48_object_library', 't49_raw_object_index', 't50_raw_value_type_checks', 't51_value_access_errors', 't52_expression_return', 't53_return_boundaries', 't54_json_stringify', 't55_return_types', 't56_result_annotations', 't57_assert', 't58_direct_calls', 't59_inline_pure', 't60_raw_direct', 't61_known_safe', 't62_leaf_calls']:
            fixture = ROOT / 'aot/tests' / (name + '.ql')
            tasks.append((fixture, fixture.with_suffix('.expected').read_bytes(), name))
        run_program_tasks(stage1, tasks, work, options.jobs)
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
