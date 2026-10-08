#!/usr/bin/env python3
"""Cross-file AOT gates, including execution after all input files are removed."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from concurrent.futures import ThreadPoolExecutor

ROOT = Path(__file__).resolve().parent.parent
QLANG = Path(os.environ.get('QLANG', ROOT / 'target/debug/qlang')).resolve()
TIMEOUT = int(os.environ.get('TEST_TIMEOUT', '180'))
CHECK_RUST = os.environ.get('QLANG_CHECK_RUST', '0') == '1'

def run(args, **kwargs):
    return subprocess.run([str(a) for a in args], cwd=kwargs.pop('cwd', ROOT), capture_output=True, timeout=TIMEOUT, **kwargs)

def compile_source(source, binary):
    return run([QLANG, '--compile', source, '-o', binary])

def boot_output(source):
    p = run([QLANG, 'bootstrapped/run_file.ql', source])
    assert p.returncode == 0, p.stderr.decode()
    return p.stdout.split(b'Interpreting...\n', 1)[1].replace(b'Execution complete.\n', b'')

def main():
    with tempfile.TemporaryDirectory(prefix='qlang-modules-') as tmp:
        work = Path(tmp)
        source = work / 'input'
        source.mkdir()
        shutil.copytree(ROOT / 'aot/tests/modules', source / 'modules')
        entry = source / 'main.ql'
        shutil.copyfile(ROOT / 'aot/tests/t15_modules.ql', entry)
        expected = boot_output(entry)
        if CHECK_RUST:
            host = run([QLANG, entry])
            assert host.returncode == 0 and host.stdout == expected, ('Rust compatibility', host.stderr)
        binary = work / 'standalone'
        p = compile_source(entry, binary)
        assert p.returncode == 0, p.stderr.decode()
        shutil.rmtree(source)
        native = run([binary], cwd=work)
        assert native.returncode == 0 and native.stdout == expected, native.stderr.decode()
        print('PASS modules: BOOT/NATIVE, inputs deleted before native execution', flush=True)

        source.mkdir()
        (source / 'bad.ql').write_text('export let hidden = 1; 1 / 0;')
        entry.write_text('import "./bad.ql";')
        p = compile_source(entry, binary)
        assert p.returncode == 0, p.stderr.decode()
        for args in ([[binary], [QLANG, entry]] if CHECK_RUST else [[binary]]):
            p = run(args)
            assert p.returncode == 1 and b'DivisionByZero' in p.stderr, p.stderr.decode()
        # The boot interpreter deliberately unwraps an unhandled initialization
        # error at the process boundary (bootstrapped/run_file.ql), matching the
        # native exit status asserted above.
        boot = run([QLANG, 'bootstrapped/run_file.ql', entry])
        assert boot.returncode == 1 and b'DivisionByZero' in boot.stdout + boot.stderr, (boot.stdout, boot.stderr)
        print('PASS modules: unhandled initialization error and exit status', flush=True)

        (source / 'lib').mkdir()
        (source / 'lib/value.ql').write_text('export let value = 42;')
        (source / 'lib/loader.ql').write_text('let load = () -> { let m = import "./value.ql"; m.value; }; export load;')
        entry.write_text('import "./lib/loader.ql"; println(load());')
        if CHECK_RUST:
            host = run([QLANG, entry])
            assert host.returncode == 0 and host.stdout == b'42\n'
        assert boot_output(entry) == b'42\n'
        p = compile_source(entry, binary)
        assert p.returncode == 0, p.stderr.decode()
        native = run([binary], cwd=work)
        assert native.returncode == 0 and native.stdout == b'42\n', native
        print('PASS modules: BOOT/NATIVE function import uses definition path', flush=True)

        # A cyclic static graph may be lazy. Reject only executed re-entry.
        for name, text, dependencies in [
            ('cycle', 'import "./lib/../main.ql";', {'lib/.keep': ''}),
            ('transitive-cycle', 'import "./a.ql";', {'a.ql': 'import "./b.ql";', 'b.ql': 'import "./a.ql";'}),
        ]:
            base = work/name; base.mkdir()
            for path, contents in dependencies.items():
                file = base/path; file.parent.mkdir(parents=True, exist_ok=True); file.write_text(contents)
            src = base/'main.ql'; src.write_text(text); exe = base/'artifact'
            result = compile_source(src, exe)
            assert result.returncode == 0, (name, result)
            result = run([exe], cwd=work)
            assert result.returncode == 1 and b'ImportCycle' in result.stderr, (name, result)
            print('PASS module initialization cycle:', name, flush=True)

        cases = [
            ('missing', 'import "./missing.ql";', {}),
            ('syntax', 'import "./bad.ql";', {'bad.ql': 'let x = ;'}),
            ('private', 'let secret = 42; import "./lib.ql";', {'lib.ql': 'export let value = secret;'}),
            ('hidden-export', 'import "./lib.ql"; println(secret);', {'lib.ql': 'let secret = 1; export let public = 2;'}),
            ('interpolated-path', 'import "${1}.ql";', {}),
            ('empty-path', 'import "";', {}),
        ]
        def reject(case):
            name, text, dependencies = case
            base = work / name; base.mkdir()
            for path, contents in dependencies.items():
                file = base / path; file.parent.mkdir(parents=True, exist_ok=True); file.write_text(contents)
            src = base / 'main.ql'; src.write_text(text)
            exe = base / 'artifact'
            p = compile_source(src, exe)
            assert p.returncode == 1 and b'CompileError' in p.stderr and not exe.exists(), (name, p.stdout, p.stderr)
            return 'PASS modules: reject ' + name
        with ThreadPoolExecutor(max_workers=int(os.environ.get('QLANG_TEST_JOBS', '1'))) as pool:
            for message in pool.map(reject, cases): print(message, flush=True)
    print('Module suite: ALL PASS')

if __name__ == '__main__':
    main()
