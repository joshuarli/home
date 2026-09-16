#!/usr/bin/env python3
"""Small host-side QEMU harness for the x86_64 installer loop.

The harness deliberately owns only files below QEMU_TEST_DIR.  It uses the
same Q35/OVMF/SATA/virtio profile for unattended tests and for `make run`; the
test-specific fw_cfg values are the only automation input supplied to the
live installer.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import signal
import socket
import stat
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Optional


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_TEST_DIR = ROOT / "dist" / "qemu"
QEMU_MACHINE = "pc-q35-9.2"
FINGERPRINT_FILENAME = "disk.fingerprint.json"
FINGERPRINT_VERSION = 1
FINGERPRINT_INPUTS = (
    "Dockerfile",
    "rootfs-packages.txt",
    "build/build-rootfs.sh",
    "build/build-iso.sh",
    "installer/install.sh",
    "iso/mkimg.home_installer.sh",
    "iso/genapkovl-home-installer.sh",
    "rootfs/configure.sh",
    "rootfs/patch-initramfs.sh",
    "rootfs/fetch.sh",
    "rootfs/home-login",
    "rootfs/home-session",
    "rootfs/home-runtime.initd",
    "rootfs/foot.ini",
    "qemu/harness.py",
)


class HarnessError(RuntimeError):
    """An expected, actionable harness failure."""


def say(message: str) -> None:
    print(message, flush=True)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_json(value: object) -> str:
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


def fail(message: str) -> "NoReturn":
    raise HarnessError(message)


def command_path(name: str) -> Optional[str]:
    return shutil.which(name)


def require_command(name: str) -> str:
    path = command_path(name)
    if not path:
        fail(f"required host command is missing: {name}")
    return path


def absolute_path(value: str | Path) -> Path:
    path = Path(value)
    if not path.is_absolute():
        path = ROOT / path
    # Keep this lexical.  Generated-path validation must see a symlink before
    # resolving it; read-only firmware paths are checked separately below.
    return Path(os.path.abspath(os.fspath(path)))


def path_is_within(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
    except ValueError:
        return False
    return True


def reject_symlink_components(path: Path, stop: Path) -> None:
    """Reject symlinks in a generated path, including its parent components."""

    current = stop
    try:
        relative = path.relative_to(stop)
    except ValueError:
        fail(f"generated path is outside its designated directory: {path}")
    for component in relative.parts:
        current = current / component
        if current.is_symlink():
            fail(f"refusing symlink in generated path: {current}")


def validate_generated_file(path: Path, directory: Path, *, replace: bool) -> None:
    """Validate a host output before the harness creates or replaces it."""

    directory = absolute_path(directory)
    path = absolute_path(path)
    if not path_is_within(path, directory) or path == directory:
        fail(f"generated file must be inside {directory}: {path}")
    reject_symlink_components(path, directory)
    resolved = path.resolve(strict=False)
    if not path_is_within(resolved, directory.resolve(strict=False)):
        fail(f"generated path resolves outside its designated directory: {path}")

    if not path.exists():
        return
    info = path.lstat()
    if stat.S_ISLNK(info.st_mode):
        fail(f"refusing symlink output: {path}")
    if not stat.S_ISREG(info.st_mode):
        fail(f"refusing non-regular output: {path}")
    if info.st_uid != os.getuid():
        fail(f"refusing output not owned by the current user: {path}")
    if not replace:
        fail(f"output already exists: {path}")


def prepare_generated_file(path: Path, directory: Path) -> Path:
    """Remove one previously-owned regular output and return its path."""

    directory.mkdir(parents=True, exist_ok=True)
    validate_generated_file(path, directory, replace=True)
    if path.exists():
        path.unlink()
    return path


def prepare_generated_socket(path: Path, directory: Path) -> Path:
    """Replace one stale socket created by an earlier harness process."""

    directory.mkdir(parents=True, exist_ok=True)
    directory = absolute_path(directory)
    path = absolute_path(path)
    if not path_is_within(path, directory) or path == directory:
        fail(f"generated socket must be inside {directory}: {path}")
    reject_symlink_components(path, directory)
    if not path.exists():
        return path
    info = path.lstat()
    if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid():
        fail(f"refusing existing non-owned QEMU control endpoint: {path}")
    path.unlink()
    return path


def check_positive_int(value: str, name: str) -> int:
    try:
        number = int(value, 10)
    except ValueError:
        fail(f"{name} must be a positive integer: {value}")
    if number <= 0:
        fail(f"{name} must be a positive integer: {value}")
    return number


def env_int(name: str, default: int) -> int:
    value = os.environ.get(name)
    return default if value is None else check_positive_int(value, name)


def run_capture(args: list[str], *, check: bool = True) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if check and result.returncode != 0:
        fail(f"command failed ({result.returncode}): {' '.join(args)}\n{result.stdout}")
    return result


def read_regular_file(path: Path, description: str) -> Path:
    if not path.is_absolute():
        path = absolute_path(path)
    if path.is_symlink() or path != path.resolve(strict=False) or not path.is_file():
        fail(f"{description} is not a regular, non-symlink file: {path}")
    return path


@dataclass(frozen=True)
class FirmwarePair:
    code: Path
    vars_template: Path
    source: str


def source_fingerprint() -> dict[str, str]:
    """Hash the product and harness inputs that make a retained disk valid."""

    files: dict[str, str] = {}
    for relative in FINGERPRINT_INPUTS:
        path = ROOT / relative
        if path.is_symlink() or not path.is_file():
            fail(f"fingerprint input is not a regular, non-symlink file: {path}")
        files[relative] = sha256_file(path)
    return files


def qemu_profile() -> dict[str, object]:
    """Return the host VM contract shared by acceptance and retained runs."""

    return {
        "machine": QEMU_MACHINE,
        "cpu": "Broadwell",
        "acceleration": "tcg",
        "memory_mb": env_int("QEMU_MEMORY_MB", 1024),
        "smp": env_int("QEMU_SMP", 4),
        "storage": "ICH9 AHCI SATA",
        "gpu": "virtio-gpu-pci",
        "input": ["virtio-keyboard-pci", "virtio-mouse-pci"],
        "automated_renderer": "pixman via fw_cfg opt/home-renderer",
        "network": "virtio-net-pci user-mode networking",
    }


def fingerprint_payload(iso: Path, pair: FirmwarePair) -> dict[str, object]:
    """Describe the build, firmware and VM profile used to create a disk."""

    iso = read_regular_file(iso, "installer ISO")
    source_files = source_fingerprint()
    profile = qemu_profile()
    return {
        "format": FINGERPRINT_VERSION,
        "iso": {
            "path": os.fspath(iso.relative_to(ROOT)) if path_is_within(iso, ROOT) else os.fspath(iso),
            "bytes": iso.stat().st_size,
            "sha256": sha256_file(iso),
        },
        "source_files": source_files,
        "source_sha256": sha256_json(source_files),
        "qemu_profile": profile,
        "qemu_profile_sha256": sha256_json(profile),
        "ovmf": {
            "code_sha256": sha256_file(pair.code),
            "vars_template_sha256": sha256_file(pair.vars_template),
        },
    }


def firmware_pair() -> FirmwarePair:
    code_override = os.environ.get("OVMF_CODE", "")
    vars_override = os.environ.get("OVMF_VARS", "")
    if bool(code_override) != bool(vars_override):
        fail("OVMF_CODE and OVMF_VARS must be supplied together")
    if code_override:
        return FirmwarePair(
            read_regular_file(absolute_path(code_override), "OVMF_CODE"),
            read_regular_file(absolute_path(vars_override), "OVMF_VARS"),
            "explicit pair",
        )

    candidates = [
        (
            ROOT / "dist" / "qemu" / "firmware" / "edk2-ovmf-nightly" / "x64" / "code.fd",
            ROOT / "dist" / "qemu" / "firmware" / "edk2-ovmf-nightly" / "x64" / "vars.fd",
            "pinned EDK2 OVMF bundle",
        ),
        (
            Path("/opt/homebrew/share/qemu/edk2-x86_64-code.fd"),
            Path("/opt/homebrew/share/qemu/edk2-i386-vars.fd"),
            "Homebrew EDK2 pair",
        ),
        (
            Path("/opt/homebrew/share/qemu/OVMF_CODE.fd"),
            Path("/opt/homebrew/share/qemu/OVMF_VARS.fd"),
            "Homebrew OVMF pair",
        ),
        (
            Path("/usr/local/share/qemu/edk2-x86_64-code.fd"),
            Path("/usr/local/share/qemu/edk2-i386-vars.fd"),
            "system EDK2 pair",
        ),
        (
            Path("/usr/local/share/qemu/OVMF_CODE.fd"),
            Path("/usr/local/share/qemu/OVMF_VARS.fd"),
            "system OVMF pair",
        ),
    ]
    for code, vars_template, source in candidates:
        if code.is_file() and vars_template.is_file() and not code.is_symlink() and not vars_template.is_symlink():
            return FirmwarePair(code, vars_template, source)
    fail("no compatible OVMF CODE/VARS pair found; run make fetch-edk2-ovmf or set both OVMF_CODE and OVMF_VARS")


@dataclass
class Paths:
    test_dir: Path
    disk: Path

    @classmethod
    def from_environment(cls) -> "Paths":
        raw_dir = os.environ.get("QEMU_TEST_DIR", str(DEFAULT_TEST_DIR))
        test_dir = absolute_path(raw_dir)
        generated_root = absolute_path(DEFAULT_TEST_DIR)
        if test_dir == Path("/") or test_dir == Path("/dev") or test_dir == ROOT:
            fail(f"unsafe QEMU test directory: {test_dir}")
        if not path_is_within(test_dir, generated_root):
            fail(f"QEMU_TEST_DIR must be inside the repository generated directory: {generated_root}")
        if generated_root.exists() and generated_root.is_symlink():
            fail(f"QEMU generated directory must not be a symlink: {generated_root}")
        reject_symlink_components(test_dir, generated_root)
        if test_dir.exists() and test_dir.is_symlink():
            fail(f"QEMU test directory must not be a symlink: {test_dir}")
        if test_dir.exists() and not test_dir.is_dir():
            fail(f"QEMU test directory is not a directory: {test_dir}")
        if test_dir.exists() and test_dir.stat().st_uid != os.getuid():
            fail(f"QEMU test directory is not owned by the current user: {test_dir}")
        raw_disk = os.environ.get("QEMU_DISK", str(test_dir / "disk.img"))
        disk = absolute_path(raw_disk)
        if not path_is_within(disk, test_dir):
            fail(f"QEMU_DISK must be inside QEMU_TEST_DIR ({test_dir}): {disk}")
        if disk.name != "disk.img":
            fail(f"QEMU_DISK must be the disposable disk.img inside QEMU_TEST_DIR: {disk}")
        reject_symlink_components(disk, test_dir)
        return cls(test_dir, disk)

    def output(self, name: str, *, replace: bool = True) -> Path:
        path = self.test_dir / name
        if replace:
            return prepare_generated_file(path, self.test_dir)
        validate_generated_file(path, self.test_dir, replace=False)
        return path


def copy_vars(template: Path, destination: Path, paths: Paths) -> Path:
    template = read_regular_file(template, "OVMF variable template")
    destination = prepare_generated_file(destination, paths.test_dir)
    shutil.copyfile(template, destination)
    return destination


def disk_fingerprint_path(paths: Paths) -> Path:
    return paths.test_dir / FINGERPRINT_FILENAME


def write_disk_fingerprint(paths: Paths, payload: dict[str, object]) -> Path:
    path = prepare_generated_file(disk_fingerprint_path(paths), paths.test_dir)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    return path


def current_disk_fingerprint(paths: Paths, iso: Path, pair: FirmwarePair) -> dict[str, object]:
    path = disk_fingerprint_path(paths)
    validate_generated_file(path, paths.test_dir, replace=True)
    if not path.is_file():
        fail(f"retained QEMU disk has no fingerprint; run make test first: {path}")
    try:
        stored = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        fail(f"retained QEMU disk fingerprint is unreadable: {path}: {error}")
    if not isinstance(stored, dict) or stored.get("format") != FINGERPRINT_VERSION:
        fail(f"retained QEMU disk fingerprint is incompatible: {path}; run make test")
    expected = fingerprint_payload(iso, pair)
    if stored != expected:
        fail(
            "retained QEMU disk is stale for the current ISO, source, firmware, "
            "or VM profile; run make test to recreate it"
        )
    return expected


class Serial:
    def __init__(self, sock: socket.socket, log_path: Path) -> None:
        self.sock = sock
        self.sock.setblocking(False)
        self.log_path = log_path
        self.buffer = bytearray()

    def read_available(self) -> str:
        changed = False
        while True:
            try:
                data = self.sock.recv(65536)
            except BlockingIOError:
                break
            except OSError:
                break
            if not data:
                break
            self.buffer.extend(data)
            changed = True
        if changed:
            self.log_path.write_bytes(bytes(self.buffer))
        return bytes(self.buffer).decode("utf-8", "replace")

    def send(self, value: str | bytes) -> None:
        data = value.encode() if isinstance(value, str) else value
        try:
            self.sock.sendall(data)
        except OSError as error:
            fail(f"could not write to guest serial console: {error}")

    def wait_for(self, pattern: str, timeout: float) -> str:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            text = self.read_available()
            if pattern in text:
                return text
            time.sleep(0.1)
        text = self.read_available()
        fail(f"timed out waiting for serial marker {pattern!r}; see {self.log_path}\n{text[-2000:]}")

    def wait_for_after(self, pattern: str, start: int, timeout: float) -> str:
        """Wait for a marker that must occur after an earlier buffer offset."""

        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            text = self.read_available()
            if pattern in text[start:]:
                return text
            time.sleep(0.1)
        text = self.read_available()
        fail(f"timed out waiting for serial marker {pattern!r} after command; see {self.log_path}\n{text[-2000:]}")

    def close(self) -> None:
        self.read_available()
        self.sock.close()


class QMP:
    def __init__(self, sock: socket.socket) -> None:
        self.sock = sock
        self.sock.settimeout(10)
        self.file = sock.makefile("rwb", buffering=0)
        greeting = self._read_message()
        if "QMP" not in greeting:
            fail(f"unexpected QMP greeting: {greeting}")
        self.command("qmp_capabilities")

    def _read_message(self) -> dict:
        line = self.file.readline()
        if not line:
            fail("QMP socket closed")
        try:
            return json.loads(line.decode("utf-8"))
        except json.JSONDecodeError as error:
            fail(f"invalid QMP response: {error}: {line!r}")

    def command(self, execute: str, arguments: Optional[dict] = None) -> dict:
        payload = {"execute": execute}
        if arguments:
            payload["arguments"] = arguments
        self.file.write((json.dumps(payload) + "\r\n").encode())
        while True:
            response = self._read_message()
            if "event" in response:
                continue
            if "error" in response:
                fail(f"QMP {execute} failed: {response['error']}")
            return response.get("return", {})

    def send_key(self, keys: Iterable[str]) -> None:
        self.command(
            "send-key",
            {"keys": [{"type": "qcode", "data": key} for key in keys]},
        )

    def chord(self, *keys: str) -> None:
        self.send_key(keys)

    def screenshot(self, path: Path) -> None:
        self.command("screendump", {"filename": str(path)})

    def powerdown(self) -> None:
        self.command("system_powerdown")

    def quit(self) -> None:
        self.command("quit")

    def close(self) -> None:
        try:
            self.file.close()
        finally:
            self.sock.close()


def connect_unix(path: Path, process: subprocess.Popen[bytes], timeout: float) -> socket.socket:
    deadline = time.monotonic() + timeout
    last_error: Optional[Exception] = None
    while time.monotonic() < deadline:
        if process.poll() is not None:
            fail(f"QEMU exited before opening {path} (status {process.returncode})")
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            sock.connect(str(path))
            return sock
        except OSError as error:
            last_error = error
            sock.close()
            time.sleep(0.1)
    fail(f"timed out connecting to QEMU socket {path}: {last_error}")


@dataclass
class VM:
    paths: Paths
    disk: Path
    vars_path: Path
    code_path: Path
    stage: str
    iso: Optional[Path] = None
    disk_format: str = "raw"
    network: bool = True
    test_seed: bool = False
    qemu_renderer: bool = False
    display: str = "none"
    no_reboot: bool = False
    memory: int = 1024
    smp: int = 4
    process: Optional[subprocess.Popen[bytes]] = None
    serial: Optional[Serial] = None
    qmp: Optional[QMP] = None
    serial_log: Optional[Path] = None
    stderr_log: Optional[Path] = None
    qmp_path: Optional[Path] = None
    serial_path: Optional[Path] = None

    def command(self) -> list[str]:
        qemu = require_command("qemu-system-x86_64")
        args = [
            qemu,
            "-name",
            f"home-installer-{self.stage}",
            "-machine",
            f"{QEMU_MACHINE},accel=tcg",
            "-cpu",
            "Broadwell",
            "-m",
            str(self.memory),
            "-smp",
            str(self.smp),
            "-drive",
            f"if=pflash,format=raw,readonly=on,file={self.code_path}",
            "-drive",
            f"if=pflash,format=raw,file={self.vars_path}",
            "-drive",
            f"if=none,id=target,format={self.disk_format},file={self.disk}",
            "-device",
            "ich9-ahci,id=sata",
            "-device",
            "ide-hd,bus=sata.2,drive=target,bootindex=2",
            "-device",
            "virtio-gpu-pci",
            "-device",
            "virtio-keyboard-pci",
            "-device",
            "virtio-mouse-pci",
        ]
        if self.qemu_renderer:
            args.extend(["-fw_cfg", "name=opt/home-renderer,string=pixman"])
        if self.iso:
            args.extend(
                [
                    "-drive",
                    f"if=none,id=installer,format=raw,media=cdrom,readonly=on,file={self.iso}",
                    "-device",
                    "ide-cd,bus=sata.1,drive=installer,bootindex=1",
                ]
            )
        if self.network:
            args.extend(["-netdev", "user,id=net0", "-device", "virtio-net-pci,netdev=net0"])
        else:
            args.extend(["-net", "none"])
        if self.test_seed:
            args.extend(
                [
                    "-fw_cfg",
                    "name=opt/home-installer-test,string=home-installer-qemu-v1",
                    "-fw_cfg",
                    "name=opt/home-secure-boot,string=disabled",
                ]
            )
        args.extend(["-display", self.display, "-monitor", "none"])
        if self.no_reboot:
            args.append("-no-reboot")
        return args

    def start(self) -> None:
        self.paths.test_dir.mkdir(parents=True, exist_ok=True)
        qmp_path = prepare_generated_socket(self.paths.test_dir / f"{self.stage}.qmp", self.paths.test_dir)
        serial_path = prepare_generated_socket(self.paths.test_dir / f"{self.stage}.serial", self.paths.test_dir)
        self.qmp_path = qmp_path
        self.serial_path = serial_path
        self.serial_log = self.paths.output(f"{self.stage}.serial.log")
        self.stderr_log = self.paths.output(f"{self.stage}.qemu.log")
        invocation = self.paths.output(f"{self.stage}.invocation.json")
        invocation.write_text(json.dumps(self.command(), indent=2) + "\n")

        args = self.command()
        args.extend(
            [
                "-qmp",
                f"unix:{qmp_path},server=on,wait=off",
                "-chardev",
                f"socket,id=serial0,path={serial_path},server=on,wait=off",
                "-serial",
                "chardev:serial0",
            ]
        )
        stderr = self.stderr_log.open("wb")
        self.process = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=stderr, stderr=stderr)
        qmp_socket = connect_unix(qmp_path, self.process, 30)
        serial_socket = connect_unix(serial_path, self.process, 30)
        self.qmp = QMP(qmp_socket)
        self.serial = Serial(serial_socket, self.serial_log)

    def require_live(self) -> tuple[subprocess.Popen[bytes], Serial, QMP]:
        if not self.process or not self.serial or not self.qmp:
            fail(f"VM {self.stage} is not running")
        return self.process, self.serial, self.qmp

    def wait_for_exit(self, timeout: float) -> int:
        process, serial, _ = self.require_live()
        deadline = time.monotonic() + timeout
        while process.poll() is None and time.monotonic() < deadline:
            serial.read_available()
            time.sleep(0.2)
        if process.poll() is None:
            fail(f"VM {self.stage} did not exit before the {timeout:.0f}s deadline")
        serial.read_available()
        return int(process.returncode)

    def clean_shutdown(self, timeout: float = 60) -> None:
        process, serial, qmp = self.require_live()
        try:
            # Alpine's minimal target does not run an ACPI daemon.  Request a
            # real guest poweroff through the already-authenticated serial
            # recovery shell, then retain QMP as a bounded fallback.
            serial.send("doas poweroff\n")
        except (HarnessError, OSError):
            pass
        deadline = time.monotonic() + timeout
        while process.poll() is None and time.monotonic() < deadline:
            serial.read_available()
            time.sleep(0.2)
        if process.poll() is None:
            try:
                qmp.powerdown()
            except HarnessError:
                pass
            deadline = time.monotonic() + timeout
            while process.poll() is None and time.monotonic() < deadline:
                serial.read_available()
                time.sleep(0.2)
        if process.poll() is None:
            fail(f"VM {self.stage} did not complete a clean shutdown")
        serial.read_available()

    def abort(self) -> None:
        if not self.process:
            return
        if self.process.poll() is None and self.qmp:
            try:
                self.qmp.quit()
            except (HarnessError, OSError):
                pass
        if self.process.poll() is None:
            try:
                self.process.send_signal(signal.SIGTERM)
            except OSError:
                pass
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=10)
        if self.serial:
            self.serial.close()
        if self.qmp:
            self.qmp.close()

    def close(self) -> None:
        if self.process and self.process.poll() is None:
            self.abort()
        else:
            if self.serial:
                self.serial.close()
            if self.qmp:
                self.qmp.close()
        for endpoint in (self.qmp_path, self.serial_path):
            if endpoint and endpoint.is_socket():
                endpoint.unlink()


def shutdown_and_close(vm: VM) -> None:
    try:
        vm.clean_shutdown()
    finally:
        vm.close()


def serial_command(vm: VM, command: str, timeout: float = 10) -> str:
    _, serial, _ = vm.require_live()
    marker = f"__HOME_E2E_{time.monotonic_ns()}__"
    start = len(serial.read_available())
    serial.send(f"{command}; printf '%s\\n' '{marker}'\n")
    output = serial.wait_for_after(marker, start, timeout)
    marker_end = output.find(marker, start) + len(marker)
    # The marker is printed before ash emits the next prompt.  Wait for that
    # fresh prompt before sending another command so the guest tty cannot
    # overrun while the shell is returning to its read loop.
    return serial.wait_for_after("~ $ ", marker_end, timeout)


FACTS_PROCESS_COMMAND = r"""dwl_count=0; foot_count=0; process_count=0; dwl_uid=; foot_uid=; foot_wayland=0; for proc in /proc/[0-9]*; do [ -r "$proc/comm" ] || continue; process_count=$((process_count + 1)); comm=$(cat "$proc/comm" 2>/dev/null || true); if [ "$comm" = dwl ]; then dwl_count=$((dwl_count + 1)); [ -n "$dwl_uid" ] || dwl_uid=$(awk '/^Uid:/ {print $2; exit}' "$proc/status" 2>/dev/null || true); elif [ "$comm" = foot ]; then foot_count=$((foot_count + 1)); [ -n "$foot_uid" ] || foot_uid=$(awk '/^Uid:/ {print $2; exit}' "$proc/status" 2>/dev/null || true); if [ -r "$proc/environ" ] && tr '\000' '\n' < "$proc/environ" 2>/dev/null | grep -q '^WAYLAND_DISPLAY='; then foot_wayland=$((foot_wayland + 1)); fi; fi; done; printf 'fact_dwl=%s\n' $dwl_count; printf 'fact_foot=%s\n' $foot_count; printf 'fact_processes=%s\n' $process_count; [ -n "$dwl_uid" ] && printf 'fact_dwl_uid=%s\n' $dwl_uid; [ -n "$foot_uid" ] && printf 'fact_foot_uid=%s\n' $foot_uid; printf 'fact_foot_wayland=%s\n' $foot_wayland"""

FACTS_RUNTIME_COMMAND = r"""printf 'fact_user=%s\n' $(id -un); printf 'fact_uid=%s\n' $(id -u); printf 'fact_runtime=%s\n' $(stat -c '%u:%g:%a' /run/user/1000 2>/dev/null || echo missing); printf 'fact_runtime_owner=%s\n' $(stat -c '%u:%g:%a' /run/user/1000 2>/dev/null || echo missing); if find /run/user/1000 -maxdepth 1 -type s -name 'wayland-*' 2>/dev/null | grep -q .; then echo fact_wayland=present; wayland_socket=$(find /run/user/1000 -maxdepth 1 -type s -name 'wayland-*' -print -quit); printf 'fact_wayland_socket=%s\n' $(stat -c '%u:%g:%a' "$wayland_socket" 2>/dev/null || echo missing); else echo fact_wayland=missing; fi; [ -e /dev/dri/card0 ] && echo fact_drm=present || echo fact_drm=missing; [ -e /dev/input/event0 ] && echo fact_input=present || echo fact_input=missing; [ -S /run/seatd.sock ] && echo fact_seat=present || echo fact_seat=missing; printf 'fact_seat_socket=%s\n' $(stat -c '%u:%g:%a' /run/seatd.sock 2>/dev/null || echo missing); printf 'fact_mem_available_kib=%s\n' $(awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo)"""


def facts(vm: VM, timeout: float = 10) -> dict[str, str]:
    output = serial_command(vm, FACTS_PROCESS_COMMAND, timeout)
    output += "\n" + serial_command(vm, FACTS_RUNTIME_COMMAND, timeout)
    result: dict[str, str] = {}
    for line in output.splitlines():
        if line.startswith("fact_") and "=" in line:
            name, value = line.split("=", 1)
            result[name] = value.strip()
    return result


def wait_for_session(vm: VM, expected_foot: int, timeout: float = 120) -> dict[str, str]:
    deadline = time.monotonic() + timeout
    # The VM's serial socket is opened before OpenRC has started ttyS0.  Do
    # not inject a facts command into the boot stream: bytes sent before the
    # login shell exists are lost or can leave only a truncated command in
    # the line discipline.  The prompt is the bounded readiness handshake for
    # the serial recovery shell; the graphical-session facts remain separate.
    _, serial, _ = vm.require_live()
    serial.wait_for("~ $ ", timeout)
    last: dict[str, str] = {}
    while time.monotonic() < deadline:
        last = facts(vm, timeout=min(10, max(1, deadline - time.monotonic())))
        if (
            last.get("fact_user") == "josh"
            and last.get("fact_uid") == "1000"
            and last.get("fact_dwl") == "1"
            and last.get("fact_foot") == str(expected_foot)
            and last.get("fact_dwl_uid") == "1000"
            and last.get("fact_foot_uid") == "1000"
            and last.get("fact_foot_wayland") == str(expected_foot)
            and last.get("fact_runtime") == "1000:1000:700"
            and last.get("fact_wayland") == "present"
            and last.get("fact_wayland_socket", "").startswith("1000:")
            and last.get("fact_drm") == "present"
            and last.get("fact_input") == "present"
            and last.get("fact_seat") == "present"
            and last.get("fact_seat_socket") != "missing"
        ):
            return last
        time.sleep(1)
    fail(f"graphical session did not reach the expected state; facts={last}; see {vm.serial_log}")


def write_acceptance_metadata(
    paths: Paths,
    *,
    iso: Path,
    disk: Path,
    fingerprint: dict[str, object],
    boot_seconds: float,
    session_facts: dict[str, str],
    target_metrics: dict[str, str],
    screenshots: list[Path],
) -> None:
    ovmf = fingerprint["ovmf"]
    if not isinstance(ovmf, dict):
        fail("acceptance fingerprint has invalid OVMF metadata")
    lines = [
        "Home installer QEMU acceptance metadata",
        "result: passed",
        f"qemu_machine: {QEMU_MACHINE}",
        "qemu_acceleration: tcg",
        "qemu_cpu: Broadwell",
        f"qemu_memory_mb: {env_int('QEMU_MEMORY_MB', 1024)}",
        f"qemu_smp: {env_int('QEMU_SMP', 4)}",
        "storage: ICH9 AHCI SATA",
        f"iso_bytes: {iso.stat().st_size}",
        f"iso_sha256: {sha256_file(iso)}",
        f"disk: {disk}",
        f"disk_fingerprint: {FINGERPRINT_FILENAME}",
        f"source_sha256: {fingerprint['source_sha256']}",
        f"qemu_profile_sha256: {fingerprint['qemu_profile_sha256']}",
        f"ovmf_code_sha256: {ovmf.get('code_sha256', 'unknown')}",
        f"ovmf_vars_template_sha256: {ovmf.get('vars_template_sha256', 'unknown')}",
        f"boot_to_usable_terminal_seconds: {boot_seconds:.3f}",
        f"steady_state_processes: {session_facts.get('fact_processes', 'unknown')}",
        f"idle_mem_available_kib: {session_facts.get('fact_mem_available_kib', 'unknown')}",
        f"enabled_services: {target_metrics.get('services', 'unknown')}",
        f"installed_efi_bytes: {target_metrics.get('efi_bytes', 'unknown')}",
        f"installed_root_used_kib: {target_metrics.get('root_used_kib', 'unknown')}",
        f"wayland_socket: {session_facts.get('fact_wayland_socket', 'unknown')}",
        f"seat_socket: {session_facts.get('fact_seat_socket', 'unknown')}",
        "screenshots:",
    ]
    lines.extend(f"  {path.name}: {screenshot_hash(path)}" for path in screenshots)
    lines.append("artifacts:")
    acceptance_stages = {
        "installer",
        "installed",
        "offline-reboot",
        "offline-reboot-boot",
        "fallback-prepare",
        "fallback",
        "regeneration-canonical",
        "regeneration-canonical-boot",
        "regeneration-fallback",
        "regeneration-fallback-boot",
    }
    for path in sorted(paths.test_dir.iterdir()):
        if path.name == "acceptance-metadata.txt" or not path.is_file() or path.is_symlink():
            continue
        if path.name == FINGERPRINT_FILENAME:
            lines.append(f"  {path.name}: bytes={path.stat().st_size} sha256={sha256_file(path)}")
            continue
        stage = next(
            (
                candidate
                for candidate in acceptance_stages
                if path.name == candidate
                or path.name.startswith(candidate + ".")
                or path.name.startswith(candidate + "-")
            ),
            None,
        )
        if stage and (path.suffix in {".log", ".json", ".ppm"} or path.name.endswith(".fd")):
            lines.append(f"  {path.name}: bytes={path.stat().st_size} sha256={sha256_file(path)}")
    paths.output("acceptance-metadata.txt").write_text("\n".join(lines) + "\n")


def send_text(qmp: QMP, text: str) -> None:
    """Type a small US-layout ASCII string through QEMU's input device."""

    direct = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    punctuation = {
        " ": ("spc",),
        "/": ("slash",),
        ".": ("dot",),
        ">": ("shift", "dot"),
        "_": ("shift", "minus"),
        "-": ("minus",),
        "=": ("equal",),
        "\n": ("ret",),
    }
    for character in text:
        if character in direct:
            if character.isupper():
                qmp.chord("shift", character.lower())
            else:
                qmp.chord(character)
        elif character in punctuation:
            qmp.chord(*punctuation[character])
        else:
            fail(f"QEMU text injection does not support this character: {character!r}")


def read_ppm(path: Path) -> tuple[int, int, bytes]:
    data = path.read_bytes()
    if not data.startswith(b"P6"):
        fail(f"QEMU screenshot is not a binary PPM: {path}")
    header_end = data.find(b"\n255\n")
    if header_end < 0:
        fail(f"QEMU screenshot has no complete PPM header: {path}")
    header = data[: header_end + len(b"\n255\n")].split()
    if len(header) < 4:
        fail(f"QEMU screenshot header is incomplete: {path}")
    width, height = int(header[1]), int(header[2])
    pixels = data[header_end + len(b"\n255\n") :]
    if width < 320 or height < 200 or len(pixels) < width * height * 3:
        fail(f"QEMU screenshot has an implausible display size: {path}")
    return width, height, pixels[: width * height * 3]


def assert_screenshot(path: Path) -> str:
    data = path.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    width, height, pixels = read_ppm(path)
    sample = pixels[: width * height * 3]
    nonblack = sum(1 for value in sample if value > 8)
    if nonblack < max(100, len(sample) // 1000):
        fail(f"QEMU screenshot is effectively blank: {path}")
    return f"{width}x{height} sha256={digest} nonblack-bytes={nonblack}"


def screenshot_hash(path: Path) -> str:
    return sha256_file(path)


def assert_screenshot_changed(before: Path, after: Path) -> None:
    if screenshot_hash(before) == screenshot_hash(after):
        fail(f"graphical output did not change between {before} and {after}")
    before_width, before_height, before_pixels = read_ppm(before)
    after_width, after_height, after_pixels = read_ppm(after)
    if (before_width, before_height) != (after_width, after_height):
        fail(f"graphical output dimensions changed between {before} and {after}")

    changed = 0
    min_x = before_width
    min_y = before_height
    max_x = max_y = -1
    for offset in range(0, len(before_pixels), 3):
        if max(
            abs(before_pixels[offset + channel] - after_pixels[offset + channel])
            for channel in range(3)
        ) <= 8:
            continue
        changed += 1
        pixel = offset // 3
        y, x = divmod(pixel, before_width)
        min_x = min(min_x, x)
        min_y = min(min_y, y)
        max_x = max(max_x, x)
        max_y = max(max_y, y)
    # A command must alter a glyph-sized region of the terminal viewport.  The
    # independent marker check below establishes which command ran; this
    # bounded pixel assertion establishes that rendered terminal content, not
    # merely a QEMU cursor or process count, changed on screen.
    if changed < 200 or max_x - min_x < 30 or max_y - min_y < 8:
        fail(
            "graphical output changed without a rendered terminal-sized region "
            f"between {before} and {after} (pixels={changed}, "
            f"bounds={min_x},{min_y}..{max_x},{max_y})"
        )


def qemu_disk_create(paths: Paths, disk: Path) -> None:
    qemu_img = require_command("qemu-img")
    validate_generated_file(disk, paths.test_dir, replace=True)
    if disk.exists():
        disk.unlink()
    fingerprint = disk_fingerprint_path(paths)
    validate_generated_file(fingerprint, paths.test_dir, replace=True)
    if fingerprint.exists():
        fingerprint.unlink()
    subprocess.run([qemu_img, "create", "-f", "raw", str(disk), "8G"], check=True)


def qemu_disk_overlay(paths: Paths, base: Path, overlay: Path) -> None:
    qemu_img = require_command("qemu-img")
    base = read_regular_file(base, "installed QEMU disk")
    validate_generated_file(overlay, paths.test_dir, replace=True)
    if overlay.exists():
        overlay.unlink()
    subprocess.run(
        [qemu_img, "create", "-f", "qcow2", "-F", "raw", "-b", str(base), str(overlay)],
        check=True,
    )


def make_vm(
    paths: Paths,
    pair: FirmwarePair,
    disk: Path,
    vars_path: Path,
    stage: str,
    *,
    iso: Optional[Path] = None,
    disk_format: str = "raw",
    network: bool = True,
    test_seed: bool = False,
    qemu_renderer: bool = False,
    display: str = "none",
    no_reboot: bool = False,
) -> VM:
    return VM(
        paths=paths,
        disk=disk,
        vars_path=vars_path,
        code_path=pair.code,
        stage=stage,
        iso=iso,
        disk_format=disk_format,
        network=network,
        test_seed=test_seed,
        qemu_renderer=qemu_renderer,
        display=display,
        no_reboot=no_reboot,
        memory=env_int("QEMU_MEMORY_MB", 1024),
        smp=env_int("QEMU_SMP", 4),
    )


def installed_session_stage(
    paths: Paths,
    pair: FirmwarePair,
    disk: Path,
    vars_path: Path,
    stage: str,
    *,
    network: bool,
    disk_format: str = "raw",
    no_reboot: bool = False,
) -> VM:
    vm = make_vm(
        paths,
        pair,
        disk,
        vars_path,
        stage,
        network=network,
        disk_format=disk_format,
        no_reboot=no_reboot,
        qemu_renderer=True,
    )
    vm.start()
    return vm


def test_installer(iso: Path) -> None:
    iso = read_regular_file(absolute_path(iso), "installer ISO")
    paths = Paths.from_environment()
    paths.test_dir.mkdir(parents=True, exist_ok=True)
    pair = firmware_pair()
    fingerprint = fingerprint_payload(iso, pair)
    disk = paths.disk
    qemu_disk_create(paths, disk)
    installer_vars = copy_vars(pair.vars_template, paths.output("installer-vars.fd"), paths)
    vm = make_vm(paths, pair, disk, installer_vars, "installer", iso=iso, test_seed=True)
    say(f"QEMU installer profile: Q35/Broadwell/TCG, SATA target={disk}")
    say("Booting the generated ISO through OVMF; the fw_cfg seed supplies explicit test input.")
    try:
        vm.start()
        status = vm.wait_for_exit(600)
        serial = vm.serial_log.read_text(errors="replace") if vm.serial_log else ""
        if "Installation complete." not in serial:
            fail(f"installer VM exited without successful installation (status {status}); see {vm.serial_log}")
        if status != 0:
            fail(f"installer VM exited with status {status}; see {vm.serial_log}")
    finally:
        vm.close()

    boot_started = time.monotonic()
    installed = installed_session_stage(paths, pair, disk, installer_vars, "installed", network=True)
    accepted_session_facts: dict[str, str] = {}
    target_metrics: dict[str, str] = {}
    screenshot_paths: list[Path] = []
    try:
        initial = wait_for_session(installed, 1)
        accepted_session_facts = initial
        boot_seconds = time.monotonic() - boot_started
        metric_output = serial_command(
            installed,
            "printf 'efi_bytes=%s\\n' \"$(doas stat -c %s /boot/EFI/alpine/linux-lts.efi)\"; "
            "printf 'root_used_kib=%s\\n' \"$(df -kP / | tail -n 1 | awk '{print $3}')\"; "
            "printf 'services=%s\\n' \"$(rc-status --all 2>/dev/null | tr '\\n' ' ')\"",
        )
        for line in metric_output.splitlines():
            if "=" in line and line.split("=", 1)[0] in {"efi_bytes", "root_used_kib", "services"}:
                name, value = line.split("=", 1)
                target_metrics[name] = value.strip()
        screenshot = paths.output("installed-terminal.ppm")
        installed.qmp.screenshot(screenshot)
        say(f"installed screenshot: {assert_screenshot(screenshot)}")
        screenshot_paths.append(screenshot)

        # A plain Return is not a binding and must not create a second client.
        installed.qmp.chord("ret")
        time.sleep(2)
        if facts(installed).get("fact_foot") != "1":
            fail("ordinary Return unexpectedly created a terminal")

        # Verify upstream dwl's exact Alt+Shift+Return binding and a command
        # in the graphical PTY.
        installed.qmp.chord("alt", "shift", "ret")
        wait_for_session(installed, 2)
        marker = f"e2emarker{time.monotonic_ns()}"
        marker_path = f"/tmp/{marker}"
        serial_command(installed, f"rm -f {marker_path}")
        before_command = paths.output("installed-terminal-before-command.ppm")
        installed.qmp.screenshot(before_command)
        say(f"pre-command screenshot: {assert_screenshot(before_command)}")
        screenshot_paths.append(before_command)
        send_text(installed.qmp, f"echo {marker} > {marker_path}\n")
        deadline = time.monotonic() + 15
        marker_seen = False
        while time.monotonic() < deadline:
            output = serial_command(installed, f"cat {marker_path} 2>/dev/null || true", timeout=5)
            if marker in output:
                marker_seen = True
                break
            time.sleep(1)
        if not marker_seen:
            fail("the graphical terminal command did not produce its independent marker")
        after_marker = paths.output("installed-terminal-after-command.ppm")
        installed.qmp.screenshot(after_marker)
        say(f"rendered command screenshot: {assert_screenshot(after_marker)}")
        assert_screenshot_changed(before_command, after_marker)
        screenshot_paths.append(after_marker)

        env_marker = f"e2eenv{time.monotonic_ns()}"
        env_path = f"/tmp/{env_marker}"
        serial_command(installed, f"rm -f {env_path}")
        send_text(installed.qmp, f"env > {env_path}\n")
        env_output = ""
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            env_output = serial_command(installed, f"cat {env_path} 2>/dev/null || true", timeout=5)
            if "WAYLAND_DISPLAY=" in env_output:
                break
            time.sleep(1)
        for expected in (
            "HOME=/home/josh",
            "USER=josh",
            "SHELL=/bin/ash",
            "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            "XDG_RUNTIME_DIR=/run/user/1000",
            "XDG_SESSION_TYPE=wayland",
            "WAYLAND_DISPLAY=",
        ):
            if expected not in env_output:
                fail(f"graphical terminal environment is missing {expected!r}")

        # Close the second client and then the original.  dwl must remain alive.
        installed.qmp.chord("alt", "shift", "c")
        wait_for_session(installed, 1)
        installed.qmp.chord("alt", "shift", "c")
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            current = facts(installed)
            if current.get("fact_dwl") == "1" and current.get("fact_foot") == "0":
                break
            time.sleep(1)
        else:
            fail("closing the last foot client did not leave dwl running")
        installed.qmp.chord("alt", "shift", "ret")
        wait_for_session(installed, 1)

        # Use the real recovery VT and compositor exit path.  tty2 must stay an
        # ash recovery login; it is not allowed to start another dwl.
        installed.qmp.chord("ctrl", "alt", "f2")
        time.sleep(2)
        send_text(installed.qmp, "josh\n")
        time.sleep(2)
        recovery_marker = f"recovery{time.monotonic_ns()}"
        recovery_path = f"/tmp/{recovery_marker}"
        serial_command(installed, f"rm -f {recovery_path}")
        send_text(installed.qmp, f"echo {recovery_marker} > {recovery_path}\n")
        recovery_output = ""
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            recovery_output = serial_command(
                installed, f"cat {recovery_path} 2>/dev/null || true", timeout=5
            )
            if recovery_marker in recovery_output:
                break
            time.sleep(1)
        else:
            fail("tty2 did not reach an ash recovery login")
        recovery_facts = facts(installed)
        if recovery_facts.get("fact_dwl") != "1" or recovery_facts.get("fact_foot") != "1":
            fail("recovery VT changed the compositor count")
        # Return through the still-authenticated recovery shell.  This
        # exercises the real VT path without depending on QEMU's
        # Ctrl+Alt+F1 shortcut to restore wlroots' keyboard focus.
        send_text(installed.qmp, "chvt 1\n")
        time.sleep(2)
        installed.qmp.chord("alt", "shift", "q")
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            current = facts(installed)
            if current.get("fact_dwl") == "0":
                break
            time.sleep(1)
        else:
            fail("dwl did not exit through its documented recovery binding")
        # The compositor returns to the tty1 shell, which is the same display
        # input path.  Exit that recovery shell and require a bounded,
        # single-session autologin restart.
        send_text(installed.qmp, "exit\n")
        wait_for_session(installed, 1)
    finally:
        shutdown_and_close(installed)

    # A real reboot with no network must still reach the desktop. Record the
    # first process and boot the same disk again as a separate stage so the
    # post-reboot observation is unambiguous.
    offline = installed_session_stage(
        paths,
        pair,
        disk,
        installer_vars,
        "offline-reboot",
        network=False,
        no_reboot=True,
    )
    try:
        wait_for_session(offline, 1)
        offline.serial.send("doas reboot\n")
        offline.wait_for_exit(150)
    finally:
        offline.close()
    offline_boot_vars = copy_vars(pair.vars_template, paths.output("offline-boot-vars.fd"), paths)
    offline_boot = installed_session_stage(
        paths, pair, disk, offline_boot_vars, "offline-reboot-boot", network=False
    )
    try:
        wait_for_session(offline_boot, 1, timeout=150)
    finally:
        shutdown_and_close(offline_boot)

    # Prove the fallback path rather than merely inferring it from fresh
    # variables: remove the canonical path on a disposable COW overlay, then
    # boot that overlay with fresh variables. Only BOOTX64.EFI can succeed.
    fallback_disk = paths.output("fallback-overlay.qcow2")
    qemu_disk_overlay(paths, disk, fallback_disk)
    fallback_prepare_vars = copy_vars(
        pair.vars_template, paths.output("fallback-prepare-vars.fd"), paths
    )
    fallback_prepare = installed_session_stage(
        paths,
        pair,
        fallback_disk,
        fallback_prepare_vars,
        "fallback-prepare",
        network=False,
        disk_format="qcow2",
    )
    try:
        wait_for_session(fallback_prepare, 1)
        serial_command(fallback_prepare, "doas rm -f /boot/EFI/alpine/linux-lts.efi")
    finally:
        shutdown_and_close(fallback_prepare)
    fallback_vars = copy_vars(pair.vars_template, paths.output("fallback-vars.fd"), paths)
    fallback = installed_session_stage(
        paths,
        pair,
        fallback_disk,
        fallback_vars,
        "fallback",
        network=False,
        disk_format="qcow2",
    )
    try:
        wait_for_session(fallback, 1)
    finally:
        shutdown_and_close(fallback)

    # Regenerate both EFI images on separate disposable overlays.  Remove one
    # image on each overlay, then boot with fresh variables.  This proves each
    # path independently, rather than proving only that the files match.
    for name, removed_path in (
        ("regeneration-canonical", "/boot/EFI/BOOT/BOOTX64.EFI"),
        ("regeneration-fallback", "/boot/EFI/alpine/linux-lts.efi"),
    ):
        regen_disk = paths.output(f"{name}-overlay.qcow2")
        qemu_disk_overlay(paths, disk, regen_disk)
        regen_vars = copy_vars(pair.vars_template, paths.output(f"{name}-vars.fd"), paths)
        regen = installed_session_stage(
            paths,
            pair,
            regen_disk,
            regen_vars,
            name,
            network=False,
            disk_format="qcow2",
        )
        try:
            wait_for_session(regen, 1)
            command = (
                "doas sh -c 'apk --no-network fix kernel-hooks && "
                "trigger=/usr/libexec/home-installer/kernel-hooks.trigger; "
                "m=$(basename $(find /lib/modules -mindepth 1 -maxdepth 1 -type d -name \"*-lts\" | head -n 1)); "
                "\"$trigger\" \"/lib/modules/$m\"; "
                "cmp /boot/EFI/alpine/linux-lts.efi /boot/EFI/BOOT/BOOTX64.EFI'"
            )
            serial_command(regen, command, timeout=120)
            serial_command(regen, f"doas rm -f -- {removed_path}")
        finally:
            shutdown_and_close(regen)

        # The canonical Alpine path is normally selected by the installer-created
        # NVRAM entry, while a fresh variable store selects only the EFI
        # fallback path.  Reuse that tested entry for the canonical-path case;
        # keep the fallback case on a genuinely fresh store.
        boot_vars_template = installer_vars if name == "regeneration-canonical" else pair.vars_template
        boot_vars = copy_vars(boot_vars_template, paths.output(f"{name}-boot-vars.fd"), paths)
        boot = installed_session_stage(
            paths,
            pair,
            regen_disk,
            boot_vars,
            f"{name}-boot",
            network=False,
            disk_format="qcow2",
        )
        try:
            wait_for_session(boot, 1)
            say(f"kernel hook regeneration: {name} booted with {removed_path} removed")
        finally:
            shutdown_and_close(boot)

    write_disk_fingerprint(paths, fingerprint)
    write_acceptance_metadata(
        paths,
        iso=iso,
        disk=disk,
        fingerprint=fingerprint,
        boot_seconds=boot_seconds,
        session_facts=accepted_session_facts,
        target_metrics=target_metrics,
        screenshots=screenshot_paths,
    )
    say(f"QEMU acceptance test passed; disposable disk retained at {disk}")


def interactive_run() -> None:
    paths = Paths.from_environment()
    disk = read_regular_file(paths.disk, "retained QEMU disk")
    pair = firmware_pair()
    iso = read_regular_file(ROOT / "dist" / "home-installer.iso", "current installer ISO")
    current_disk_fingerprint(paths, iso, pair)
    paths.test_dir.mkdir(parents=True, exist_ok=True)
    vars_path = paths.test_dir / "run-vars.fd"
    if vars_path.exists():
        validate_generated_file(vars_path, paths.test_dir, replace=True)
    else:
        copy_vars(pair.vars_template, vars_path, paths)

    qemu = require_command("qemu-system-x86_64")
    display = os.environ.get("QEMU_DISPLAY")
    if not display:
        display = "cocoa" if platform.system() == "Darwin" else "gtk"
    vm = make_vm(paths, pair, disk, vars_path, "interactive", display=display)
    args = vm.command() + ["-serial", "stdio"]
    say("Starting the retained installed VM. Close QEMU or use its guest controls to stop it.")
    os.execv(qemu, args)


def doctor() -> None:
    missing = []
    for name in ("docker", "python3", "qemu-system-x86_64", "qemu-img"):
        if not command_path(name):
            missing.append(name)
    if missing:
        fail("missing host prerequisites: " + ", ".join(missing))
    qemu = require_command("qemu-system-x86_64")
    machine = run_capture([qemu, "-machine", "help"]).stdout
    cpu = run_capture([qemu, "-cpu", "help"]).stdout
    devices = run_capture([qemu, "-device", "help"]).stdout
    displays = run_capture([qemu, "-display", "help"]).stdout
    requirements = {
        f"machine {QEMU_MACHINE}": QEMU_MACHINE in machine,
        "Broadwell CPU": re.search(r"^\s*Broadwell(?:[-.\s]|$)", cpu, re.MULTILINE) is not None,
        "virtio GPU": "virtio-gpu-pci" in devices,
        "virtio keyboard": "virtio-keyboard-pci" in devices,
        "virtio mouse": "virtio-mouse-pci" in devices,
        "ICH9 AHCI": "ich9-ahci" in devices,
        "SATA ide-hd": "ide-hd" in devices,
        "interactive display": any(name in displays for name in ("cocoa", "sdl", "gtk")),
    }
    for name, available in requirements.items():
        say(f"{'ok' if available else 'missing'}: {name}")
    if not all(requirements.values()):
        fail("installed QEMU does not expose the required x86_64 test profile")
    buildx = run_capture([require_command("docker"), "buildx", "version"], check=False)
    if buildx.returncode != 0:
        fail(f"Docker Buildx is unavailable:\n{buildx.stdout}")
    say(f"ok: {qemu}")
    say("ok: Docker and Buildx are available for the linux/amd64 image build")
    say("note: TCG is required for the Intel guest on macOS arm64; HVF is not used")
    say("note: QEMU Ethernet/virtio GPU/input do not certify physical Wi-Fi/i915/touchpad behavior")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("doctor")
    test_parser = subparsers.add_parser("test")
    test_parser.add_argument("--iso", default=str(ROOT / "dist" / "home-installer.iso"))
    subparsers.add_parser("run")
    args = parser.parse_args(argv)
    if args.command == "doctor":
        doctor()
    elif args.command == "test":
        test_installer(args.iso)
    elif args.command == "run":
        interactive_run()
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except HarnessError as error:
        print(f"QEMU harness: ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)
