#!/usr/bin/env python3
"""Exercise real ELF relocations, corrupted artifacts and atomic publication."""
import argparse
from pathlib import Path
import struct
import subprocess
import tempfile

from native_link import ELF, LinkError, ROOT, link, validate


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--historical-dir', type=Path,
                        help='also reject the retained malformed interpreter from assignment-check')
    options = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='qlang-link-test-') as tmp:
        work = Path(tmp); ir = work / 'strings.ll'; binary = work / 'strings'
        # Same layout and escaping contract as qlangc, with an empty buffer,
        # multibyte UTF-8 and an embedded NUL. No library/parser is the oracle.
        values = [b'ASCII\n', '中文\0😀\n'.encode(), b'']
        lines = ['declare void @ql_write(i32, ptr, i64)', 'define i32 @main() {']
        for i, value in enumerate(values):
            lines += [f'  %p{i} = getelementptr i8, ptr @.strbox{i}, i64 8',
                      f'  %v{i} = load ptr, ptr %p{i}',
                      f'  call void @ql_write(i32 1, ptr %v{i}, i64 {len(value)})']
        lines += ['  ret i32 0', '}']
        for i, value in enumerate(values):
            escaped = ''.join('\\%02X' % c for c in value)
            lines += [f'@.str{i} = private unnamed_addr constant [{len(value)} x i8] c"{escaped}"',
                      f'@.strbox{i} = global {{ i64, ptr, i64 }} {{ i64 2, ptr @.str{i}, i64 {len(value)} }}']
        ir.write_text('\n'.join(lines) + '\n')
        for opt in (0, 2):
            assert link(ir, binary, opt=opt) == len(values)
            result = subprocess.run([str(binary)], capture_output=True, timeout=20)
            assert result.returncode == 0 and not result.stderr, result
            assert result.stdout == b''.join(values), result.stdout
            print('PASS static strings, UTF-8, NUL and empty buffer at -O' + str(opt), flush=True)

        good = binary.read_bytes(); elf = ELF(binary)
        address = elf.symbols()['.strbox0']; header = elf.offset(address, 24)
        target = elf.relocations()[address + 8][1]
        bad = work / 'bad'
        def reject(name, data):
            bad.write_bytes(data)
            try:
                validate(ir, bad)
            except LinkError:
                print('PASS reject:', name, flush=True)
            else:
                raise AssertionError('accepted ' + name)

        reject('truncated ELF', good[:24])
        data = bytearray(good); struct.pack_into('<H', data, 18, 62)
        reject('wrong architecture', data)
        data = bytearray(good); struct.pack_into('<Q', data, header, 4)
        reject('wrong string tag', data)
        data = bytearray(good); struct.pack_into('<Q', data, header + 16, 1000000000)
        reject('wrong string length', data)
        data = bytearray(good); data[elf.offset(target, 1)] ^= 1
        reject('wrong string bytes', data)
        # Hide relocations from the loader while leaving section data intact.
        # This recreates the important property of the historical bad link.
        data = bytearray(good)
        for kind, _, offset, _, _, size, _, _ in elf.segments:
            if kind == 2:
                for at in range(offset, offset + size, 16):
                    tag, _ = elf.unpack('<qQ', at)
                    if tag == 8:
                        struct.pack_into('<Q', data, at + 8, 0)
        reject('missing loader relocations', data)

        # A linker reporting success with a bad candidate must not replace the
        # previous working executable. A nonzero linker exit must not either.
        fake = work / 'clang'
        fake.write_text('#!/usr/bin/env python3\nimport sys,shutil\nshutil.copyfile(' + repr(str(bad)) + ', sys.argv[sys.argv.index("-o")+1])\n')
        fake.chmod(0o755)
        try:
            link(ir, binary, clang=fake)
        except LinkError:
            pass
        else:
            raise AssertionError('published a malformed linker result')
        assert binary.read_bytes() == good
        fake.write_text('#!/usr/bin/env python3\nimport sys\nsys.exit(7)\n')
        try:
            link(ir, binary, clang=fake)
        except subprocess.CalledProcessError as error:
            assert error.returncode == 7
        else:
            raise AssertionError('ignored linker failure')
        assert binary.read_bytes() == good
        assert not list(work.glob('.qlang-link-*'))
        print('PASS link failures preserve the previous executable', flush=True)

    if options.historical_dir:
        base = options.historical_dir.resolve()
        original_ir = base / 'core/interpreter.ll'
        count = validate(original_ir, base / 'core/interpreter')
        try:
            validate(original_ir, base / 'diagnostics/interpreter-missing-relocations')
        except LinkError as error:
            assert 'missing string-buffer relocation' in str(error), error
        else:
            raise AssertionError('accepted the historical malformed executable')
        print('PASS historical interpreter: validated', count, 'strings and rejected the malformed link', flush=True)
    print('Link suite: ALL CHECKS PASS', flush=True)


if __name__ == '__main__':
    main()
