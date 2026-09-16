#!/usr/bin/env python3
import os
import tempfile
from pathlib import Path

import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "qemu"))
import harness  # noqa: E402


with tempfile.TemporaryDirectory(prefix="home-qemu-path-test-") as temporary:
    directory = Path(temporary) / "generated"
    directory.mkdir()
    paths = harness.Paths(directory, directory / "disk.img")

    safe = paths.output("safe.log")
    assert safe.parent == directory

    link = directory / "link"
    link.symlink_to(directory / "elsewhere", target_is_directory=True)
    try:
        harness.validate_generated_file(link / "disk.img", directory, replace=True)
    except harness.HarnessError:
        pass
    else:
        raise AssertionError("symlink output path was accepted")

    block_like = directory / "directory-output"
    block_like.mkdir()
    try:
        harness.validate_generated_file(block_like, directory, replace=True)
    except harness.HarnessError:
        pass
    else:
        raise AssertionError("directory output path was accepted")

    resolved_temporary = Path(temporary).resolve()
    iso = resolved_temporary / "home-installer.iso"
    code = resolved_temporary / "code.fd"
    vars_template = resolved_temporary / "vars.fd"
    for path, contents in ((iso, b"iso"), (code, b"code"), (vars_template, b"vars")):
        path.write_bytes(contents)
    pair = harness.FirmwarePair(code, vars_template, "test firmware")
    payload = harness.fingerprint_payload(iso, pair)
    harness.write_disk_fingerprint(paths, payload)
    assert harness.current_disk_fingerprint(paths, iso, pair) == payload

    iso.write_bytes(b"new iso")
    try:
        harness.current_disk_fingerprint(paths, iso, pair)
    except harness.HarnessError:
        pass
    else:
        raise AssertionError("stale retained-disk fingerprint was accepted")

    width, height = 320, 200
    before_pixels = bytearray(width * height * 3)
    after_pixels = bytearray(before_pixels)
    for y in range(20, 30):
        for x in range(40, 80):
            offset = (y * width + x) * 3
            after_pixels[offset : offset + 3] = b"\xff\xff\xff"

    def write_ppm(path, pixels):
        path.write_bytes(f"P6\n{width} {height}\n255\n".encode() + pixels)

    before = directory / "before.ppm"
    after = directory / "after.ppm"
    write_ppm(before, before_pixels)
    write_ppm(after, after_pixels)
    harness.assert_screenshot_changed(before, after)

print("QEMU output path tests passed")
