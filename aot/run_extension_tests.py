#!/usr/bin/env python3
"""Build host before independent QLang DSOs; execute with all sources removed."""
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile
from native_link import link
from run_selfhost_tests import ROOT, TIMEOUT


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compiler', required=True, type=Path)
    parser.add_argument('--keep', type=Path)
    options = parser.parse_args()
    compiler = options.compiler.resolve()
    temporary = None
    if options.keep:
        work = options.keep.resolve()
        if work.exists() and any(work.iterdir()):
            parser.error('--keep must name an empty output directory')
        work.mkdir(parents=True, exist_ok=True)
    else:
        temporary = tempfile.TemporaryDirectory(prefix='qlang-extensions-'); work = Path(temporary.name)
    try:
        source = work/'source'; source.mkdir(exist_ok=True)
        shutil.copytree(ROOT/'aot/tests/extensions', source, dirs_exist_ok=True)
        shutil.copyfile(ROOT/'aot/tests/t37_extensions.ql', source/'host.ql')
        def emit(name, mode):
            ir = work/(name+'.ll')
            with ir.open('wb') as output:
                subprocess.run([compiler, mode, source/(name+'.ql'), ROOT/'aot/runtime.ql'],
                               stdout=output, check=True, timeout=TIMEOUT)
            return ir
        # No extension binary exists at host compilation/link time.
        host = emit('host', '--emit-llvm')
        for opt in (0, 2):
            link(host, work/f'host-O{opt}', opt=opt, timeout=TIMEOUT)
        print('PASS compiled hosts before extensions existed', flush=True)
        for name in ('plugin', 'second', 'failure', 'cycle'):
            ir = emit(name, '--emit-module')
            # The DSO must import allocator leaves, not carry another runtime.
            text = ir.read_text()
            assert 'define i32 @main' not in text and 'define ptr @ql_alloc' not in text
            for opt in (0, 2):
                link(ir, work/f'{name}-O{opt}.so', opt=opt, timeout=TIMEOUT, shared=True)
            print('PASS independent extension:', name, flush=True)
        original = (work/'second.ll').read_text()
        bad = work/'wrong-abi.ll'
        assert r'\71\6C\61\6E\67\2D\6E\61\74\69\76\65\2D\76\31' in original
        bad.write_text(original.replace(r'\71\6C\61\6E\67\2D\6E\61\74\69\76\65\2D\76\31',
                                        r'\71\6C\61\6E\67\2D\6E\61\74\69\76\65\2D\76\39'))
        link(bad, work/'wrong-abi.so', timeout=TIMEOUT, shared=True)
        noentry = work/'no-entry.ll'
        noentry.write_text(original.replace('@qlang_extension_init_v1(', '@not_the_entry('))
        link(noentry, work/'no-entry.so', timeout=TIMEOUT, shared=True)
        (work/'not-native.so').write_text('println("must not execute source");')
        # Leave just deployment directories, no QLang sources.
        for file in source.glob('*.ql'): file.unlink()
        expected = (ROOT/'aot/tests/t37_extensions.expected').read_bytes()
        for opt in (0, 2):
            shutil.copyfile(work/f'cycle-O{opt}.so', source/'cycle.so')
            paths = [work/f'plugin-O{opt}.so', work/f'second-O{opt}.so', work/f'failure-O{opt}.so',
                     source/'cycle.so', work/'wrong-abi.so', work/'not-native.so', work/'no-entry.so']
            # The process cwd differs from every defining source directory.
            for hostopt in (0, 2):
                result = subprocess.run([work/f'host-O{hostopt}', *paths], cwd='/tmp',
                                        capture_output=True, timeout=TIMEOUT)
                assert result.returncode == 0 and result.stdout == expected and not result.stderr, result
                print(f'PASS host O{hostopt} / extensions O{opt}: 28 contracts, sources removed', flush=True)
        print('Native extension suite: ALL CHECKS PASS', flush=True)
    finally:
        if temporary: temporary.cleanup()


if __name__ == '__main__':
    main()
