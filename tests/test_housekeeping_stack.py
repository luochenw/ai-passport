#!/usr/bin/env python3
"""Regression fixtures from the ESP32-C3 housekeeping overflow call path."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location(
    "check_housekeeping_stack", ROOT / "tools" / "check_housekeeping_stack.py"
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class StackBudgetTest(unittest.TestCase):
    def setUp(self) -> None:
        self.names = ("usb_keepalive_task", *MODULE.AUTH_TIMEOUT_PATH)
        self.sizes = (16, 80, 32, 1056, 176, 1152)
        self.symbols = "\n".join(
            f"{0x42000000 + index * 256:08x} t {name}"
            for index, name in enumerate(self.names)
        )
        self.frames = "\n\n".join(
            f"00000010 00000024 00000000 FDE cie=00000000 "
            f"pc={0x42000000 + index * 256:08x}..{0x42000080 + index * 256:08x}\n"
            f"  DW_CFA_def_cfa_offset: {size}\n"
            "  DW_CFA_def_cfa_offset: 0"
            for index, size in enumerate(self.sizes)
        )
        self.disassembly = "\n".join(
            f"{0x42000000 + index * 256:08x} <{name}>:\n"
            + (f"  42000004: 000000ef jal 42000100 <{self.names[index + 1]}>\n"
               if index + 1 < len(self.names) else "  42000004: 8082 ret\n")
            for index, name in enumerate(self.names)
        )

    def measure(self, frames: str | None = None, assembly: str | None = None):
        return MODULE.measure_path(self.symbols, self.frames if frames is None else frames,
                                   self.disassembly if assembly is None else assembly)

    def test_old_capacity_fails_and_new_capacity_has_margin(self) -> None:
        path = self.measure()
        self.assertEqual(sum(size for _, size in path), 2512)
        with self.assertRaisesRegex(ValueError, "task has 2048"):
            MODULE.verify_budget(path, 2048, 0)
        self.assertEqual(MODULE.verify_budget(path, 8192, 1536), 4144)

    def test_frame_growth_is_measured_not_just_first_prologue_offset(self) -> None:
        frames = self.frames.replace("DW_CFA_def_cfa_offset: 1056",
                                     "DW_CFA_def_cfa_offset: 512\n"
                                     "  DW_CFA_def_cfa_offset: 4096")
        self.assertEqual(self.measure(frames)[3], ("build_state", 4096))

    def test_missing_debug_info_fails_instead_of_assuming_zero(self) -> None:
        with self.assertRaisesRegex(ValueError, "missing DWARF frame"):
            self.measure(frames="")

    def test_changed_call_graph_requires_audit(self) -> None:
        with self.assertRaisesRegex(ValueError, "compiled edge"):
            self.measure(assembly=self.disassembly.replace("<build_state>\n", "<other>\n"))

    def test_dynamic_stack_description_requires_audit(self) -> None:
        with self.assertRaisesRegex(ValueError, "dynamic CFA expression"):
            self.measure(frames=self.frames.replace("DW_CFA_def_cfa_offset: 1056",
                                                   "DW_CFA_def_cfa_expression: unsupported"))

    def test_capacity_matches_task_allocation(self) -> None:
        source = ('#define HOUSEKEEPING_STACK_BYTES 8192\n'
                  'xTaskCreate(usb_keepalive_task, "usb_keepalive",\n'
                  '            HOUSEKEEPING_STACK_BYTES, NULL, 5, NULL);')
        self.assertEqual(MODULE.configured_stack_bytes(source, "usb_keepalive_task"), 8192)
        with self.assertRaisesRegex(ValueError, "task allocation"):
            MODULE.configured_stack_bytes(source.replace(
                'HOUSEKEEPING_STACK_BYTES, NULL', '2048, NULL'), "usb_keepalive_task")


if __name__ == "__main__":
    unittest.main()
