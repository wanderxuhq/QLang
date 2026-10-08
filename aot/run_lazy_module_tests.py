#!/usr/bin/env python3
"""Verify lazy cyclic graphs, active initialization cycles, and guard cleanup."""
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
    options = parser.parse_args(); compiler = options.compiler.resolve()
    with tempfile.TemporaryDirectory(prefix='qlang-lazy-modules-') as tmp:
        work = Path(tmp); tree = work/'source'; tree.mkdir()
        shutil.copytree(ROOT/'aot/tests/modules/lazy', tree/'modules/lazy')
        source = tree/'main.ql'; shutil.copyfile(ROOT/'aot/tests/t36_lazy_modules.ql', source)
        expected = (ROOT/'aot/tests/t36_lazy_modules.expected').read_bytes()
        if options.interpreter:
            assert body(execute(options.interpreter.resolve(), source, cwd=work)) == expected
            print('PASS native QLang core: lazy module contracts', flush=True)
        ir = work/'program.ll'; emit(compiler, source, ir)
        binaries = []
        for opt in (0, 2):
            binary = work/f'program-O{opt}'; link(ir, binary, opt=opt); binaries.append(binary)
        shutil.rmtree(tree)
        for binary in binaries:
            result = subprocess.run([binary], cwd=work, capture_output=True, timeout=TIMEOUT)
            assert result.returncode == 0 and result.stdout == expected and not result.stderr, result
            print('PASS lazy modules without source files:', binary.name, flush=True)
        tree.mkdir(); (tree/'lib').mkdir()
        for name, text in [
            ('active-root', 'import "./lib/../main.ql"; println("UNREACHABLE");'),
            ('inactive-root', 'if false { import "./main.ql"; }; println("OK");'),
        ]:
            source.write_text(text); emit(compiler, source, ir)
            for opt in (0, 2):
                binary = work/f'{name}-O{opt}'; link(ir, binary, opt=opt)
                result = subprocess.run([binary], cwd=work, capture_output=True, timeout=TIMEOUT)
                if name == 'active-root':
                    assert result.returncode == 1 and b'ImportCycle' in result.stderr and b'UNREACHABLE' not in result.stdout, result
                else:
                    assert result.returncode == 0 and result.stdout == b'OK\n' and not result.stderr, result
                print('PASS root cycle guard:', name, opt, flush=True)
    print('Lazy module suite: ALL CHECKS PASS', flush=True)


if __name__ == '__main__':
    main()
