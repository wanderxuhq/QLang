#!/usr/bin/env python3
"""Build the QLang toolchain binaries (target/tools/{verify,link}).

These are ordinary QLang programs (`aot/verify.ql`, `aot/link.ql`) compiled by the
current compiler. Bootstrapping them is the only place that still needs the Python
linker: once `target/tools/link` exists, the build path can use it instead.
"""
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TOOLS = ROOT / 'target' / 'tools'

SOURCES = {'verify': ROOT / 'aot' / 'verify.ql', 'link': ROOT / 'aot' / 'link.ql'}


def compile_tool(compiler, name, source):
    ir = TOOLS / f'{name}.ll'
    binary = TOOLS / name
    with ir.open('w') as handle:
        subprocess.run([str(compiler), '--emit-llvm', str(source), str(ROOT / 'aot' / 'runtime.ql')],
                       stdout=handle, check=True)
    # Bootstrap with the Python linker; the resulting binary is QLang from then on.
    subprocess.run([sys.executable, str(ROOT / 'aot' / 'native_link.py'), str(ir), '-o', str(binary)],
                   check=True, cwd=ROOT)
    ir.unlink(missing_ok=True)
    return binary


def ensure_tools(compiler):
    """Build (or rebuild) the toolchain binaries; returns dict name -> path."""
    TOOLS.mkdir(parents=True, exist_ok=True)
    built = {}
    for name, source in SOURCES.items():
        binary = TOOLS / name
        stale = (not binary.exists() or binary.stat().st_mtime < source.stat().st_mtime)
        if stale:
            compile_tool(compiler, name, source)
        built[name] = binary
    return built


def main():
    compiler = Path(sys.argv[1] if len(sys.argv) > 1 else os.environ.get('QLANG_COMPILER', 'target/selfhost/stage2'))
    if not compiler.exists():
        sys.exit(f'compiler not found: {compiler}')
    for name, path in ensure_tools(compiler).items():
        print(f'{name}: {path}')


if __name__ == '__main__':
    main()
