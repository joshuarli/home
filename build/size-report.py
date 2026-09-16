#!/usr/bin/env python3
"""Generate a post-build size report for the network-first installer ISO.

The ISO carries a bootable Alpine live environment and a small installer
overlay. The installed target rootfs is deliberately not embedded: after
network preflight, the installer installs its direct package manifest from
Alpine repositories. This report keeps those measurements distinct.

``bsdtar`` is used for ISO 9660 access because it is available on macOS. The
nested gzip overlay is streamed through :mod:`tarfile`, never extracted.
"""

from __future__ import annotations

import argparse
from collections import defaultdict
from dataclasses import dataclass
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
from typing import BinaryIO, Iterable


ISO_SECTOR_BYTES = 2048
OVERLAY_MEMBER = "home-installer.apkovl.tar.gz"
TARGET_PACKAGE_MANIFEST_MEMBER = "root/home-installer/rootfs-packages.txt"
REMOVED_ROOTFS_MEMBER = "root/home-installer/rootfs.tar.gz"
MAX_PACKAGE_MANIFEST_BYTES = 1024 * 1024


class SizeReportError(RuntimeError):
    """Raised when the post-build inputs cannot be measured safely."""


@dataclass(frozen=True)
class ArchiveEntry:
    kind: str
    logical_bytes: int
    allocated_bytes: int
    path: str


@dataclass(frozen=True)
class PackageManifestRow:
    line_number: int
    package: str


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
    bsdtar: str, arguments: list[str], *, iso: Path
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
            raise SizeReportError(
                f"cannot parse bsdtar listing line {line_number}: {line!r}"
            )
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


def clean_tar_path(path: str) -> str:
    while path.startswith("./"):
        path = path[2:]
    return path or "."


def parse_iso_metadata(path: Path) -> dict[str, str]:
    """Read the simple ``label: value`` ISO metadata contract safely."""

    values: dict[str, str] = {}
    for line_number, line in enumerate(
        path.read_text(encoding="utf-8").splitlines(), start=1
    ):
        if not line or line.startswith("#") or ": " not in line:
            continue
        label, value = line.split(": ", 1)
        if not label or not value:
            continue
        if label in values:
            raise SizeReportError(
                f"duplicate ISO metadata label {label!r} on line {line_number}: {path}"
            )
        values[label] = value
    return values


def parse_metadata_iso_bytes(metadata: dict[str, str]) -> int:
    value = metadata.get("iso bytes")
    if value is None:
        raise SizeReportError("ISO metadata is missing 'iso bytes'")
    try:
        parsed = int(value)
    except ValueError as error:
        raise SizeReportError(f"invalid ISO metadata iso bytes: {value!r}") from error
    if parsed < 0:
        raise SizeReportError(f"invalid ISO metadata iso bytes: {value!r}")
    return parsed


def parse_target_package_manifest(data: bytes) -> list[PackageManifestRow]:
    """Parse the direct target package list embedded in the installer overlay."""

    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as error:
        raise SizeReportError("target package manifest is not valid UTF-8") from error

    rows: list[PackageManifestRow] = []
    for line_number, line in enumerate(text.splitlines(), start=1):
        package = line.strip()
        if not package or package.startswith("#"):
            continue
        if any(character.isspace() for character in package):
            raise SizeReportError(
                f"target package manifest has multiple fields on line {line_number}: {line!r}"
            )
        rows.append(PackageManifestRow(line_number, package))
    if not rows:
        raise SizeReportError("target package manifest is missing or empty")
    return rows


def analyze_overlay_tar(stream: BinaryIO) -> dict[str, object]:
    """Enumerate the nested overlay and read its small package manifest."""

    categories: dict[str, list[int]] = defaultdict(lambda: [0, 0, 0])
    members: list[tuple[str, str, int, str]] = []
    assets: list[tuple[str, str, int]] = []
    regular_bytes = regular_files = directories = symlinks = 0
    package_manifest_data: bytes | None = None

    with tarfile.open(fileobj=stream, mode="r|gz") as archive:
        for member in archive:
            path = clean_tar_path(member.name)
            if path == ".":
                continue
            if member.isfile():
                kind, size = "file", member.size
                regular_bytes += size
                regular_files += 1
            elif member.isdir():
                kind, size = "directory", 0
                directories += 1
            elif member.issym():
                kind, size = "symlink", 0
                symlinks += 1
            elif member.islnk():
                kind, size = "hardlink", 0
            else:
                kind, size = "other", 0

            category = top_level(path)
            category_row = categories[category]
            category_row[0] += size
            category_row[1] += 1
            if kind == "file":
                category_row[2] += 1
            members.append((path, kind, size, category))
            if path.startswith("root/home-installer/") and kind != "directory":
                assets.append((path, kind, size))

            if path == REMOVED_ROOTFS_MEMBER:
                raise SizeReportError(
                    "installer overlay still contains the removed embedded target rootfs: "
                    f"{REMOVED_ROOTFS_MEMBER}"
                )
            if path != TARGET_PACKAGE_MANIFEST_MEMBER:
                continue
            if package_manifest_data is not None:
                raise SizeReportError(
                    "installer overlay contains duplicate package manifests: "
                    f"{TARGET_PACKAGE_MANIFEST_MEMBER}"
                )
            if not member.isfile():
                raise SizeReportError(
                    "target package manifest is not a regular file: "
                    f"{TARGET_PACKAGE_MANIFEST_MEMBER}"
                )
            if member.size > MAX_PACKAGE_MANIFEST_BYTES:
                raise SizeReportError(
                    "target package manifest exceeds the safe size limit "
                    f"({MAX_PACKAGE_MANIFEST_BYTES} bytes)"
                )
            package_stream = archive.extractfile(member)
            if package_stream is None:
                raise SizeReportError(
                    "cannot read target package manifest: "
                    f"{TARGET_PACKAGE_MANIFEST_MEMBER}"
                )
            try:
                package_manifest_data = package_stream.read(MAX_PACKAGE_MANIFEST_BYTES + 1)
            finally:
                package_stream.close()
            if len(package_manifest_data) > MAX_PACKAGE_MANIFEST_BYTES:
                raise SizeReportError(
                    "target package manifest exceeds the safe size limit "
                    f"({MAX_PACKAGE_MANIFEST_BYTES} bytes)"
                )

    if package_manifest_data is None:
        raise SizeReportError(
            "installer overlay is missing target package manifest: "
            f"{TARGET_PACKAGE_MANIFEST_MEMBER}"
        )
    return {
        "assets": assets,
        "categories": dict(categories),
        "members": members,
        "package_manifest_bytes": package_manifest_data,
        "package_manifest": parse_target_package_manifest(package_manifest_data),
        "regular_bytes": regular_bytes,
        "regular_files": regular_files,
        "directories": directories,
        "symlinks": symlinks,
    }


def analyze_embedded_overlay(bsdtar: str, iso: Path) -> dict[str, object]:
    """Stream the overlay from the ISO into :func:`analyze_overlay_tar`."""

    environment = os.environ.copy()
    environment["LC_ALL"] = "C"
    process = subprocess.Popen(
        [bsdtar, "-xOf", str(iso), OVERLAY_MEMBER],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=environment,
    )
    assert process.stdout is not None
    analysis_error: Exception | None = None
    result: dict[str, object] | None = None
    try:
        result = analyze_overlay_tar(process.stdout)
    except Exception as error:
        analysis_error = error
    finally:
        process.stdout.close()

    stderr = process.stderr.read().decode("utf-8", errors="replace") if process.stderr else ""
    returncode = process.wait()
    if analysis_error is not None:
        raise analysis_error
    if returncode != 0:
        detail = stderr.strip() or "no bsdtar diagnostic"
        raise SizeReportError(f"cannot extract {OVERLAY_MEMBER}: {detail}")
    assert result is not None
    return result


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_iso_members(path: Path, entries: Iterable[ArchiveEntry]) -> None:
    rows = ["kind\tlogical_bytes\tallocated_bytes\tpath"]
    for entry in sorted(entries, key=lambda item: item.path):
        rows.append(
            f"{entry.kind}\t{entry.logical_bytes}\t{entry.allocated_bytes}\t{entry.path}"
        )
    path.write_text("\n".join(rows) + "\n", encoding="utf-8")


def write_overlay_members(path: Path, members: Iterable[tuple[str, str, int, str]]) -> None:
    rows = ["kind\tbytes\ttop_level\tpath"]
    for member_path, kind, size, category in sorted(members):
        rows.append(f"{kind}\t{size}\t{category}\t{member_path}")
    path.write_text("\n".join(rows) + "\n", encoding="utf-8")


def write_target_package_manifest(
    path: Path, packages: Iterable[PackageManifestRow]
) -> None:
    rows = ["line\tpackage"]
    for package in packages:
        rows.append(f"{package.line_number}\t{package.package}")
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


def format_live_payloads(entries: list[ArchiveEntry]) -> list[str]:
    apk_entries = [
        entry for entry in entries if entry.kind == "file" and entry.path.startswith("apks/")
    ]
    modloop_entries = [
        entry
        for entry in entries
        if entry.kind == "file" and entry.path.startswith("boot/modloop")
    ]
    apk_bytes = sum(entry.logical_bytes for entry in apk_entries)
    modloop_bytes = sum(entry.logical_bytes for entry in modloop_entries)
    return [
        "Live installer payloads",
        f"  live APK repository (apks/): {apk_bytes} bytes ({human_bytes(apk_bytes)}); "
        f"{len(apk_entries)} files",
        f"  live kernel modloop (boot/modloop*): {modloop_bytes} bytes ({human_bytes(modloop_bytes)}); "
        f"{len(modloop_entries)} files",
    ]


def format_overlay_section(overlay: dict[str, object], overlay_bytes: int) -> list[str]:
    regular_bytes = int(overlay["regular_bytes"])
    lines = [
        "Installer overlay",
        f"  compressed ISO member: {overlay_bytes} bytes ({human_bytes(overlay_bytes)})",
        f"  uncompressed regular-file bytes: {regular_bytes} ({human_bytes(regular_bytes)})",
        f"  regular files: {overlay['regular_files']}; directories: {overlay['directories']}; symlinks: {overlay['symlinks']}",
        "  top-level paths (regular-file bytes)",
        "    path                                      bytes             files",
    ]
    categories = overlay["categories"]
    assert isinstance(categories, dict)
    for category, values in sorted(categories.items(), key=lambda item: item[1][0], reverse=True):
        lines.append(
            f"    {category:<42} {values[0]:>14} ({human_bytes(values[0]):>12}) {values[2]:>10}"
        )
    return lines


def format_overlay_assets(overlay: dict[str, object]) -> list[str]:
    assets = overlay["assets"]
    assert isinstance(assets, list)
    lines = [
        "Explicit installer assets (root/home-installer)",
        "  bytes             kind       path",
    ]
    for path, kind, size in sorted(assets, key=lambda item: item[0]):
        lines.append(f"  {size:>14} {kind:<10} {path}")
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


def format_target_packages(
    packages: list[PackageManifestRow], manifest_bytes: bytes, metadata: dict[str, str]
) -> list[str]:
    manifest_hash = sha256_bytes(manifest_bytes)
    metadata_hash = metadata.get("target package manifest sha256")
    lines = [
        "Network-installed target rootfs",
        "  The finished target rootfs is not embedded in this ISO.",
        "  After network and DNS preflight, the installer uses this direct package manifest with apk.",
        f"  direct package manifest: {len(packages)} packages; {len(manifest_bytes)} bytes ({human_bytes(len(manifest_bytes))})",
        f"  direct package manifest SHA-256: {manifest_hash}",
    ]
    if metadata_hash is not None:
        lines.append(f"  ISO metadata manifest SHA-256: {metadata_hash}")
    lines.extend(("  direct target packages (manifest order)", "    line       package"))
    for package in packages:
        lines.append(f"    {package.line_number:>4}       {package.package}")
    return lines


def generate_report(dist: Path) -> tuple[str, Path]:
    iso = dist / "home-installer.iso"
    iso_metadata_path = dist / "iso-metadata.txt"
    require_regular_file(iso, "installer ISO")
    require_regular_file(iso_metadata_path, "ISO metadata")
    bsdtar = shutil.which("bsdtar")
    if bsdtar is None:
        raise SizeReportError(
            "make size requires bsdtar (install libarchive; macOS includes /usr/bin/bsdtar)"
        )

    iso_bytes = iso.stat().st_size
    metadata = parse_iso_metadata(iso_metadata_path)
    metadata_iso_bytes = parse_metadata_iso_bytes(metadata)
    if metadata_iso_bytes != iso_bytes:
        raise SizeReportError(
            f"ISO metadata size {metadata_iso_bytes} does not match {iso_bytes}"
        )
    metadata_iso_hash = metadata.get("iso sha256")
    iso_hash = sha256_file(iso)
    if metadata_iso_hash is not None and metadata_iso_hash != iso_hash:
        raise SizeReportError("ISO metadata SHA-256 does not match home-installer.iso")

    listing = run_bsdtar(bsdtar, ["-tvf", str(iso)], iso=iso).stdout
    iso_entries = parse_bsdtar_listing(listing)
    overlay_member = next(
        (entry for entry in iso_entries if entry.path == OVERLAY_MEMBER), None
    )
    if overlay_member is None:
        raise SizeReportError(f"ISO member is missing: {OVERLAY_MEMBER}")
    if overlay_member.kind != "file" or overlay_member.logical_bytes <= 0:
        raise SizeReportError(f"ISO member is not a non-empty file: {OVERLAY_MEMBER}")

    overlay = analyze_embedded_overlay(bsdtar, iso)
    package_manifest_bytes = overlay["package_manifest_bytes"]
    assert isinstance(package_manifest_bytes, bytes)
    metadata_manifest_hash = metadata.get("target package manifest sha256")
    if (
        metadata_manifest_hash is not None
        and metadata_manifest_hash != sha256_bytes(package_manifest_bytes)
    ):
        raise SizeReportError(
            "ISO metadata target package manifest SHA-256 does not match installer overlay"
        )

    detail_dir = dist / "size-report"
    detail_dir.mkdir(parents=True, exist_ok=True)
    write_iso_members(detail_dir / "iso-members.tsv", iso_entries)
    members = overlay["members"]
    assert isinstance(members, list)
    write_overlay_members(detail_dir / "overlay-members.tsv", members)
    packages = overlay["package_manifest"]
    assert isinstance(packages, list)
    write_target_package_manifest(detail_dir / "target-package-manifest.tsv", packages)

    lines = [
        "Home installer post-build size report",
        "",
        "Measurements distinguish compressed live-media members, the streamed installer overlay, and the direct target package manifest.",
        "The target rootfs is network-installed and is not an embedded ISO payload.",
        "",
        "Artifact",
        f"  ISO: {iso_bytes} bytes ({human_bytes(iso_bytes)})",
        f"  ISO SHA-256: {iso_hash}",
        f"  embedded installer overlay: {overlay_member.logical_bytes} bytes ({human_bytes(overlay_member.logical_bytes)})",
        "",
    ]
    lines.extend(format_live_payloads(iso_entries))
    lines.append("")
    lines.extend(format_iso_section(iso_entries, iso_bytes))
    lines.append("")
    lines.extend(format_largest_iso(iso_entries, iso_bytes))
    lines.append("")
    lines.extend(format_overlay_section(overlay, overlay_member.logical_bytes))
    lines.append("")
    lines.extend(format_overlay_assets(overlay))
    lines.append("")
    lines.extend(format_target_packages(packages, package_manifest_bytes, metadata))
    lines.extend(
        (
            "",
            "Complete detail files",
            f"  ISO members: {detail_dir / 'iso-members.tsv'}",
            f"  installer overlay members: {detail_dir / 'overlay-members.tsv'}",
            f"  direct target package manifest: {detail_dir / 'target-package-manifest.tsv'}",
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
