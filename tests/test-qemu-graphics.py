#!/usr/bin/env python3
"""Focused host-only checks for the common installed-VM graphics contract."""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "qemu"))
import harness  # noqa: E402


class QemuGraphicsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="home-qemu-graphics-test-")
        self.addCleanup(self.temporary.cleanup)
        directory = Path(self.temporary.name)
        # VM.command() does not touch output ownership; avoid coupling this
        # command-shape regression to Paths' separate safety contract.
        self.paths = object()
        self.disk = directory / "disk.img"
        self.pair = harness.FirmwarePair(directory / "code.fd", directory / "vars.fd", "test firmware")

    @staticmethod
    def graphics_fragment(command: list[str]) -> tuple[str, tuple[str, ...], tuple[str, ...]]:
        vga = command[command.index("-vga") + 1]
        devices = tuple(command[index + 1] for index, value in enumerate(command[:-1]) if value == "-device")
        renderer = tuple(command[index + 1] for index, value in enumerate(command[:-1]) if value == "-fw_cfg")
        return vga, devices, renderer

    def test_acceptance_and_interactive_vms_share_one_explicit_renderer(self) -> None:
        acceptance = harness.make_vm(
            self.paths,
            self.pair,
            self.disk,
            self.pair.vars_template,
            "acceptance",
            display="none",
        )
        interactive = harness.make_vm(
            self.paths,
            self.pair,
            self.disk,
            self.pair.vars_template,
            "interactive",
            display="cocoa",
        )
        with mock.patch.object(harness, "require_command", return_value="qemu-system-x86_64"):
            acceptance_graphics = self.graphics_fragment(acceptance.command())
            interactive_graphics = self.graphics_fragment(interactive.command())

        self.assertEqual(acceptance_graphics, interactive_graphics)
        vga, devices, renderer = acceptance_graphics
        self.assertEqual(vga, "std")
        self.assertNotIn("virtio-gpu-pci", devices)
        self.assertEqual(renderer, ("name=opt/home-renderer,string=pixman",))

    def test_profile_describes_the_actual_single_gpu_path(self) -> None:
        profile = harness.qemu_profile()
        self.assertEqual(profile["gpu"], "std VGA (bochs-drm)")
        self.assertEqual(profile["renderer"], "pixman via fw_cfg opt/home-renderer")

    def test_unavailable_network_keeps_a_present_nic_without_dhcp(self) -> None:
        unavailable = harness.make_vm(
            self.paths,
            self.pair,
            self.disk,
            self.pair.vars_template,
            "offline-network",
            network=True,
            network_unavailable=True,
        )
        with mock.patch.object(harness, "require_command", return_value="qemu-system-x86_64"):
            command = unavailable.command()
        self.assertIn("user,id=net0,ipv4=off", command)
        self.assertIn("virtio-net-pci,netdev=net0", command)

    def test_graphics_facts_resolve_the_drm_identity(self) -> None:
        command = harness.FACTS_RUNTIME_COMMAND
        self.assertIn("/dev/dri/by-path/*-card", command)
        self.assertIn("bochs-drm", command)
        self.assertIn("fact_drm_identity", command)
        self.assertIn("fact_dwl_drm_open", harness.FACTS_PROCESS_COMMAND)
        self.assertNotIn("/dev/dri/card0", command)


if __name__ == "__main__":
    unittest.main()
