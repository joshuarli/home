#!/usr/bin/env python3
"""Generate a post-build size report for the finished installer ISO.

The ISO contains compressed payloads for two different systems: the live
installer and the prepared installed target.  This report keeps those
measurements separate.  It uses the host's bsdtar (available on macOS) to
enumerate the ISO, then streams the nested prepared rootfs archive without
extracting it to disk.
"""

from __future__ import annotations

import argparse
from collections import defaultdict
from dataclasses import dataclass
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
from typing import BinaryIO, Iterable, TextIO


ISO_SECTOR_BYTES = 2048
OVERLAY_MEMBER = "home-installer.apkovl.tar.gz"
ROOTFS_MEMBER = "root/home-installer/rootfs.tar.gz"


class SizeReportError(RuntimeError):
    """Raised when the post-build inputs cannot be measured safely."""


@dataclass(frozen=True)
class ArchiveEntry:
    kind: str
    logical_bytes: int
    allocated_bytes: int
    path: str


@dataclass(frozen=True)
class PackageRow:
    name: str
    version: str
    architecture: str
    installed_bytes: int
    package_bytes: int
    dependencies: str


def human_bytes(value: int) -> str:
    units = ("B", "KiB", "MiB", "GiB", "TiB")
    amount = float(value)
    for unit in units:
        if amount < 1024 or unit == units[-1]:
            return f"{amount:.2f} {unit}"
        amount /= 1024
    raise AssertionError("unreachable")


def percent(value: int, total: int) -> str:
    if total <= 0:
        return "0.00%"
    return f"{100.0 * value / total:6.2f}%"


def require_regular_file(path: Path, description: str) -> None:
    if not path.is_file() or path.is_symlink():
        raise SizeReportError(f"{description} is not a regular file: {path}")


def run_bsdtar(
    bsdtar: str,
    arguments: list[str],
    *,
    iso: Path,
) -> subprocess.CompletedProcess[str]:
    environment = os.environ.copy()
    environment["LC_ALL"] = "C"
    result = subprocess.run(
        [bsdtar, *arguments],
        check=False,
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or "no bsdtar diagnostic"
        raise SizeReportError(f"bsdtar failed for {iso}: {detail}")
    return result


def parse_bsdtar_listing(listing: str) -> list[ArchiveEntry]:
    """Parse bsdtar's stable long listing into logical and sector sizes."""

    entries: list[ArchiveEntry] = []
    for line_number, line in enumerate(listing.splitlines(), start=1):
        fields = line.split(maxsplit=8)
        if len(fields) < 9:
            raise SizeReportError(f"cannot parse bsdtar listing line {line_number}: {line!r}")
        mode = fields[0]
        try:
            logical_bytes = int(fields[4])
        except ValueError as error:
            raise SizeReportError(
                f"cannot parse bsdtar size on line {line_number}: {line!r}"
            ) from error
        path = fields[8]
        if " -> " in path:
            path = path.split(" -> ", 1)[0]
        path = path.removeprefix("./")
        if path == "." or not path:
            continue
        if mode.startswith("d"):
            kind = "directory"
        elif mode.startswith("-"):
            kind = "file"
        elif mode.startswith("l"):
            kind = "symlink"
        else:
            kind = mode[0]
        allocated_bytes = (
            ((logical_bytes + ISO_SECTOR_BYTES - 1) // ISO_SECTOR_BYTES)
            * ISO_SECTOR_BYTES
            if logical_bytes
            else 0
        )
        entries.append(ArchiveEntry(kind, logical_bytes, allocated_bytes, path))
    return entries


def top_level(path: str) -> str:
    return path.split("/", 1)[0] or "."


def sum_entries(entries: Iterable[ArchiveEntry]) -> tuple[int, int, int]:
    logical = allocated = count = 0
    for entry in entries:
        logical += entry.logical_bytes
        allocated += entry.allocated_bytes
        count += 1
    return logical, allocated, count


def category_entries(entries: Iterable[ArchiveEntry]) -> dict[str, list[ArchiveEntry]]:
    categories: dict[str, list[ArchiveEntry]] = defaultdict(list)
    for entry in entries:
        categories[top_level(entry.path)].append(entry)
    return dict(categories)


def parse_metadata_values(path: Path) -> dict[str, int]:
    values: dict[str, int] = {}
    patterns = {
        "rootfs_archive_bytes": r"^rootfs archive bytes: (\d+)$",
        "iso_bytes": r"^iso bytes: (\d+)$",
        "installed_root_kib": r"^installed filesystem allocated KiB \(du -sk\): (\d+)$",
    }
    for line in path.read_text(encoding="utf-8").splitlines():
        for key, pattern in patterns.items():
            match = re.match(pattern, line)
            if match:
                values[key] = int(match.group(1))
    return values


def parse_package_rows(path: Path) -> list[PackageRow]:
    rows: list[PackageRow] = []
    in_packages = False
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("resolved packages ("):
            in_packages = True
            continue
        if line.startswith("largest installed package contributors ("):
            break
        if not in_packages or not line:
            continue
        fields = line.split("\t", 5)
        if len(fields) != 6:
            raise SizeReportError(f"cannot parse package metadata line: {line!r}")
        try:
            rows.append(
                PackageRow(
                    name=fields[0],
                    version=fields[1],
                    architecture=fields[2],
                    installed_bytes=int(fields[3]),
                    package_bytes=int(fields[4]),
                    dependencies=fields[5],
                )
            )
        except ValueError as error:
            raise SizeReportError(f"cannot parse package sizes: {line!r}") from error
    if not rows:
        raise SizeReportError(f"package table is missing or empty: {path}")
    return rows


def clean_tar_path(path: str) -> str:
    while path.startswith("./"):
        path = path[2:]
    return path or "."


def rootfs_class(path: str) -> str:
    if path.startswith(("lib/firmware/", "usr/lib/firmware/")):
        return "firmware"
    if path.startswith(("lib/modules/", "usr/lib/modules/")):
        return "kernel modules"
    if path.startswith(("boot/", "usr/lib/kernel/")):
        return "kernel/boot files"
    if path.startswith("usr/share/fonts/"):
        return "fonts"
    if path.startswith(("usr/lib/llvm", "usr/lib/libLLVM")):
        return "LLVM runtime"
    return "other"


def analyze_rootfs_tar(stream: BinaryIO) -> dict[str, object]:
    categories: dict[str, list[int]] = defaultdict(lambda: [0, 0, 0])
    classes: dict[str, int] = defaultdict(int)
    members: list[tuple[str, str, int, str]] = []
    files: list[tuple[int, str]] = []
    regular_bytes = 0
    regular_files = 0
    directories = 0
    symlinks = 0

    with tarfile.open(fileobj=stream, mode="r|gz") as archive:
        for member in archive:
            path = clean_tar_path(member.name)
            if path == ".":
                continue
            if member.isfile():
                kind = "file"
                size = member.size
                regular_bytes += size
                regular_files += 1
                files.append((size, path))
                classes[rootfs_class(path)] += size
            elif member.isdir():
                kind = "directory"
                size = 0
                directories += 1
            elif member.issym():
                kind = "symlink"
                size = 0
                symlinks += 1
            elif member.islnk():
                kind = "hardlink"
                size = 0
            else:
                kind = "other"
                size = 0
            category = top_level(path)
            category_row = categories[category]
            category_row[0] += size
            category_row[1] += 1
            if kind == "file":
                category_row[2] += 1
            members.append((path, kind, size, category))

    return {
        "categories": dict(categories),
        "classes": dict(classes),
        "members": members,
        "files": files,
        "regular_bytes": regular_bytes,
        "regular_files": regular_files,
        "directories": directories,
        "symlinks": symlinks,
    }


def analyze_embedded_rootfs(bsdtar: str, iso: Path) -> dict[str, object]:
    environment = os.environ.copy()
    environment["LC_ALL"] = "C"
    outer = subprocess.Popen(
        [bsdtar, "-xOf", str(iso), OVERLAY_MEMBER],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=environment,
    )
    assert outer.stdout is not None
    found: dict[str, object] | None = None
    embedded_bytes = 0
    try:
        with tarfile.open(fileobj=outer.stdout, mode="r|gz") as overlay:
            for member in overlay:
                if member.name != ROOTFS_MEMBER or found is not None:
                    continue
                embedded_bytes = member.size
                rootfs_stream = overlay.extractfile(member)
                if rootfs_stream is None:
                    raise SizeReportError(f"cannot read embedded member: {ROOTFS_MEMBER}")
                found = analyze_rootfs_tar(rootfs_stream)
                rootfs_stream.close()
    finally:
        outer.stdout.close()
    stderr = outer.stderr.read().decode("utf-8", errors="replace") if outer.stderr else ""
    returncode = outer.wait()
    if returncode != 0:
        detail = stderr.strip() or "no bsdtar diagnostic"
        raise SizeReportError(f"cannot extract {OVERLAY_MEMBER}: {detail}")
    if found is None:
        raise SizeReportError(f"embedded member is missing: {ROOTFS_MEMBER}")
    found["archive_bytes"] = embedded_bytes
    return found


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def write_iso_members(path: Path, entries: Iterable[ArchiveEntry]) -> None:
    rows = ["kind\tlogical_bytes\tallocated_bytes\tpath"]
    for entry in sorted(entries, key=lambda item: item.path):
        rows.append(
            f"{entry.kind}\t{entry.logical_bytes}\t{entry.allocated_bytes}\t{entry.path}"
        )
    path.write_text("\n".join(rows) + "\n", encoding="utf-8")


def write_rootfs_members(path: Path, members: Iterable[tuple[str, str, int, str]]) -> None:
    rows = ["kind\tbytes\ttop_level\tpath"]
    for member_path, kind, size, category in sorted(members):
        rows.append(f"{kind}\t{size}\t{category}\t{member_path}")
    path.write_text("\n".join(rows) + "\n", encoding="utf-8")


def write_packages(path: Path, packages: Iterable[PackageRow]) -> None:
    rows = [
        "name\tversion\tarchitecture\tinstalled_bytes\tpackage_bytes\tdependencies"
    ]
    for package in sorted(packages, key=lambda item: (-item.installed_bytes, item.name)):
        rows.append(
            "\t".join(
                (
                    package.name,
                    package.version,
                    package.architecture,
                    str(package.installed_bytes),
                    str(package.package_bytes),
                    package.dependencies,
                )
            )
        )
    path.write_text("\n".join(rows) + "\n", encoding="utf-8")


def format_iso_section(entries: list[ArchiveEntry], iso_bytes: int) -> list[str]:
    lines = [
        "ISO 9660 members by top-level path",
        "  logical bytes are file sizes; allocated bytes round each member to 2048-byte ISO sectors",
        "  category                                      logical             allocated   entries   of ISO",
    ]
    categories = category_entries(entries)
    for category, category_entries_list in sorted(
        categories.items(), key=lambda item: sum_entries(item[1])[0], reverse=True
    ):
        logical, allocated, count = sum_entries(category_entries_list)
        lines.append(
            f"  {category:<42} {logical:>14} ({human_bytes(logical):>12}) "
            f"{allocated:>14} {count:>8} {percent(logical, iso_bytes):>8}"
        )
    logical, allocated, count = sum_entries(entries)
    lines.extend(
        (
            f"  {'ISO members accounted':<42} {logical:>14} ({human_bytes(logical):>12}) "
            f"{allocated:>14} {count:>8} {percent(logical, iso_bytes):>8}",
            f"  {'ISO overhead/unlisted sectors':<42} {iso_bytes - logical:>14} "
            f"({human_bytes(iso_bytes - logical):>12})",
            f"  {'ISO sector allocation gap':<42} {iso_bytes - allocated:>14} "
            f"({human_bytes(iso_bytes - allocated):>12})",
        )
    )
    return lines


def format_rootfs_section(rootfs: dict[str, object], metadata: dict[str, int]) -> list[str]:
    regular_bytes = int(rootfs["regular_bytes"])
    lines = [
        "Embedded prepared rootfs archive",
        f"  compressed archive member: {metadata['rootfs_archive_bytes']} bytes ({human_bytes(metadata['rootfs_archive_bytes'])})",
        f"  uncompressed regular-file bytes: {regular_bytes} ({human_bytes(regular_bytes)})",
        f"  archive compression ratio: {metadata['rootfs_archive_bytes'] / regular_bytes:.3f}",
        f"  regular files: {rootfs['regular_files']}; directories: {rootfs['directories']}; symlinks: {rootfs['symlinks']}",
        f"  installed filesystem allocation from build metadata: {metadata.get('installed_root_kib', 0) * 1024} bytes ({human_bytes(metadata.get('installed_root_kib', 0) * 1024)})",
        "  top-level paths (regular-file bytes)",
        "    path                                      bytes             files",
    ]
    categories = rootfs["categories"]
    assert isinstance(categories, dict)
    for category, values in sorted(categories.items(), key=lambda item: item[1][0], reverse=True):
        lines.append(
            f"    {category:<42} {values[0]:>14} ({human_bytes(values[0]):>12}) {values[2]:>10}"
        )
    lines.extend(
        (
            "  selected file classes (regular-file bytes; classes are mutually exclusive)",
            "    class                                      bytes",
        )
    )
    classes = rootfs["classes"]
    assert isinstance(classes, dict)
    for category, size in sorted(classes.items(), key=lambda item: item[1], reverse=True):
        lines.append(f"    {category:<42} {size:>14} ({human_bytes(size):>12})")
    return lines


def format_largest_iso(entries: list[ArchiveEntry], iso_bytes: int) -> list[str]:
    lines = ["Largest ISO members (logical bytes)", "  bytes             of ISO   path"]
    for entry in sorted(
        (item for item in entries if item.kind == "file"),
        key=lambda item: (-item.logical_bytes, item.path),
    )[:25]:
        lines.append(
            f"  {entry.logical_bytes:>14} {percent(entry.logical_bytes, iso_bytes):>8}   {entry.path}"
        )
    return lines


def format_largest_rootfs(rootfs: dict[str, object]) -> list[str]:
    lines = ["Largest embedded rootfs files", "  bytes             path"]
    files = rootfs["files"]
    assert isinstance(files, list)
    for size, path in sorted(files, key=lambda item: (-item[0], item[1]))[:25]:
        lines.append(f"  {size:>14} ({human_bytes(size):>12})   {path}")
    return lines


def format_packages(packages: list[PackageRow]) -> list[str]:
    installed_total = sum(package.installed_bytes for package in packages)
    package_total = sum(package.package_bytes for package in packages)
    lines = [
        "Prepared target package closure",
        f"  packages: {len(packages)}",
        f"  sum of installed package sizes: {installed_total} bytes ({human_bytes(installed_total)})",
        f"  sum of compressed APK sizes: {package_total} bytes ({human_bytes(package_total)})",
        "  largest installed package contributions",
        "    installed bytes   APK bytes        package",
    ]
    for package in sorted(
        packages, key=lambda item: (-item.installed_bytes, item.name)
    )[:25]:
        lines.append(
            f"    {package.installed_bytes:>14} {package.package_bytes:>14}   "
            f"{package.name} {package.version}"
        )
    return lines


def generate_report(dist: Path) -> tuple[str, Path]:
    iso = dist / "home-installer.iso"
    rootfs_metadata_path = dist / "rootfs-metadata.txt"
    iso_metadata_path = dist / "iso-metadata.txt"
    require_regular_file(iso, "installer ISO")
    require_regular_file(rootfs_metadata_path, "rootfs metadata")
    require_regular_file(iso_metadata_path, "ISO metadata")
    bsdtar = shutil.which("bsdtar")
    if bsdtar is None:
        raise SizeReportError(
            "make size requires bsdtar (install libarchive; macOS includes /usr/bin/bsdtar)"
        )

    iso_bytes = iso.stat().st_size
    metadata = parse_metadata_values(rootfs_metadata_path)
    metadata.update(parse_metadata_values(iso_metadata_path))
    if metadata.get("iso_bytes") not in (None, iso_bytes):
        raise SizeReportError(
            f"ISO metadata size {metadata['iso_bytes']} does not match {iso_bytes}"
        )
    if "rootfs_archive_bytes" not in metadata:
        raise SizeReportError("rootfs archive size is missing from ISO metadata")

    listing = run_bsdtar(bsdtar, ["-tvf", str(iso)], iso=iso).stdout
    iso_entries = parse_bsdtar_listing(listing)
    overlay = next((entry for entry in iso_entries if entry.path == OVERLAY_MEMBER), None)
    if overlay is None:
        raise SizeReportError(f"ISO member is missing: {OVERLAY_MEMBER}")
    if overlay.logical_bytes <= 0:
        raise SizeReportError(f"ISO member is empty: {OVERLAY_MEMBER}")

    rootfs = analyze_embedded_rootfs(bsdtar, iso)
    if rootfs["archive_bytes"] != metadata["rootfs_archive_bytes"]:
        raise SizeReportError(
            "embedded rootfs archive size "
            f"{rootfs['archive_bytes']} does not match metadata "
            f"{metadata['rootfs_archive_bytes']}"
        )
    packages = parse_package_rows(rootfs_metadata_path)

    detail_dir = dist / "size-report"
    detail_dir.mkdir(parents=True, exist_ok=True)
    write_iso_members(detail_dir / "iso-members.tsv", iso_entries)
    members = rootfs["members"]
    assert isinstance(members, list)
    write_rootfs_members(detail_dir / "rootfs-members.tsv", members)
    write_packages(detail_dir / "packages.tsv", packages)

    lines = [
        "Home installer post-build size report",
        "",
        "Measurements distinguish compressed ISO members from the installed target filesystem.",
        "The ISO is uncompressed at the filesystem-member level; most members are already compressed archives.",
        "",
        "Artifact",
        f"  ISO: {iso_bytes} bytes ({human_bytes(iso_bytes)})",
        f"  ISO SHA-256: {sha256_file(iso)}",
        f"  embedded installer overlay: {overlay.logical_bytes} bytes ({human_bytes(overlay.logical_bytes)})",
        f"  live APK repository: {sum(entry.logical_bytes for entry in iso_entries if entry.path.startswith('apks/') and entry.kind == 'file')} bytes",
        f"  live kernel modloop: {sum(entry.logical_bytes for entry in iso_entries if entry.path == 'boot/modloop-lts')} bytes",
        "",
    ]
    lines.extend(format_iso_section(iso_entries, iso_bytes))
    lines.append("")
    lines.extend(format_largest_iso(iso_entries, iso_bytes))
    lines.append("")
    lines.extend(format_rootfs_section(rootfs, metadata))
    lines.append("")
    lines.extend(format_largest_rootfs(rootfs))
    lines.append("")
    lines.extend(format_packages(packages))
    lines.extend(
        (
            "",
            "Complete detail files",
            f"  ISO members: {detail_dir / 'iso-members.tsv'}",
            f"  embedded rootfs members: {detail_dir / 'rootfs-members.tsv'}",
            f"  resolved packages: {detail_dir / 'packages.tsv'}",
        )
    )
    report = "\n".join(lines) + "\n"
    report_path = dist / "size-report.txt"
    report_path.write_text(report, encoding="utf-8")
    return report, report_path


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--dist",
        type=Path,
        default=Path("dist"),
        help="build output directory (default: dist)",
    )
    arguments = parser.parse_args(argv)
    try:
        report, _ = generate_report(arguments.dist)
    except (OSError, subprocess.SubprocessError, tarfile.TarError, SizeReportError) as error:
        print(f"size report: {error}", file=sys.stderr)
        return 1
    print(report, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
