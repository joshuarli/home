#!/usr/bin/env python3
"""Focused tests for the post-build size report's parsers."""

from __future__ import annotations

from io import BytesIO
import importlib.util
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest


MODULE_PATH = Path(__file__).resolve().parents[1] / "build" / "size-report.py"
SPEC = importlib.util.spec_from_file_location("size_report", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
size_report = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = size_report
SPEC.loader.exec_module(size_report)


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

    def test_package_metadata_parser_reads_the_complete_resolved_table(self):
        with tempfile.NamedTemporaryFile(
            prefix="home-packages-metadata-", mode="w", encoding="utf-8"
        ) as temporary:
            path = Path(temporary.name)
            path.write_text(
                "\n".join(
                    (
                        "Home installer rootfs metadata",
                        "resolved packages (name\tversion\tarch\tinstalled_bytes\tpackage_bytes\tdependencies):",
                        "mesa\t1.0\tx86_64\t400\t200\tlibdrm",
                        "linux-lts\t2.0\tx86_64\t900\t800\tfirmware",
                        "largest installed package contributors (name\tversion):",
                    )
                ),
                encoding="utf-8",
            )
            rows = size_report.parse_package_rows(path)
            self.assertEqual([row.name for row in rows], ["mesa", "linux-lts"])
            self.assertEqual(rows[1].installed_bytes, 900)
            self.assertEqual(rows[0].dependencies, "libdrm")

    def test_rootfs_tar_aggregates_top_level_paths_and_firmware_class(self):
        archive_bytes = BytesIO()
        with tarfile.open(fileobj=archive_bytes, mode="w:gz") as archive:
            for name, contents in (
                ("./lib/firmware/intel.bin", b"12345"),
                ("./usr/bin/tool", b"123"),
            ):
                info = tarfile.TarInfo(name)
                info.size = len(contents)
                archive.addfile(info, BytesIO(contents))
            directory = tarfile.TarInfo("./lib/firmware")
            directory.type = tarfile.DIRTYPE
            archive.addfile(directory)
            link = tarfile.TarInfo("./etc/current")
            link.type = tarfile.SYMTYPE
            link.linkname = "../usr/bin/tool"
            archive.addfile(link)
        archive_bytes.seek(0)

        result = size_report.analyze_rootfs_tar(archive_bytes)

        self.assertEqual(result["regular_bytes"], 8)
        self.assertEqual(result["regular_files"], 2)
        self.assertEqual(result["symlinks"], 1)
        self.assertEqual(result["classes"]["firmware"], 5)
        self.assertEqual(result["categories"]["lib"][0], 5)
        self.assertEqual(result["categories"]["usr"][0], 3)

if __name__ == "__main__":
    unittest.main()
