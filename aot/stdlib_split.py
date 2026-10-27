#!/usr/bin/env python3
"""Split a compiled QLang module into a reusable stdlib object and a user module.

Motivation: every QLang build re-emits ~180k IR lines of runtime+stdlib and then
asks `clang -O2` to optimise them again. Those bodies are program-independent
(probes §23/§24: 284 shared functions are textually identical across inputs), so
they can be compiled once into `stdlib.o` and linked.

What is program-independent, and what is not:

  * preamble (type/declarations), cold helpers, every runtime/stdlib function
    body, the string globals and `@__stdlib_init` — fixed text;
  * `@main`, user functions, user string globals, the per-program counter
    comments — per program.

The split is a *pure text transform* on the module the compiler already emits,
so the compiler keeps producing byte-identical IR; only the link step changes.
If anything here is wrong the link fails loudly (missing symbol / type mismatch)
rather than silently miscompiling.

Environment variable QLANG_STDLIB_OBJECT turns the split on for
`aot/native_link.py`; without it every path behaves exactly as before.
"""
import hashlib
import json
import pathlib
import re
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
CACHE_ROOT = ROOT / 'target' / 'stdlib'
SPLIT_VERSION = '7'

DEFINE = re.compile(r'^define\s')
GLOBAL = re.compile(r'^@([A-Za-z0-9_$.]+)\s*=\s')
FUNC_NAME = re.compile(r'^define\s+.*?@([A-Za-z0-9_$.]+)\(')
REF = re.compile(r'@([A-Za-z0-9_$.]+)')


def parse_module(text):
    """Split IR text into (preamble, {fn: body}, {global: definition})."""
    lines = text.splitlines()
    preamble, functions, globals_ = [], {}, {}
    i = 0
    while i < len(lines):
        line = lines[i]
        if DEFINE.match(line):
            name = FUNC_NAME.match(line).group(1)
            body = [line]
            i += 1
            while i < len(lines):
                body.append(lines[i])
                if lines[i] == '}':
                    i += 1
                    break
                i += 1
            functions[name] = '\n'.join(body)
            continue
        m = GLOBAL.match(line)
        if m:
            globals_[m.group(1)] = line
            i += 1
            continue
        preamble.append(line)
        i += 1
    return preamble, functions, globals_


def declare_for_function(body):
    """`define internal ... @f(...) alwaysinline {` -> `declare ... @f(...)`."""
    header = body.splitlines()[0]
    header = re.sub(r'^define\s+', 'declare ', header)
    header = re.sub(r'^(declare\s+)(internal|hidden|private)\s+', r'\1', header)
    header = re.sub(r'\s+alwaysinline', '', header)
    header = re.sub(r'\s*\{\s*$', '', header)
    return header


def external_for_global(definition):
    """`@x = hidden global TYPE {init}` -> `@x = external global TYPE`."""
    name = GLOBAL.match(definition).group(1)
    head = definition.split(' = ', 1)[1]
    kind_match = re.search(r'\b(global|constant)\b', head)
    kind = kind_match.group(1)
    rest = head[kind_match.end():].strip()
    type_text = rest
    if rest and rest[0] in '[{':
        depth = 0
        for index, ch in enumerate(rest):
            if ch in '[{':
                depth += 1
            elif ch in ']}':
                depth -= 1
                if depth == 0:
                    type_text = rest[:index + 1]
                    break
    else:
        type_text = rest.split()[0] if rest else 'i8'
    return f'@{name} = external {kind} {type_text}'


def stdlib_key(compiler):
    h = hashlib.sha256()
    h.update(SPLIT_VERSION.encode())
    for path in (compiler, ROOT / 'aot' / 'runtime.ql', ROOT / 'stdlib' / 'bundle.ql'):
        h.update(pathlib.Path(path).read_bytes())
    return h.hexdigest()[:16]


def build_stdlib(compiler, cache_root=CACHE_ROOT):
    """Compile the fixed prefix once; returns (object path, symbols dict)."""
    compiler = pathlib.Path(compiler).resolve()
    key = stdlib_key(compiler)
    out = pathlib.Path(cache_root) / key
    object_path = out / 'stdlib.o'
    symbols_path = out / 'symbols.json'
    if object_path.exists() and symbols_path.exists():
        return object_path, json.loads(symbols_path.read_text())

    out.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='qlang-stdlib-') as tmp:
        empty = pathlib.Path(tmp) / 'empty.ql'
        empty.write_text('')
        full = out / 'full.ll'
        with full.open('wb') as handle:
            subprocess.run([str(compiler), '--emit-llvm', str(empty), str(ROOT / 'aot' / 'runtime.ql')],
                           cwd=ROOT, check=True, stdout=handle)
        preamble, functions, globals_ = parse_module(full.read_text())

    functions.pop('main', None)
    # The value-ABI leaves (ql_tag/ql_empty/ql_word/ql_byte/ql_truthy) are
    # `internal … alwaysinline`: each module can keep its own copy, and inlining
    # them at the call site is exactly what the monolithic build did. Routing
    # them through the object boundary instead would cost a real call per tag
    # test (~+1k instructions per program).
    pinned = {name for name, body in functions.items()
              if body.startswith('define internal ') and 'alwaysinline' in body.splitlines()[0]}
    # Both modules keep their own `internal` copy (legal: internal is module-local);
    # only the symbol table excludes them, so the user module never declares them.
    stdlib_functions = {name: (body if name in pinned else body.replace('define internal ', 'define hidden ', 1))
                        for name, body in functions.items()}

    # The ABI descriptor is defined per program (identical text); keep the user
    # module's copy and let the stdlib reference it.
    abi_name = 'qlang_extension_abi_v1'
    abi_decl = None
    if abi_name in globals_:
        abi_decl = external_for_global(globals_.pop(abi_name))

    stdlib_text = '\n'.join(preamble) + '\n'
    if abi_decl:
        stdlib_text += abi_decl + '\n'
    stdlib_text += '\n'.join(stdlib_functions.values()) + '\n'
    stdlib_text += '\n'.join(globals_.values()) + '\n'
    stdlib_ll = out / 'stdlib.ll'
    stdlib_ll.write_text(stdlib_text)

    # name -> symbol, recovered from the emitter's `; ql-symbol` comments; the
    # compiler needs it in `--emit-llvm-split` mode to call library functions.
    named = {}
    for line in preamble + [b for body in functions.values() for b in body.splitlines()]:
        marker = '; ql-symbol '
        if marker in line:
            _, rest = line.split(marker, 1)
            parts = rest.split()
            if len(parts) >= 3:
                named[parts[0]] = (parts[1], parts[2])
            elif len(parts) == 2:
                named[parts[0]] = (parts[1], '-1')
    (out / 'symbols.tsv').write_text(''.join(f'{k}\t{sym}\t{fa}\n' for k, (sym, fa) in sorted(named.items())))

    symbols = {
        'functions': {name: declare_for_function(body) for name, body in functions.items()
                      if name not in pinned},
        'globals': {name: external_for_global(text) for name, text in globals_.items()},
    }
    symbols_path.write_text(json.dumps(symbols, indent=0, sort_keys=True))

    subprocess.run(['clang', '-O2', '-c', str(stdlib_ll), '-o', str(object_path)],
                   cwd=ROOT, check=True)

    # Analysis interface: the tables a user program's analysis reads from the
    # runtime/stdlib analysis. Cached next to the object so `--emit-llvm-split`
    # can skip re-parsing the standard library entirely.
    (out / 'interface.txt').write_bytes(subprocess.run(
        [str(compiler), '--emit-stdlib-interface', str(ROOT / 'aot' / 'runtime.ql')],
        cwd=ROOT, check=True, capture_output=True).stdout)
    return object_path, symbols


def split_user_ir(text, symbols):
    """Remove stdlib definitions from a user module and declare what it uses."""
    preamble, functions, globals_ = parse_module(text)
    stdlib_fns = symbols['functions']
    stdlib_globals = symbols['globals']

    removed_fns = [name for name in functions if name in stdlib_fns]
    for name in removed_fns:
        del functions[name]
    removed_globals = [name for name in globals_ if name in stdlib_globals]
    for name in removed_globals:
        del globals_[name]

    body = '\n'.join(preamble) + '\n'
    body += '\n'.join(functions.values()) + '\n'
    body += '\n'.join(globals_.values()) + '\n'
    referenced = set(REF.findall(body))

    declares = [stdlib_fns[name] for name in sorted(referenced) if name in stdlib_fns]
    externals = [stdlib_globals[name] for name in sorted(referenced) if name in stdlib_globals]
    return '\n'.join(preamble) + '\n' + '\n'.join(declares + externals) + '\n' + \
        '\n'.join(functions.values()) + '\n' + '\n'.join(globals_.values()) + '\n'


def build_symbols_for_ir(object_path):
    """Symbol table that belongs to a prebuilt stdlib object (its symbols.json)."""
    symbols_path = pathlib.Path(object_path).with_name('symbols.json')
    if not symbols_path.exists():
        raise FileNotFoundError(f'{symbols_path} is missing; rebuild the stdlib object')
    return json.loads(symbols_path.read_text())


def split_file(ir_path, out_path, symbols):
    text = pathlib.Path(ir_path).read_text()
    pathlib.Path(out_path).write_text(split_user_ir(text, symbols))
    return out_path


if __name__ == '__main__':
    compiler = sys.argv[1] if len(sys.argv) > 1 else str(ROOT / 'target/selfhost/stage2')
    obj, syms = build_stdlib(compiler)
    print(f'{obj} ({len(syms["functions"])} functions, {len(syms["globals"])} globals)')
