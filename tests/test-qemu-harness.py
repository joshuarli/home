#!/usr/bin/env python3
"""Focused host-only regressions for QEMU harness control boundaries."""

from __future__ import annotations

import errno
import os
import pty
import re
import subprocess
import sys
import tempfile
import unittest
from collections import deque
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "qemu"))
import harness  # noqa: E402


FRAME_TOKEN = re.compile(rb"__home_token='([0-9a-f]+)'")


class RunningProcess:
    returncode = None

    def poll(self):
        return self.returncode


class ScriptedSocket:
    """A nonblocking serial peer which can echo input and fragment output."""

    def __init__(self, handler, *, initial: bytes = b"~ $ "):
        self.handler = handler
        self.incoming = deque([initial])
        self.sent: list[bytes] = []
        self.closed = False

    def setblocking(self, value):
        self.blocking = value

    def sendall(self, data):
        self.sent.append(data)
        self.handler(self, data)

    def recv(self, size):
        if self.closed:
            return b""
        if not self.incoming:
            raise BlockingIOError()
        value = self.incoming.popleft()
        if value is None:
            self.closed = True
            return b""
        if len(value) <= size:
            return value
        self.incoming.appendleft(value[size:])
        return value[:size]

    def close(self):
        self.closed = True


class PTYSocket:
    """The socket-shaped subset Serial needs for a real local shell PTY."""

    def __init__(self, descriptor):
        self.descriptor = descriptor
        self.closed = False

    def setblocking(self, value):
        os.set_blocking(self.descriptor, value)

    def sendall(self, data):
        offset = 0
        while offset < len(data):
            offset += os.write(self.descriptor, data[offset:])

    def recv(self, size):
        try:
            return os.read(self.descriptor, size)
        except OSError as error:
            # A PTY master reports EIO when its last slave closes; Serial
            # treats that equivalently to a socket EOF.
            if error.errno == errno.EIO:
                return b""
            raise

    def close(self):
        if not self.closed:
            self.closed = True
            os.close(self.descriptor)


def frame(data: bytes, status: int, output: bytes = b"") -> bytes:
    match = FRAME_TOKEN.search(data)
    if not match:
        raise AssertionError(f"serial command did not carry a frame token: {data!r}")
    prefix = b"\x1eHOME_SERIAL_" + match.group(1)
    return prefix + b"_BEGIN\x1f" + output + prefix + b"_STATUS_" + str(status).encode() + b"\x1f"


class FakeVM:
    def __init__(self, serial):
        self.process = RunningProcess()
        self.serial = serial

    def require_live(self):
        return self.process, self.serial, object()


class SerialCommandTests(unittest.TestCase):
    def make_vm(self, handler):
        temporary = tempfile.TemporaryDirectory(prefix="home-qemu-serial-test-")
        self.addCleanup(temporary.cleanup)
        serial = harness.Serial(ScriptedSocket(handler), Path(temporary.name) / "serial.log")
        return FakeVM(serial)

    def test_checked_nonzero_guest_command_fails(self):
        def handler(sock, data):
            sock.incoming.append(frame(data, 0 if b"stty -echo" in data else 1))

        vm = self.make_vm(handler)
        with self.assertRaisesRegex(harness.HarnessError, "guest command failed with status 1"):
            harness.serial_command(vm, "false", timeout=0.1)

    def test_expected_nonzero_result_is_available_without_checking(self):
        def handler(sock, data):
            sock.incoming.append(frame(data, 0 if b"stty -echo" in data else 23))

        vm = self.make_vm(handler)
        result = harness.serial_command(vm, "false", timeout=0.1, check=False)
        self.assertEqual(result.returncode, 23)
        self.assertEqual(result.status, 23)
        self.assertEqual(result.output, "")

    def test_fragmented_fresh_output_excludes_the_frame(self):
        def handler(sock, data):
            reply = frame(data, 0) if b"stty -echo" in data else frame(data, 0, b"fresh output\n")
            sock.incoming.extend(bytes([byte]) for byte in reply)

        vm = self.make_vm(handler)
        result = harness.serial_command(vm, "printf fresh", timeout=0.2)
        self.assertEqual(result.output, "fresh output\n")
        self.assertEqual(result.returncode, 0)

    def test_preframe_stale_bytes_are_not_command_output(self):
        def handler(sock, data):
            if b"stty -echo" in data:
                sock.incoming.append(frame(data, 0))
            else:
                sock.incoming.append(b"late prior output\n" + frame(data, 0, b"fresh output\n"))

        vm = self.make_vm(handler)
        result = harness.serial_command(vm, "printf fresh", timeout=0.1)
        self.assertEqual(result.output, "fresh output\n")

    def test_readiness_helper_does_not_return_the_historical_transcript(self):
        temporary = tempfile.TemporaryDirectory(prefix="home-qemu-readiness-test-")
        self.addCleanup(temporary.cleanup)
        serial = harness.Serial(
            ScriptedSocket(lambda sock, data: None, initial=b"old boot output\n~ $ "),
            Path(temporary.name) / "serial.log",
        )

        self.assertEqual(
            serial.wait_for("~ $ ", 0.1, process=RunningProcess()),
            "~ $ ",
        )
        self.assertIn(b"old boot output", serial.transcript)

    def test_real_pty_preserves_early_failure_and_excludes_echo(self):
        master, slave = pty.openpty()
        process = subprocess.Popen(
            ["/bin/sh", "-i"],
            stdin=slave,
            stdout=slave,
            stderr=slave,
            close_fds=True,
        )
        os.close(slave)
        temporary = tempfile.TemporaryDirectory(prefix="home-qemu-pty-test-")
        self.addCleanup(temporary.cleanup)
        serial = harness.Serial(PTYSocket(master), Path(temporary.name) / "serial.log")
        vm = FakeVM(serial)
        vm.process = process
        try:
            serial.send("PS1='HOME_READY> '; export PS1\n")
            serial.wait_for("HOME_READY> ", 1, process=process)
            serial.INITIAL_PROMPT = "HOME_READY> "
            result = harness.serial_command(
                vm,
                "printf 'first\\n'; false; printf 'second\\n'",
                timeout=1,
                check=False,
            )
            self.assertEqual(result.returncode, 1)
            self.assertEqual(result.output, "first\n")
        finally:
            try:
                serial.close()
            finally:
                if process.poll() is None:
                    process.terminate()
                process.wait(timeout=5)

    def test_real_pty_reports_status_when_control_shell_has_errexit(self):
        """A failed child command must not kill the framed control shell."""

        master, slave = pty.openpty()
        process = subprocess.Popen(
            ["/bin/sh", "-i"],
            stdin=slave,
            stdout=slave,
            stderr=slave,
            close_fds=True,
        )
        os.close(slave)
        temporary = tempfile.TemporaryDirectory(prefix="home-qemu-pty-errexit-test-")
        self.addCleanup(temporary.cleanup)
        serial = harness.Serial(PTYSocket(master), Path(temporary.name) / "serial.log")
        try:
            serial.send("PS1='HOME_READY> '; export PS1\n")
            serial.wait_for("HOME_READY> ", 1, process=process)
            serial.INITIAL_PROMPT = "HOME_READY> "
            serial.establish_shell(process, 1)
            serial._send_framed_script(
                command="enable errexit",
                script="set -e; __home_status=0",
                process=process,
                timeout=1,
            )

            result = serial.command("false", process=process, timeout=1)

            self.assertEqual(result.returncode, 1)
            self.assertEqual(result.output, "")
            self.assertIsNone(process.poll())
        finally:
            try:
                serial.close()
            finally:
                if process.poll() is None:
                    process.terminate()
                process.wait(timeout=5)

    def test_echoed_transport_input_cannot_satisfy_a_frame(self):
        def handler(sock, data):
            sock.incoming.append(data)
            if b"stty -echo" in data:
                sock.incoming.append(frame(data, 0))

        vm = self.make_vm(handler)
        with self.assertRaisesRegex(harness.HarnessError, "timed out waiting for serial command frame"):
            harness.serial_command(vm, "printf never-ran", timeout=0.02)

    def test_previous_command_frame_cannot_satisfy_the_next_command(self):
        command_count = 0

        def handler(sock, data):
            nonlocal command_count
            if b"stty -echo" in data:
                sock.incoming.append(frame(data, 0))
                return
            if command_count == 0:
                command_count += 1
                sock.incoming.append(frame(data, 0, b"previous output\n"))

        vm = self.make_vm(handler)
        first = harness.serial_command(vm, "printf previous", timeout=0.1)
        self.assertEqual(first.output, "previous output\n")
        with self.assertRaisesRegex(harness.HarnessError, "timed out waiting for serial command frame"):
            harness.serial_command(vm, "printf never-ran", timeout=0.02)

    def test_eof_cannot_produce_a_successful_result(self):
        def handler(sock, data):
            if b"stty -echo" in data:
                sock.incoming.append(frame(data, 0))
            else:
                sock.incoming.append(None)

        vm = self.make_vm(handler)
        with self.assertRaisesRegex(harness.HarnessError, "serial console reached EOF"):
            harness.serial_command(vm, "printf never-ran", timeout=0.1)

    def test_withheld_graphical_input_cannot_satisfy_the_challenge(self):
        responses = [
            harness.SerialCommandResult(command="cat", output="", returncode=1),
            harness.SerialCommandResult(command="cat", output="", returncode=1),
        ]
        original = harness.serial_command

        def missing_file(*args, **kwargs):
            return responses.pop(0) if responses else harness.SerialCommandResult("cat", "", 1)

        harness.serial_command = missing_file
        self.addCleanup(setattr, harness, "serial_command", original)
        with self.assertRaisesRegex(harness.HarnessError, "did not produce readable output"):
            harness.wait_for_guest_file_output(
                object(), "/tmp/missing", "expected\n", "challenge", timeout=0.01
            )

    def test_empty_graphical_challenge_output_is_not_accepted(self):
        original = harness.serial_command

        def empty_file(*args, **kwargs):
            return harness.SerialCommandResult("cat", "", 0)

        harness.serial_command = empty_file
        self.addCleanup(setattr, harness, "serial_command", original)
        with self.assertRaisesRegex(harness.HarnessError, "unexpected output"):
            harness.wait_for_guest_file_output(
                object(), "/tmp/empty", "expected\n", "challenge", timeout=0.01
            )

    def test_failed_file_read_cannot_satisfy_a_graphical_challenge(self):
        original = harness.serial_command

        def failed_file_read(*args, **kwargs):
            return harness.SerialCommandResult("cat", "expected\n", 1)

        harness.serial_command = failed_file_read
        self.addCleanup(setattr, harness, "serial_command", original)
        with self.assertRaisesRegex(harness.HarnessError, "did not produce readable output"):
            harness.wait_for_guest_file_output(
                object(), "/tmp/missing", "expected\n", "challenge", timeout=0.01
            )


class GraphicalInputTests(unittest.TestCase):
    def test_graphical_challenge_can_type_a_pipe_to_tee(self):
        class QMP:
            def __init__(self):
                self.chords = []

            def chord(self, *keys):
                self.chords.append(keys)

        qmp = QMP()
        harness.send_text(qmp, "echo marker | tee /tmp/result\n")
        self.assertIn(("shift", "backslash"), qmp.chords)
        self.assertEqual(qmp.chords[-1], ("ret",))

    def test_graphical_challenge_can_read_the_prior_shell_status(self):
        class QMP:
            def __init__(self):
                self.chords = []

            def chord(self, *keys):
                self.chords.append(keys)

        qmp = QMP()
        harness.send_text(qmp, "echo $? > /tmp/status\n")
        self.assertIn(("shift", "4"), qmp.chords)
        self.assertIn(("shift", "slash"), qmp.chords)
        self.assertEqual(qmp.chords[-1], ("ret",))


class GuestShellContractTests(unittest.TestCase):
    def test_boot_mount_check_requires_an_exact_vfat_boot_mount(self):
        with tempfile.TemporaryDirectory(prefix="home-qemu-mounts-test-") as directory:
            mounts = Path(directory) / "mounts"

            def check(contents: str) -> int:
                mounts.write_text(contents)
                return subprocess.run(
                    ["/bin/sh", "-ec", harness.boot_mount_vfat_command(str(mounts))],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                ).returncode

            self.assertEqual(
                check("proc /proc proc rw 0 0\n/dev/sda1 /boot vfat rw 0 0\n"),
                0,
            )
            self.assertNotEqual(check("/dev/sda3 / ext4 rw 0 0\n"), 0)
            self.assertNotEqual(check("/dev/sda3 /boot ext4 rw 0 0\n"), 0)
            self.assertNotEqual(
                check("/dev/sda2 /boot vfat rw 0 0\n"),
                0,
            )

            with self.assertRaisesRegex(harness.HarnessError, "not a device path"):
                harness.boot_mount_vfat_command(expected_source="relative-esp")

    def test_cmdline_token_rewrite_preserves_other_quoted_settings(self):
        with tempfile.TemporaryDirectory(prefix="home-qemu-secureboot-conf-test-") as directory:
            config = Path(directory) / "secureboot.conf"
            original = (
                'cmdline="console=ttyS0 root=UUID=test rw"\n'
                "signing_disabled=yes\n"
                'output_dir="/boot/EFI/alpine"\n'
                'output_name="linux-{flavor}.efi"\n'
            )
            config.write_text(original)

            result = subprocess.run(
                [
                    "/bin/sh",
                    "-ec",
                    harness.append_cmdline_token_command(str(config), "test-regeneration-token"),
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                config.read_text(),
                (
                    'cmdline="console=ttyS0 root=UUID=test rw test-regeneration-token"\n'
                    "signing_disabled=yes\n"
                    'output_dir="/boot/EFI/alpine"\n'
                    'output_name="linux-{flavor}.efi"\n'
                ),
            )

            malformed = "cmdline=console=ttyS0 root=UUID=test rw\n"
            config.write_text(malformed)
            result = subprocess.run(
                [
                    "/bin/sh",
                    "-ec",
                    harness.append_cmdline_token_command(str(config), "test-regeneration-token"),
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(config.read_text(), malformed)


class CleanupTests(unittest.TestCase):
    def test_session_accepts_the_selected_bochs_drm_identity(self):
        class Serial:
            def establish_shell(self, process, timeout):
                return None

        class VM:
            serial_log = "test serial log"

            def require_live(self):
                return object(), Serial(), object()

        expected_facts = {
            "fact_user": "josh",
            "fact_uid": "1000",
            "fact_dwl": "1",
            "fact_foot": "1",
            "fact_dwl_uid": "1000",
            "fact_foot_uid": "1000",
            "fact_foot_wayland": "1",
            "fact_runtime": "1000:1000:700",
            "fact_wayland": "present",
            "fact_wayland_socket": "1000:1000:700",
            "fact_drm": "present",
            "fact_drm_device": "/dev/dri/card0",
            "fact_drm_device_realpath": "/dev/dri/card0",
            "fact_drm_driver": "bochs-drm",
            "fact_drm_identity": "/dev/dri/by-path/pci-0000:00:01.0-card",
            "fact_dwl_drm_device": "/dev/dri/card0",
            "fact_dwl_drm_open": "/dev/dri/card0",
            "fact_input": "present",
            "fact_seat": "present",
            "fact_seat_socket": "0:65535:770",
        }
        with (
            mock.patch.object(harness, "facts", return_value=expected_facts),
            mock.patch.object(harness.time, "monotonic", side_effect=[0, 0, 0, 2]),
            mock.patch.object(harness.time, "sleep"),
        ):
            self.assertEqual(harness.wait_for_session(VM(), 1, timeout=1), expected_facts)

    def test_command_failure_is_not_overwritten_by_cleanup_failure(self):
        class FailingVM:
            def clean_shutdown(self):
                raise harness.HarnessError("command failure")

            def close(self):
                raise harness.HarnessError("cleanup failure")

        with self.assertRaisesRegex(harness.HarnessError, "command failure") as caught:
            harness.shutdown_and_close(FailingVM())
        self.assertNotIn("cleanup failure", str(caught.exception))

    def test_stage_failure_is_not_overwritten_by_later_cleanup(self):
        class FailingVM:
            closed = False

            def close(self):
                self.closed = True
                raise harness.HarnessError("cleanup failure")

        vm = FailingVM()

        def failed_stage():
            try:
                raise harness.HarnessError("command failure")
            except BaseException as primary:
                harness.cleanup_after_failure(primary, "closing failed stage", vm.close)
                raise

        with self.assertRaisesRegex(harness.HarnessError, "command failure") as caught:
            failed_stage()
        self.assertTrue(vm.closed)
        self.assertNotIn("cleanup failure", str(caught.exception))
        if hasattr(caught.exception, "add_note"):
            self.assertIn(
                "cleanup failure while closing failed stage",
                "\n".join(getattr(caught.exception, "__notes__", [])),
            )

    def test_unexpected_qemu_exit_status_is_rejected(self):
        class ExitingProcess:
            def __init__(self):
                self.returncode = 17

            def poll(self):
                return self.returncode

        class Serial:
            def read_available(self):
                return b""

        vm = object.__new__(harness.VM)
        vm.stage = "exit-status"
        vm.process = ExitingProcess()
        vm.serial = Serial()
        vm.qmp = object()
        with self.assertRaisesRegex(harness.HarnessError, "unexpected status 17"):
            vm.wait_for_exit(0.1)

    def test_clean_shutdown_rejects_a_premature_zero_status_exit(self):
        class ExitingProcess:
            returncode = 0

            def poll(self):
                return self.returncode

        vm = object.__new__(harness.VM)
        vm.stage = "premature-exit"
        vm.process = ExitingProcess()
        vm.serial = object()
        vm.qmp = object()
        with self.assertRaisesRegex(harness.HarnessError, "exited unexpectedly before clean shutdown"):
            vm.clean_shutdown()

    def test_installed_stage_closes_a_vm_when_startup_fails(self):
        class FailingVM:
            def __init__(self):
                self.closed = False

            def start(self):
                raise harness.HarnessError("connection setup failed")

            def close(self):
                self.closed = True

        vm = FailingVM()
        original = harness.make_vm
        harness.make_vm = lambda *args, **kwargs: vm
        self.addCleanup(setattr, harness, "make_vm", original)
        with self.assertRaisesRegex(harness.HarnessError, "connection setup failed"):
            harness.installed_session_stage(None, None, None, None, "test", network=False)
        self.assertTrue(vm.closed)

    def test_vm_start_failure_closes_process_sockets_and_log_handle(self):
        class Process:
            def __init__(self):
                self.returncode = None
                self.terminated = False

            def poll(self):
                return self.returncode

            def send_signal(self, value):
                self.terminated = True
                self.returncode = -value

            def wait(self, timeout):
                if self.returncode is None:
                    self.returncode = 0
                return self.returncode

            def kill(self):
                self.returncode = -9

        class Socket:
            def __init__(self):
                self.closed = False

            def close(self):
                self.closed = True

        class QMP:
            def __init__(self, sock):
                self.sock = sock

            def quit(self):
                return None

            def close(self):
                self.sock.close()

        temporary = tempfile.TemporaryDirectory(prefix="home-qemu-vm-start-test-")
        self.addCleanup(temporary.cleanup)
        root = (Path(temporary.name) / "repository").resolve()
        root.mkdir()
        generated_root = root / "dist" / "qemu"
        process = Process()
        qmp_socket = Socket()
        serial_socket = Socket()
        log_handles = []

        def popen(*args, **kwargs):
            log_handles.append(kwargs["stdout"])
            return process

        with (
            mock.patch.object(harness, "ROOT", root),
            mock.patch.object(harness, "DEFAULT_TEST_DIR", generated_root),
            mock.patch.object(harness.VM, "command", return_value=["fake-qemu"]),
            mock.patch.object(harness.subprocess, "Popen", side_effect=popen),
            mock.patch.object(
                harness,
                "connect_unix",
                side_effect=[qmp_socket, serial_socket],
            ),
            mock.patch.object(harness, "QMP", QMP),
            mock.patch.object(harness, "Serial", side_effect=harness.HarnessError("serial setup failed")),
        ):
            paths = harness.Paths(generated_root, generated_root / "disk.img")
            paths.ensure_test_dir()
            paths.disk.write_bytes(b"disposable disk")
            vars_path = paths.output("vars.fd")
            vars_path.write_bytes(b"variables")
            vm = harness.VM(paths, paths.disk, vars_path, generated_root / "code.fd", "startup")
            with self.assertRaisesRegex(harness.HarnessError, "serial setup failed"):
                vm.start()

        self.assertTrue(process.terminated)
        self.assertTrue(qmp_socket.closed)
        self.assertTrue(serial_socket.closed)
        self.assertEqual(len(log_handles), 1)
        self.assertTrue(log_handles[0].closed)


if __name__ == "__main__":
    unittest.main()
