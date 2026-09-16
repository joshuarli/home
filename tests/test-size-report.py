#!/usr/bin/env python3
"""Focused tests for the post-build network-first size report."""

from __future__ import annotations

from io import BytesIO
import hashlib
import importlib.util
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock


MODULE_PATH = Path(__file__).resolve().parents[1] / "build" / "size-report.py"
SPEC = importlib.util.spec_from_file_location("size_report", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
size_report = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = size_report
SPEC.loader.exec_module(size_report)


def overlay_stream(*members: tuple[str, bytes, str]) -> BytesIO:
    """Build an in-memory apkovl stream as ``(path, contents, kind)`` rows."""

    archive_bytes = BytesIO()
    with tarfile.open(fileobj=archive_bytes, mode="w:gz") as archive:
        for name, contents, kind in members:
            info = tarfile.TarInfo(name)
            if kind == "directory":
                info.type = tarfile.DIRTYPE
                archive.addfile(info)
            elif kind == "symlink":
                info.type = tarfile.SYMTYPE
                info.linkname = "target"
                archive.addfile(info)
            else:
                info.size = len(contents)
                archive.addfile(info, BytesIO(contents))
    archive_bytes.seek(0)
    return archive_bytes


class SizeReportTests(unittest.TestCase):
    def test_bsdtar_listing_preserves_paths_and_iso_sector_allocation(self):
        listing = "\n".join(
            (
                "dr-xr-xr-x  2 0 0     2048 Jan  1 00:00 boot",
                "-r--r--r--  1 0 0     2049 Jan  1 00:00 boot/payload.bin",
                "lrwxrwxrwx  1 0 0        0 Jan  1 00:00 boot/current -> payload.bin",
            )
        )
        entries = size_report.parse_bsdtar_listing(listing)
        self.assertEqual(
            [(entry.kind, entry.logical_bytes, entry.allocated_bytes, entry.path) for entry in entries],
            [
                ("directory", 2048, 2048, "boot"),
                ("file", 2049, 4096, "boot/payload.bin"),
                ("symlink", 0, 0, "boot/current"),
            ],
        )

    def test_package_manifest_parser_keeps_direct_packages_and_source_lines(self):
        rows = size_report.parse_target_package_manifest(
            b"# target runtime\n\nalpine-base\nlinux-lts\n"
        )
        self.assertEqual(
            rows,
            [
                size_report.PackageManifestRow(3, "alpine-base"),
                size_report.PackageManifestRow(4, "linux-lts"),
            ],
        )

    def test_overlay_tar_enumerates_assets_and_package_manifest_without_rootfs(self):
        stream = overlay_stream(
            ("./root", b"", "directory"),
            ("./root/home-installer", b"", "directory"),
            (
                "./root/home-installer/rootfs-packages.txt",
                b"# package source\nalpine-base\nlinux-lts\n",
                "file",
            ),
            ("./root/home-installer/install.sh", b"#!/bin/sh\n", "file"),
            ("./etc/current", b"", "symlink"),
        )

        result = size_report.analyze_overlay_tar(stream)

        self.assertEqual(result["regular_files"], 2)
        self.assertEqual(result["regular_bytes"], 49)
        self.assertEqual(result["directories"], 2)
        self.assertEqual(result["symlinks"], 1)
        self.assertEqual(result["categories"]["root"][0], 49)
        self.assertEqual(
            result["package_manifest"],
            [
                size_report.PackageManifestRow(2, "alpine-base"),
                size_report.PackageManifestRow(3, "linux-lts"),
            ],
        )
        self.assertEqual(
            [path for path, _kind, _size in result["assets"]],
            [
                "root/home-installer/rootfs-packages.txt",
                "root/home-installer/install.sh",
            ],
        )

    def test_overlay_tar_rejects_the_removed_embedded_rootfs(self):
        stream = overlay_stream(
            ("root/home-installer/rootfs-packages.txt", b"alpine-base\n", "file"),
            ("root/home-installer/rootfs.tar.gz", b"old payload", "file"),
        )

        with self.assertRaisesRegex(size_report.SizeReportError, "removed embedded target rootfs"):
            size_report.analyze_overlay_tar(stream)

    def test_generate_report_requires_only_iso_and_iso_metadata_with_mocked_archive_access(self):
        iso_contents = b"not a real ISO; archive access is mocked"
        manifest = b"alpine-base\nlinux-lts\n"
        iso_hash = hashlib.sha256(iso_contents).hexdigest()
        manifest_hash = hashlib.sha256(manifest).hexdigest()
        iso_entries = [
            size_report.ArchiveEntry("file", 96, 2048, "boot/modloop-lts"),
            size_report.ArchiveEntry("file", 32, 2048, "apks/x86_64/APKINDEX.tar.gz"),
            size_report.ArchiveEntry("file", 64, 2048, "home-installer.apkovl.tar.gz"),
        ]
        overlay = {
            "assets": [
                ("root/home-installer/rootfs-packages.txt", "file", len(manifest)),
            ],
            "categories": {"root": [len(manifest), 1, 1]},
            "members": [
                (
                    "root/home-installer/rootfs-packages.txt",
                    "file",
                    len(manifest),
                    "root",
                ),
            ],
            "package_manifest_bytes": manifest,
            "package_manifest": [
                size_report.PackageManifestRow(1, "alpine-base"),
                size_report.PackageManifestRow(2, "linux-lts"),
            ],
            "regular_bytes": len(manifest),
            "regular_files": 1,
            "directories": 0,
            "symlinks": 0,
        }

        with tempfile.TemporaryDirectory(prefix="home-size-report-") as temporary:
            dist = Path(temporary)
            (dist / "home-installer.iso").write_bytes(iso_contents)
            (dist / "iso-metadata.txt").write_text(
                "\n".join(
                    (
                        "Home installer ISO metadata",
                        f"iso bytes: {len(iso_contents)}",
                        f"iso sha256: {iso_hash}",
                        f"target package manifest sha256: {manifest_hash}",
                    )
                )
                + "\n",
                encoding="utf-8",
            )
            with (
                mock.patch.object(size_report.shutil, "which", return_value="/usr/bin/bsdtar"),
                mock.patch.object(
                    size_report,
                    "run_bsdtar",
                    return_value=subprocess.CompletedProcess([], 0, stdout="", stderr=""),
                ),
                mock.patch.object(size_report, "parse_bsdtar_listing", return_value=iso_entries),
                mock.patch.object(size_report, "analyze_embedded_overlay", return_value=overlay),
            ):
                report, report_path = size_report.generate_report(dist)

            self.assertIn("The target rootfs is network-installed", report)
            self.assertIn("live APK repository (apks/): 32 bytes", report)
            self.assertTrue(report_path.is_file())
            self.assertEqual(
                (dist / "size-report" / "iso-members.tsv").read_text(encoding="utf-8").count("\n"),
                4,
            )
            self.assertEqual(
                (dist / "size-report" / "overlay-members.tsv").read_text(encoding="utf-8"),
                "kind\tbytes\ttop_level\tpath\n"
                "file\t22\troot\troot/home-installer/rootfs-packages.txt\n",
            )
            self.assertEqual(
                (dist / "size-report" / "target-package-manifest.tsv").read_text(
                    encoding="utf-8"
                ),
                "line\tpackage\n1\talpine-base\n2\tlinux-lts\n",
            )


if __name__ == "__main__":
    unittest.main()
