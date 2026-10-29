#!/usr/bin/env python3
"""Benchmark harness: emitted AArch64 instruction counts + compile time.

The yardstick is `clang -O2 -S` instruction lines, not IR lines (see AGENTS.md
2.5). Every benchmark is compiled by a given compiler, its IR is passed through
clang -O2, and the resulting assembly is counted. The binary is then linked and
run so a benchmark that got faster by changing behaviour is caught.

Usage:
  python3 aot/bench/run_bench.py --compiler target/selfhost/stage2
  python3 aot/bench/run_bench.py --compiler /tmp/stage2_new --only b_chars
"""
import argparse
import os
import pathlib
import re
import resource
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'aot'))
BENCH_DIR = ROOT / "aot" / "bench"
RUNTIME = ROOT / "aot" / "runtime.ql"
INSN = re.compile(r"^\s+[a-z]")
LINK = ROOT / "aot" / "native_link.py"


def run(cmd, **kw):
    return subprocess.run(cmd, cwd=str(ROOT), capture_output=True, text=True, **kw)


def child_cpu():
    """CPU time of finished children (s). Immune to a noisy/contended host."""
    usage = resource.getrusage(resource.RUSAGE_CHILDREN)
    return usage.ru_utime + usage.ru_stime


def insn_count(asm_text):
    return sum(1 for line in asm_text.splitlines() if INSN.match(line))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--compiler", required=True)
    ap.add_argument("--only", default="")
    ap.add_argument("--keep", action="store_true", help="keep intermediate files")
    ap.add_argument("--no-run", action="store_true", help="skip linking/running")
    ap.add_argument("--lto", action="store_true",
                    help="with --split: link the library as bitcode with ThinLTO "
                         "(compile ~2.4x faster than monolithic, runtime parity)")
    ap.add_argument("--split", action="store_true",
                    help="compile via the precompiled stdlib object (fast compile; "
                         "insns then only cover the user module and are NOT comparable)")
    args = ap.parse_args()

    compiler = str(pathlib.Path(args.compiler).resolve())
    symbols = None
    interface = None
    if args.split:
        # 库只编一次:编译只发用户模块(编译时间口径)。
        try:
            from run_selfhost_tests import _use_stdlib_object
            _use_stdlib_object(pathlib.Path(compiler))
            symbols = os.environ.get('QLANG_STDLIB_SYMBOLS')
            interface = os.environ.get('QLANG_STDLIB_INTERFACE')
        except Exception as error:  # pragma: no cover
            print(f"note: stdlib object unavailable ({error}); emitting monolithically", file=sys.stderr)
    work = ROOT / "target" / "bench"
    work.mkdir(parents=True, exist_ok=True)

    benches = sorted(p for p in BENCH_DIR.glob("b_*.ql"))
    if args.only:
        benches = [p for p in benches if args.only in p.name]
    if not benches:
        print("no benchmarks found", file=sys.stderr)
        return 2

    rows = []
    for source in benches:
        name = source.stem
        ir = work / f"{name}.ll"
        asm = work / f"{name}.s"
        binary = work / name

        t0 = time.monotonic()
        emit_args = [compiler, "--emit-llvm-split" if symbols else "--emit-llvm", str(source), str(RUNTIME)]
        if symbols:
            emit_args += [symbols, interface if interface else '-']
        proc = run(emit_args, timeout=600)
        frontend = time.monotonic() - t0
        if proc.returncode != 0:
            print(f"{name}: compiler failed\n{proc.stderr}", file=sys.stderr)
            return 1
        ir.write_text(proc.stdout)

        t0 = time.monotonic()
        proc = run(["clang", "-O2", "-S", str(ir), "-o", str(asm)], timeout=600)
        backend = time.monotonic() - t0
        if proc.returncode != 0:
            print(f"{name}: clang failed\n{proc.stderr}", file=sys.stderr)
            return 1
        insns = insn_count(asm.read_text())

        output = ""
        if not args.no_run:
            # split 模式优先用 QLang 链接器(构建路径不再依赖 Python);不可用时回落。
            link_tool = ROOT / "target" / "tools" / "link"
            obj = os.environ.get('QLANG_STDLIB_OBJECT')
            proc = None
            if symbols and obj and link_tool.exists():
                tool_args = [str(link_tool), str(ir), "-o", str(binary), "--stdlib-object", obj]
                if args.lto:
                    tool_args += ["--stdlib-ir", os.environ.get('QLANG_STDLIB_OBJECT', '').replace('stdlib.o', 'strings.tsv'), "--lto"]
                proc = run(tool_args, timeout=1800)
                if proc.returncode != 0:
                    proc = None
            if proc is None:
                link_args = [sys.executable, str(LINK), str(ir), "-o", str(binary)]
                if args.lto:
                    link_args.append("--lto")
                proc = run(link_args, timeout=900)
            if proc.returncode != 0:
                print(f"{name}: link failed\n{proc.stderr}", file=sys.stderr)
                return 1
            best = None
            best_cpu = None
            for _ in range(5):
                t0 = time.monotonic()
                cpu0 = child_cpu()
                proc = run([str(binary)], timeout=180)
                cpu = child_cpu() - cpu0
                elapsed = time.monotonic() - t0
                if proc.returncode != 0:
                    break
                best = elapsed if best is None else min(best, elapsed)
                best_cpu = cpu if best_cpu is None else min(best_cpu, cpu)
            if proc.returncode != 0:
                print(f"{name}: run failed ({proc.returncode})\n{proc.stderr}", file=sys.stderr)
                return 1
            output = proc.stdout.strip().splitlines()[-1] if proc.stdout.strip() else ""

        rows.append(dict(name=name, insns=insns, frontend=frontend,
                         backend=backend, output=output,
                         runtime=0.0 if args.no_run else best,
                         cpu=0.0 if args.no_run else best_cpu))

        if not args.keep:
            for path in (ir, asm, binary):
                try:
                    path.unlink()
                except FileNotFoundError:
                    pass

    width = max(len(r["name"]) for r in rows)
    print(f"{'bench'.ljust(width)}  {'insns':>8}  {'front(s)':>8}  {'clang(s)':>8}  {'run(s)':>7}  {'cpu(s)':>7}  output")
    for r in rows:
        print(f"{r['name'].ljust(width)}  {r['insns']:>8}  {r['frontend']:>8.2f}  {r['backend']:>8.2f}  {r['runtime']:>7.3f}  {r['cpu']:>7.3f}  {r['output']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
