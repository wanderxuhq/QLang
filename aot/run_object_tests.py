#!/usr/bin/env python3
"""Object API contracts and recoverable invalid-receiver failures at O0/O2."""
import argparse
from pathlib import Path
import subprocess
import tempfile

from native_link import link
from run_selfhost_tests import ROOT, TIMEOUT, emit


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compiler', required=True, type=Path)
    options = parser.parse_args()
    compiler = options.compiler.resolve()
    with tempfile.TemporaryDirectory(prefix='qlang-objects-') as tmp:
        work = Path(tmp)
        source = ROOT / 'aot/tests/t28_objects.ql'
        ir = work / 'objects.ll'; emit(compiler, source, ir)
        for opt in (0, 2):
            binary = work / f'objects-O{opt}'; link(ir, binary, opt=opt)
            result = subprocess.run([str(binary)], capture_output=True, timeout=TIMEOUT)
            assert result.returncode == 0 and not result.stderr, result
            assert result.stdout == source.with_suffix('.expected').read_bytes(), result.stdout
            print(f'PASS -O{opt}: Object receiver/key validation and stored-value contracts', flush=True)
        cases = {
            'keys': 'std.Object.keys([])',
            'values': 'std.Object.values(42)',
            'merge-first': 'std.Object.merge(false)',
            'merge-second': 'std.Object.merge({})(null)',
            'hasOwn': 'std.Object.hasOwn("text")',
            'get': 'std.Object.get(x -> x)',
            'field-receiver': 'std.Object.field([], "x")',
            'field-key': 'std.Object.field({}, {})',
        }
        probe = work / 'errors.ql'
        probe.write_text('\n'.join(f'if args[0] == "{name}" {{ ({code})?; }};' for name, code in cases.items())
                         + '\nprintln("UNREACHABLE");\n')
        ir = work / 'errors.ll'; emit(compiler, probe, ir)
        for opt in (0, 2):
            binary = work / f'errors-O{opt}'; link(ir, binary, opt=opt)
            for name in cases:
                result = subprocess.run([str(binary), name], capture_output=True, timeout=TIMEOUT)
                assert result.returncode == 1 and b'TypeMismatch' in result.stderr, (name, result)
                assert not result.stdout, (name, result.stdout)
            print(f'PASS -O{opt}: eight unhandled errors exit with status 1, without crashing', flush=True)
        print('Object suite: ALL CHECKS PASS', flush=True)


if __name__ == '__main__':
    main()
