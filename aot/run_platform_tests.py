#!/usr/bin/env python3
"""Native bootstrap contracts: argv, file text, canonical paths and descriptor cleanup."""
import json
import os
from pathlib import Path
import resource
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
QLANG = Path(os.environ.get('QLANG', ROOT / 'target/release/qlang')).resolve()
TIMEOUT = int(os.environ.get('TEST_TIMEOUT', '240'))
SOURCE = '''
if args.length == 0 { println(std.JSON.stringify(args)); }
else if args[0] == "--repeat" {
  let i = 0;
  while i < 100 {
    std.fs.readFileText(args[1])?;
    std.fs.canonicalPath(args[1])?;
    i = i + 1;
  };
  println("PASS descriptor cleanup");
} else {
  println(std.JSON.stringify(args));
  let text = std.fs.readFileText(args[0]);
  if isError(text) { println(std.JSON.stringify({error: text.type})); }
  else { println(std.JSON.stringify(text)); };
  let path = std.fs.canonicalPath(args[0]);
  if isError(path) { println(std.JSON.stringify({error: path.type})); }
  else { println(std.JSON.stringify(path)); };
};
println(std.fs.readFileText(42).type);
println(std.fs.canonicalPath(null).type);
println(std.fs.readFileText("bad\\0path").type);
println(std.fs.canonicalPath("bad\\0path").type);
'''

def run(argv, **kwargs):
    p = subprocess.run([str(a) for a in argv], cwd=ROOT, capture_output=True, timeout=TIMEOUT, **kwargs)
    assert p.returncode == 0, (argv, p.returncode, p.stderr.decode(errors='replace'))
    return p.stdout.decode().splitlines()

def main():
    with tempfile.TemporaryDirectory(prefix='qlang-platform-') as temp:
        work = Path(temp)
        src = work / 'platform.ql'; src.write_text(SOURCE)
        exe = work / 'platform'
        run([QLANG, '--compile', src, '-o', exe])
        suffix = ['TypeMismatch', 'TypeMismatch', 'IOError', 'IOError']
        assert run([exe]) == ['[]'] + suffix
        cases = [('empty', b''), ('unicode', '中文🙂\nA\0Z'.encode()),
                 ('chunks', ('a' * 65535 + '🙂' + 'z' * 100).encode()),
                 ('bad-continuation', b'\xc2A'), ('overlong', b'\xc0\xaf'),
                 ('surrogate', b'\xed\xa0\x80'), ('too-large', b'\xf4\x90\x80\x80'),
                 ('truncated', b'\xf0\x9f')]
        for name, data in cases:
            path = work / name; path.write_bytes(data)
            out = run([exe, path, '', 'two words', '中文🙂'])
            assert json.loads(out[0]) == [str(path), '', 'two words', '中文🙂']
            try: expected = data.decode('utf-8')
            except UnicodeDecodeError: expected = {'error': 'IOError'}
            assert json.loads(out[1]) == expected, name
            assert json.loads(out[2]) == str(path.resolve()), name
            assert out[3:] == suffix, name
            print('PASS platform:', name, flush=True)
        missing = work / 'missing'
        out = run([exe, missing])
        assert [json.loads(s) for s in out[1:3]] == [{'error': 'IOError'}] * 2
        out = run([exe, work])
        assert json.loads(out[1]) == {'error': 'IOError'} and json.loads(out[2]) == str(work)
        (work / 'real/nested').mkdir(parents=True)
        (work / 'real/value').write_text('resolved')
        (work / 'link').symlink_to(work / 'real/nested', target_is_directory=True)
        path = work / 'link/../value'
        out = run([exe, path])
        assert json.loads(out[1]) == 'resolved'
        assert json.loads(out[2]) == str((work / 'real/value').resolve())
        print('PASS platform: missing files, directories, symlink followed by ..', flush=True)
        def descriptor_limit():
            resource.setrlimit(resource.RLIMIT_NOFILE, (64, 64))
        out = run([exe, '--repeat', work / 'empty'], preexec_fn=descriptor_limit)
        assert out == ['PASS descriptor cleanup'] + suffix
        print('PASS platform: 100 read/resolve pairs with a 64-descriptor limit', flush=True)
    print('Platform suite: ALL PASS')

if __name__ == '__main__':
    main()
