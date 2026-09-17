#!/usr/bin/env python3
"""Check the compiled authentication-timeout path against a task stack budget.

Run inside the ESP-IDF environment after building, for example:
  python3 tools/check_housekeeping_stack.py build/FoloToy-AI-Passport.elf \
      --stack-bytes 8192

The old 2048-byte housekeeping task overflowed on this path even after the
NimBLE stack was enlarged. DWARF frame sizes include compiler spills and the
linked C library, which source-level buffer counting misses. This is a known
path regression check, not a whole-program maximum-stack proof; runtime stack
watermarks and device tests are still required.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path


AUTH_TIMEOUT_PATH = (
    "device_trust_tick",
    "queue_state_snapshot",
    "build_state",
    "snprintf",
    "_svfprintf_r",
)


def parse_symbols(text: str) -> dict[str, int]:
    symbols = {}
    for line in text.splitlines():
        match = re.match(r"^([0-9a-fA-F]+)\s+[tTwW]\s+(\S+)$", line.strip())
        if match:
            symbols[match[2]] = int(match[1], 16)
    return symbols


def parse_frames(text: str) -> dict[int, int]:
    frames = {}
    for block in re.split(r"\n\s*\n", text):
        match = re.search(r"\bFDE\b[^\n]*\bpc=([0-9a-fA-F]+)\.\.", block)
        if not match:
            continue
        address = int(match[1], 16)
        if "DW_CFA_def_cfa_expression" in block:
            raise ValueError(f"dynamic CFA expression at 0x{address:x}; audit required")
        offsets = [int(value) for value in re.findall(
            r"DW_CFA_def_cfa_offset:\s*(\d+)", block
        )]
        # A leaf FDE without offsets has the CIE's initial zero-byte frame.
        frames[address] = max(frames.get(address, 0), max(offsets, default=0))
    return frames


def parse_disassembly(text: str) -> dict[str, str]:
    functions = {}
    matches = list(re.finditer(r"^([0-9a-fA-F]+) <([^>]+)>:\s*$", text, re.M))
    for index, match in enumerate(matches):
        end = matches[index + 1].start() if index + 1 < len(matches) else len(text)
        functions[match[2]] = text[match.end():end]
    return functions


def measure_path(symbols_text: str, frames_text: str, disassembly_text: str,
                 task_symbol: str = "usb_keepalive_task") -> list[tuple[str, int]]:
    symbols = parse_symbols(symbols_text)
    frames = parse_frames(frames_text)
    functions = parse_disassembly(disassembly_text)
    path = (task_symbol, *AUTH_TIMEOUT_PATH)
    result = []
    for name in path:
        if name not in symbols or name not in functions:
            raise ValueError(f"missing compiled function {name}; audit the changed call path")
        if symbols[name] not in frames:
            raise ValueError(f"missing DWARF frame for {name}; use the unstripped build ELF")
        result.append((name, frames[symbols[name]]))
    for caller, callee in zip(path, path[1:]):
        # Require a call/tail-call instruction, not a data or branch reference.
        pattern = rf"\b(?:jal|jalr|call|tail|j)\s+[^\n]*<{re.escape(callee)}>"
        if not re.search(pattern, functions[caller]):
            raise ValueError(f"compiled edge {caller} -> {callee} changed; audit required")
    return result


def verify_budget(path: list[tuple[str, int]], stack_bytes: int, reserve_bytes: int) -> int:
    if stack_bytes <= 0 or reserve_bytes < 0:
        raise ValueError("stack bytes must be positive and reserve bytes must be nonnegative")
    needed = sum(frame for _, frame in path) + reserve_bytes
    if needed > stack_bytes:
        raise ValueError(f"known path plus reserve needs {needed} bytes, task has {stack_bytes}")
    return stack_bytes - needed


def configured_stack_bytes(source: str, task_symbol: str) -> int:
    source = re.sub(r"/\*.*?\*/|//[^\n]*", "", source, flags=re.S)
    match = re.search(r"^\s*#define\s+HOUSEKEEPING_STACK_BYTES\s+(\d+)\s*$", source, re.M)
    if not match:
        raise ValueError("HOUSEKEEPING_STACK_BYTES must be a literal byte capacity")
    allocation = (rf"\bxTaskCreate\s*\(\s*{re.escape(task_symbol)}\s*,\s*"
                  r'"[^"\n]*"\s*,\s*HOUSEKEEPING_STACK_BYTES\s*,')
    if not re.search(allocation, source):
        raise ValueError(f"{task_symbol} task allocation must use HOUSEKEEPING_STACK_BYTES")
    return int(match[1])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("elf", type=Path)
    parser.add_argument("--stack-bytes", type=int,
                        help="override byte capacity; default reads HOUSEKEEPING_STACK_BYTES")
    parser.add_argument("--source", type=Path,
                        default=Path(__file__).resolve().parent.parent / "main" / "main.c",
                        help="source of the just-built task allocation")
    parser.add_argument("--reserve-bytes", type=int, default=1536,
                        help="additional budget for RTOS and unenumerated callees (default: 1536)")
    parser.add_argument("--task-symbol", default="usb_keepalive_task")
    parser.add_argument("--tool-prefix", default="riscv32-esp-elf-")
    args = parser.parse_args()
    try:
        stack_bytes = args.stack_bytes
        if stack_bytes is None:
            stack_bytes = configured_stack_bytes(args.source.read_text(), args.task_symbol)

        def run(tool: str, *options: str) -> str:
            return subprocess.check_output(
                [args.tool_prefix + tool, *options, str(args.elf)], text=True
            )

        path = measure_path(run("nm", "--defined-only"),
                            run("readelf", "--debug-dump=frames"),
                            run("objdump", "-d"), args.task_symbol)
        for name, size in path:
            print(f"  {name}: {size} bytes")
        spare = verify_budget(path, stack_bytes, args.reserve_bytes)
    except (OSError, subprocess.CalledProcessError, ValueError) as error:
        print(f"Housekeeping stack budget: FAIL ({error})", file=sys.stderr)
        return 1
    print(f"Housekeeping stack budget: PASS (path {sum(size for _, size in path)} + "
          f"reserve {args.reserve_bytes} <= {stack_bytes}; spare {spare} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
