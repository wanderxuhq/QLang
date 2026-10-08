#!/usr/bin/env python3
"""Verify private source scopes and interpreter/native diagnostic boundaries."""
import argparse
from contextlib import nullcontext
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def verify_reports(binary, expected, origins, frames, timeout):
    for mode in [''] + list(origins):
        result = subprocess.run([binary] + ([mode] if mode else []),
                                capture_output=True, timeout=timeout)
        assert result.stdout == expected, (binary, mode, result)
        if not mode:
            assert result.returncode == 0 and not result.stderr, result
        else:
            assert result.returncode == 1 and result.stderr.startswith(
                (origins[mode] + ':').encode()), (binary, mode, result)
            actual = [line.decode()[5:] for line in result.stderr.splitlines()
                      if line.startswith(b'  at ')]
            assert actual == frames.get(mode, []), (binary, mode, actual, result.stderr)
            assert b'/bootstrapped/interpreter.ql:' not in result.stderr, result.stderr
        print('PASS source context:', binary.name, mode or 'existing fields', flush=True)


def verify_context(binary, source, timeout):
    point = 'interpreted.ql:7:9'
    other = 'caller.ql:11:3'
    origins = {
        'fresh': point, 'reused': point, 'called': f'{source}:11:21',
        'after-native': other, 'after-restore': point, 'ordinary': f'{source}:24:16',
        'following': f'{source}:28:17', 'partial': f'{source}:30:32',
        'attached': point, 'inherited': point, 'same-point': point,
    }
    frames = {'reused': [other], 'called': [other], 'same-point': [point]}
    verify_reports(binary, b'diagnostic context checks: 12\n', origins, frames, timeout)


def verify_boundary(binary, source, timeout):
    origins = {
        'native': f'{source}:9:21', 'partial': f'{source}:19:22',
        'callback': 'callback.ql:1:1', 'after': 'host-scope.ql:80:2',
        'no-leak': f'{source}:33:14',
    }
    frames = {
        'native': ['user.ql:1:1'], 'partial': ['partial-user.ql:1:1'],
        'callback': ['outer-user.ql:1:1'],
    }
    verify_reports(binary, b'native source bridge checks: 8\n', origins, frames, timeout)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compiler', required=True, type=Path)
    parser.add_argument('--source-root', type=Path, default=ROOT)
    parser.add_argument('--output-dir', type=Path)
    parser.add_argument('--timeout', type=int, default=3600)
    options = parser.parse_args()
    root = options.source_root.resolve()
    if options.output_dir:
        options.output_dir = options.output_dir.resolve()
        options.output_dir.mkdir(parents=True, exist_ok=True)
    workspace = (nullcontext(str(options.output_dir)) if options.output_dir else
                 tempfile.TemporaryDirectory(prefix='qlang-source-context-'))
    from native_link import link
    with workspace as directory:
        work = Path(directory)
        fixtures = (
            (root / 'aot/tests/t40_diagnostic_context.ql', (0, 2), verify_context),
            (root / 'bootstrapped/tests/native_source_bridge.ql', (2,), verify_boundary),
        )
        for source, levels, verify in fixtures:
            ir = work / (source.stem + '.ll')
            with ir.open('wb') as output:
                subprocess.run([options.compiler.resolve(), '--emit-llvm', source,
                                root / 'aot/runtime.ql'], stdout=output, check=True,
                               timeout=options.timeout, cwd=root)
            for opt in levels:
                binary = work / f'{source.stem}-O{opt}'
                link(ir, binary, opt=opt, timeout=options.timeout)
                verify(binary, source, options.timeout)
    print('Source context suite: ALL CHECKS PASS', flush=True)


if __name__ == '__main__':
    main()
