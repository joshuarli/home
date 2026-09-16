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

disk_bytes=$((12 * 1024 * 1024 * 1024))
for sector_size in 512 4096; do
	output=$(INSTALLER_GEOMETRY_ONLY=1 sh "$installer" "$disk_bytes" "$sector_size")
	disk_sectors=$((disk_bytes / sector_size))
	alignment=$(printf '%s\n' "$output" | awk -F= '$1 == "alignment_sectors" {print $2}')
	check_field "$output" disk_bytes "$disk_bytes"
	check_field "$output" disk_sectors "$disk_sectors"
	check_field "$output" sector_size "$sector_size"
	check_field "$output" alignment_sectors $((1024 * 1024 / sector_size))
	check_field "$output" boot_start $((1024 * 1024 / sector_size))
	check_field "$output" boot_sectors $((512 * 1024 * 1024 / sector_size))
	check_field "$output" swap_sectors $((1024 * 1024 * 1024 / sector_size))
	root_start=$(printf '%s\n' "$output" | awk -F= '$1 == "root_start" {print $2}')
	root_sectors=$(printf '%s\n' "$output" | awk -F= '$1 == "root_sectors" {print $2}')
	root_end=$(printf '%s\n' "$output" | awk -F= '$1 == "root_end" {print $2}')
	[ $((root_start % alignment)) -eq 0 ] || fail "root start is not aligned for sector size $sector_size"
	[ $((root_sectors % alignment)) -eq 0 ] || fail "root size is not aligned for sector size $sector_size"
	[ "$root_end" -le $((disk_sectors - 34)) ] || fail "root overlaps backup GPT for sector size $sector_size"
	[ $((root_sectors * sector_size)) -ge $((2 * 1024 * 1024 * 1024)) ] ||
		fail "root is below its minimum size for sector size $sector_size"
done

if INSTALLER_GEOMETRY_ONLY=1 sh "$installer" 3 512 >/dev/null 2>&1; then
	fail 'non-divisible disk geometry was accepted'
fi
if INSTALLER_GEOMETRY_ONLY=1 sh "$installer" "$((3 * 1024 * 1024 * 1024))" 2048 >/dev/null 2>&1; then
	fail 'unsupported logical sector size was accepted'
fi

temporary=$(mktemp -d "/tmp/home-installer-geometry.XXXXXX")
trap 'rm -rf "$temporary"' EXIT HUP INT TERM
stub_bin=$temporary/bin
mkdir "$stub_bin"
marker=$temporary/wipefs-called
cat > "$stub_bin/blockdev" <<'EOF'
#!/bin/sh
case "$1" in
--getsize64) printf '3\n' ;;
--getss) printf '512\n' ;;
*) exit 1 ;;
esac
EOF
cat > "$stub_bin/wipefs" <<EOF
#!/bin/sh
touch '$marker'
exit 99
EOF
chmod 0755 "$stub_bin/blockdev" "$stub_bin/wipefs"
if PATH="$stub_bin:$PATH" sh -c 'INSTALLER_LIBRARY_ONLY=1 . "$1"; partition_target_disk /dev/fake' sh "$installer" \
	>/dev/null 2>&1; then
	fail 'invalid real-device geometry unexpectedly passed'
fi
[ ! -e "$marker" ] || fail 'invalid geometry invoked wipefs'

nvme=$(INSTALLER_PARTITION_NAMES_ONLY=1 sh "$installer" /dev/nvme0n1)
[ "$nvme" = "$(printf '/dev/nvme0n1p1\n/dev/nvme0n1p2\n/dev/nvme0n1p3')" ] || fail "NVMe partition names are wrong"
mmc=$(INSTALLER_PARTITION_NAMES_ONLY=1 sh "$installer" /dev/mmcblk0)
[ "$mmc" = "$(printf '/dev/mmcblk0p1\n/dev/mmcblk0p2\n/dev/mmcblk0p3')" ] || fail "MMC partition names are wrong"
virtio=$(INSTALLER_PARTITION_NAMES_ONLY=1 sh "$installer" /dev/vda)
[ "$virtio" = "$(printf '/dev/vda1\n/dev/vda2\n/dev/vda3')" ] || fail "ordinary partition names are wrong"

echo 'installer layout tests passed'
