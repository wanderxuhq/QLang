#!/usr/bin/env python3
"""Deterministic JSON decimal/f64 boundary differential test (HOST vs NATIVE)."""

import argparse
import json
import math
import os
from pathlib import Path
import random
import struct
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compiler', type=Path, help='reuse a native self-hosted compiler')
    options = parser.parse_args()
    os.chdir(Path(__file__).resolve().parent.parent)
    qlang = os.environ.get("QLANG", "./target/release/qlang")
    rng = random.Random(20260923)
    values = [
        "5e-324", "2.2250738585072014e-308", "1.7976931348623157e308",
        "2.2250738585072011e-308", "1e-300", "1e300", "-0.0", "0.1", "3.14",
        "9007199254740993", "2.4703282292062327e-324", "2.4703282292062328e-324",
        "1.00000000000000011102230246251565404236316680908203125",
        "1.00000000000000011102230246251565404236316680908203126",
    ]
    while len(values) < 30:
        number = struct.unpack(">d", rng.getrandbits(64).to_bytes(8, "big"))[0]
        if math.isfinite(number):
            values.append(repr(number))

    source = (
        "let values = " + json.dumps(values) + ";\n"
        "let i = 0; while i < values.length {\n"
        "  println(std.JSON.stringify(std.JSON.parse(values[i])));\n"
        "  i = i + 1;\n"
        "};\n"
    )
    with tempfile.TemporaryDirectory(prefix="qlang-numeric-") as work:
        path = Path(work) / "numbers.ql"
        path.write_text(source, encoding="utf-8")
        binary = Path(work) / "numbers.bin"
        host = subprocess.run(
            [qlang, str(path)], capture_output=True, check=True, timeout=60,
        )
        if options.compiler:
            from run_selfhost_tests import emit, link
            ir = Path(work) / "numbers.ll"
            emit(options.compiler.resolve(), path, ir)
            link(ir, binary)
        else:
            subprocess.run(
                [qlang, "--compile", str(path), "-o", str(binary)],
                check=True, timeout=120,
            )
        native = subprocess.run(
            [str(binary)], capture_output=True, check=True, timeout=120,
        )
        expected = host.stdout.decode().splitlines()
        actual = native.stdout.decode().splitlines()
        if len(expected) != len(values) or expected != actual:
            for index, literal in enumerate(values):
                host_line = expected[index] if index < len(expected) else "<missing>"
                native_line = actual[index] if index < len(actual) else "<missing>"
                if host_line != native_line:
                    print(f"MISMATCH {literal}: host={host_line}, native={native_line}")
            raise SystemExit(
                f"FAIL: expected {len(values)} lines, HOST={len(expected)}, "
                f"NATIVE={len(actual)}"
            )
        print(f"{len(values)} decimal boundary/random cases: PASS")


if __name__ == "__main__":
    main()
