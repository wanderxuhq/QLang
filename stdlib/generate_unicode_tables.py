#!/usr/bin/env python3
"""Generate portable QLang Unicode 15.1 data (no backend or runtime intrinsics).

Supply UnicodeData.txt, SpecialCasing.txt, DerivedCoreProperties.txt, PropList.txt
from https://www.unicode.org/Public/15.1.0/ucd/ via --ucd-dir.
Python generates static data only; all library algorithms execute in QLang.
"""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SHA256 = {'UnicodeData.txt': '2fc713e6a31a87c4850a37fe2caffa4218180fadb5de86b43a143ddb4581fb86', 'SpecialCasing.txt': '55a477efd933a52cd27e6a9bf70265bb2d8814af31aab07767abc8eb421f27ef', 'DerivedCoreProperties.txt': 'f55d0db69123431a7317868725b1fcbf1eab6b265d756d1bd7f0f6d9f9ee108b', 'PropList.txt': '05672956317b6296bc2ec3d6cef1f6452b57ff4f2efc6dc55b0a19277d5fcfd1'}


def records(text):
    for line in text.splitlines():
        line = line.split('#')[0].strip()
        if line:
            yield [part.strip() for part in line.split(';')]


def generate(directory):
    sources = {name: (directory / name).read_bytes() for name in
               ('UnicodeData.txt', 'SpecialCasing.txt', 'DerivedCoreProperties.txt', 'PropList.txt')}
    for name, data in sources.items():
        assert hashlib.sha256(data).hexdigest() == SHA256[name], f'unexpected Unicode data: {name}'
    texts = {name: data.decode('utf-8') for name, data in sources.items()}
    for name in ('SpecialCasing.txt', 'DerivedCoreProperties.txt', 'PropList.txt'):
        assert f'{name[:-4]}-15.1.0.txt' in texts[name], f'wrong Unicode version: {name}'
    upper, lower = {}, {}
    for row in records(texts['UnicodeData.txt']):
        cp = int(row[0], 16)
        for mapping, field in ((upper, 12), (lower, 13)):
            if row[field]:
                mapping[cp] = [int(row[field], 16)]
    for row in records(texts['SpecialCasing.txt']):
        if not row[4]:
            cp = int(row[0], 16)
            lower[cp] = [int(x, 16) for x in row[1].split()]
            upper[cp] = [int(x, 16) for x in row[3].split()]
    fields = {'version': '15.1.0'}
    for name, mapping in (('upper', upper), ('lower', lower)):
        chunks, chunk = [], ''
        for cp, values in sorted(mapping.items()):
            if values == [cp]:
                continue
            assert 1 <= len(values) <= 3
            record = chr(cp) + ''.join(map(chr, values)) + '|'
            assert record.count('|') == 1
            if len(chunk) + len(record) > 128:
                chunks.append(chunk); chunk = ''
            chunk += record
        if chunk:
            chunks.append(chunk)
        fields[name] = chunks
    for name, prop, source in (('cased', 'Cased', 'DerivedCoreProperties.txt'),
                               ('ignorable', 'Case_Ignorable', 'DerivedCoreProperties.txt'),
                               ('space', 'White_Space', 'PropList.txt')):
        chars = []
        for row in records(texts[source]):
            if row[1] == prop:
                ends = [int(x, 16) for x in row[0].split('..')]
                chars.extend(chr(cp) for cp in range(ends[0], ends[-1] + 1))
        text = ''.join(chars)
        fields[name] = [text[i:i+128] for i in range(0, len(text), 128)]
    result = '// Generated Unicode 15.1.0 data. Regenerate with generate_unicode_tables.py.\n'
    result += '// Unicode copyright Unicode, Inc.; see unicode-LICENSE.txt.\n'
    for name, data in sources.items():
        result += f'// {name} SHA-256 {hashlib.sha256(data).hexdigest()}\n'
    result += 'let unicodeData = ' + json.dumps(fields, ensure_ascii=False, indent=2) + ';\nexport unicodeData;\n'
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ucd-dir', required=True, type=Path)
    parser.add_argument('--check', action='store_true')
    options = parser.parse_args()
    path = ROOT / 'unicode_data.ql'
    expected = generate(options.ucd_dir)
    if options.check:
        assert path.read_text() == expected, 'Unicode tables are stale'
    else:
        path.write_text(expected)
    print('Unicode 15.1 data verified' if options.check else 'Unicode 15.1 data generated')


if __name__ == '__main__':
    main()
