#!/usr/bin/env python3
"""Small host-side QEMU harness for the x86_64 installer loop.

The harness deliberately owns only files below QEMU_TEST_DIR.  It uses the
same Q35/OVMF/SATA/std-VGA profile for unattended tests and for `make run`; the
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
from typing import Callable, Iterable, NoReturn, Optional


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_TEST_DIR = ROOT / "dist" / "qemu"
QEMU_MACHINE = "pc-q35-9.2"
QEMU_GPU = "std"
QEMU_RENDERER = "pixman"
FINGERPRINT_FILENAME = "disk.fingerprint.json"
FINGERPRINT_VERSION = 1
FINGERPRINT_INPUTS = (
    "Dockerfile",
    "rootfs-packages.txt",
    "build/build-iso.sh",
    "installer/install.sh",
    "iso/mkimg.home_installer.sh",
    "iso/genapkovl-home-installer.sh",
    "rootfs/configure.sh",
    "rootfs/repositories",
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


def fail(message: str) -> NoReturn:
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


def lstat_if_exists(path: Path) -> Optional[os.stat_result]:
    """Return lstat data without following a possibly hostile final link."""

    try:
        return path.lstat()
    except FileNotFoundError:
        return None
    except OSError as error:
        fail(f"could not inspect generated path {path}: {error}")


def reject_symlink_components(path: Path, stop: Path) -> None:
    """Reject symlinks in a generated path, including its parent components."""

    path = absolute_path(path)
    stop = absolute_path(stop)
    try:
        relative = path.relative_to(stop)
    except ValueError:
        fail(f"generated path is outside its designated directory: {path}")
    current = stop
    info = lstat_if_exists(current)
    if info is not None:
        if stat.S_ISLNK(info.st_mode):
            fail(f"refusing symlink in generated path: {current}")
        if not stat.S_ISDIR(info.st_mode):
            fail(f"generated path ancestor is not a directory: {current}")
    for component in relative.parts:
        current = current / component
        info = lstat_if_exists(current)
        if info is None:
            continue
        if stat.S_ISLNK(info.st_mode):
            fail(f"refusing symlink in generated path: {current}")
        if current != path and not stat.S_ISDIR(info.st_mode):
            fail(f"generated path ancestor is not a directory: {current}")


def validate_generated_path(path: Path, directory: Path, description: str) -> tuple[Path, Path]:
    """Validate lexical containment before a generated path is touched."""

    directory = absolute_path(directory)
    path = absolute_path(path)
    if not path_is_within(path, directory) or path == directory:
        fail(f"generated {description} must be inside {directory}: {path}")
    reject_symlink_components(path, directory)
    resolved = path.resolve(strict=False)
    if not path_is_within(resolved, directory.resolve(strict=False)):
        fail(f"generated path resolves outside its designated directory: {path}")
    return path, directory


def validate_generated_file(path: Path, directory: Path, *, replace: bool) -> None:
    """Validate a host output before the harness creates or replaces it."""

    path, _ = validate_generated_path(path, directory, "file")
    info = lstat_if_exists(path)
    if info is None:
        return
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

    path, directory = validate_generated_path(path, directory, "file")
    directory.mkdir(parents=True, exist_ok=True)
    validate_generated_file(path, directory, replace=True)
    if lstat_if_exists(path) is not None:
        path.unlink()
    return path


def require_generated_regular_file(path: Path, directory: Path, description: str) -> Path:
    """Require an existing regular, user-owned writable QEMU input."""

    path, directory = validate_generated_path(path, directory, description)
    validate_generated_file(path, directory, replace=True)
    info = lstat_if_exists(path)
    if info is None:
        fail(f"required generated {description} does not exist: {path}")
    # Unlinking a previous generated output is safe for a hard link, but
    # passing one to QEMU is not: QEMU would write the external inode through
    # the generated name. A writable VM input must have one link of its own.
    if info.st_nlink != 1:
        fail(f"refusing hard-linked generated {description}: {path}")
    return path


def prepare_generated_socket(path: Path, directory: Path) -> Path:
    """Replace one stale socket created by an earlier harness process."""

    path, directory = validate_generated_path(path, directory, "socket")
    directory.mkdir(parents=True, exist_ok=True)
    path, _ = validate_generated_path(path, directory, "socket")
    info = lstat_if_exists(path)
    if info is None:
        return path
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
        "gpu": "std VGA (bochs-drm)",
        "input": ["virtio-keyboard-pci", "virtio-mouse-pci"],
        "renderer": "pixman via fw_cfg opt/home-renderer",
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


@dataclass(frozen=True)
class Paths:
    test_dir: Path
    disk: Path

    def __post_init__(self) -> None:
        object.__setattr__(self, "test_dir", absolute_path(self.test_dir))
        object.__setattr__(self, "disk", absolute_path(self.disk))
        self.validate()

    def validate(self) -> None:
        """Recheck the complete generated-tree boundary before each write."""

        generated_root = absolute_path(DEFAULT_TEST_DIR)
        repository_root = absolute_path(ROOT)
        if self.test_dir == Path("/") or self.test_dir == Path("/dev") or self.test_dir == repository_root:
            fail(f"unsafe QEMU test directory: {self.test_dir}")
        if not path_is_within(self.test_dir, generated_root):
            fail(f"QEMU_TEST_DIR must be inside the repository generated directory: {generated_root}")
        # Check from the trusted repository root, rather than only from
        # dist/qemu.  Otherwise a direct harness invocation can follow a
        # symlinked dist/ directory before the firmware-fetch script gets a
        # chance to reject it.
        reject_symlink_components(self.test_dir, repository_root)
        resolved_test_dir = self.test_dir.resolve(strict=False)
        resolved_repository_root = repository_root.resolve(strict=False)
        if not path_is_within(resolved_test_dir, resolved_repository_root):
            fail(f"QEMU generated directory resolves outside the repository: {self.test_dir}")
        info = lstat_if_exists(self.test_dir)
        if info is not None:
            if not stat.S_ISDIR(info.st_mode):
                fail(f"QEMU test directory is not a directory: {self.test_dir}")
            if info.st_uid != os.getuid():
                fail(f"QEMU test directory is not owned by the current user: {self.test_dir}")
        if self.disk != self.test_dir / "disk.img":
            fail(f"QEMU_DISK must be the disposable disk.img inside QEMU_TEST_DIR: {self.disk}")
        validate_generated_file(self.disk, self.test_dir, replace=True)

    @classmethod
    def from_environment(cls) -> "Paths":
        raw_dir = os.environ.get("QEMU_TEST_DIR", str(DEFAULT_TEST_DIR))
        test_dir = absolute_path(raw_dir)
        raw_disk = os.environ.get("QEMU_DISK", str(test_dir / "disk.img"))
        disk = absolute_path(raw_disk)
        return cls(test_dir, disk)

    def ensure_test_dir(self) -> None:
        """Create the already-validated generated directory without aliases."""

        self.validate()
        self.test_dir.mkdir(parents=True, exist_ok=True)
        self.validate()

    def output(self, name: str, *, replace: bool = True) -> Path:
        self.ensure_test_dir()
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


def invalidate_prior_success(paths: Paths) -> None:
    """Remove reports that could otherwise misrepresent a failed new attempt."""

    paths.ensure_test_dir()
    for path in (disk_fingerprint_path(paths), paths.test_dir / "acceptance-metadata.txt"):
        validate_generated_file(path, paths.test_dir, replace=True)
        if lstat_if_exists(path) is not None:
            path.unlink()


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


@dataclass(frozen=True)
class SerialCommandResult:
    """The exact output and exit status from one framed guest command."""

    command: str
    output: str
    returncode: int

    @property
    def status(self) -> int:
        """Compatibility-friendly spelling for callers discussing shell status."""

        return self.returncode


def shell_quote(value: str) -> str:
    """Quote one value for the already-established POSIX serial shell."""

    if "\x00" in value:
        fail("serial shell commands cannot contain NUL bytes")
    return "'" + value.replace("'", "'\"'\"'") + "'"


def boot_mount_vfat_command(
    mounts_path: str = "/proc/mounts", expected_source: str = "/dev/sda1"
) -> str:
    """Require the QEMU target's actual ESP, without depending on util-linux."""

    if not expected_source.startswith("/dev/"):
        fail(f"expected ESP source is not a device path: {expected_source!r}")

    return (
        "boot_source=\n"
        "boot_fstype=\n"
        "while read -r source mountpoint fstype options; do\n"
        '    [ "$mountpoint" = /boot ] || continue\n'
        "    boot_source=$source\n"
        "    boot_fstype=$fstype\n"
        "    break\n"
        f"done < {shell_quote(mounts_path)}\n"
        '[ "$boot_source" = '
        f"{shell_quote(expected_source)}"
        ' ] && [ "$boot_fstype" = vfat ]'
    )


def append_cmdline_token_command(config_path: str, token: str) -> str:
    """Append a safe test token inside one shell-quoted kernel command line."""

    if re.fullmatch(r"[A-Za-z0-9._-]+", token) is None:
        fail(f"kernel command-line token is not shell-safe: {token!r}")
    config = shell_quote(config_path)
    temporary_template = shell_quote(f"{config_path}.home-regeneration.XXXXXX")
    sed_program = f's#^cmdline="\\([^\"]*\\)"$#cmdline="\\1 {token}"#'
    token_suffix = shell_quote(f' {token}"')
    return (
        f"config={config}\n"
        "grep -Eq '^cmdline=\"[^\"]*\"$' \"$config\"\n"
        f"temporary=$(mktemp {temporary_template})\n"
        "trap 'rm -f \"$temporary\"' EXIT HUP INT TERM\n"
        f"sed {shell_quote(sed_program)} \"$config\" > \"$temporary\"\n"
        f"grep -Fq {token_suffix} \"$temporary\"\n"
        "mv -f \"$temporary\" \"$config\"\n"
        "trap - EXIT HUP INT TERM\n"
        f"grep -Fq {token_suffix} \"$config\""
    )


class Serial:
    """A serial transcript plus a silent, framed shell-control channel.

    The transcript is append-only diagnostics.  Command results are copied
    from the interval after a command is sent and before that command's
    cryptographically unpredictable status frame; callers never receive the
    transcript itself as a response object.
    """

    FRAME_PREFIX = b"\x1eHOME_SERIAL_"
    FRAME_BEGIN = b"_BEGIN"
    FRAME_STATUS = b"_STATUS_"
    FRAME_SUFFIX = b"\x1f"
    INITIAL_PROMPT = "~ $ "

    def __init__(self, sock: socket.socket, log_path: Path) -> None:
        self.sock = sock
        self.sock.setblocking(False)
        self.log_path = log_path
        self.transcript = bytearray()
        self._control_ready = False
        self._closed_by_host = False
        self._eof = False
        self._read_error: Optional[OSError] = None
        self._frame_sequence = 0

    def _append_transcript(self, data: bytes) -> None:
        self.transcript.extend(data)
        try:
            with self.log_path.open("ab") as stream:
                stream.write(data)
        except OSError as error:
            fail(f"could not append the serial transcript {self.log_path}: {error}")

    def read_available(self) -> str:
        """Read and return only newly available serial text, retaining diagnostics."""

        if self._closed_by_host:
            return ""
        received = bytearray()
        while True:
            try:
                data = self.sock.recv(65536)
            except BlockingIOError:
                break
            except InterruptedError:
                continue
            except OSError as error:
                self._read_error = error
                break
            if not data:
                self._eof = True
                break
            received.extend(data)
            self._append_transcript(data)
        return bytes(received).decode("utf-8", "replace")

    def _diagnostic_tail(self) -> str:
        return bytes(self.transcript[-2000:]).decode("utf-8", "replace")

    def _assert_usable(self, context: str) -> None:
        if self._read_error is not None:
            fail(f"could not read guest serial console while {context}: {self._read_error}; see {self.log_path}")
        if self._eof:
            fail(f"serial console reached EOF while {context}; see {self.log_path}\n{self._diagnostic_tail()}")
        if self._closed_by_host:
            fail(f"serial console is closed while {context}; see {self.log_path}")

    @staticmethod
    def _assert_process_live(process: subprocess.Popen[bytes], context: str) -> None:
        if process.poll() is not None:
            fail(f"QEMU exited unexpectedly while {context} (status {process.returncode})")

    def send(self, value: str | bytes) -> None:
        self._assert_usable("sending a serial command")
        data = value.encode() if isinstance(value, str) else value
        try:
            self.sock.sendall(data)
        except OSError as error:
            fail(f"could not write to guest serial console: {error}")

    def wait_for(
        self,
        pattern: str,
        timeout: float,
        *,
        process: Optional[subprocess.Popen[bytes]] = None,
        start: int = 0,
    ) -> str:
        """Wait for an initial serial readiness marker, never a command result."""

        deadline = time.monotonic() + timeout
        needle = pattern.encode()
        while True:
            if process is not None:
                self._assert_process_live(process, f"waiting for serial marker {pattern!r}")
            self.read_available()
            self._assert_usable(f"waiting for serial marker {pattern!r}")
            if needle in self.transcript[start:]:
                # This legacy readiness helper is intentionally kept distinct
                # from framed command results. It is used only for the one
                # initial shell prompt, before the silent control channel is
                # established. Do not expose the diagnostic transcript as a
                # response object even for this handshake.
                return pattern
            if time.monotonic() >= deadline:
                fail(
                    f"timed out waiting for serial marker {pattern!r}; see {self.log_path}\n"
                    f"{self._diagnostic_tail()}"
                )
            time.sleep(0.05)

    def _new_frame_token(self) -> str:
        self._frame_sequence += 1
        return f"{self._frame_sequence:x}{os.urandom(16).hex()}"

    def _wait_for_frame(
        self,
        *,
        command: str,
        token: str,
        start: int,
        process: subprocess.Popen[bytes],
        timeout: float,
    ) -> SerialCommandResult:
        """Extract output strictly between one begin and complete status frame."""

        frame_prefix = self.FRAME_PREFIX + token.encode()
        begin = frame_prefix + self.FRAME_BEGIN + self.FRAME_SUFFIX
        status_prefix = frame_prefix + self.FRAME_STATUS
        deadline = time.monotonic() + timeout
        while True:
            self._assert_process_live(process, f"waiting for serial command {command!r}")
            self.read_available()
            self._assert_usable(f"waiting for serial command {command!r}")
            fresh = bytes(self.transcript[start:])
            begin_start = fresh.find(begin)
            if begin_start >= 0:
                output_start = begin_start + len(begin)
                frame_start = fresh.find(status_prefix, output_start)
                if frame_start < 0:
                    if time.monotonic() >= deadline:
                        fail(
                            f"timed out waiting for serial command status frame for {command!r}; "
                            f"see {self.log_path}\n{self._diagnostic_tail()}"
                        )
                    time.sleep(0.05)
                    continue
                status_start = frame_start + len(status_prefix)
                frame_end = fresh.find(self.FRAME_SUFFIX, status_start)
                if frame_end >= 0:
                    status_bytes = fresh[status_start:frame_end]
                    if not re.fullmatch(rb"[0-9]+", status_bytes):
                        fail(
                            f"guest serial command returned a malformed status frame for {command!r}; "
                            f"see {self.log_path}\n{self._diagnostic_tail()}"
                        )
                    self._assert_process_live(process, f"completing serial command {command!r}")
                    return SerialCommandResult(
                        command=command,
                        output=fresh[output_start:frame_start].decode("utf-8", "replace"),
                        returncode=int(status_bytes),
                    )
            if time.monotonic() >= deadline:
                fail(
                    f"timed out waiting for serial command frame for {command!r}; see {self.log_path}\n"
                    f"{self._diagnostic_tail()}"
                )
            time.sleep(0.05)

    def _send_framed_script(
        self,
        *,
        command: str,
        script: str,
        process: subprocess.Popen[bytes],
        timeout: float,
    ) -> SerialCommandResult:
        self._assert_process_live(process, f"sending serial command {command!r}")
        self.read_available()
        self._assert_usable(f"sending serial command {command!r}")
        start = len(self.transcript)
        token = self._new_frame_token()
        # The complete binary frame is assembled by the guest shell.  The
        # echoed input contains only a printf format string and a separate
        # token assignment, so echo can never forge the frame being awaited.
        begin_frame = "printf '\\036HOME_SERIAL_%s_BEGIN\\037' \"$__home_token\""
        status_frame = "printf '\\036HOME_SERIAL_%s_STATUS_%s\\037' \"$__home_token\" \"$__home_status\""
        self.send(f"__home_token={shell_quote(token)}; {begin_frame}; {script}; {status_frame}\n")
        return self._wait_for_frame(
            command=command,
            token=token,
            start=start,
            process=process,
            timeout=timeout,
        )

    def establish_shell(self, process: subprocess.Popen[bytes], timeout: float) -> None:
        """Turn the login shell into a silent control channel exactly once."""

        if self._control_ready:
            return
        # This is intentionally the only prompt dependency.  Once the login
        # shell is known to exist, disable terminal echo/output translation and
        # suppress PS1/PS2 before accepting framed command responses.
        self.wait_for(self.INITIAL_PROMPT, timeout, process=process)
        result = self._send_framed_script(
            command="serial shell setup",
            # Use the conditional form so a shell whose profile enabled
            # errexit still reports a failed terminal setup instead of
            # exiting before its status frame.
            script=(
                "if stty -echo -opost; then __home_status=0; "
                "else __home_status=$?; fi; PS1=; PS2=; export PS1 PS2"
            ),
            process=process,
            timeout=timeout,
        )
        if result.returncode != 0:
            fail(
                f"could not configure serial terminal echo/output (status {result.returncode}); "
                f"see {self.log_path}\n{result.output[-2000:]}"
            )
        self._control_ready = True

    def command(
        self,
        command: str,
        *,
        process: subprocess.Popen[bytes],
        timeout: float,
    ) -> SerialCommandResult:
        self.establish_shell(process, timeout)
        return self._send_framed_script(
            command=command,
            # A checked transport must not turn ``failed; successful`` into
            # success. The ``if`` also keeps an outer serial shell with
            # errexit enabled alive long enough to emit the child's status.
            # Expected probe failures remain explicit through shell
            # conditionals/``||`` and the caller's ``check=False`` choice.
            script=(
                f"if sh -ec {shell_quote(command)}; then __home_status=0; "
                "else __home_status=$?; fi"
            ),
            process=process,
            timeout=timeout,
        )

    def close(self) -> None:
        if self._closed_by_host:
            return
        self.read_available()
        self._closed_by_host = True
        self.sock.close()


class QMP:
    def __init__(self, sock: socket.socket) -> None:
        self.sock = sock
        self._closed = False
        try:
            self.sock.settimeout(10)
            self.file = sock.makefile("rwb", buffering=0)
            greeting = self._read_message()
            if "QMP" not in greeting:
                fail(f"unexpected QMP greeting: {greeting}")
            self.command("qmp_capabilities")
        except BaseException as primary:
            try:
                self.close()
            except BaseException as cleanup_error:
                add_note = getattr(primary, "add_note", None)
                if add_note is not None:
                    add_note(f"cleanup failure while closing failed QMP setup: {cleanup_error}")
            raise

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
        if self._closed:
            return
        self._closed = True
        try:
            if hasattr(self, "file"):
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
    network_unavailable: bool = False
    test_seed: bool = False
    test_seed_value: str = "home-installer-qemu-v1"
    qemu_renderer: bool = True
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
            "-vga",
            QEMU_GPU,
            "-device",
            "virtio-keyboard-pci",
            "-device",
            "virtio-mouse-pci",
        ]
        if self.qemu_renderer:
            args.extend(["-fw_cfg", f"name=opt/home-renderer,string={QEMU_RENDERER}"])
        if self.iso:
            args.extend(
                [
                    "-device",
                    "qemu-xhci,id=usb",
                    "-drive",
                    f"if=none,id=installer,format=raw,readonly=on,file={self.iso}",
                    "-device",
                    "usb-storage,bus=usb.0,drive=installer,bootindex=1",
                ]
            )
        if self.network:
            netdev = "user,id=net0"
            if self.network_unavailable:
                # Keep the virtual NIC present while disabling user-mode IPv4.
                # The installer's DHCP attempt must fail without making boot
                # depend on a missing device or external host network.
                netdev += ",ipv4=off"
            args.extend(["-netdev", netdev, "-device", "virtio-net-pci,netdev=net0"])
        else:
            args.extend(["-net", "none"])
        if self.test_seed:
            args.extend(
                [
                    "-fw_cfg",
                    f"name=opt/home-installer-test,string={self.test_seed_value}",
                    "-fw_cfg",
                    "name=opt/home-secure-boot,string=disabled",
                ]
            )
        args.extend(["-display", self.display, "-monitor", "none"])
        if self.no_reboot:
            args.append("-no-reboot")
        return args

    def start(self) -> None:
        if self.process or self.serial or self.qmp:
            fail(f"VM {self.stage} has already been started")
        self.paths.ensure_test_dir()
        # QEMU writes both of these paths. Revalidate them at the launch
        # boundary instead of relying on the environment-only Paths check:
        # overlays and variable stores are supplied by internal callers.
        self.disk = require_generated_regular_file(self.disk, self.paths.test_dir, "QEMU disk")
        self.vars_path = require_generated_regular_file(
            self.vars_path,
            self.paths.test_dir,
            "OVMF variable store",
        )
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
        qmp_socket: Optional[socket.socket] = None
        serial_socket: Optional[socket.socket] = None
        try:
            # Popen duplicates these descriptors for the child.  Closing the
            # parent copy immediately prevents a failed connection setup from
            # retaining the QEMU log file indefinitely.
            with self.stderr_log.open("wb") as stderr:
                self.process = subprocess.Popen(
                    args,
                    stdin=subprocess.DEVNULL,
                    stdout=stderr,
                    stderr=stderr,
                )
            qmp_socket = connect_unix(qmp_path, self.process, 30)
            self.qmp = QMP(qmp_socket)
            qmp_socket = None
            serial_socket = connect_unix(serial_path, self.process, 30)
            self.serial = Serial(serial_socket, self.serial_log)
            serial_socket = None
        except BaseException as primary:
            for sock in (serial_socket, qmp_socket):
                if sock is None:
                    continue
                try:
                    sock.close()
                except OSError as cleanup_error:
                    self._add_cleanup_note(primary, "closing startup socket", cleanup_error)
            try:
                self.close()
            except BaseException as cleanup_error:
                self._add_cleanup_note(primary, "cleaning up failed VM startup", cleanup_error)
            raise

    def require_live(self) -> tuple[subprocess.Popen[bytes], Serial, QMP]:
        if not self.process or not self.serial or not self.qmp:
            fail(f"VM {self.stage} is not running")
        return self.process, self.serial, self.qmp

    @staticmethod
    def _add_cleanup_note(primary: BaseException, operation: str, cleanup_error: BaseException) -> None:
        add_cleanup_note(primary, operation, cleanup_error)

    def _wait_for_stopped(
        self,
        process: subprocess.Popen[bytes],
        serial: Serial,
        timeout: float,
        action: str,
    ) -> int:
        deadline = time.monotonic() + timeout
        while process.poll() is None and time.monotonic() < deadline:
            serial.read_available()
            time.sleep(0.2)
        if process.poll() is None:
            fail(f"VM {self.stage} did not {action} before the {timeout:.0f}s deadline")
        serial.read_available()
        return int(process.returncode)

    def wait_for_exit(self, timeout: float, *, check: bool = True) -> int:
        process, serial, _ = self.require_live()
        status = self._wait_for_stopped(process, serial, timeout, "exit")
        if check and status != 0:
            fail(f"VM {self.stage} exited with unexpected status {status}")
        return status

    def clean_shutdown(self, timeout: float = 60) -> None:
        process, serial, qmp = self.require_live()
        # A normal stage reaches this method while its guest is still alive.
        # Accepting an earlier zero-status exit here would turn an unexpected
        # VM disappearance into a passing cleanup path.
        if process.poll() is not None:
            fail(
                f"VM {self.stage} exited unexpectedly before clean shutdown "
                f"(status {process.returncode})"
            )
        try:
            # Alpine's minimal target does not run an ACPI daemon.  Request a
            # real guest poweroff through the already-authenticated serial
            # recovery shell, then retain QMP as a bounded fallback.
            serial.send("doas poweroff\n")
        except (HarnessError, OSError):
            if process.poll() is not None:
                fail(
                    f"VM {self.stage} exited unexpectedly before clean shutdown "
                    f"(status {process.returncode})"
                )
        try:
            status = self._wait_for_stopped(process, serial, timeout, "complete a clean shutdown")
        except HarnessError:
            try:
                qmp.powerdown()
            except HarnessError:
                pass
            status = self._wait_for_stopped(process, serial, timeout, "complete a clean shutdown")
        if status != 0:
            fail(f"VM {self.stage} shut down with unexpected status {status}")

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

    def _remove_owned_endpoint(self, endpoint: Optional[Path]) -> None:
        if endpoint is None:
            return
        endpoint, _ = validate_generated_path(endpoint, self.paths.test_dir, "socket")
        info = lstat_if_exists(endpoint)
        if info is None:
            return
        if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid():
            fail(f"refusing non-owned QEMU control endpoint during cleanup: {endpoint}")
        endpoint.unlink()

    def close(self) -> None:
        failure: Optional[BaseException] = None

        def attempt(operation: str, callback) -> None:
            nonlocal failure
            try:
                callback()
            except BaseException as error:
                if failure is None:
                    failure = error
                else:
                    self._add_cleanup_note(failure, operation, error)

        if self.process and self.process.poll() is None:
            attempt("stopping QEMU", self.abort)
        if self.serial:
            serial = self.serial
            self.serial = None
            attempt("closing serial control", serial.close)
        if self.qmp:
            qmp = self.qmp
            self.qmp = None
            attempt("closing QMP control", qmp.close)
        for endpoint in (self.qmp_path, self.serial_path):
            attempt("removing QEMU control endpoint", lambda endpoint=endpoint: self._remove_owned_endpoint(endpoint))
        if failure is not None:
            raise failure


def add_cleanup_note(primary: BaseException, operation: str, cleanup_error: BaseException) -> None:
    """Preserve a primary failure while making required cleanup diagnosable."""

    note = f"cleanup failure while {operation}: {cleanup_error}"
    add_note = getattr(primary, "add_note", None)
    if add_note is not None:
        add_note(note)


def cleanup_after_failure(
    primary: BaseException,
    operation: str,
    callback: Callable[[], None],
) -> None:
    """Run required cleanup without allowing it to replace an earlier failure."""

    try:
        callback()
    except BaseException as cleanup_error:
        add_cleanup_note(primary, operation, cleanup_error)


def shutdown_and_close(vm: VM) -> None:
    primary: Optional[BaseException] = None
    try:
        vm.clean_shutdown()
    except BaseException as error:
        primary = error
    try:
        vm.close()
    except BaseException as cleanup_error:
        if primary is None:
            raise
        add_cleanup_note(primary, "closing VM", cleanup_error)
    if primary is not None:
        raise primary


def serial_command(
    vm: VM,
    command: str,
    timeout: float = 10,
    *,
    check: bool = True,
) -> SerialCommandResult:
    """Run one guest command with fresh output and a captured shell status.

    Commands are checked by default.  Callers that intentionally probe an
    expected failure must pass ``check=False`` and inspect ``returncode``.
    """

    process, serial, _ = vm.require_live()
    result = serial.command(command, process=process, timeout=timeout)
    if check and result.returncode != 0:
        fail(
            f"guest command failed with status {result.returncode}: {command!r}; "
            f"see {serial.log_path}\n{result.output[-2000:]}"
        )
    return result


def wait_for_guest_file(vm: VM, path: str, description: str, timeout: float = 15) -> SerialCommandResult:
    """Wait for a guest-created file without treating a missing file as output."""

    deadline = time.monotonic() + timeout
    last: Optional[SerialCommandResult] = None
    while True:
        remaining = max(0.1, deadline - time.monotonic())
        result = serial_command(
            vm,
            f"cat -- {shell_quote(path)}",
            timeout=min(5, remaining),
            check=False,
        )
        if result.returncode == 0:
            return result
        last = result
        if result.returncode != 1:
            fail(
                f"{description} file read failed with unexpected status {result.returncode}: {path}; "
                f"see the serial transcript\n{result.output[-2000:]}"
            )
        if time.monotonic() >= deadline:
            fail(
                f"{description} did not produce readable output before the {timeout:.0f}s deadline: {path}; "
                f"last status={last.returncode} output={last.output[-2000:]!r}"
            )
        time.sleep(min(0.5, max(0.01, deadline - time.monotonic())))


def wait_for_guest_file_output(
    vm: VM,
    path: str,
    expected: str,
    description: str,
    timeout: float = 15,
) -> str:
    """Require exact, fresh output from a guest action observed through a file."""

    result = wait_for_guest_file(vm, path, description, timeout)
    if result.output != expected:
        fail(
            f"{description} produced unexpected output from {path}: "
            f"expected {expected!r}, got {result.output!r}"
        )
    return result.output


def assert_foot_pty(vm: VM, terminal_path: str) -> None:
    """Require a graphical terminal path to belong to a foot process tree."""

    if re.fullmatch(r"/dev/pts/[0-9]+", terminal_path) is None:
        fail(f"graphical command did not report a pseudo-terminal path: {terminal_path!r}")
    command = f"""set -e
target={shell_quote(terminal_path)}
foot_pty=0
for proc in /proc/[0-9]*; do
    [ -r "$proc/status" ] || continue
    [ -e "$proc/fd/0" ] || continue
    terminal=$(readlink "$proc/fd/0" 2>/dev/null || :)
    [ "$terminal" = "$target" ] || continue
    ancestor=${{proc##*/}}
    steps=0
    while [ "$steps" -lt 32 ]; do
        comm=$(cat "/proc/$ancestor/comm" 2>/dev/null || :)
        if [ "$comm" = foot ]; then
            foot_pty=1
            break
        fi
        parent=$(awk '/^PPid:/ {{print $2; exit}}' "/proc/$ancestor/status" 2>/dev/null || :)
        case "$parent" in
            ''|*[!0-9]*) break ;;
        esac
        [ "$parent" != "$ancestor" ] || break
        ancestor=$parent
        steps=$((steps + 1))
    done
    [ "$foot_pty" = 0 ] || break
done
printf 'fact_foot_pty=%s\\n' "$foot_pty"
"""
    result = serial_command(vm, command)
    if result.output != "fact_foot_pty=1\n":
        fail(
            f"graphical pseudo-terminal {terminal_path} is not owned by a foot session: "
            f"{result.output!r}"
        )


FACTS_PROCESS_COMMAND = r"""set -e
dwl_count=0
foot_count=0
process_count=0
dwl_uid=
foot_uid=
foot_wayland=0
dwl_drm_device=
dwl_drm_open=
for proc in /proc/[0-9]*; do
    [ -r "$proc/comm" ] || continue
    process_count=$((process_count + 1))
    comm=$(cat "$proc/comm" 2>/dev/null || true)
    if [ "$comm" = dwl ]; then
        dwl_count=$((dwl_count + 1))
        [ -n "$dwl_uid" ] || dwl_uid=$(awk '/^Uid:/ {print $2; exit}' "$proc/status" 2>/dev/null || true)
        if [ -r "$proc/environ" ]; then
            dwl_drm_device=$(tr '\000' '\n' < "$proc/environ" 2>/dev/null | sed -n 's/^WLR_DRM_DEVICES=//p' | head -n 1)
        fi
        if [ -z "$dwl_drm_open" ]; then
            for fd in "$proc"/fd/*; do
                opened=$(readlink "$fd" 2>/dev/null || true)
                case "$opened" in
                    /dev/dri/card[0-9]*)
                        dwl_drm_open=$(readlink -f "$fd" 2>/dev/null || true)
                        break
                        ;;
                esac
            done
        fi
    elif [ "$comm" = foot ]; then
        foot_count=$((foot_count + 1))
        [ -n "$foot_uid" ] || foot_uid=$(awk '/^Uid:/ {print $2; exit}' "$proc/status" 2>/dev/null || true)
        if [ -r "$proc/environ" ] && tr '\000' '\n' < "$proc/environ" 2>/dev/null | grep -q '^WAYLAND_DISPLAY='; then
            foot_wayland=$((foot_wayland + 1))
        fi
    fi
done
printf 'fact_dwl=%s\n' "$dwl_count"
printf 'fact_foot=%s\n' "$foot_count"
printf 'fact_processes=%s\n' "$process_count"
if [ -n "$dwl_uid" ]; then printf 'fact_dwl_uid=%s\n' "$dwl_uid"; fi
if [ -n "$foot_uid" ]; then printf 'fact_foot_uid=%s\n' "$foot_uid"; fi
printf 'fact_foot_wayland=%s\n' "$foot_wayland"
if [ -n "$dwl_drm_device" ]; then printf 'fact_dwl_drm_device=%s\n' "$dwl_drm_device"; else printf 'fact_dwl_drm_device=missing\n'; fi
if [ -n "$dwl_drm_open" ]; then printf 'fact_dwl_drm_open=%s\n' "$dwl_drm_open"; else printf 'fact_dwl_drm_open=missing\n'; fi"""

FACTS_RUNTIME_COMMAND = r"""set -e
printf 'fact_user=%s\n' "$(id -un)"
printf 'fact_uid=%s\n' "$(id -u)"
printf 'fact_runtime=%s\n' "$(stat -c '%u:%g:%a' /run/user/1000 2>/dev/null || echo missing)"
printf 'fact_runtime_owner=%s\n' "$(stat -c '%u:%g:%a' /run/user/1000 2>/dev/null || echo missing)"
if find /run/user/1000 -maxdepth 1 -type s -name 'wayland-*' 2>/dev/null | grep -q .; then
    echo fact_wayland=present
    wayland_socket=$(find /run/user/1000 -maxdepth 1 -type s -name 'wayland-*' -print -quit)
    printf 'fact_wayland_socket=%s\n' "$(stat -c '%u:%g:%a' "$wayland_socket" 2>/dev/null || echo missing)"
else
    echo fact_wayland=missing
fi

drm_device=
drm_driver=
drm_identity=
drm_matches=0
for candidate in /dev/dri/by-path/*-card; do
    [ -L "$candidate" ] || continue
    resolved=$(readlink -f "$candidate" 2>/dev/null || true)
    case "$resolved" in
        /dev/dri/card[0-9]*) ;;
        *) continue ;;
    esac
    card=${resolved##*/}
    driver_link=/sys/class/drm/$card/device/driver
    [ -L "$driver_link" ] || continue
    driver=$(readlink "$driver_link" 2>/dev/null || true)
    [ "${driver##*/}" = bochs-drm ] || continue
    drm_matches=$((drm_matches + 1))
    drm_device=$resolved
    drm_driver=${driver##*/}
    drm_identity=$candidate
done
if [ "$drm_matches" -eq 0 ]; then
    # Minimal udev setups may omit /dev/dri/by-path.  Resolve the intended
    # device from its sysfs driver identity instead of assuming card0.
    for driver_link in /sys/class/drm/card*/device/driver; do
        [ -L "$driver_link" ] || continue
        driver=$(readlink "$driver_link" 2>/dev/null || true)
        [ "${driver##*/}" = bochs-drm ] || continue
        card_path=${driver_link%/device/driver}
        card=${card_path##*/}
        candidate=/dev/dri/$card
        [ -e "$candidate" ] || continue
        drm_matches=$((drm_matches + 1))
        drm_device=$candidate
        drm_driver=${driver##*/}
        drm_identity=$driver_link
    done
fi
if [ "$drm_matches" -eq 1 ]; then
    echo fact_drm=present
    printf 'fact_drm_device=%s\n' "$drm_device"
    printf 'fact_drm_device_realpath=%s\n' "$(readlink -f "$drm_device" 2>/dev/null || echo missing)"
    printf 'fact_drm_driver=%s\n' "$drm_driver"
    printf 'fact_drm_identity=%s\n' "$drm_identity"
else
    echo fact_drm=missing
    echo fact_drm_device=missing
    echo fact_drm_device_realpath=missing
    echo fact_drm_driver=missing
    echo fact_drm_identity=missing
fi

if [ -e /dev/input/event0 ]; then echo fact_input=present; else echo fact_input=missing; fi
if [ -S /run/seatd.sock ]; then echo fact_seat=present; else echo fact_seat=missing; fi
printf 'fact_seat_socket=%s\n' "$(stat -c '%u:%g:%a' /run/seatd.sock 2>/dev/null || echo missing)"
mem_available=$(awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo)
printf 'fact_mem_available_kib=%s\n' "$mem_available"
"""


def facts(vm: VM, timeout: float = 10) -> dict[str, str]:
    output = serial_command(vm, FACTS_PROCESS_COMMAND, timeout).output
    output += "\n" + serial_command(vm, FACTS_RUNTIME_COMMAND, timeout).output
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
    process, serial, _ = vm.require_live()
    serial.establish_shell(process, timeout)
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
            and last.get("fact_drm_device", "") != "missing"
            and last.get("fact_drm_device_realpath", "") != "missing"
            and last.get("fact_drm_identity", "") != "missing"
            and last.get("fact_input") == "present"
            and last.get("fact_seat") == "present"
            and last.get("fact_seat_socket") != "missing"
            and last.get("fact_drm_driver") == "bochs-drm"
            and last.get("fact_dwl_drm_device") == last.get("fact_drm_device")
            and last.get("fact_dwl_drm_open") == last.get("fact_drm_device_realpath")
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
        f"gpu: {QEMU_GPU} bochs-drm",
        f"renderer: {QEMU_RENDERER} via fw_cfg opt/home-renderer",
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
        f"target_world_packages_verified: {target_metrics.get('target_world_count', 'unknown')}",
        f"installed_efi_bytes: {target_metrics.get('efi_bytes', 'unknown')}",
        f"installed_root_used_kib: {target_metrics.get('root_used_kib', 'unknown')}",
        f"wayland_socket: {session_facts.get('fact_wayland_socket', 'unknown')}",
        f"drm_device: {session_facts.get('fact_drm_device', 'unknown')}",
        f"drm_device_realpath: {session_facts.get('fact_drm_device_realpath', 'unknown')}",
        f"drm_identity: {session_facts.get('fact_drm_identity', 'unknown')}",
        f"dwl_drm_device: {session_facts.get('fact_dwl_drm_device', 'unknown')}",
        f"dwl_drm_open: {session_facts.get('fact_dwl_drm_open', 'unknown')}",
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
        "offline-network",
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


def publish_acceptance_success(
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
    """Publish retained-run evidence only after the complete test succeeds."""

    try:
        write_disk_fingerprint(paths, fingerprint)
        write_acceptance_metadata(
            paths,
            iso=iso,
            disk=disk,
            fingerprint=fingerprint,
            boot_seconds=boot_seconds,
            session_facts=session_facts,
            target_metrics=target_metrics,
            screenshots=screenshots,
        )
    except BaseException as primary:
        try:
            invalidate_prior_success(paths)
        except BaseException as cleanup_error:
            add_note = getattr(primary, "add_note", None)
            if add_note is not None:
                add_note(f"cleanup failure while invalidating incomplete acceptance evidence: {cleanup_error}")
        raise


def send_text(qmp: QMP, text: str) -> None:
    """Type a small US-layout ASCII string through QEMU's input device."""

    direct = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    punctuation = {
        " ": ("spc",),
        "/": ("slash",),
        ".": ("dot",),
        ">": ("shift", "dot"),
        "|": ("shift", "backslash"),
        "$": ("shift", "4"),
        "?": ("shift", "slash"),
        "&": ("shift", "7"),
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
        # Keep the guest input queue from collapsing adjacent QMP key events
        # while a terminal emulator and shell are processing a longer line.
        time.sleep(0.01)


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
    # A command must alter a glyph-sized region of the terminal viewport. The
    # independent pseudo-terminal challenge establishes which command ran;
    # this bounded pixel assertion establishes that rendered terminal content,
    # not merely a QEMU cursor or process count, changed on screen.
    if changed < 200 or max_x - min_x < 30 or max_y - min_y < 8:
        fail(
            "graphical output changed without a rendered terminal-sized region "
            f"between {before} and {after} (pixels={changed}, "
            f"bounds={min_x},{min_y}..{max_x},{max_y})"
        )


def assert_rendered_terminal_output(before: Path, after: Path) -> None:
    """Require fresh changed pixels in the cleared terminal's upper view."""

    before_width, before_height, before_pixels = read_ppm(before)
    after_width, after_height, after_pixels = read_ppm(after)
    if (before_width, before_height) != (after_width, after_height):
        fail(f"rendered terminal screenshots have different dimensions: {before}, {after}")
    crop_height = max(120, before_height // 3)
    changed = 0
    for y in range(min(crop_height, before_height)):
        row_start = y * before_width * 3
        row_end = row_start + before_width * 3
        for offset in range(row_start, row_end, 3):
            if max(
                abs(before_pixels[offset + channel] - after_pixels[offset + channel])
                for channel in range(3)
            ) > 8:
                changed += 1
    if changed < 50:
        fail(
            "fresh graphical command did not change the cleared terminal viewport "
            f"in a rendered region (changed_pixels={changed})"
        )


def qemu_disk_create(paths: Paths, disk: Path) -> None:
    paths.ensure_test_dir()
    disk = absolute_path(disk)
    if disk != paths.disk:
        fail(f"QEMU disk creation must use the disposable disk.img: {paths.disk}")
    qemu_img = require_command("qemu-img")
    disk = prepare_generated_file(disk, paths.test_dir)
    prepare_generated_file(disk_fingerprint_path(paths), paths.test_dir)
    run_capture([qemu_img, "create", "-f", "raw", str(disk), "8G"])


def qemu_disk_overlay(paths: Paths, base: Path, overlay: Path) -> None:
    qemu_img = require_command("qemu-img")
    base = require_generated_regular_file(base, paths.test_dir, "installed QEMU disk")
    overlay = prepare_generated_file(overlay, paths.test_dir)
    run_capture(
        [qemu_img, "create", "-f", "qcow2", "-F", "raw", "-b", str(base), str(overlay)],
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
    network_unavailable: bool = False,
    test_seed: bool = False,
    test_seed_value: str = "home-installer-qemu-v1",
    qemu_renderer: bool = True,
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
        network_unavailable=network_unavailable,
        test_seed=test_seed,
        test_seed_value=test_seed_value,
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
    network_unavailable: bool = False,
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
        network_unavailable=network_unavailable,
        disk_format=disk_format,
        no_reboot=no_reboot,
    )
    try:
        vm.start()
    except BaseException as primary:
        # This helper returns a live VM to its caller.  If connection setup
        # fails before that return, ownership is still here and must not leak
        # the subprocess, sockets, or log handles to a later caller finally.
        cleanup_after_failure(primary, "closing failed installed stage", vm.close)
        raise
    return vm


def assert_network_preflight_required(
    paths: Paths, pair: FirmwarePair, iso: Path, disk: Path
) -> None:
    """Prove a failed network preflight powers off before writing the disk."""

    qemu_disk_create(paths, disk)
    before = sha256_file(disk)
    vars_path = copy_vars(pair.vars_template, paths.output("network-failure-vars.fd"), paths)
    vm = make_vm(
        paths,
        pair,
        disk,
        vars_path,
        "network-failure",
        iso=iso,
        network=True,
        network_unavailable=True,
        test_seed=True,
        test_seed_value="home-installer-qemu-no-network-v1",
    )
    try:
        vm.start()
        vm.wait_for_exit(180)
        serial = vm.serial_log.read_text(errors="replace") if vm.serial_log else ""
        if "DHCP preflight failed; refusing to modify the target disk" not in serial:
            fail(f"network failure VM did not fail closed before installation; see {vm.serial_log}")
        if sha256_file(disk) != before:
            fail("network preflight failure modified the disposable target disk")
    except BaseException as primary:
        cleanup_after_failure(primary, "closing network failure VM", vm.close)
        raise
    else:
        vm.close()
    say("network preflight failure rejected before any target-disk write")


def test_installer(iso: Path) -> None:
    paths = Paths.from_environment()
    # A failed attempt must never leave a prior green report or fingerprint
    # looking current. These paths are validated before anything is removed.
    invalidate_prior_success(paths)
    iso = read_regular_file(absolute_path(iso), "installer ISO")
    pair = firmware_pair()
    fingerprint = fingerprint_payload(iso, pair)
    disk = paths.disk
    assert_network_preflight_required(paths, pair, iso, disk)
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
        if "efivarfs verified at /sys/firmware/efi/efivars (fstype=efivarfs)" not in serial:
            fail(f"installer did not record an exact efivarfs mount verification; see {vm.serial_log}")
        if "explicit disabled QEMU test seed" not in serial:
            fail(f"installer did not record the authenticated QEMU Secure Boot seed path; see {vm.serial_log}")
        if status != 0:
            fail(f"installer VM exited with status {status}; see {vm.serial_log}")
    except BaseException as primary:
        cleanup_after_failure(primary, "closing installer VM", vm.close)
        raise
    else:
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
            "efi_bytes=$(doas stat -c %s /boot/EFI/alpine/linux-lts.efi) || exit $?\n"
            "df_output=$(df -kP /) || exit $?\n"
            "root_used_kib=$(printf '%s\\n' \"$df_output\" | awk 'END {print $3}') || exit $?\n"
            "[ -n \"$root_used_kib\" ] || exit 1\n"
            "world_count=0\n"
            "world_missing=0\n"
            "while IFS= read -r package; do\n"
            "    [ -n \"$package\" ] || continue\n"
            "    world_count=$((world_count + 1))\n"
            "    /sbin/apk info -e \"$package\" >/dev/null 2>&1 || world_missing=$((world_missing + 1))\n"
            "done < /etc/apk/world\n"
            "[ \"$world_count\" -gt 0 ] && [ \"$world_missing\" -eq 0 ] || exit 1\n"
            "services=$(rc-status --all 2>/dev/null) || exit $?\n"
            "services=$(printf '%s' \"$services\" | tr '\\n' ' ') || exit $?\n"
            "printf 'efi_bytes=%s\\n' \"$efi_bytes\"\n"
            "printf 'root_used_kib=%s\\n' \"$root_used_kib\"\n"
            "printf 'target_world_count=%s\\n' \"$world_count\"\n"
            "printf 'services=%s\\n' \"$services\"",
        ).output
        for line in metric_output.splitlines():
            if "=" in line and line.split("=", 1)[0] in {
                "efi_bytes", "root_used_kib", "target_world_count", "services"
            }:
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

        # Ctrl+Return opens exactly one second foot. The per-run tty challenge
        # below must be emitted by that graphical pseudo-terminal, not echoed
        # by the serial control shell or inherited from an earlier command.
        installed.qmp.chord("ctrl", "ret")
        wait_for_session(installed, 2)
        marker = f"e2epty{os.urandom(8).hex()}"
        marker_path = f"/tmp/{marker}"
        rendered_path = f"/tmp/{marker}-rendered"
        rendered_status_path = f"/tmp/{marker}-rendered-status"
        serial_command(installed, f"rm -f {marker_path} {rendered_path} {rendered_status_path}")
        # Do not queue multiple shell lines before the graphical terminal has
        # consumed the first one. The fresh tty file is both a focus handshake
        # and an exact proof that the command ran in the second foot PTY.
        send_text(installed.qmp, f"tty > {marker_path}\n")
        graphical_tty = wait_for_guest_file(installed, marker_path, "graphical terminal challenge").output
        if re.fullmatch(r"/dev/pts/[0-9]+\n", graphical_tty) is None:
            fail(f"graphical terminal command did not return an exact pseudo-terminal path: {graphical_tty!r}")
        assert_foot_pty(installed, graphical_tty.rstrip("\n"))
        installed.qmp.chord("ctrl", "l")
        time.sleep(0.5)
        before_command = paths.output("installed-terminal-before-command.ppm")
        installed.qmp.screenshot(before_command)
        say(f"pre-command screenshot: {assert_screenshot(before_command)}")
        screenshot_paths.append(before_command)
        # tee writes one per-run result to the foot viewport and a separate
        # file. Its exact fresh file content proves the graphical command ran;
        # the screenshot then proves that same output rendered, without OCR or
        # a brittle whole-screen golden image.
        send_text(
            installed.qmp,
            f"echo {marker} | tee {rendered_path}\n",
        )
        wait_for_guest_file_output(
            installed,
            rendered_path,
            marker + "\n",
            "rendered graphical terminal challenge",
        )
        time.sleep(0.2)
        after_marker = paths.output("installed-terminal-after-command.ppm")
        installed.qmp.screenshot(after_marker)
        say(f"rendered command screenshot: {assert_screenshot(after_marker)}")
        assert_screenshot_changed(before_command, after_marker)
        assert_rendered_terminal_output(before_command, after_marker)
        screenshot_paths.append(after_marker)
        # The graphical shell retains the pipeline status while host-side
        # serial reads and screenshots are happening. Read it in a separate,
        # paced command so both tee's exact output and successful exit are
        # observed without letting the status command itself affect the image.
        send_text(installed.qmp, f"echo $? > {rendered_status_path}\n")
        wait_for_guest_file_output(
            installed,
            rendered_status_path,
            "0\n",
            "rendered graphical terminal command status",
        )

        env_marker = f"e2eenv{os.urandom(8).hex()}"
        env_path = f"/tmp/{env_marker}"
        serial_command(installed, f"rm -f {env_path}")
        send_text(installed.qmp, f"env > {env_path}\n")
        env_output = wait_for_guest_file(installed, env_path, "graphical terminal environment").output
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
        installed.qmp.chord("ctrl", "ret")
        wait_for_session(installed, 1)

        # Use the real recovery VT and compositor exit path.  tty2 must stay an
        # ash recovery login; it is not allowed to start another dwl.
        installed.qmp.chord("ctrl", "alt", "f2")
        time.sleep(2)
        send_text(installed.qmp, "josh\n")
        time.sleep(2)
        recovery_marker = f"recovery{os.urandom(8).hex()}"
        recovery_path = f"/tmp/{recovery_marker}"
        recovery_status_path = f"/tmp/{recovery_marker}-status"
        serial_command(installed, f"rm -f {recovery_path} {recovery_status_path}")
        send_text(installed.qmp, f"tty > {recovery_path}\n")
        wait_for_guest_file_output(
            installed,
            recovery_path,
            "/dev/tty2\n",
            "tty2 recovery shell",
        )
        time.sleep(0.2)
        send_text(installed.qmp, f"echo $? > {recovery_status_path}\n")
        wait_for_guest_file_output(
            installed,
            recovery_status_path,
            "0\n",
            "tty2 recovery command status",
        )
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

        # Kill the compositor from the serial recovery channel to model an
        # abnormal compositor failure. The tty1 ash shell must remain
        # recoverable, and explicitly exiting it must restart one fresh
        # graphical session through agetty.
        serial_command(
            installed,
            "dwl_pid=$(for proc in /proc/[0-9]*; do "
            "[ \"$(cat \"$proc/comm\" 2>/dev/null || true)\" = dwl ] && "
            "printf '%s\\n' \"${proc##*/}\" && break; done); "
            "[ -n \"$dwl_pid\" ] && doas kill -TERM \"$dwl_pid\"",
        )
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            current = facts(installed)
            if current.get("fact_dwl") == "0":
                break
            time.sleep(1)
        else:
            fail("terminating dwl did not leave the tty1 recovery shell")
        installed.qmp.chord("ctrl", "alt", "f2")
        time.sleep(1)
        send_text(installed.qmp, "chvt 1\n")
        time.sleep(1)
        send_text(installed.qmp, "exit\n")
        wait_for_session(installed, 1)
    except BaseException as primary:
        cleanup_after_failure(primary, "shutting down installed VM", lambda: shutdown_and_close(installed))
        raise
    else:
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
    except BaseException as primary:
        cleanup_after_failure(primary, "closing offline reboot VM", offline.close)
        raise
    else:
        offline.close()
    offline_boot_vars = copy_vars(pair.vars_template, paths.output("offline-boot-vars.fd"), paths)
    offline_boot = installed_session_stage(
        paths, pair, disk, offline_boot_vars, "offline-reboot-boot", network=False
    )
    try:
        wait_for_session(offline_boot, 1, timeout=150)
    except BaseException as primary:
        cleanup_after_failure(primary, "shutting down offline boot VM", lambda: shutdown_and_close(offline_boot))
        raise
    else:
        shutdown_and_close(offline_boot)

    # A present NIC with both user-mode address families disabled must not
    # delay or prevent the graphical session. This is distinct from the
    # offline-reboot stage, which has no NIC at all.
    offline_network = installed_session_stage(
        paths,
        pair,
        disk,
        offline_boot_vars,
        "offline-network",
        network=True,
        network_unavailable=True,
    )
    try:
        wait_for_session(offline_network, 1, timeout=150)
    except BaseException as primary:
        cleanup_after_failure(
            primary,
            "shutting down unavailable-network VM",
            lambda: shutdown_and_close(offline_network),
        )
        raise
    else:
        shutdown_and_close(offline_network)

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
        serial_command(
            fallback_prepare,
            "doas sh -ec 'rm -f -- /boot/EFI/alpine/linux-lts.efi; "
            "test ! -e /boot/EFI/alpine/linux-lts.efi'",
        )
    except BaseException as primary:
        cleanup_after_failure(
            primary,
            "shutting down fallback preparation VM",
            lambda: shutdown_and_close(fallback_prepare),
        )
        raise
    else:
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
    except BaseException as primary:
        cleanup_after_failure(primary, "shutting down fallback VM", lambda: shutdown_and_close(fallback))
        raise
    else:
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
            network=True,
            disk_format="qcow2",
        )
        try:
            wait_for_session(regen, 1)
            regeneration_token = f"home-installer-regeneration-{os.urandom(16).hex()}"
            regeneration_script = (
                f"{boot_mount_vfat_command(expected_source='/dev/sda1')}\n"
                "grep -q \"root=UUID=\" /etc/kernel-hooks.d/secureboot.conf\n"
                f"{append_cmdline_token_command('/etc/kernel-hooks.d/secureboot.conf', regeneration_token)}\n"
                "before=$(sha256sum /boot/EFI/alpine/linux-lts.efi)\n"
                "before=${before%% *}\n"
                "apk --no-cache fix --reinstall secureboot-hook linux-lts\n"
                f"grep -Fq {shell_quote(regeneration_token)} /etc/kernel-hooks.d/secureboot.conf\n"
                "[ -L /etc/kernel-hooks.d/50-secureboot.hook ]\n"
                "[ -x /usr/share/kernel-hooks.d/secureboot.hook ]\n"
                "after=$(sha256sum /boot/EFI/alpine/linux-lts.efi)\n"
                "after=${after%% *}\n"
                "[ \"$before\" != \"$after\" ]\n"
                "[ -s /boot/EFI/alpine/linux-lts.efi ]\n"
                "[ -s /boot/EFI/BOOT/BOOTX64.EFI ]\n"
                "cmp /boot/EFI/alpine/linux-lts.efi /boot/EFI/BOOT/BOOTX64.EFI"
            )
            serial_command(regen, f"doas sh -ec {shell_quote(regeneration_script)}", timeout=300)
            serial_command(
                regen,
                f"doas sh -ec 'rm -f -- {removed_path}; test ! -e {removed_path}'",
            )
        except BaseException as primary:
            cleanup_after_failure(
                primary,
                f"shutting down {name} VM",
                lambda: shutdown_and_close(regen),
            )
            raise
        else:
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
            cmdline = serial_command(boot, "cat /proc/cmdline").output
            if regeneration_token not in cmdline:
                fail(
                    f"{name} boot did not consume its newly generated kernel command line "
                    f"token {regeneration_token!r}: {cmdline!r}"
                )
            say(f"kernel hook regeneration: {name} booted with {removed_path} removed")
        except BaseException as primary:
            cleanup_after_failure(
                primary,
                f"shutting down {name} boot VM",
                lambda: shutdown_and_close(boot),
            )
            raise
        else:
            shutdown_and_close(boot)

    publish_acceptance_success(
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
    paths.ensure_test_dir()
    disk = require_generated_regular_file(paths.disk, paths.test_dir, "retained QEMU disk")
    pair = firmware_pair()
    iso = read_regular_file(ROOT / "dist" / "home-installer.iso", "current installer ISO")
    current_disk_fingerprint(paths, iso, pair)
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


def probe_qemu_profile(qemu: str) -> None:
    """Launch the selected headless device profile and complete QMP shutdown."""

    args = [
        qemu,
        "-nodefaults",
        "-machine",
        f"{QEMU_MACHINE},accel=tcg",
        "-cpu",
        "Broadwell",
        "-m",
        "64",
        "-smp",
        "1",
        "-vga",
        QEMU_GPU,
        "-device",
        "virtio-keyboard-pci",
        "-device",
        "virtio-mouse-pci",
        "-device",
        "qemu-xhci,id=usb",
        "-display",
        "none",
        "-qmp",
        "stdio",
    ]
    payload = (
        '{"execute":"qmp_capabilities"}\n'
        '{"execute":"quit"}\n'
    )
    try:
        result = subprocess.run(
            args,
            input=payload,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=15,
        )
    except subprocess.TimeoutExpired as error:
        fail(f"QEMU profile probe timed out: {error}")
    if result.returncode != 0:
        fail(f"QEMU profile probe failed ({result.returncode}):\n{result.stdout}")
    if '"QMP"' not in result.stdout or '"return"' not in result.stdout:
        fail(f"QEMU profile probe did not complete the QMP handshake:\n{result.stdout}")


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
    vga = run_capture([qemu, "-vga", "help"]).stdout
    displays = run_capture([qemu, "-display", "help"]).stdout
    requirements = {
        f"machine {QEMU_MACHINE}": QEMU_MACHINE in machine,
        "Broadwell CPU": re.search(r"^\s*Broadwell(?:[-.\s]|$)", cpu, re.MULTILINE) is not None,
        "std VGA": re.search(r"^\s*std(?:\s|$)", vga, re.MULTILINE) is not None,
        "virtio keyboard": "virtio-keyboard-pci" in devices,
        "virtio mouse": "virtio-mouse-pci" in devices,
        "ICH9 AHCI": "ich9-ahci" in devices,
        "SATA ide-hd": "ide-hd" in devices,
        "Q35 USB controller": "qemu-xhci" in devices,
        "USB storage": "usb-storage" in devices,
        "interactive display": any(name in displays for name in ("cocoa", "sdl", "gtk")),
    }
    for name, available in requirements.items():
        say(f"{'ok' if available else 'missing'}: {name}")
    if not all(requirements.values()):
        fail("installed QEMU does not expose the required x86_64 test profile")
    probe_qemu_profile(qemu)
    say("ok: selected std VGA/bochs-drm profile launched and shut down through QMP")
    buildx = run_capture([require_command("docker"), "buildx", "version"], check=False)
    if buildx.returncode != 0:
        fail(f"Docker Buildx is unavailable:\n{buildx.stdout}")
    say(f"ok: {qemu}")
    say("ok: Docker and Buildx are available for the linux/amd64 image build")
    say("note: TCG is required for the Intel guest on macOS arm64; HVF is not used")
    say("note: QEMU Ethernet/std VGA/input do not certify physical Wi-Fi/i915/touchpad behavior")


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
