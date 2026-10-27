#!/usr/bin/env python3
"""Keep closures, cycles and large buffers live across native collections."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

from native_link import link

ROOT = Path(__file__).resolve().parent.parent
QLANG = Path(os.environ.get('QLANG', ROOT / 'target/release/qlang')).resolve()
TIMEOUT = int(os.environ.get('TEST_TIMEOUT', '240'))

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compiler', type=Path, help='reuse a native self-hosted compiler')
    options = parser.parse_args()
    source = ROOT / 'aot/tests/t18_gc.ql'
    expected = source.with_suffix('.expected').read_bytes()
    with tempfile.TemporaryDirectory(prefix='qlang-gc-') as tmp:
        ir = Path(tmp) / 'stress.ll'
        with ir.open('wb') as output:
            symbols = os.environ.get('QLANG_STDLIB_SYMBOLS')
            interface = os.environ.get('QLANG_STDLIB_INTERFACE')
            command = ([str(options.compiler.resolve()),
                        '--emit-llvm-split' if symbols else '--emit-llvm', str(source),
                        str(ROOT / 'aot/runtime.ql')] + ([str(symbols), str(interface or '-')] if symbols else []) if options.compiler else
                       [str(QLANG), 'aot/qlangc.ql', source.read_text(), str(source),
                        (ROOT / 'aot/runtime.ql').read_text()])
            subprocess.run(command, cwd=ROOT, stdout=output, check=True, timeout=TIMEOUT)
        for opt in ('-O0', '-O2'):
            allocator = Path(tmp) / ('allocator' + opt)
            subprocess.run(['clang', opt, '-fuse-ld=lld', '-Wl,--threads=1', '-Wl,--export-dynamic', '-Wall', '-Wextra', '-Werror',
                            'aot/tests/gc_allocator.c', 'aot/runtime.c', '-ldl', '-o', str(allocator)],
                           cwd=ROOT, check=True, timeout=TIMEOUT)
            subprocess.run([str(allocator)], check=True, timeout=TIMEOUT)
            print('PASS allocator roots and interior pointers', opt, flush=True)
            binary = Path(tmp) / ('stress' + opt)
            link(ir, binary, opt=int(opt[-1]), timeout=TIMEOUT)
            result = subprocess.run([str(binary)], capture_output=True, timeout=TIMEOUT)
            assert result.returncode == 0, (opt, result.returncode, result.stderr)
            assert result.stdout == expected, (opt, result.stdout, result.stderr)
            print('PASS GC stress', opt, flush=True)
    print('GC suite: ALL PASS')

if __name__ == '__main__':
    main()
