#!/usr/bin/env python3
"""Cross-file AOT gates, including execution after all input files are removed."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from concurrent.futures import ThreadPoolExecutor

ROOT = Path(__file__).resolve().parent.parent
# 工具链只用 QLang 自己:编译器 stage2 + 链接器 tools/link。
# 早先这里默认 target/debug/qlang(Rust 宿主),那条路跑 boot 会挂(见 AGENTS §2.1);
# 现在 boot 腿用**native 解释器**(由 stage2 编译 bootstrapped/run_file.ql 得到)。
COMPILER = Path(os.environ.get('QLANG_COMPILER', ROOT / 'target/selfhost/stage2')).resolve()
LINKER = Path(os.environ.get('QLANG_LINKER', ROOT / 'target/tools/link')).resolve()
RUNTIME = ROOT / 'aot/runtime.ql'
TIMEOUT = int(os.environ.get('TEST_TIMEOUT', '300'))

def run(args, **kwargs):
    capture = not ('stdout' in kwargs)
    return subprocess.run([str(a) for a in args], cwd=kwargs.pop('cwd', ROOT),
                          capture_output=capture, timeout=TIMEOUT, **kwargs)

def compile_source(source, binary):
    ir = Path(str(binary) + '.ll')
    with ir.open('wb') as out:
        p = run([COMPILER, '--emit-llvm', source, RUNTIME], stdout=out, stderr=subprocess.PIPE)
    if p.returncode != 0:
        return p
    return run([LINKER, ir, '-o', binary])

_INTERPRETER = []

def interpreter():
    """native 解释器:把 bootstrapped/run_file.ql 编成可执行(stage2 + tools/link)。"""
    if _INTERPRETER:
        return _INTERPRETER[0]
    path = Path(os.environ.get('QLANG_INTERPRETER', ROOT / 'target/native-interpreter/interpreter'))
    # Reuse only a same-source interpreter: a stale binary silently turns the
    # boot leg into a mixed-source baseline (AGENTS trap #3).
    sources = [ROOT / 'aot/runtime.ql'] + sorted((ROOT / 'bootstrapped').glob('*.ql'))
    stale = path.exists() and any(src.stat().st_mtime > path.stat().st_mtime for src in sources)
    if not path.exists() or stale:
        path.parent.mkdir(parents=True, exist_ok=True)
        ir = path.parent / 'interpreter.ll'
        with ir.open('wb') as out:
            p = run([COMPILER, '--emit-llvm', ROOT / 'bootstrapped/run_file.ql', RUNTIME], stdout=out, stderr=subprocess.PIPE)
        assert p.returncode == 0, p.stderr.decode()
        p = run([LINKER, ir, '-o', path])
        assert p.returncode == 0, p.stderr.decode()
        ir.unlink(missing_ok=True)
    _INTERPRETER.append(path)
    return path

def boot_output(source):
    """解释器跑一遍,只要程序自身的输出。

    末尾可能跟"未处理错误"的诊断(语言契约:顶层未处理错误 ⇒ exit 1,例如 t15 最后一条语句
    把 String 赋给 Number 注解,产生 Error 值)—— 那不是输出,截掉它,退出码留给调用方断言。
    """
    p = run([interpreter(), source])
    assert p.returncode in (0, 1), p.stderr.decode()
    body = p.stdout.split(b'Interpreting...\n', 1)[1]
    return body.split(b'Execution complete.', 1)[0]

def main():
    with tempfile.TemporaryDirectory(prefix='qlang-modules-') as tmp:
        work = Path(tmp)
        source = work / 'input'
        source.mkdir()
        shutil.copytree(ROOT / 'aot/tests/modules', source / 'modules')
        entry = source / 'main.ql'
        shutil.copyfile(ROOT / 'aot/tests/t15_modules.ql', entry)
        expected = boot_output(entry)
        binary = work / 'standalone'
        p = compile_source(entry, binary)
        assert p.returncode == 0, p.stderr.decode()
        shutil.rmtree(source)
        native = run([binary], cwd=work)
        # t15 最后一条语句产生未处理 Error ⇒ 语言契约是 exit 1;两个引擎都必须一致。
        assert native.returncode in (0, 1) and native.stdout == expected, native.stderr.decode()
        print('PASS modules: BOOT/NATIVE, inputs deleted before native execution', flush=True)

        source.mkdir()
        (source / 'bad.ql').write_text('let zero = 0; export let hidden = 1; 1 / zero;')
        entry.write_text('import "./bad.ql";')
        p = compile_source(entry, binary)
        assert p.returncode == 0, p.stderr.decode()
        for args in [[binary]]:
            p = run(args)
            assert p.returncode == 1 and b'DivisionByZero' in p.stderr, p.stderr.decode()
        # The boot interpreter deliberately unwraps an unhandled initialization
        # error at the process boundary (bootstrapped/run_file.ql), matching the
        # native exit status asserted above.
        boot = run([interpreter(), entry])
        assert boot.returncode == 1 and b'DivisionByZero' in boot.stdout + boot.stderr, (boot.stdout, boot.stderr)
        print('PASS modules: unhandled initialization error and exit status', flush=True)

        (source / 'lib').mkdir()
        (source / 'lib/value.ql').write_text('export let value = 42;')
        (source / 'lib/loader.ql').write_text('let load = () -> { let m = import "./value.ql"; m.value; }; export load;')
        entry.write_text('import "./lib/loader.ql"; println(load());')
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
