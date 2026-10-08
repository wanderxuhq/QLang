#!/usr/bin/env python3
"""Verify compiler-proven temporary/frame lifetimes, including allocation growth."""
import argparse
from pathlib import Path
import re
import resource
import subprocess
import tempfile

from native_link import validate
from run_selfhost_tests import ROOT, TIMEOUT, emit


def limited_stack():
    _, hard = resource.getrlimit(resource.RLIMIT_STACK)
    resource.setrlimit(resource.RLIMIT_STACK, (1024 * 1024, hard))


def check_entry_allocas(ir):
    label = None
    count = 0
    for line in ir.read_text().splitlines():
        if line.startswith('define '):
            label = None
        elif re.fullmatch(r'[-\w.]+:', line):
            label = line[:-1]
        elif ' = alloca ' in line:
            assert label == 'entry', ('loop/block-dependent stack growth', label, line)
            count += 1
    assert count > 0, 'no stack storage emitted'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compiler', required=True, type=Path)
    options = parser.parse_args()
    compiler = options.compiler.resolve()
    with tempfile.TemporaryDirectory(prefix='qlang-lifetime-') as tmp:
        work = Path(tmp)
        source = ROOT / 'aot/tests/t22_lifetimes.ql'
        expected = source.with_suffix('.expected').read_bytes().replace(b'\n1000\n', b'\n100000\n')
        stress = work / 'lifetime-stress.ql'
        stress.write_text(source.read_text().replace('println(loop(1000));', 'println(loop(100000));'))
        ir = work / 'lifetime.ll'
        emit(compiler, stress, ir)
        check_entry_allocas(ir)
        for opt in (0, 2):
            binary = work / ('lifetime-O' + str(opt))
            subprocess.run(['clang', f'-O{opt}', '-fuse-ld=lld', '-Wl,--threads=1', '-Wl,--export-dynamic',
                            str(ir), str(ROOT / 'aot/runtime.c'), '-ldl', '-o', str(binary)],
                           check=True, timeout=TIMEOUT)
            validate(ir, binary)
            result = subprocess.run([str(binary)], capture_output=True, timeout=TIMEOUT,
                                    preexec_fn=limited_stack)
            assert result.returncode == 0 and not result.stderr, result
            assert result.stdout == expected, (result.stdout, expected)
            print(f'PASS -O{opt}: later uses, aliases, escaping closures/results, errors and bounded stack', flush=True)

        # Count allocator calls, not elapsed time. Constants, comparisons and
        # call buffers must not add per-iteration heap churn to this loop.
        runtime = (ROOT / 'aot/runtime.c').read_text()
        runtime = runtime.replace('#include <stddef.h>', '#include <stdio.h>\n#include <stddef.h>')
        runtime = runtime.replace('void* ql_alloc(size_t n) {',
                                  'static unsigned long long allocations;\n'
                                  '__attribute__((destructor)) static void report(void) { '
                                  'fprintf(stderr, "ALLOCATIONS %llu\\n", allocations); }\n'
                                  'void* ql_alloc(size_t n) { ++allocations;')
        instrumented = work / 'count-runtime.c'; instrumented.write_text(runtime)
        counts = []
        for n in (1000, 2000):
            source = work / 'count.ql'
            source.write_text('let count = (limit) -> { let i = 0; while i < limit { i = i + 1; }; i; };\n'
                              f'println(count({n}));\n')
            ir = work / 'count.ll'; binary = work / 'count'
            emit(compiler, source, ir); check_entry_allocas(ir)
            subprocess.run(['clang', '-O2', '-fuse-ld=lld', '-Wl,--threads=1', '-Wl,--export-dynamic',
                            str(ir), str(instrumented), '-ldl', '-o', str(binary)], check=True, timeout=TIMEOUT)
            validate(ir, binary)
            result = subprocess.run([str(binary)], capture_output=True, timeout=TIMEOUT)
            assert result.returncode == 0 and result.stdout == f'{n}\n'.encode(), result
            match = re.fullmatch(rb'ALLOCATIONS (\d+)\n', result.stderr)
            assert match, result.stderr
            counts.append(int(match[1]))
        # Scalars, including the returned counter, are inline values. Doubling
        # the iteration count must add no heap allocations at all.
        assert counts[1] == counts[0], counts
        print('PASS allocation growth:', counts, 'for 1000/2000 iterations', flush=True)
        print('Lifetime suite: ALL CHECKS PASS', flush=True)


if __name__ == '__main__':
    main()
