#!/usr/bin/env python3
"""Array API contracts, stored values, identity search and invalid inputs at O0/O2."""
import argparse
from pathlib import Path
import subprocess
import tempfile

from native_link import link
from run_selfhost_tests import ROOT, TIMEOUT, emit
from run_interpreter_tests import body


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compiler', required=True, type=Path)
    parser.add_argument('--library', type=Path, help='verify an explicit portable ArrayLibrary module')
    parser.add_argument('--interpreter', type=Path, help='also verify through the native QLang interpreter')
    options = parser.parse_args()
    compiler = options.compiler.resolve()
    with tempfile.TemporaryDirectory(prefix='qlang-arrays-') as tmp:
        work = Path(tmp)
        source = ROOT / 'aot/tests/t29_arrays.ql'
        expected = source.with_suffix('.expected').read_bytes()
        prefix = ''
        if options.library:
            library = options.library.resolve()
            text = library.read_text()
            for forbidden in ('ql_mem_', 'readU64', 'writeU64', 'ql_alloc', 'std.Array.'):
                assert forbidden not in text, forbidden
            prefix = 'import ' + str(library) + ';\n'
            text = source.read_text().replace('std.Array.', 'ArrayLibrary.')
            source = work / 'portable-arrays.ql'; source.write_text(prefix + text)
        ir = work / 'arrays.ll'; emit(compiler, source, ir)
        for opt in (0, 2):
            binary = work / f'arrays-O{opt}'; link(ir, binary, opt=opt)
            result = subprocess.run([str(binary)], capture_output=True, timeout=TIMEOUT)
            assert result.returncode == 0 and not result.stderr, result
            assert result.stdout == expected, result.stdout
            print(f'PASS -O{opt}: Array validation, stored values, index boundaries and identity search', flush=True)
        if options.interpreter:
            result = subprocess.run([str(options.interpreter.resolve()), str(source)],
                                    cwd=work, capture_output=True, timeout=TIMEOUT)
            actual = body(result)
            assert actual == expected, actual
            print('PASS native QLang interpreter: same Array contracts', flush=True)
        cases = {
            'length': 'std.Array.length({})',
            'add': 'std.Array.add(42)',
            'push': 'std.Array.push(null)',
            'pop': 'std.Array.pop(false)',
            'get': 'std.Array.get("text")',
            'reverse': 'std.Array.reverse(x -> x)',
            'concat': 'std.Array.concat([])({})',
            'at': 'std.Array.at([], "0")',
        }
        probe = work / 'errors.ql'
        text = '\n'.join(f'if args[0] == "{name}" {{ ({code})?; }};' for name, code in cases.items())
        if options.library:
            text = text.replace('std.Array.', 'ArrayLibrary.')
        probe.write_text(prefix + text + '\nprintln("UNREACHABLE");\n')
        ir = work / 'errors.ll'; emit(compiler, probe, ir)
        for opt in (0, 2):
            binary = work / f'errors-O{opt}'; link(ir, binary, opt=opt)
            for name in cases:
                result = subprocess.run([str(binary), name], capture_output=True, timeout=TIMEOUT)
                assert result.returncode == 1 and b'TypeMismatch' in result.stderr, (name, result)
                assert not result.stdout, (name, result.stdout)
            print(f'PASS -O{opt}: eight unhandled errors exit with status 1, without crashing', flush=True)
        print('Array suite: ALL CHECKS PASS', flush=True)


if __name__ == '__main__':
    main()
