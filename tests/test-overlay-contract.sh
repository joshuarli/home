#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
overlay=$repo/iso/genapkovl-home-installer.sh
service=$(mktemp "${TMPDIR:-/tmp}/home-overlay-contract.XXXXXX")
trap 'rm -f "$service"' EXIT HUP INT TERM

grep -Fq 'HOME_INSTALLER_ASSETS' "$overlay"
grep -Fq 'rootfs-packages.txt' "$overlay"
if grep -Fq 'rootfs.tar.gz' "$overlay"; then
	echo 'overlay contract: complete target rootfs archive remains embedded' >&2
	exit 1
fi

# Extract the generated QEMU service body so the test cannot accidentally
# validate the separate, already-bounded media-overlay wait above it.
sed -n '/home-installer-qemu.*<<.*EOF/,/^EOF$/p' "$overlay" |
    sed '1d;$d' > "$service"

[ -s "$service" ] || {
	echo 'overlay contract: could not extract QEMU service body' >&2
	exit 1
}
grep -Fq 'while [ "$attempt" -lt 60 ] && [ ! -x /root/home-installer/install.sh ]; do' "$service"
grep -Fq 'attempt=$((attempt + 1))' "$service"
grep -Fq "home-installer: install script is not available after 60 seconds" "$service"
grep -Fq 'return 1' "$service"
grep -Fq 'home-installer-qemu-no-network-v1' "$service"
if grep -Fq 'while [ ! -f /root/home-installer/install.sh ]; do' "$service"; then
	echo 'overlay contract: unbounded installer wait remains' >&2
	exit 1
fi
sh -n "$service"

echo 'overlay retry contract tests passed'
