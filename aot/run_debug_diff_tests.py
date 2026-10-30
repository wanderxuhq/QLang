#!/usr/bin/env python3
"""debug / release 差分测试套件:每个测试用例两种档位各编一次,输出必须逐字节相同。

debug 档(`--debug`)是**保守发射**:发射器不消费分析的优化结论 —— 不直调/不内联/不 raw ABI、
不 unbox 裸槽、不省略"可证不会失败"的检查、不删死函数。它存在的意义有两条:

  1. 让"优化不健全"变成可观测的:哪个测试用例 debug 对、release 错,就定位到具体优化;
  2. 语言调试:所有值都走通用路径,没有裸槽/直调/闭包省略这些特例。

所以本测试套件的判据是**两档一致**,而不是"只有 release 对"。
"""
import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'aot'))
from run_selfhost_tests import emit, link, _use_stdlib_object  # noqa: E402

TIMEOUT = 600
# 需要 extension 宿主/模块链接的测试用例:本测试套件只做"编译器档位差分",不建 extension,
# 它们的红与档位无关(两档同样红)。真正的 extension 覆盖在 run_selfhost/interpreter 里。
SKIP = {'t37_extensions'}


def run(binary, cwd):
    return subprocess.run([str(binary)], capture_output=True, timeout=TIMEOUT, cwd=cwd)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--compiler', type=Path, required=True)
    ap.add_argument('--output-dir', type=Path)
    options = ap.parse_args()
    compiler = options.compiler.resolve()
    _use_stdlib_object(compiler)
    workspace = (options.output_dir.resolve() if options.output_dir else None)
    with (tempfile.TemporaryDirectory(prefix='qlang-debugdiff-') if workspace is None else _keep(workspace)) as tmp:
        work = Path(tmp)
        work.mkdir(parents=True, exist_ok=True)
        failures = []
        checked = 0
        for source in sorted((ROOT / 'aot/tests').glob('t*.ql')):
            expected = source.with_suffix('.expected')
            if not expected.exists() or source.stem in SKIP:
                continue
            if not _emits(compiler, source):
                # A fixture listed with a golden file must compile. Silently
                # skipping hid every emit regression from this differential gate.
                failures.append((source.name, 'emit 失败'))
                continue
            outputs = {}
            for mode in ('release', 'debug'):
                ir = work / f'{source.stem}.{mode}.ll'
                binary = work / f'{source.stem}.{mode}'
                _emit_mode(compiler, source, ir, mode)
                link(ir, binary)
                outputs[mode] = run(binary, work)
            checked += 1
            if outputs['release'].returncode != outputs['debug'].returncode:
                failures.append((source.name, 'debug/release 退出码不同'))
            elif outputs['release'].stdout != outputs['debug'].stdout:
                failures.append((source.name, 'debug/release 输出不同'))
            elif outputs['release'].stdout != expected.read_bytes():
                failures.append((source.name, '与 .expected 不同(两档相同)'))
        for name, why in failures:
            print(f'FAIL debug-diff: {name}: {why}', flush=True)
        if failures:
            print(f'debug/release 差分测试套件: {len(failures)} 个失败 / {checked} 个测试用例', flush=True)
            return 1
        print(f'debug/release 差分测试套件: ALL PASS({checked} 个测试用例,两档输出逐字节相同)', flush=True)
        return 0


class _keep:
    def __init__(self, path):
        self.path = path

    def __enter__(self):
        self.path.mkdir(parents=True, exist_ok=True)
        return str(self.path)

    def __exit__(self, *args):
        return False


def _emits(compiler, source):
    proc = subprocess.run([str(compiler), '--emit-llvm-split', str(source), str(ROOT / 'aot/runtime.ql'),
                           os.environ['QLANG_STDLIB_SYMBOLS'], os.environ.get('QLANG_STDLIB_MOD', '-')],
                          capture_output=True, cwd=ROOT)
    return proc.returncode == 0


def _emit_mode(compiler, source, ir, mode):
    from run_selfhost_tests import RUNTIME
    args = [str(compiler)]
    if mode == 'debug':
        args.append('--debug')
    args += ['--emit-llvm-split', str(source), str(RUNTIME),
             os.environ['QLANG_STDLIB_SYMBOLS'], os.environ.get('QLANG_STDLIB_MOD', '-')]
    with ir.open('wb') as output:
        proc = subprocess.run(args, stdout=output, stderr=subprocess.PIPE, cwd=ROOT)
    if proc.returncode != 0:
        raise SystemExit(f'emit({mode}) failed for {source}: {proc.stderr.decode()[-300:]}')


if __name__ == '__main__':
    sys.exit(main())
