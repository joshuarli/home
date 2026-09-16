#!/usr/bin/env python3
"""Focused host-only regressions for QEMU generated-path ownership."""

from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "qemu"))
import harness  # noqa: E402


class GeneratedPathTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="home-qemu-path-test-")
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name) / "repository"
        root.mkdir()
        self.root = root.resolve()
        self.generated_root = self.root / "dist" / "qemu"

    def harness_context(self):
        return mock.patch.multiple(
            harness,
            ROOT=self.root,
            DEFAULT_TEST_DIR=self.generated_root,
            FINGERPRINT_INPUTS=(),
        )

    def paths_from_environment(self, test_dir: Path | None = None, disk: Path | None = None):
        values = {"QEMU_TEST_DIR": str(test_dir or self.generated_root)}
        if disk is not None:
            values["QEMU_DISK"] = str(disk)
        with mock.patch.dict(os.environ, values, clear=True):
            return harness.Paths.from_environment()

    def test_safe_outputs_and_stale_fingerprint(self):
        with self.harness_context():
            paths = self.paths_from_environment()
            safe = paths.output("safe.log")
            self.assertEqual(safe.parent, self.generated_root)

            iso = self.root / "home-installer.iso"
            code = self.root / "code.fd"
            vars_template = self.root / "vars.fd"
            for path, contents in ((iso, b"iso"), (code, b"code"), (vars_template, b"vars")):
                path.write_bytes(contents)
            pair = harness.FirmwarePair(code, vars_template, "test firmware")
            payload = harness.fingerprint_payload(iso, pair)
            harness.write_disk_fingerprint(paths, payload)
            self.assertEqual(harness.current_disk_fingerprint(paths, iso, pair), payload)

            iso.write_bytes(b"new iso")
            with self.assertRaises(harness.HarnessError):
                harness.current_disk_fingerprint(paths, iso, pair)

    def test_symlinked_dist_is_rejected_by_direct_harness_invocation(self):
        outside = Path(self.temporary.name) / "outside"
        outside.mkdir()
        (self.root / "dist").symlink_to(outside, target_is_directory=True)
        with self.harness_context():
            with self.assertRaisesRegex(harness.HarnessError, "symlink"):
                self.paths_from_environment()

    def test_nested_generated_directory_symlink_is_rejected(self):
        self.generated_root.mkdir(parents=True)
        outside = Path(self.temporary.name) / "outside"
        outside.mkdir()
        nested = self.generated_root / "nested"
        nested.symlink_to(outside, target_is_directory=True)
        with self.harness_context():
            with self.assertRaisesRegex(harness.HarnessError, "symlink"):
                self.paths_from_environment(nested)

    def test_nonregular_and_dangling_symlink_outputs_are_rejected(self):
        with self.harness_context():
            paths = self.paths_from_environment()
            paths.ensure_test_dir()
            directory_output = paths.test_dir / "directory-output"
            directory_output.mkdir()
            with self.assertRaisesRegex(harness.HarnessError, "non-regular"):
                paths.output(directory_output.name)

            dangling = paths.test_dir / "dangling-output"
            dangling.symlink_to(self.root / "outside-output")
            with self.assertRaisesRegex(harness.HarnessError, "symlink"):
                harness.prepare_generated_file(dangling, paths.test_dir)

            dangling_socket = paths.test_dir / "dangling-socket"
            dangling_socket.symlink_to(self.root / "outside-socket")
            with self.assertRaisesRegex(harness.HarnessError, "symlink"):
                harness.prepare_generated_socket(dangling_socket, paths.test_dir)

    def test_external_directory_and_noncanonical_disk_are_rejected(self):
        with self.harness_context():
            with self.assertRaisesRegex(harness.HarnessError, "must be inside"):
                self.paths_from_environment(self.root / "outside")
            with self.assertRaisesRegex(harness.HarnessError, "disposable disk.img"):
                self.paths_from_environment(disk=self.generated_root / "nested" / "disk.img")
            paths = self.paths_from_environment()
            with self.assertRaisesRegex(harness.HarnessError, "must be inside"):
                paths.output("../outside.log")

    def test_symlinked_or_nonregular_disposable_disk_is_rejected(self):
        self.generated_root.mkdir(parents=True)
        disk = self.generated_root / "disk.img"
        disk.symlink_to(self.root / "outside-disk")
        with self.harness_context():
            with self.assertRaisesRegex(harness.HarnessError, "symlink"):
                self.paths_from_environment()
        disk.unlink()
        disk.mkdir()
        with self.harness_context():
            with self.assertRaisesRegex(harness.HarnessError, "non-regular"):
                self.paths_from_environment()

    def test_vm_rejects_out_of_tree_writable_inputs_before_qemu_starts(self):
        """VM.start() must retain the generated-tree boundary itself."""

        with self.harness_context():
            paths = self.paths_from_environment()
            paths.ensure_test_dir()
            paths.disk.write_bytes(b"disposable disk")
            vars_path = paths.output("vars.fd")
            vars_path.write_bytes(b"variables")
            code_path = self.root / "code.fd"
            code_path.write_bytes(b"code")

            for field, outside in (
                ("disk", self.root / "outside-disk.img"),
                ("vars_path", self.root / "outside-vars.fd"),
            ):
                values = {"disk": paths.disk, "vars_path": vars_path}
                values[field] = outside
                vm = harness.VM(
                    paths,
                    values["disk"],
                    values["vars_path"],
                    code_path,
                    f"outside-{field}",
                )
                with (
                    self.subTest(field=field),
                    mock.patch.object(harness.VM, "command", return_value=["fake-qemu"]),
                    mock.patch.object(
                        harness.subprocess,
                        "Popen",
                        side_effect=AssertionError("QEMU must not start for an unsafe writable path"),
                    ),
                ):
                    with self.assertRaisesRegex(harness.HarnessError, "must be inside"):
                        vm.start()

    def test_disk_creator_rejects_a_noncanonical_target_before_qemu_img(self):
        with self.harness_context():
            paths = self.paths_from_environment()
            other_disk = paths.test_dir / "other-disk.img"
            with mock.patch.object(
                harness,
                "require_command",
                side_effect=AssertionError("qemu-img must not run for an unsafe target"),
            ):
                with self.assertRaisesRegex(harness.HarnessError, "disposable disk.img"):
                    harness.qemu_disk_create(paths, other_disk)

    def test_vm_rejects_hard_linked_writable_inputs_before_qemu_starts(self):
        """A generated filename must not alias an external writable inode."""

        with self.harness_context():
            paths = self.paths_from_environment()
            paths.ensure_test_dir()
            code_path = self.root / "code.fd"
            code_path.write_bytes(b"code")
            outside_disk = self.root / "outside-disk.img"
            outside_disk.write_bytes(b"outside disk")
            outside_vars = self.root / "outside-vars.fd"
            outside_vars.write_bytes(b"outside variables")
            vars_path = paths.test_dir / "vars.fd"

            def assert_refused(disk: Path, variables: Path) -> None:
                vm = harness.VM(paths, disk, variables, code_path, "hard-link")
                with (
                    mock.patch.object(harness.VM, "command", return_value=["fake-qemu"]),
                    mock.patch.object(
                        harness.subprocess,
                        "Popen",
                        side_effect=AssertionError("QEMU must not start for a hard-linked writable path"),
                    ),
                ):
                    with self.assertRaisesRegex(harness.HarnessError, "hard-linked"):
                        vm.start()

            os.link(outside_disk, paths.disk)
            vars_path.write_bytes(b"variables")
            assert_refused(paths.disk, vars_path)
            self.assertEqual(outside_disk.read_bytes(), b"outside disk")
            paths.disk.unlink()
            vars_path.unlink()

            paths.disk.write_bytes(b"disk")
            os.link(outside_vars, vars_path)
            assert_refused(paths.disk, vars_path)
            self.assertEqual(outside_vars.read_bytes(), b"outside variables")

    def test_cleanup_refuses_to_delete_a_non_socket_endpoint(self):
        with self.harness_context():
            paths = self.paths_from_environment()
            endpoint = paths.output("not-a-socket")
            endpoint.write_text("do not delete\n")
            vm = object.__new__(harness.VM)
            vm.paths = paths

            with self.assertRaisesRegex(harness.HarnessError, "non-owned QEMU control endpoint"):
                vm._remove_owned_endpoint(endpoint)

            self.assertEqual(endpoint.read_text(), "do not delete\n")

    def test_new_attempt_removes_only_prior_success_reports(self):
        with self.harness_context():
            paths = self.paths_from_environment()
            fingerprint = paths.output(harness.FINGERPRINT_FILENAME)
            metadata = paths.output("acceptance-metadata.txt")
            unrelated = paths.output("keep.log")
            fingerprint.write_text("old retained-disk verdict\n")
            metadata.write_text("result: passed\n")
            unrelated.write_text("retain diagnostic\n")

            harness.invalidate_prior_success(paths)

            self.assertFalse(fingerprint.exists())
            self.assertFalse(metadata.exists())
            self.assertEqual(unrelated.read_text(), "retain diagnostic\n")

    def test_failed_publication_removes_its_partial_success_evidence(self):
        with self.harness_context():
            paths = self.paths_from_environment()
            iso = self.root / "home-installer.iso"
            iso.write_bytes(b"iso")
            with mock.patch.object(
                harness,
                "write_acceptance_metadata",
                side_effect=harness.HarnessError("metadata write failed"),
            ):
                with self.assertRaisesRegex(harness.HarnessError, "metadata write failed"):
                    harness.publish_acceptance_success(
                        paths,
                        iso=iso,
                        disk=paths.disk,
                        fingerprint={},
                        boot_seconds=0,
                        session_facts={},
                        target_metrics={},
                        screenshots=[],
                    )
            self.assertFalse((paths.test_dir / harness.FINGERPRINT_FILENAME).exists())
            self.assertFalse((paths.test_dir / "acceptance-metadata.txt").exists())

    def test_screenshot_change_guard_still_accepts_a_terminal_sized_delta(self):
        with self.harness_context():
            paths = self.paths_from_environment()
            width, height = 320, 200
            before_pixels = bytearray(width * height * 3)
            after_pixels = bytearray(before_pixels)
            for y in range(20, 30):
                for x in range(40, 80):
                    offset = (y * width + x) * 3
                    after_pixels[offset : offset + 3] = b"\xff\xff\xff"

            def write_ppm(path, pixels):
                path.write_bytes(f"P6\n{width} {height}\n255\n".encode() + pixels)

            before = paths.output("before.ppm")
            after = paths.output("after.ppm")
            write_ppm(before, before_pixels)
            write_ppm(after, after_pixels)
            harness.assert_screenshot_changed(before, after)

    def test_screenshot_change_guard_rejects_a_nonrendered_tiny_delta(self):
        with self.harness_context():
            paths = self.paths_from_environment()
            width, height = 320, 200
            before_pixels = bytearray(width * height * 3)
            after_pixels = bytearray(before_pixels)
            after_pixels[0:3] = b"\xff\xff\xff"

            def write_ppm(path, pixels):
                path.write_bytes(f"P6\n{width} {height}\n255\n".encode() + pixels)

            before = paths.output("tiny-before.ppm")
            after = paths.output("tiny-after.ppm")
            write_ppm(before, before_pixels)
            write_ppm(after, after_pixels)
            with self.assertRaisesRegex(harness.HarnessError, "terminal-sized region"):
                harness.assert_screenshot_changed(before, after)


if __name__ == "__main__":
    unittest.main()
