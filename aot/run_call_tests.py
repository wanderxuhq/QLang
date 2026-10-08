#!/usr/bin/env python3
"""Check borrowed call arguments, retained partials and allocation-free call loops."""
import argparse
from pathlib import Path
import re
import subprocess
import tempfile

from native_link import validate
from run_lifetime_tests import check_entry_allocas, limited_stack
from run_selfhost_tests import ROOT, TIMEOUT, emit


def build(ir, runtime, binary, opt):
    subprocess.run(['clang', f'-O{opt}', '-fuse-ld=lld', '-Wl,--threads=1', '-Wl,--export-dynamic',
                    str(ir), str(runtime), '-ldl', '-o', str(binary)], check=True, timeout=TIMEOUT)
    validate(ir, binary)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compiler', required=True, type=Path)
    options = parser.parse_args()
    compiler = options.compiler.resolve()
    with tempfile.TemporaryDirectory(prefix='qlang-calls-') as tmp:
        work = Path(tmp)
        # Borrowing requires the new dispatcher contract. An older runtime must
        # fail compilation rather than retain pointers to caller stack storage.
        runtime_text = (ROOT / 'aot/runtime.ql').read_text()
        legacy = work / 'legacy-runtime.ql'
        legacy.write_text(runtime_text.replace('let __call = __call_borrowed;\n', '')
                          .replace('__call_borrowed', '__call'))
        probe = work / 'probe.ql'; probe.write_text('println(1);')
        rejected = subprocess.run([str(compiler), '--emit-llvm', str(probe), str(legacy)],
                                  capture_output=True, timeout=TIMEOUT)
        assert rejected.returncode == 1 and not rejected.stdout, rejected
        assert b'missing runtime binding: __call_borrowed' in rejected.stderr, rejected.stderr
        print('PASS incompatible call runtime rejected before code generation', flush=True)
        native_calls = ROOT / 'aot/tests/t27_native_calls.ql'
        native_ir = work / 'native-calls.ll'
        emit(compiler, native_calls, native_ir)
        for opt in (0, 2):
            binary = work / f'native-calls-O{opt}'
            build(native_ir, ROOT / 'aot/runtime.c', binary, opt)
            result = subprocess.run([str(binary)], capture_output=True, timeout=TIMEOUT)
            assert result.returncode == 0 and not result.stderr, result
            assert result.stdout == native_calls.with_suffix('.expected').read_bytes(), result.stdout
            print(f'PASS -O{opt}: native positional arguments, arity and Error policy', flush=True)
        fixture = ROOT / 'aot/tests/t24_call_buffers.ql'
        expected = fixture.with_suffix('.expected').read_bytes()
        stress = work / 'retained.ql'
        stress.write_text(fixture.read_text().replace('j < 1000', 'j < 20000'))
        ir = work / 'retained.ll'
        emit(compiler, stress, ir)
        check_entry_allocas(ir)
        for opt in (0, 2):
            binary = work / f'retained-O{opt}'
            build(ir, ROOT / 'aot/runtime.c', binary, opt)
            result = subprocess.run([str(binary)], capture_output=True, timeout=TIMEOUT)
            assert result.returncode == 0 and not result.stderr, result
            assert result.stdout == expected, (opt, result.stdout, expected)
            print(f'PASS -O{opt}: partial snapshots, aliases, escaped arguments, policies and allocation churn', flush=True)

        runtime = (ROOT / 'aot/runtime.c').read_text()
        runtime = runtime.replace('#include <stddef.h>', '#include <stdio.h>\n#include <stddef.h>')
        runtime = runtime.replace('void* ql_alloc(size_t n) {',
                                  'static unsigned long long allocations;\n'
                                  '__attribute__((destructor)) static void report(void) { '
                                  'fprintf(stderr, "ALLOCATIONS %llu\\n", allocations); }\n'
                                  'void* ql_alloc(size_t n) { ++allocations;')
        instrumented = work / 'count-runtime.c'
        instrumented.write_text(runtime)
        counts = {0: [], 2: []}
        for n in (1000, 2000, 100000):
            source = work / 'loop.ql'
            source.write_text('''let step = (value: Number) -> value + 1;
let aliases = [step, step];
let extrema = [std.Math.max, std.Math.min];
let run = (limit) -> {
  let i = 0;
  while i < limit {
    i = extrema[i % 2](i, i, i, i, i, i);
    i = aliases[i % 2](i);
  };
  i;
};
''' + f'println(run({n}));\n')
            ir = work / 'loop.ll'
            emit(compiler, source, ir)
            check_entry_allocas(ir)
            for opt in (0, 2):
                binary = work / f'loop-O{opt}'
                build(ir, instrumented, binary, opt)
                result = subprocess.run([str(binary)], capture_output=True, timeout=TIMEOUT,
                                        preexec_fn=limited_stack)
                assert result.returncode == 0 and result.stdout == f'{n}\n'.encode(), result
                match = re.fullmatch(rb'ALLOCATIONS (\d+)\n', result.stderr)
                assert match, result.stderr
                counts[opt].append(int(match[1]))
        for opt, values in counts.items():
            # Compare equal-width printed results: all per-call heap work must
            # disappear even with computed callees and dynamic annotations.
            assert values[0] == values[1], (opt, values)
            print(f'PASS -O{opt}: allocations {values[:2]} for 1000/2000 annotated/variadic calls; '
                  '100000 calls fit a 1 MiB stack', flush=True)
        print('Call-buffer suite: ALL CHECKS PASS', flush=True)


if __name__ == '__main__':
    main()
