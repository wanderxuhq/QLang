#!/usr/bin/env python3
"""Check native extensions through the QLang core, including callback reports."""
import argparse
import os
from contextlib import nullcontext
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def interpreter_body(result):
    start = b'Interpreting...\n'
    assert start in result.stdout, result
    body = result.stdout.split(start, 1)[1]
    if result.returncode == 0:
        assert body.endswith(b'Execution complete.\n'), result
        body = body[:-len(b'Execution complete.\n')]
    elif b'Execution complete.\n' in body:
        # The CLI prints Error.toString after this marker on unhandled errors.
        # Keep program output separate from that existing error summary.
        body, _, summary = body.rpartition(b'Execution complete.\n')
        assert summary.strip(), result
    return body


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compiler', required=True, type=Path)
    parser.add_argument('--interpreter', required=True, type=Path)
    parser.add_argument('--source-root', type=Path, default=ROOT)
    parser.add_argument('--output-dir', type=Path)
    parser.add_argument('--existing-suite', type=Path,
                        help='reuse checked artifacts from a completed run_extension_tests.py suite')
    parser.add_argument('--reuse-builds', action='store_true',
                        help='reuse checked bridge host/DSO artifacts in the output directory')
    parser.add_argument('--diagnostics-only', action='store_true',
                        help='run source/lexical-boundary checks after separately verified extension parity')
    parser.add_argument('--timeout', type=int, default=3600)
    options = parser.parse_args()
    if options.reuse_builds and options.output_dir is None:
        parser.error('--reuse-builds requires --output-dir')
    root = options.source_root.resolve()
    compiler = options.compiler.resolve()
    core = options.interpreter.resolve()
    sys.path.insert(0, str(root/'aot'))
    from native_link import link, validate
    if options.output_dir:
        options.output_dir = options.output_dir.resolve()
        options.output_dir.mkdir(parents=True, exist_ok=True)
    workspace = nullcontext(str(options.output_dir)) if options.output_dir else tempfile.TemporaryDirectory(prefix='qlang-extension-core-')
    with workspace as directory:
        work = Path(directory)
        def run(command):
            return subprocess.run([str(x) for x in command], capture_output=True,
                                  cwd='/tmp', timeout=options.timeout)
        if not options.diagnostics_only:
            baseline = options.existing_suite.resolve() if options.existing_suite else work/'baseline'
            if not options.existing_suite:
                subprocess.run([sys.executable, root/'aot/run_extension_tests.py',
                                '--compiler', compiler, '--keep', baseline],
                               check=True, timeout=options.timeout*16,
                               env=os.environ | {'TEST_TIMEOUT':str(options.timeout)})
            # Reusing an artifact does not bypass the checked linker requirement.
            for opt in (0, 2):
                validate(baseline/'host.ll', baseline/f'host-O{opt}')
                for name in ('plugin', 'second', 'failure', 'cycle'):
                    validate(baseline/(name+'.ll'), baseline/f'{name}-O{opt}.so')
            for name in ('wrong-abi', 'no-entry'):
                validate(baseline/(name+'.ll'), baseline/(name+'.so'))
            original_host = baseline/'source/host.ql'
            # This is interpreted input; extension source files stay absent.
            original_host.write_bytes((root/'aot/tests/t37_extensions.ql').read_bytes())
            assert not any((baseline/'source').glob('plugin*.ql'))
            expected = (root/'aot/tests/t37_extensions.expected').read_bytes()
            for opt in (0, 2):
                shutil.copyfile(baseline/f'cycle-O{opt}.so', baseline/'source/cycle.so')
                paths = [baseline/f'plugin-O{opt}.so', baseline/f'second-O{opt}.so',
                         baseline/f'failure-O{opt}.so', baseline/'source/cycle.so',
                         baseline/'wrong-abi.so', baseline/'not-native.so', baseline/'no-entry.so']
                # Recheck reused direct artifacts as well as the interpreter path.
                for level in (0, 2):
                    result = run([baseline/f'host-O{level}', *paths])
                    assert result.returncode == 0 and result.stdout == expected and not result.stderr, result
                result = run([core, original_host, *paths])
                (work/f'core-baseline-O{opt}.stdout').write_bytes(result.stdout)
                assert result.returncode == 0 and interpreter_body(result) == expected and not result.stderr, result
                print(f'PASS native core / extensions O{opt}: 28 contracts, module sources absent', flush=True)

        source = work/'source'; source.mkdir(exist_ok=True)
        fixture_names = ('bridge_diagnostics_host', 'bridge_diagnostics_plugin')
        if not options.diagnostics_only:
            fixture_names += ('bridge_host', 'bridge_plugin')
        for name in fixture_names:
            shutil.copyfile(root/'aot/tests/extensions'/(name+'.ql'), source/(name+'.ql'))
        def emit(name, module=False):
            ir = work/(name+'.ll')
            if options.reuse_builds:
                for opt in (0, 2):
                    suffix = '.so' if module else ''
                    validate(ir, work/f'{name}-O{opt}{suffix}')
                return ir
            with ir.open('wb') as output:
                subprocess.run([compiler, '--emit-module' if module else '--emit-llvm',
                                source/(name+'.ql'), root/'aot/runtime.ql'],
                               stdout=output, check=True, timeout=options.timeout)
            return ir
        # These additional hosts also compile before their extensions exist.
        for name in [name for name in fixture_names if name.endswith('_host')]:
            ir = emit(name)
            for opt in (0, 2):
                if not options.reuse_builds:
                    link(ir, work/f'{name}-O{opt}', opt=opt, timeout=options.timeout)
        for name in [name for name in fixture_names if name.endswith('_plugin')]:
            ir = emit(name, module=True)
            for opt in (0, 2):
                if not options.reuse_builds:
                    link(ir, work/f'{name}-O{opt}.so', opt=opt, timeout=options.timeout, shared=True)
        plugin = source/'bridge_diagnostics_plugin.ql'
        host = source/'bridge_diagnostics_host.ql'
        plugin_lines = plugin.read_text().splitlines()
        host_lines = host.read_text().splitlines()
        def point(path, lines, line, token):
            return f'{path}:{line}:{lines[line-1].index(token)+1}'
        origins = {
            'native': point(plugin, plugin_lines, 1, '1 / 0'),
            'callback': point(host, host_lines, 3, '1 / 0'),
            'reused': point(plugin, plugin_lines, 3, 'Error.raise'),
            'after': point(host, host_lines, 11, '1 / 0'),
        }
        frames = {
            'native': [point(host, host_lines, 5, 'module.fail')],
            'callback': [point(plugin, plugin_lines, 2, 'callback()'),
                         point(host, host_lines, 7, 'module.apply')],
            'reused': [point(host, host_lines, 9, 'module.reuse')],
            'after': [],
        }
        # Keep only the two interpreter entry scripts, no module sources.
        for name in [name for name in fixture_names if name.endswith('_plugin')]:
            (source/(name+'.ql')).unlink()
        expected = None if options.diagnostics_only else (root/'aot/tests/extensions/bridge_host.expected').read_bytes()
        for opt in (0, 2):
            if not options.diagnostics_only:
                dso = work/f'bridge_plugin-O{opt}.so'
                for level in (0, 2):
                    result = run([work/f'bridge_host-O{level}', dso])
                    assert result.returncode == 0 and result.stdout == expected and not result.stderr, result
                result = run([core, source/'bridge_host.ql', dso])
                (work/f'core-bridge-O{opt}.stdout').write_bytes(result.stdout)
                assert result.returncode == 0 and interpreter_body(result) == expected and not result.stderr, result
                print(f'PASS bridge identity/callback/type contracts: extensions O{opt}', flush=True)
            dso = work/f'bridge_diagnostics_plugin-O{opt}.so'
            commands = [(f'native-O{level}', [work/f'bridge_diagnostics_host-O{level}'], False)
                        for level in (0, 2)] + [('core', [core, host], True)]
            for label, command, interpreted in commands:
                for mode, origin in origins.items():
                    result = run([*command, dso, mode])
                    body = interpreter_body(result) if interpreted else result.stdout
                    (work/f'{label}-extension-O{opt}-{mode}.stderr').write_bytes(result.stderr)
                    assert result.returncode == 1 and body == b'', (label, mode, result)
                    assert result.stderr.startswith((origin+':').encode()), (label, mode, result.stderr)
                    actual = [line.decode()[5:] for line in result.stderr.splitlines() if line.startswith(b'  at ')]
                    assert actual == frames[mode], (label, mode, actual, frames[mode], result.stderr)
                    assert b'/bootstrapped/' not in result.stderr, result.stderr
                print(f'PASS source origins and exact callback frames: {label} / extension O{opt}', flush=True)
        # An escaped closure resolves a relative extension path at its defining
        # source module, even after that module's initialization has finished.
        scope = source/'plugin-scope'; scope.mkdir(exist_ok=True)
        shutil.copyfile(work/'bridge_diagnostics_plugin-O2.so', scope/'extension.so')
        (scope/'factory.ql').write_text('export let factory = () -> { () -> import ("./" + "extension.so"); };\n')
        relative = source/'relative.ql'
        relative.write_text('import ./plugin-scope/factory.ql;\nlet load = factory();\nlet module = load();\nprintln(module.apply(() -> 17));\n')
        result = run([core, relative])
        assert result.returncode == 0 and interpreter_body(result) == b'17\n' and not result.stderr, result
        print('PASS escaped import resolves at defining source module', flush=True)
        private = source/'private-bridge.ql'
        private.write_text('println(std.Object.hasOwn(std)("__extensions"));\n')
        result = run([core, private])
        assert result.returncode == 0 and interpreter_body(result) == b'false\n' and not result.stderr, result
        print('PASS internal bridge absent from interpreted std', flush=True)
    print('Native core extension suite: ALL CHECKS PASS', flush=True)


if __name__ == '__main__':
    main()
