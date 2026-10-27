#!/usr/bin/env python3
"""Link QLang IR and verify static string pointers before publishing an ELF.

The current backend emits unstripped AArch64 ELF64 executables. Verification
uses PT_LOAD/PT_DYNAMIC and the QLang string symbols, without running the output.
"""
import argparse
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent


class LinkError(ValueError):
    pass


class ELF:
    def __init__(self, path):
        self.data = Path(path).read_bytes()
        h = self.unpack('<16sHHIQQQIHHHHHH', 0)
        if h[0][:7] != b'\x7fELF\x02\x01\x01' or h[2] != 183 or h[1] not in (2, 3):
            raise LinkError('expected an AArch64 ELF64 little-endian executable')
        self.pie = h[1] == 3
        if h[9] != 56 or h[11] != 64 or not h[10] or not h[12]:
            raise LinkError('missing or unsupported ELF header tables')
        self.segments = [self.unpack('<IIQQQQQQ', h[5] + i * 56) for i in range(h[10])]
        self.sections = [self.unpack('<IIQQQQIIQQ', h[6] + i * 64) for i in range(h[12])]

    def read(self, offset, size):
        if offset < 0 or size < 0 or offset > len(self.data) or size > len(self.data) - offset:
            raise LinkError('ELF data extends beyond the file')
        return self.data[offset:offset + size]

    def unpack(self, fmt, offset):
        return struct.unpack(fmt, self.read(offset, struct.calcsize(fmt)))

    def offset(self, address, size):
        for kind, _, offset, base, _, length, _, _ in self.segments:
            if kind == 1 and base <= address and address - base <= length and size <= length - (address - base):
                result = offset + address - base
                self.read(result, size)
                return result
        raise LinkError(f'address 0x{address:x} is not backed by a loadable file range')

    def symbols(self):
        result = {}
        for section in self.sections:
            if section[1] != 2:  # SHT_SYMTAB, checked before stripping
                continue
            _, _, _, _, start, size, strings, _, _, stride = section
            if stride != 24 or size % stride or strings >= len(self.sections):
                raise LinkError('invalid symbol table')
            names_section = self.sections[strings]
            names = self.read(names_section[4], names_section[5])
            for at in range(start, start + size, stride):
                name, info, _, index, address, length = self.unpack('<IBBHQQ', at)
                end = names.find(b'\0', name)
                if end < 0:
                    raise LinkError('invalid symbol name')
                label = names[name:end]
                if re.fullmatch(rb'\.strbox\d+', label):
                    if not index or info & 15 != 1 or length not in (24, 48) or label in result:
                        raise LinkError(f'invalid string symbol {label!r}')
                    result[label.decode()] = address
        if not result:
            raise LinkError('no QLang string symbols; validate before stripping')
        return result

    def relocations(self):
        dynamic = {}
        for kind, _, offset, _, _, size, _, _ in self.segments:
            if kind != 2:  # PT_DYNAMIC: use the table that the loader consumes
                continue
            if size % 16:
                raise LinkError('invalid dynamic table')
            for at in range(offset, offset + size, 16):
                tag, value = self.unpack('<qQ', at)
                if tag == 0:
                    break
                dynamic[tag] = value
        # The supported build command produces plain RELA. Do not silently
        # accept a packing format which this validator cannot reconstruct.
        if any(tag in dynamic for tag in (17, 36, 0x6000000f, 0x60000011)):
            raise LinkError('packed/REL relocations are not supported by this build checker')
        if 7 not in dynamic:
            return {}
        size = dynamic.get(8, 0)
        if dynamic.get(9) != 24 or size % 24:
            raise LinkError('invalid dynamic RELA table')
        start = self.offset(dynamic[7], size)
        result = {}
        for at in range(start, start + size, 24):
            target, info, addend = self.unpack('<QQq', at)
            if target in result:
                raise LinkError(f'duplicate dynamic relocation at 0x{target:x}')
            result[target] = (info, addend)
        return result


def ir_strings(ir):
    text = Path(ir).read_text()
    buffers = {}
    for match in re.finditer(r'^@\.str(\d+) = private unnamed_addr constant \[(\d+) x i8\] c"((?:\\[0-9A-Fa-f]{2})*)"', text, re.M):
        value = bytes.fromhex(match[3].replace('\\', ''))
        if len(value) != int(match[2]):
            raise LinkError('IR string length does not match its bytes')
        buffers[match[1]] = value
    result = {}
    for match in re.finditer(r'^@\.strbox(\d+) = (?:hidden )?(?:global \{ i64, ptr, i64 \} \{ i64 2, ptr @\.str(\d+), i64 (\d+) \}|global \{ i64, ptr, i64, i64, i64, i64 \} \{ i64 2, ptr @\.str(\d+), i64 (\d+), i64 0, i64 0, i64 0 \})', text, re.M):
        buffer_index = match[2] or match[4]
        declared = match[3] or match[5]
        value = buffers.get(buffer_index)
        if value is None or len(value) != int(declared):
            raise LinkError('IR string box does not match its buffer')
        result['.strbox' + match[1]] = value
    if not result:
        raise LinkError('input has no supported QLang string declarations')
    return result


def validate(ir, binary, extra_ir=None):
    expected = ir_strings(ir)
    if extra_ir is not None:
        # Split build: the ELF also carries the runtime/stdlib object's strings.
        # Validate them against the object's own IR instead of ignoring them.
        expected.update(ir_strings(extra_ir))
    elf = ELF(binary)
    symbols = elf.symbols()
    relocations = elf.relocations()
    if symbols.keys() != expected.keys():
        raise LinkError('ELF string symbols do not match the input IR')
    for name, value in expected.items():
        address = symbols[name]
        tag, buffer, size = elf.unpack('<QQQ', elf.offset(address, 24))
        if tag != 2 or size != len(value):
            raise LinkError(f'{name}: string header does not match IR')
        relocation = relocations.get(address + 8)
        if relocation:
            info, buffer = relocation
            if info != 1027:  # R_AARCH64_RELATIVE, symbol index zero
                raise LinkError(f'{name}: unsupported buffer relocation')
        elif elf.pie:
            raise LinkError(f'{name}: missing string-buffer relocation')
        if not buffer:
            raise LinkError(f'{name}: null string-buffer pointer')
        if elf.read(elf.offset(buffer, size), size) != value:
            raise LinkError(f'{name}: linked string bytes do not match IR')
    return len(expected)


def link(ir, binary, opt=2, timeout=600, clang='clang', shared=False, stdlib_object=None):
    if stdlib_object is None:
        stdlib_object = os.environ.get('QLANG_STDLIB_OBJECT')
    ir, binary = Path(ir).resolve(), Path(binary).absolute()
    # Parse before invoking Clang; never publish partial or unrelated output.
    ir_strings(ir)
    binary.parent.mkdir(parents=True, exist_ok=True)
    stdlib_ir = None
    if stdlib_object is not None and not shared:
        candidate_ir = Path(stdlib_object).with_name('stdlib.ll')
        if candidate_ir.exists():
            stdlib_ir = candidate_ir
    with tempfile.TemporaryDirectory(prefix='.qlang-link-', dir=binary.parent) as tmp:
        candidate = Path(tmp) / 'program'
        already_split = False
        try:
            already_split = '; split-stdlib' in Path(ir).read_text(errors='ignore')[:200000]
        except OSError:
            already_split = False
        if stdlib_object is not None and not shared and not already_split:
            # Compile the runtime/stdlib bodies once (target/stdlib/<key>) and
            # link them instead of re-optimising ~180k IR lines every build.
            from stdlib_split import build_symbols_for_ir, split_file
            symbols = build_symbols_for_ir(Path(stdlib_object))
            user_ir = Path(tmp) / 'user.ll'
            split_file(ir, user_ir, symbols)
            inputs = [str(user_ir), str(ROOT / 'aot/runtime.c'), str(stdlib_object),
                      '-Wl,--export-dynamic', '-ldl']
        elif stdlib_object is not None and not shared:
            # The compiler already emitted the user-only module (`--emit-llvm-split`).
            inputs = [str(ir), str(ROOT / 'aot/runtime.c'), str(stdlib_object),
                      '-Wl,--export-dynamic', '-ldl']
        else:
            inputs = [str(ir), '-shared', '-fPIC'] if shared else [str(ir), str(ROOT / 'aot/runtime.c'), '-Wl,--export-dynamic', '-ldl']
        subprocess.run([str(clang), f'-O{opt}', '-fuse-ld=lld', '-Wl,--threads=1',
                        *inputs, '-o', str(candidate)],
                       cwd=ROOT, check=True, timeout=timeout)
        count = validate(ir, candidate, extra_ir=stdlib_ir)
        os.replace(candidate, binary)
    return count


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('ir', type=Path)
    parser.add_argument('-o', '--output', required=True, type=Path)
    parser.add_argument('--opt', choices=range(4), type=int, default=2)
    parser.add_argument('--shared', action='store_true', help='link a QLang extension without a second runtime')
    parser.add_argument('--stdlib-object', type=Path,
                        help='link a precompiled runtime/stdlib object (see aot/stdlib_split.py)')
    parser.add_argument('--check-only', action='store_true', help='validate an existing ELF without linking')
    options = parser.parse_args()
    try:
        if options.check_only:
            count = validate(options.ir, options.output)
        else:
            stdlib_object = options.stdlib_object or os.environ.get('QLANG_STDLIB_OBJECT')
            count = link(options.ir, options.output, options.opt, shared=options.shared,
                         stdlib_object=stdlib_object)
    except (OSError, LinkError, subprocess.SubprocessError) as error:
        print(f'LinkError: {error}', file=sys.stderr)
        return 1
    print(f'validated {count} static strings: {options.output}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
