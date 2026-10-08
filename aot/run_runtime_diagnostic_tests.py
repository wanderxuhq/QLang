#!/usr/bin/env python3
"""Check unhandled source reports while preserving the public Error interface."""
import argparse
from contextlib import nullcontext
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = (
    ('t38_runtime_diagnostics', b'runtime source checks: 18\n'),
    ('t39_runtime_module_diagnostics', b'runtime module source checks: 7\n'),
)


def execute(command, interpreted, timeout, cwd):
    result = subprocess.run([str(x) for x in command], capture_output=True,
                            timeout=timeout, cwd=cwd)
    body = result.stdout
    if interpreted:
        assert b'Interpreting...\n' in body, result
        body = body.split(b'Interpreting...\n', 1)[1]
        if result.returncode == 0:
            assert body.endswith(b'Execution complete.\n'), result
            body = body[:-len(b'Execution complete.\n')]
        elif b'Execution complete.\n' in body:
            # The CLI appends Error.toString after the execution marker.
            body, _, summary = body.rpartition(b'Execution complete.\n')
            assert summary.strip(), result
    return result, body


def verify(command, source, expected, *, interpreted=False, timeout=3600,
           cwd=None, old_extension=None):
    def run(arguments):
        return execute(command + arguments, interpreted, timeout, cwd)

    result, body = run([])
    assert result.returncode == 0 and body == expected and not result.stderr, result
    print('PASS Error interface:', source.name, flush=True)
    direct = source.stem == 't38_runtime_diagnostics'
    modes = ('fail', 'cached', 'first', 'second', 'recursive', 'library') if direct else (
        'trace', 'import', 'assign')
    for mode in modes:
        result, body = run([mode])
        err = result.stderr
        assert result.returncode == 1 and body == expected, (mode, result)
        assert b'/bootstrapped/' not in err and b'<stdlib_bundle>' not in err, (mode, err)

        def origin(path, line, col):
            assert f'{path}:{line}:{col}:'.encode() in err, (mode, err)

        def frames(points):
            actual = [line.decode() for line in err.splitlines() if line.startswith(b'  at ')]
            wanted = [f'  at {source}:{line}:{col}' for line, col in points]
            assert actual == wanted, (mode, actual, wanted, err)

        if mode == 'fail':
            origin(source, 20, 15)
            origin(source, 3, 14)
            assert b'caused by:' in err, err
        elif mode in ('cached', 'first', 'second', 'recursive'):
            origin(source, 7, 14)
            if mode == 'recursive':
                lines = source.read_text().splitlines()
                points = [(17, lines[16].index('recur(n - 1)') + 1)] * 3
                points += [(18, lines[17].index('recur(3)') + 1)]
            else:
                points = {'cached': [], 'first': [(9, 13)], 'second': [(10, 14)]}[mode]
            frames(points)
        elif mode == 'library':
            assert err.startswith(b'stdlib/string.ql:'), err
            assert f'  at {source}:34:'.encode() in err, err
        elif mode == 'trace':
            origin(source.parent / 'runtime_diagnostics/lib.ql', 3, 9)
            lines = source.read_text().splitlines()
            frames([(12, lines[11].index('boom()') + 1),
                    (13, lines[12].index('outer()') + 1)])
        elif mode == 'import':
            origin(source.parent / 'runtime_diagnostics/failure.ql', 2, 3)
            frames([(9, 15)])
        else:
            origin(source, 18, 57)
        print('PASS source report:', source.name, mode, flush=True)
    if direct and old_extension is not None:
        assert not interpreted, 'old native ABI requires directly compiled execution'
        result, body = run(['old-abi', old_extension])
        assert result.returncode == 0 and body == expected + b'ImportABI\n' and not result.stderr, result
        print('PASS old native extension ABI rejection', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--compiler', type=Path, help='build native fixtures at O0 and O2')
    mode.add_argument('--interpreter', type=Path, help='run fixtures through a built QLang core')
    parser.add_argument('--source-root', type=Path, default=ROOT, help='frozen source tree or repository root')
    parser.add_argument('--output-dir', type=Path, help='retain generated native IR and binaries')
    parser.add_argument('--old-extension', type=Path, help='also check rejection of a pre-diagnostics DSO')
    parser.add_argument('--timeout', type=int, default=3600)
    options = parser.parse_args()
    root = options.source_root.resolve()
    if options.interpreter and options.old_extension:
        parser.error('--old-extension is only supported with --compiler')
    if options.output_dir:
        options.output_dir = options.output_dir.resolve()
        options.output_dir.mkdir(parents=True, exist_ok=True)
    workspace = (nullcontext(str(options.output_dir)) if options.output_dir else
                 tempfile.TemporaryDirectory(prefix='qlang-runtime-diagnostics-'))
    with workspace as directory:
        work = Path(directory)
        for name, expected in FIXTURES:
            source = root / 'aot/tests' / (name + '.ql')
            if options.interpreter:
                verify([options.interpreter.resolve(), source], source, expected,
                       interpreted=True, timeout=options.timeout, cwd=work)
            else:
                from native_link import link
                ir = work / (name + '.ll')
                with ir.open('wb') as output:
                    subprocess.run([options.compiler.resolve(), '--emit-llvm', source,
                                    root / 'aot/runtime.ql'], stdout=output, check=True,
                                   timeout=options.timeout, cwd=root)
                for opt in (0, 2):
                    binary = work / f'{name}-O{opt}'
                    link(ir, binary, opt=opt, timeout=options.timeout)
                    verify([binary], source, expected, timeout=options.timeout, cwd=work,
                           old_extension=options.old_extension.resolve() if options.old_extension else None)
        if options.interpreter:
            source = work / 'private-context.ql'
            source.write_text('println(std.Object.hasOwn(std)("__diagnostics"));\n')
            result, body = execute([options.interpreter.resolve(), source], True,
                                   options.timeout, work)
            assert result.returncode == 0 and body == b'false\n' and not result.stderr, result
            print('PASS private context omitted from interpreted std', flush=True)
    print('Runtime diagnostic suite: ALL CHECKS PASS', flush=True)


if __name__ == '__main__':
    main()
