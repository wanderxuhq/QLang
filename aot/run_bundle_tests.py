#!/usr/bin/env python3
"""Check QLang source packaging against original files and scalar coordinates."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import tempfile

from run_selfhost_tests import TIMEOUT


def unpack(bundle):
    expression, rest = bundle.split('let standardLibrarySource = ', 1)[1].split(';\nlet standardLibraryOrigins = ', 1)
    # QLang additionally escapes interpolation markers in JSON string literals.
    expression = expression.replace(r'\${', '${')
    decoder = json.JSONDecoder()
    chunks = []
    while expression:
        value, end = decoder.raw_decode(expression)
        chunks.append(value)
        expression = expression[end:]
        if expression:
            assert expression.startswith(' + '), expression[:40]
            expression = expression[3:]
    origins = rest.split(';\nexport ', 1)[0]
    origins = re.sub(r'\b(path|startLine|endLine|sourceLineStarts|sourceLength):', r'"\1":', origins)
    return ''.join(chunks), json.loads(origins)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundler', type=Path, required=True)
    options = parser.parse_args()
    bundler = options.bundler.resolve()
    modules = [
        ('empty.ql', ''),
        ('first.ql', 'let first = "中😀";\r\nexport first;\r'),
        ('second.ql', 'import ./first.ql;\r\nlet text = `x${first}`;\rlet separator = "\u2028\u2029";\nexport text;'),
        ('trivia.ql', '\r\n\r\n'),
        ('last.ql', 'let last = "no final newline";'),
    ]
    with tempfile.TemporaryDirectory(prefix='qlang-source-bundle-') as tmp:
        work = Path(tmp); library = work/'stdlib'; library.mkdir()
        manifest = {'modules': [name for name, _ in modules], 'exports': [{'name': 'First', 'value': 'first'}]}
        (library/'manifest.json').write_text(json.dumps(manifest))
        for name, text in modules:
            (library/name).write_bytes(text.encode())
        result = subprocess.run([bundler], cwd=work, capture_output=True, timeout=TIMEOUT, check=True)
        assert not result.stderr, result.stderr
        source, origins = unpack(result.stdout.decode())
        expected = 'let __build_standard_library = (std) -> {\n'
        next_line = 2
        for origin, (name, text) in zip(origins, modules, strict=True):
            matches = list(re.finditer(r'\r\n|\r|\n', text))
            starts = [0] + [match.end() for match in matches]
            lines = []
            start = 0
            for match in matches:
                lines.append((text[start:match.start()], match.group()))
                start = match.end()
            if start < len(text):
                lines.append((text[start:], '\n'))
            assert origin == {'path': 'stdlib/'+name, 'startLine': next_line,
                              'endLine': next_line+len(lines)-1,
                              'sourceLineStarts': starts, 'sourceLength': len(text)}, origin
            for line, ending in lines:
                if line.startswith('import '): line = '// bundled import'
                elif line.startswith('export '): line = '// bundled export'
                expected += line + ending
            next_line += len(lines)
        expected += '{First: first};\n};\n'
        assert source == expected, (source, expected)
        (library/'bundle.ql').write_bytes(result.stdout)
        check = subprocess.run([bundler, '--check'], cwd=work, capture_output=True, timeout=TIMEOUT)
        assert check.returncode == 0 and check.stdout == b'Standard library source bundle verified\n' and not check.stderr, check
        print('PASS QLang packager: original newlines, scalar offsets, interpolation, empty/EOF sources', flush=True)
        (library/'last.ql').write_text('let last = 1;')
        stale = subprocess.run([bundler, '--check'], cwd=work, capture_output=True, timeout=TIMEOUT)
        assert stale.returncode == 1 and b'BundleError' in stale.stderr and not stale.stdout, stale
        print('PASS QLang packager: stale source bundle rejected', flush=True)
    print('Source bundle suite: ALL CHECKS PASS', flush=True)


if __name__ == '__main__':
    main()
