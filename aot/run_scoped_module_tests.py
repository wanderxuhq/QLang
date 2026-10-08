#!/usr/bin/env python3
"""Exercise lexical imports/exports and execute with the source tree removed."""
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile
from native_link import link
from run_selfhost_tests import ROOT, TIMEOUT, emit
from run_interpreter_tests import body, execute


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compiler', required=True, type=Path)
    parser.add_argument('--interpreter', type=Path)
    options = parser.parse_args()
    compiler = options.compiler.resolve()
    with tempfile.TemporaryDirectory(prefix='qlang-scoped-modules-') as tmp:
        work = Path(tmp); tree = work / 'source'; tree.mkdir()
        shutil.copytree(ROOT/'aot/tests/modules/scoped', tree/'modules/scoped')
        source = tree/'main.ql'
        shutil.copyfile(ROOT/'aot/tests/t35_scoped_modules.ql', source)
        expected = (ROOT/'aot/tests/t35_scoped_modules.expected').read_bytes()
        if options.interpreter:
            assert body(execute(options.interpreter.resolve(), source, cwd=work)) == expected
            print('PASS scoped modules: native QLang core', flush=True)
        ir = work/'program.ll'; emit(compiler, source, ir)
        binaries = []
        for opt in (0, 2):
            binary = work/f'program-O{opt}'; link(ir, binary, opt=opt)
            binaries.append(binary)
        shutil.rmtree(tree)
        for binary in binaries:
            result = subprocess.run([binary], cwd=work, capture_output=True, timeout=TIMEOUT)
            assert result.returncode == 0 and result.stdout == expected and not result.stderr, result
            print(f'PASS {binary.name}: lexical module contracts, source tree removed', flush=True)
        tree.mkdir()
        (tree/'value.ql').write_text('export let answer = 42;')
        for name, text in [
            ('function-local', 'let f = () -> { import "./value.ql"; }; println(answer);'),
            ('block-local', 'if true { import "./value.ql"; }; println(answer);'),
            ('unexecuted-name', 'let f = () -> { export let private = 1; }; println(private);'),
        ]:
            source.write_text(text)
            result = subprocess.run([compiler, '--emit-llvm', source, ROOT/'aot/runtime.ql'],
                                    capture_output=True, timeout=TIMEOUT)
            assert result.returncode == 1 and not result.stdout and b'CompileError' in result.stderr, (name, result)
            print('PASS module scope rejection:', name, flush=True)
    print('Scoped module suite: ALL CHECKS PASS', flush=True)


if __name__ == '__main__':
    main()
