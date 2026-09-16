#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
installer=$repo/installer/install.sh

fail() {
	echo "layout test: $*" >&2
	exit 1
}

check_field() {
	output=$1
	field=$2
	wanted=$3
	actual=$(printf '%s\n' "$output" | awk -F= -v name="$field" '$1 == name {print $2}')
	[ "$actual" = "$wanted" ] || fail "$field: expected $wanted, got ${actual:-<missing>}"
}

for sector_size in 512 4096; do
	disk_bytes=$((12 * 1024 * 1024 * 1024))
	disk_sectors=$((disk_bytes / sector_size))
	output=$(INSTALLER_LAYOUT_ONLY=1 sh "$installer" "$disk_sectors" "$sector_size")
	check_field "$output" alignment_sectors 2048
	check_field "$output" boot_start 2048
	check_field "$output" boot_sectors $((512 * 1024 * 1024 / sector_size))
	check_field "$output" swap_sectors $((1024 * 1024 * 1024 / sector_size))
	root_start=$(printf '%s\n' "$output" | awk -F= '$1 == "root_start" {print $2}')
	root_sectors=$(printf '%s\n' "$output" | awk -F= '$1 == "root_sectors" {print $2}')
	[ $((root_start % 2048)) -eq 0 ] || fail "root start is not aligned for sector size $sector_size"
	[ $((root_sectors % 2048)) -eq 0 ] || fail "root size is not aligned for sector size $sector_size"
	done

nvme=$(INSTALLER_PARTITION_NAMES_ONLY=1 sh "$installer" /dev/nvme0n1)
[ "$nvme" = "$(printf '/dev/nvme0n1p1\n/dev/nvme0n1p2\n/dev/nvme0n1p3')" ] || fail "NVMe partition names are wrong"
mmc=$(INSTALLER_PARTITION_NAMES_ONLY=1 sh "$installer" /dev/mmcblk0)
[ "$mmc" = "$(printf '/dev/mmcblk0p1\n/dev/mmcblk0p2\n/dev/mmcblk0p3')" ] || fail "MMC partition names are wrong"
virtio=$(INSTALLER_PARTITION_NAMES_ONLY=1 sh "$installer" /dev/vda)
[ "$virtio" = "$(printf '/dev/vda1\n/dev/vda2\n/dev/vda3')" ] || fail "ordinary partition names are wrong"

echo 'installer layout tests passed'
