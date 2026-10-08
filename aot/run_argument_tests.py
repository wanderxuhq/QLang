#!/usr/bin/env python3
"""Check the existing script args contract through the QLang interpreter CLI."""
import argparse
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--interpreter', type=Path)
    mode.add_argument('--host', type=Path, help='retained host executing the QLang evaluator')
    options = parser.parse_args()
    command = ([str(options.interpreter.resolve())] if options.interpreter else
               [str(options.host.resolve()), str(ROOT / 'bootstrapped/run_file.ql')])
    with tempfile.TemporaryDirectory(prefix='qlang-arguments-') as tmp:
        work = Path(tmp)
        def run(name, text, arguments, expected):
            source = work / (name + '.ql')
            source.write_text(text)
            result = subprocess.run(command + [str(source)] + arguments, cwd=work,
                                    capture_output=True, timeout=1800)
            assert result.returncode == 0 and not result.stderr, result
            assert b'Interpreting...\n' in result.stdout, result.stdout
            body = result.stdout.split(b'Interpreting...\n', 1)[1]
            assert body == expected + b'Execution complete.\n', body
            print('PASS interpreter arguments:', name, flush=True)
        run('empty', 'println(args.length);', [], b'0\n')
        run('values', '''println(args.length);
println(String.check(args[0]));
println(args[0] == "with spaces");
println(args[1] == "");
println(args[2] == "中文");
println(args[3] == "--flag");
''', ['with spaces', '', '中文', '--flag'], b'4\ntrue\ntrue\ntrue\ntrue\ntrue\n')
        (work / 'nested.ql').write_text('export { nestedArgs: args };')
        (work / 'module.ql').write_text('''let received = args;
args = ["module rebound"];
let child = import ./nested.ql;
let change = () -> { received[0] = "changed"; };
export { received, change, nestedArgs: child.nestedArgs, localArgs: args };
''')
        run('scope', '''let original = args;
if true { let args = ["local"]; println(args[0] == "local"); };
println(args[0] == "process");
args = ["rebound"];
let ns = import ./module.ql;
println(ns.received[0] == "process");
println(ns.nestedArgs[0] == "process");
println(ns.localArgs[0] == "module rebound");
ns.change();
println(original[0] == "changed");
println(ns.nestedArgs[0] == "changed");
println(args[0] == "rebound");
''', ['process'], b'true\n' * 8)
    print('Interpreter argument CLI suite: ALL CHECKS PASS', flush=True)


if __name__ == '__main__':
    main()
