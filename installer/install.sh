#!/bin/sh
set -eu

archive=/root/home-installer/rootfs.tar.gz
target=/mnt/home-installer
efi_root=/sys/firmware/efi
sys_block_root=/sys/block
installer_media_root=/media
is_qemu=${IS_QEMU-0}
qemu_test_mode=0
wifi_conf=
wpa_pid=
wpa_log=/tmp/home-installer-wpa.$$.log
stty_state=
media_disks=
root_mounted=0
boot_mounted=0
dev_mounted=0
sys_mounted=0
run_mounted=0
proc_mounted=0

# Keep every arithmetic operation inside the exact range used by the shell and
# partitioning tools.  This is far beyond the supported laptop's storage size,
# but rejects unrepresentable geometry instead of wrapping it into a layout.
max_geometry_bytes=9007199254740991
alignment_bytes=$((1024 * 1024))
boot_bytes=$((512 * 1024 * 1024))
swap_bytes=$((1024 * 1024 * 1024))
minimum_root_bytes=$((2 * 1024 * 1024 * 1024))
gpt_head_sectors=34
gpt_tail_sectors=34

die() {
	echo "ERROR: $*" >&2
	exit 1
}

align_up() {
	align_value=$1
	align_sectors=$2
	printf '%s\n' $(( (align_value + align_sectors - 1) / align_sectors * align_sectors ))
}

require_decimal() {
	decimal_value=$1
	decimal_name=$2
	case "$decimal_value" in
		''|*[!0-9]*) die "invalid $decimal_name: $decimal_value" ;;
	esac
	case "$decimal_value" in
		0|[1-9]*) ;;
		*) die "invalid $decimal_name: $decimal_value" ;;
	esac
	[ "${#decimal_value}" -le 16 ] ||
		die "$decimal_name is out of supported range: $decimal_value"
}

require_positive_decimal() {
	require_decimal "$1" "$2"
	[ "$1" -gt 0 ] || die "$2 must be greater than zero"
}

resolve_device_path() {
	readlink -f "$1"
}

is_block_device() {
	[ -b "$1" ]
}

validate_sector_size() {
	case "$1" in
		512|4096) ;;
		*) die "unsupported logical sector size: $1" ;;
	esac
}

validate_disk_geometry() {
	geometry_bytes=$1
	geometry_sector_size=$2
	require_positive_decimal "$geometry_bytes" 'disk byte count'
	[ "$geometry_bytes" -le "$max_geometry_bytes" ] ||
		die "disk byte count is out of supported range: $geometry_bytes"
	validate_sector_size "$geometry_sector_size"
	[ $((geometry_bytes % geometry_sector_size)) -eq 0 ] ||
		die "disk byte count is not divisible by its logical sector size"
}

validate_partition_layout() {
	validation_disk_bytes=$1
	validation_sector_size=$2
	validation_disk_sectors=$3
	validation_alignment=$4
	validation_boot_start=$5
	validation_boot_sectors=$6
	validation_swap_start=$7
	validation_swap_sectors=$8
	validation_root_start=$9
	validation_root_sectors=${10}
	validation_gpt_head=${11}
	validation_gpt_tail=${12}

	validate_disk_geometry "$validation_disk_bytes" "$validation_sector_size"
	require_positive_decimal "$validation_disk_sectors" 'disk sector count'
	require_positive_decimal "$validation_alignment" 'layout alignment'
	require_positive_decimal "$validation_boot_start" 'ESP start sector'
	require_positive_decimal "$validation_boot_sectors" 'ESP sector count'
	require_positive_decimal "$validation_swap_start" 'swap start sector'
	require_positive_decimal "$validation_swap_sectors" 'swap sector count'
	require_positive_decimal "$validation_root_start" 'root start sector'
	require_positive_decimal "$validation_root_sectors" 'root sector count'
	require_positive_decimal "$validation_gpt_head" 'GPT head reservation'
	require_positive_decimal "$validation_gpt_tail" 'GPT tail reservation'

	validation_max_sectors=$((max_geometry_bytes / validation_sector_size))
	[ "$validation_disk_sectors" -le "$validation_max_sectors" ] ||
		die "disk sector count is out of supported range: $validation_disk_sectors"
	[ "$validation_disk_bytes" -eq $((validation_disk_sectors * validation_sector_size)) ] ||
		die 'disk byte count and logical sector count disagree'
	[ "$validation_gpt_head" -eq "$gpt_head_sectors" ] ||
		die 'unexpected GPT head reservation'
	[ "$validation_gpt_tail" -eq "$gpt_tail_sectors" ] ||
		die 'unexpected GPT tail reservation'
	[ "$validation_disk_sectors" -gt $((validation_gpt_head + validation_gpt_tail)) ] ||
		die 'disk has no usable sectors outside the GPT metadata'
	[ $((alignment_bytes % validation_sector_size)) -eq 0 ] ||
		die 'logical sector size cannot represent the required 1 MiB alignment'
	[ "$validation_alignment" -eq $((alignment_bytes / validation_sector_size)) ] ||
		die 'layout alignment does not equal 1 MiB'

	for validation_count in "$validation_boot_start" "$validation_boot_sectors" \
		"$validation_swap_start" "$validation_swap_sectors" \
		"$validation_root_start" "$validation_root_sectors"; do
		[ "$validation_count" -le "$validation_disk_sectors" ] ||
			die 'partition layout exceeds the disk sector count'
	done
	[ $((validation_boot_sectors * validation_sector_size)) -eq "$boot_bytes" ] ||
		die 'ESP size is not 512 MiB'
	[ $((validation_swap_sectors * validation_sector_size)) -eq "$swap_bytes" ] ||
		die 'swap size is not 1 GiB'
	[ $((validation_root_sectors * validation_sector_size)) -ge "$minimum_root_bytes" ] ||
		die 'root partition is smaller than 2 GiB'
	[ "$validation_boot_start" -ge "$validation_gpt_head" ] ||
		die 'ESP overlaps primary GPT metadata'
	[ $((validation_boot_start % validation_alignment)) -eq 0 ] ||
		die 'ESP start is not 1 MiB aligned'
	[ $((validation_swap_start % validation_alignment)) -eq 0 ] ||
		die 'swap start is not 1 MiB aligned'
	[ $((validation_root_start % validation_alignment)) -eq 0 ] ||
		die 'root start is not 1 MiB aligned'

	validation_boot_end=$((validation_boot_start + validation_boot_sectors))
	validation_swap_end=$((validation_swap_start + validation_swap_sectors))
	validation_root_end=$((validation_root_start + validation_root_sectors))
	validation_last_usable_end=$((validation_disk_sectors - validation_gpt_tail))
	[ "$validation_boot_end" -le "$validation_swap_start" ] ||
		die 'ESP and swap partitions overlap'
	[ "$validation_swap_end" -le "$validation_root_start" ] ||
		die 'swap and root partitions overlap'
	[ "$validation_root_end" -le "$validation_last_usable_end" ] ||
		die 'root partition overlaps backup GPT metadata'
	[ "$validation_root_end" -le "$validation_disk_sectors" ] ||
		die 'root partition ends beyond disk capacity'
}

partition_layout() {
	layout_disk_sectors=$1
	layout_sector_size=$2
	require_positive_decimal "$layout_disk_sectors" 'disk sector count'
	validate_sector_size "$layout_sector_size"
	layout_max_sectors=$((max_geometry_bytes / layout_sector_size))
	[ "$layout_disk_sectors" -le "$layout_max_sectors" ] ||
		die "disk sector count is out of supported range: $layout_disk_sectors"
	layout_disk_bytes=$((layout_disk_sectors * layout_sector_size))
	layout_alignment=$((alignment_bytes / layout_sector_size))
	layout_boot_sectors=$((boot_bytes / layout_sector_size))
	layout_swap_sectors=$((swap_bytes / layout_sector_size))
	layout_boot_start=$(align_up "$gpt_head_sectors" "$layout_alignment")
	layout_swap_start=$(align_up $((layout_boot_start + layout_boot_sectors)) "$layout_alignment")
	layout_root_start=$(align_up $((layout_swap_start + layout_swap_sectors)) "$layout_alignment")
	[ "$layout_disk_sectors" -gt $((gpt_head_sectors + gpt_tail_sectors)) ] ||
		die 'disk has no usable sectors outside the GPT metadata'
	layout_last_usable_end=$((layout_disk_sectors - gpt_tail_sectors))
	layout_root_sectors=$((layout_last_usable_end - layout_root_start))
	layout_root_sectors=$((layout_root_sectors / layout_alignment * layout_alignment))
	[ "$layout_root_sectors" -gt 0 ] ||
		die 'disk is too small for the fixed partition layout'

	validate_partition_layout "$layout_disk_bytes" "$layout_sector_size" \
		"$layout_disk_sectors" "$layout_alignment" "$layout_boot_start" \
		"$layout_boot_sectors" "$layout_swap_start" "$layout_swap_sectors" \
		"$layout_root_start" "$layout_root_sectors" "$gpt_head_sectors" \
		"$gpt_tail_sectors"

	printf 'disk_bytes=%s\n' "$layout_disk_bytes"
	printf 'disk_sectors=%s\n' "$layout_disk_sectors"
	printf 'sector_size=%s\n' "$layout_sector_size"
	printf 'gpt_head_sectors=%s\n' "$gpt_head_sectors"
	printf 'gpt_tail_sectors=%s\n' "$gpt_tail_sectors"
	printf 'first_usable_sector=%s\n' "$gpt_head_sectors"
	printf 'last_usable_sector=%s\n' $((layout_last_usable_end - 1))
	printf 'alignment_sectors=%s\n' "$layout_alignment"
	printf 'boot_start=%s\n' "$layout_boot_start"
	printf 'boot_sectors=%s\n' "$layout_boot_sectors"
	printf 'swap_start=%s\n' "$layout_swap_start"
	printf 'swap_sectors=%s\n' "$layout_swap_sectors"
	printf 'root_start=%s\n' "$layout_root_start"
	printf 'root_sectors=%s\n' "$layout_root_sectors"
	printf 'root_end=%s\n' $((layout_root_start + layout_root_sectors))
}

partition_layout_from_geometry() {
	geometry_bytes=$1
	geometry_sector_size=$2
	validate_disk_geometry "$geometry_bytes" "$geometry_sector_size"
	geometry_disk_sectors=$((geometry_bytes / geometry_sector_size))
	partition_layout "$geometry_disk_sectors" "$geometry_sector_size"
}

read_disk_geometry() {
	geometry_disk=$1
	if ! disk_bytes=$(blockdev --getsize64 "$geometry_disk"); then
		die "could not read target disk capacity: $geometry_disk"
	fi
	if ! sector_size=$(blockdev --getss "$geometry_disk"); then
		die "could not read target logical sector size: $geometry_disk"
	fi
	validate_disk_geometry "$disk_bytes" "$sector_size"
	disk_sectors=$((disk_bytes / sector_size))
}

layout_field() {
	layout_text=$1
	field_name=$2
	printf '%s\n' "$layout_text" | awk -F= -v name="$field_name" '
		$1 == name {
			if (seen++)
				duplicate = 1
			value = $2
		}
		END {
			if (seen != 1 || duplicate || value == "")
				exit 1
			print value
		}'
}

load_partition_layout() {
	read_disk_geometry "$1"
	layout=$(partition_layout "$disk_sectors" "$sector_size") || return 1
	reported_disk_bytes=$(layout_field "$layout" disk_bytes) || die 'partition layout omitted disk byte count'
	reported_disk_sectors=$(layout_field "$layout" disk_sectors) || die 'partition layout omitted disk sector count'
	reported_sector_size=$(layout_field "$layout" sector_size) || die 'partition layout omitted logical sector size'
	gpt_head=$(layout_field "$layout" gpt_head_sectors) || die 'partition layout omitted GPT head reservation'
	gpt_tail=$(layout_field "$layout" gpt_tail_sectors) || die 'partition layout omitted GPT tail reservation'
	alignment=$(layout_field "$layout" alignment_sectors) || die 'partition layout omitted alignment'
	boot_start=$(layout_field "$layout" boot_start) || die 'partition layout omitted ESP start'
	boot_sectors=$(layout_field "$layout" boot_sectors) || die 'partition layout omitted ESP size'
	swap_start=$(layout_field "$layout" swap_start) || die 'partition layout omitted swap start'
	swap_sectors=$(layout_field "$layout" swap_sectors) || die 'partition layout omitted swap size'
	root_start=$(layout_field "$layout" root_start) || die 'partition layout omitted root start'
	root_sectors=$(layout_field "$layout" root_sectors) || die 'partition layout omitted root size'
	[ "$reported_disk_bytes" = "$disk_bytes" ] || die 'partition layout changed disk byte capacity'
	[ "$reported_disk_sectors" = "$disk_sectors" ] || die 'partition layout changed disk sector capacity'
	[ "$reported_sector_size" = "$sector_size" ] || die 'partition layout changed logical sector size'
	validate_partition_layout "$disk_bytes" "$sector_size" "$disk_sectors" \
		"$alignment" "$boot_start" "$boot_sectors" "$swap_start" \
		"$swap_sectors" "$root_start" "$root_sectors" "$gpt_head" "$gpt_tail"
}

inspect_efivarfs_mount() {
	efivarfs_path=$1
	if ! efivarfs_mount_info=$(findmnt -rn -T "$efivarfs_path" -o TARGET,FSTYPE); then
		die "could not inspect the efivarfs mount state at $efivarfs_path"
	fi
	set -- $efivarfs_mount_info
	[ "$#" -eq 2 ] || die "malformed efivarfs mount state at $efivarfs_path"
	efivarfs_mount_target=$1
	efivarfs_mount_type=$2
}

ensure_efivarfs_mounted() {
	efivarfs_path=$1
	if [ ! -d "$efivarfs_path" ]; then
		mkdir -p "$efivarfs_path" || die "could not create efivarfs mountpoint: $efivarfs_path"
	fi
	inspect_efivarfs_mount "$efivarfs_path"
	if [ "$efivarfs_mount_target" = "$efivarfs_path" ]; then
		[ "$efivarfs_mount_type" = efivarfs ] ||
			die "expected efivarfs at $efivarfs_path, found $efivarfs_mount_type"
		return 0
	fi
	[ "$efivarfs_mount_type" = sysfs ] ||
		die "efivarfs mountpoint is not contained by sysfs: $efivarfs_path"

	# efivarfs may be built into the kernel, so a failed module load is not a
	# capability result.  The mount and exact postcondition below are decisive.
	modprobe efivarfs >/dev/null 2>&1 || true
	mount -t efivarfs efivarfs "$efivarfs_path" ||
		die "could not mount efivarfs at $efivarfs_path"
	inspect_efivarfs_mount "$efivarfs_path"
	[ "$efivarfs_mount_target" = "$efivarfs_path" ] &&
		[ "$efivarfs_mount_type" = efivarfs ] ||
		die "efivarfs mount was not verified at $efivarfs_path"
}

read_secure_boot_state() {
	secure_boot_path=$1
	[ -f "$secure_boot_path" ] && [ -r "$secure_boot_path" ] || return 1
	secure_boot_bytes=$(od -An -t u1 "$secure_boot_path" 2>/dev/null) || return 1
	set -- $secure_boot_bytes
	[ "$#" -eq 5 ] || return 1
	case "$5" in
		0) printf '%s\n' disabled ;;
		1) printf '%s\n' enabled ;;
		*) return 1 ;;
	esac
}

secure_boot_preflight() {
	secure_boot_efi_root=$1
	secure_boot_qemu_mode=$2
	secure_boot_qemu_seed=$3
	[ -d "$secure_boot_efi_root" ] || die 'this installer requires UEFI mode'
	secure_boot_efivars=$secure_boot_efi_root/efivars
	ensure_efivarfs_mounted "$secure_boot_efivars"
	echo "efivarfs verified at $secure_boot_efivars (fstype=$efivarfs_mount_type)"
	secure_boot_var=$secure_boot_efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c

	if [ -e "$secure_boot_var" ] || [ -L "$secure_boot_var" ]; then
		secure_boot_state=$(read_secure_boot_state "$secure_boot_var") ||
			die 'Secure Boot state is malformed; refusing to install an unsigned image'
		case "$secure_boot_state" in
			enabled) die 'Secure Boot is enabled; this unsigned installer requires it to be disabled' ;;
			disabled) ;;
			*) die 'Secure Boot state is malformed; refusing to install an unsigned image' ;;
		esac
		return 0
	fi

	# The pinned OVMF test bundle has been observed to mount efivarfs without
	# publishing this standard variable.  This narrow seed is accepted only for
	# that authenticated QEMU path and never for an unreadable or malformed var.
	if [ "$secure_boot_qemu_mode" = 1 ] && [ -r "$secure_boot_qemu_seed" ] &&
		[ "$(cat "$secure_boot_qemu_seed")" = disabled ]; then
		echo 'WARNING: verified efivarfs has no SecureBoot variable; accepting the explicit disabled QEMU test seed.' >&2
		return 0
	fi
	die 'Secure Boot state is unavailable; refusing to install an unsigned image'
}

partition_device_names() {
	disk=$1
	disk_name=$(basename "$disk")
	case "$disk_name" in
		nvme*n[0-9]|mmcblk[0-9])
			printf '%s\n' "$disk"p1 "$disk"p2 "$disk"p3
			;;
		*)
			printf '%s\n' "$disk"1 "$disk"2 "$disk"3
			;;
	esac
}

parent_disk() {
	parent_device=$1
	case "$parent_device" in
		/dev/*) ;;
		*) return 1 ;;
	esac
	parent_type=$(lsblk -dnro TYPE "$parent_device") || return 1
	case "$parent_type" in
		disk|rom)
			printf '%s\n' "$parent_device"
			;;
		part)
			parent_name=$(lsblk -dnro PKNAME "$parent_device") || return 1
			case "$parent_name" in
				''|*[!A-Za-z0-9._-]*) return 1 ;;
			esac
			parent_whole_disk=/dev/$parent_name
			parent_whole_type=$(lsblk -dnro TYPE "$parent_whole_disk") || return 1
			[ "$parent_whole_type" = disk ] || return 1
			printf '%s\n' "$parent_whole_disk"
			;;
		*)
			# Device-mapper, loop, RAID, and similar arrangements are not safe
			# targets for this fixed whole-disk installer.
			return 1
			;;
	esac
}

discover_installer_media_disks() {
	media_disks=
	for media_mount in "$installer_media_root"/*; do
		[ -d "$media_mount" ] || continue
		# -M selects an exact mountpoint.  An unmounted directory is ordinary;
		# a mounted block source whose parent cannot be resolved is not.
		media_source=$(findmnt -rn -M "$media_mount" -o SOURCE 2>/dev/null) || continue
		[ -n "$media_source" ] ||
			die "could not inspect installer media mount: $media_mount"
		case "$media_source" in
			/dev/*)
				media_disk=$(parent_disk "$media_source") ||
					die "could not determine installer media parent disk: $media_source"
				media_disks="$media_disks $media_disk"
				;;
		esac
	done
}

is_media_disk() {
	for media_disk in $media_disks; do
		[ "$1" = "$media_disk" ] && return 0
	done
	return 1
}

disk_is_mounted() {
	mount_checked_disk=$1
	mounted_sources=$(findmnt -rn -o SOURCE) ||
		die 'could not inspect mounted filesystem sources'
	[ -n "$mounted_sources" ] || die 'mounted filesystem source inspection was empty'
	mount_checked_devices=$(lsblk -nr -o PATH "$mount_checked_disk") ||
		die "could not inspect target disk descendants: $mount_checked_disk"
	[ -n "$mount_checked_devices" ] ||
		die "target disk has no inspectable block-device tree: $mount_checked_disk"
	while IFS= read -r mount_checked_device; do
		[ -n "$mount_checked_device" ] || continue
		case "$mount_checked_device" in
			/dev/*) ;;
			*) die "unexpected target block-device path: $mount_checked_device" ;;
		esac
		while IFS= read -r mounted_source; do
			case "$mounted_source" in
				"$mount_checked_device"|"$mount_checked_device"\[* ) return 0 ;;
			esac
		done <<EOF
$mounted_sources
EOF
	done <<EOF
$mount_checked_devices
EOF
	return 1
}

validate_target_disk() {
	requested_disk=$1
	disk=$(resolve_device_path "$requested_disk") || die 'target must resolve to a /dev device'
	case "$disk" in
		/dev/*) ;;
		*) die 'target must resolve to a /dev device' ;;
	esac
	is_block_device "$disk" || die "not a block device: $disk"
	disk_type=$(lsblk -dnro TYPE "$disk") ||
		die "could not inspect target disk type: $disk"
	[ "$disk_type" = disk ] || die "target must be a whole disk: $disk"
	base=$(basename "$disk")
	case "$base" in
		fd*|loop*|ram*|sr*|zram*|dm-*|md*)
			die "unsupported target disk type: $disk"
			;;
	esac
	[ -d "$sys_block_root/$base" ] ||
		die "target is not a kernel whole-disk device: $disk"
	if ! removable=$(cat "$sys_block_root/$base/removable"); then
		die "could not inspect target removability: $disk"
	fi
	case "$removable" in
		0) ;;
		1) die "refusing removable target disk: $disk" ;;
		*) die "invalid target removability state: $disk" ;;
	esac
	if ! read_only=$(blockdev --getro "$disk"); then
		die "could not inspect target read-only state: $disk"
	fi
	case "$read_only" in
		0) ;;
		1) die "target disk is read-only: $disk" ;;
		*) die "invalid target read-only state: $disk" ;;
	esac
	is_media_disk "$disk" && die "the installer media resolves to the target disk: $disk"
	disk_is_mounted "$disk" && die "target disk or one of its partitions is mounted: $disk"
	if ! root_source=$(findmnt -rn -M / -o SOURCE); then
		die 'could not inspect the live root filesystem source'
	fi
	[ -n "$root_source" ] || die 'live root filesystem source inspection was empty'
	case "$root_source" in
		/dev/*)
			root_disk=$(parent_disk "$root_source") ||
				die "could not determine the live root parent disk: $root_source"
			[ "$disk" != "$root_disk" ] ||
				die "refusing the live system's root disk: $disk"
			;;
	esac
	if ! active_swaps=$(swapon --show=NAME --noheadings); then
		die 'could not inspect active swap devices'
	fi
	while IFS= read -r active_swap; do
		[ -n "$active_swap" ] || continue
		case "$active_swap" in
			/dev/*) ;;
			*) die "active swap is not a supported block device: $active_swap" ;;
		esac
		active_swap_disk=$(parent_disk "$active_swap") ||
			die "could not determine active swap parent disk: $active_swap"
		[ "$active_swap_disk" != "$disk" ] ||
			die "target disk has active swap: $disk"
	done <<EOF
$active_swaps
EOF
	printf '%s\n' "$disk"
}

require_disk_confirmation() {
	confirmation_value=$1
	confirmation_disk=$2
	confirmation_error=$3
	[ "$confirmation_value" = "$confirmation_disk" ] || die "$confirmation_error"
}

partition_table_ready() {
	dump=$(sfdisk --dump "$disk" 2>/dev/null) || return 1
	printf '%s\n' "$dump" | grep -Fq "$boot_partition :" || return 1
	printf '%s\n' "$dump" | grep -Fq "$swap_partition :" || return 1
	printf '%s\n' "$dump" | grep -Fq "$root_partition :" || return 1
}

partition_target_disk() {
	disk=$1
	# All geometry and every partition boundary are checked before wipefs can
	# erase an existing signature or sfdisk can change the table.
	load_partition_layout "$disk"
	partition_names=$(partition_device_names "$disk")
	boot_partition=$(printf '%s\n' "$partition_names" | sed -n '1p')
	swap_partition=$(printf '%s\n' "$partition_names" | sed -n '2p')
	root_partition=$(printf '%s\n' "$partition_names" | sed -n '3p')
	[ -n "$boot_partition" ] && [ -n "$swap_partition" ] && [ -n "$root_partition" ] ||
		die 'could not determine target partition device names'

	wipefs -af "$disk"
	sfdisk --wipe always "$disk" <<EOF
label: gpt
unit: sectors
start=$boot_start, size=$boot_sectors, type=U, name="Alpine boot"
start=$swap_start, size=$swap_sectors, type=S, name="Alpine swap"
start=$root_start, size=$root_sectors, type=L, name="Alpine root"
EOF
	blockdev --rereadpt "$disk" 2>/dev/null || true
	partx -u "$disk" 2>/dev/null || true
	if command -v mdev >/dev/null 2>&1; then
		mdev -s 2>/dev/null || true
	fi

	attempt=0
	while [ "$attempt" -lt 30 ]; do
		[ -b "$boot_partition" ] && [ -b "$swap_partition" ] && [ -b "$root_partition" ] &&
			partition_table_ready && break
		attempt=$((attempt + 1))
		sleep 1
	done
	[ -b "$boot_partition" ] && [ -b "$swap_partition" ] && [ -b "$root_partition" ] &&
		partition_table_ready ||
		die 'partition devices did not appear within 30 seconds'
}

if [ "${INSTALLER_LAYOUT_ONLY-0}" = 1 ]; then
	[ "$#" -eq 2 ] || die 'usage: INSTALLER_LAYOUT_ONLY=1 install.sh DISK_SECTORS SECTOR_SIZE'
	partition_layout "$1" "$2"
	exit 0
fi

if [ "${INSTALLER_GEOMETRY_ONLY-0}" = 1 ]; then
	[ "$#" -eq 2 ] || die 'usage: INSTALLER_GEOMETRY_ONLY=1 install.sh DISK_BYTES SECTOR_SIZE'
	partition_layout_from_geometry "$1" "$2"
	exit 0
fi

if [ "${INSTALLER_DISK_LAYOUT_ONLY-0}" = 1 ]; then
	[ "$#" -eq 1 ] || die 'usage: INSTALLER_DISK_LAYOUT_ONLY=1 install.sh DISK'
	read_disk_geometry "$1"
	partition_layout "$disk_sectors" "$sector_size"
	exit 0
fi

if [ "${INSTALLER_PARTITION_NAMES_ONLY-0}" = 1 ]; then
	[ "$#" -eq 1 ] || die 'usage: INSTALLER_PARTITION_NAMES_ONLY=1 install.sh DISK'
	partition_device_names "$1"
	exit 0
fi

require_command() {
	command -v "$1" >/dev/null 2>&1 || die "required command is missing: $1"
}

restore_terminal() {
	if [ -n "$stty_state" ]; then
		if stty "$stty_state" 2>/dev/null || stty echo 2>/dev/null; then
			stty_state=
			return 0
		fi
		return 1
	fi
}

cleanup_failure() {
	echo "ERROR: cleanup failed: $*" >&2
	cleanup_failed=1
}

cleanup_remove() {
	cleanup_path=$1
	[ -n "$cleanup_path" ] || return 0
	rm -f -- "$cleanup_path" || cleanup_failure "could not remove $cleanup_path"
}

cleanup_unmount_tree() {
	cleanup_path=$1
	umount -R "$cleanup_path" || cleanup_failure "could not unmount $cleanup_path"
}

cleanup_unmount() {
	cleanup_path=$1
	umount "$cleanup_path" || cleanup_failure "could not unmount $cleanup_path"
}

cleanup_wpa_supplicant() {
	cleanup_pid=$1
	[ -n "$cleanup_pid" ] || return 0
	# $! is a direct child recorded when this installer starts wpa_supplicant;
	# unlike a name match in /proc, it remains an ownership boundary for cleanup.
	if kill -0 "$cleanup_pid" 2>/dev/null; then
		kill "$cleanup_pid" 2>/dev/null ||
			cleanup_failure "could not stop owned wpa_supplicant process $cleanup_pid"
	fi
	# A process terminated by cleanup commonly has a nonzero wait status.  Its
	# disappearance, rather than that status, is the cleanup postcondition.
	wait "$cleanup_pid" 2>/dev/null || true
}

cleanup() {
	status=$?
	cleanup_failed=0
	set +e
	restore_terminal || cleanup_failure 'could not restore terminal echo'
	if [ -n "$wpa_pid" ]; then
		cleanup_wpa_supplicant "$wpa_pid"
		wpa_pid=
	fi
	cleanup_remove "$wifi_conf"
	cleanup_remove "$wpa_log"
	if [ "$run_mounted" -eq 1 ]; then
		cleanup_unmount_tree "$target/run"
	fi
	if [ "$sys_mounted" -eq 1 ]; then
		cleanup_unmount_tree "$target/sys"
	fi
	if [ "$proc_mounted" -eq 1 ]; then
		cleanup_unmount "$target/proc"
	fi
	if [ "$dev_mounted" -eq 1 ]; then
		cleanup_unmount_tree "$target/dev"
	fi
	if [ "$boot_mounted" -eq 1 ]; then
		cleanup_unmount "$target/boot"
	fi
	if [ "$root_mounted" -eq 1 ]; then
		cleanup_unmount "$target"
	fi
	if [ "$cleanup_failed" -ne 0 ] && [ "$status" -eq 0 ]; then
		status=1
	fi
	trap - EXIT INT TERM
	exit "$status"
}

mount_dev_tree() {
	mount --rbind /dev "$target/dev"
	dev_mounted=1
	mount --make-rslave "$target/dev"
}

mount_sys_tree() {
	mount --rbind /sys "$target/sys"
	sys_mounted=1
	mount --make-rslave "$target/sys"
}

mount_run_tree() {
	mount --rbind /run "$target/run"
	run_mounted=1
	mount --make-rslave "$target/run"
}

verify_target_boot_mount() {
	boot_mount_info=$(findmnt -rn -M "$target/boot" -o SOURCE,FSTYPE) ||
		die "could not inspect the target ESP mount: $target/boot"
	set -- $boot_mount_info
	[ "$#" -eq 2 ] || die "malformed target ESP mount state: $target/boot"
	[ "$1" = "$boot_partition" ] ||
		die "target /boot is not mounted from the ESP: $boot_partition"
	[ "$2" = vfat ] || die "target /boot is not a vfat ESP: $target/boot"
}

# Library tests may provide disposable sysfs/media fixtures without changing
# the physical installer boundary.  These overrides are intentionally read
# only after all production functions have been defined and the library mode
# exits before any target selection or destructive operation.
if [ "${INSTALLER_LIBRARY_ONLY-0}" = 1 ]; then
	sys_block_root=${INSTALLER_SYS_BLOCK_ROOT-/sys/block}
	installer_media_root=${INSTALLER_MEDIA_ROOT-/media}
fi

# Host-side safety tests source only these functions.  This mode cannot reach
# target selection, mounting, or any destructive operation.
if [ "${INSTALLER_LIBRARY_ONLY-0}" = 1 ]; then
	return 0 2>/dev/null || exit 0
fi

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for command_name in awk blkid blockdev chroot cmp cp efibootmgr findmnt grep \
	ip lsblk mkfs.ext4 mkfs.vfat mktemp mkswap mount nslookup od partx \
	readlink sed sfdisk stat stty tar timeout umount udhcpc wipefs \
	swapon wpa_passphrase wpa_supplicant modprobe; do
	require_command "$command_name"
done

[ "$(id -u)" -eq 0 ] || die 'run this installer as root'
[ -d "$efi_root" ] || die 'this installer requires UEFI mode'
[ -f "$archive" ] || die 'embedded rootfs archive is missing'

# Unattended disk selection is an authenticated QEMU-test input, not a
# general environment override. A physical invocation must always select and
# confirm its target interactively. The fw_cfg file cannot exist on the
# laptop, so setting IS_QEMU by itself cannot bypass this boundary.
qemu_seed_file=/sys/firmware/qemu_fw_cfg/by_name/opt/home-installer-test/raw
if [ "$is_qemu" = 1 ]; then
	[ "${INSTALLER_TEST_MODE-}" = 1 ] || die 'QEMU mode requires the explicit test mode input'
	[ -r "$qemu_seed_file" ] && [ "$(cat "$qemu_seed_file")" = home-installer-qemu-v1 ] ||
		die 'QEMU mode requires the explicit installer fw_cfg test seed'
	qemu_test_mode=1
else
	[ -z "${INSTALLER_DISK-}" ] || die 'INSTALLER_DISK is only accepted by the explicit QEMU test mode'
	[ -z "${INSTALLER_CONFIRM-}" ] || die 'INSTALLER_CONFIRM is only accepted by the explicit QEMU test mode'
fi

qemu_secure_boot_file=/sys/firmware/qemu_fw_cfg/by_name/opt/home-secure-boot/raw
secure_boot_preflight "$efi_root" "$qemu_test_mode" "$qemu_secure_boot_file"

if [ "$qemu_test_mode" = 1 ]; then
	wifi_iface=${QEMU_NET_IFACE-}
	[ -n "$wifi_iface" ] || die 'QEMU mode requires the explicit QEMU_NET_IFACE test input'
	[ -d "/sys/class/net/$wifi_iface" ] || die "QEMU network interface does not exist: $wifi_iface"
	echo "QEMU mode: using the explicitly identified Ethernet interface $wifi_iface."
else
	wifi_interfaces=
	for sys_iface in /sys/class/net/*; do
		iface=$(basename "$sys_iface")
		[ -d "$sys_iface/wireless" ] || continue
		vendor=
		[ -r "$sys_iface/device/vendor" ] && vendor=$(cat "$sys_iface/device/vendor")
		[ "$vendor" = 0x8086 ] || continue
		wifi_interfaces="$wifi_interfaces $iface"
	done
	set -- $wifi_interfaces
	[ "$#" -gt 0 ] || die 'no Intel wireless interface was found'
	if [ "$#" -eq 1 ]; then
		wifi_iface=$1
	else
		echo 'Available Intel wireless interfaces:'
		index=1
		for iface do
			echo "  $index) $iface"
			index=$((index + 1))
		done
		printf 'Select interface [1]: '
		read -r choice
		choice=${choice:-1}
		case "$choice" in
			*[!0-9]*|'') die 'invalid wireless interface selection' ;;
		esac
		wifi_iface=$(printf '%s\n' $wifi_interfaces | awk -v wanted="$choice" 'NR == wanted {print; exit}')
		[ -n "$wifi_iface" ] || die 'invalid wireless interface selection'
	fi

	printf 'Wi-Fi SSID: '
	read -r ssid
	[ -n "$ssid" ] || die 'SSID cannot be empty'
	printf 'Wi-Fi passphrase: '
	stty_state=$(stty -g)
	stty -echo
	if ! read -r passphrase; then
		restore_terminal
		die 'could not read the Wi-Fi passphrase'
	fi
	restore_terminal
	printf '\n'
	wifi_conf=$(mktemp /tmp/home-installer.wpa.XXXXXX)
	chmod 0600 "$wifi_conf"
	wpa_passphrase "$ssid" "$passphrase" > "$wifi_conf"
	sed -i '/^[[:space:]]*#psk=/d' "$wifi_conf"
	unset passphrase

	echo "Connecting to Wi-Fi on $wifi_iface..."
	ip link set "$wifi_iface" up
	wpa_supplicant -i "$wifi_iface" -c "$wifi_conf" >"$wpa_log" 2>&1 &
	wpa_pid=$!
fi

network_ready=0
ip link set "$wifi_iface" up
attempt=0
while [ "$attempt" -lt 5 ]; do
	if udhcpc -i "$wifi_iface" -q -n -t 5 -T 1 >/dev/null 2>&1; then
		network_ready=1
		break
	fi
	attempt=$((attempt + 1))
	[ "$attempt" -lt 5 ] && sleep 1
done
if [ "$network_ready" -eq 1 ]; then
	echo 'DHCP preflight passed.'
	if timeout 5 nslookup dl-cdn.alpinelinux.org >/dev/null 2>&1; then
		echo 'DNS preflight passed.'
	else
		echo 'WARNING: DNS preflight failed; the embedded installation payload is still available.' >&2
	fi
else
	echo 'WARNING: DHCP did not complete; continuing with the embedded payload and persisted network configuration.' >&2
fi

discover_installer_media_disks

echo 'Available whole-disk target candidates:'
candidate_count=0
for sys_disk in "$sys_block_root"/*; do
	base=$(basename "$sys_disk")
	disk=/dev/$base
	case "$base" in
		fd*|loop*|ram*|sr*|zram*|dm-*|md*) continue ;;
	esac
	[ -b "$disk" ] || continue
	[ "$(lsblk -dnro TYPE "$disk" 2>/dev/null || true)" = disk ] || continue
	is_media_disk "$disk" && continue
	candidate_bytes=$(blockdev --getsize64 "$disk") ||
		die "could not inspect target disk capacity: $disk"
	echo "  $disk $candidate_bytes bytes"
	candidate_count=$((candidate_count + 1))
done
[ "$candidate_count" -gt 0 ] || die 'no target disks found'

disk=${INSTALLER_DISK-}
if [ "$qemu_test_mode" = 1 ]; then
	[ -n "$disk" ] || die 'QEMU test mode requires INSTALLER_DISK'
	confirmation=${INSTALLER_CONFIRM-}
	require_disk_confirmation "$confirmation" "$disk" 'QEMU test target was not explicitly confirmed'
else
	printf 'Target disk (ALL DATA WILL BE ERASED): '
	read -r disk
fi
disk=$(validate_target_disk "$disk")

if [ "$qemu_test_mode" != 1 ]; then
	printf "Type '%s' again to confirm: " "$disk"
	read -r confirmation
fi
require_disk_confirmation "$confirmation" "$disk" 'disk erase was not confirmed'
partition_target_disk "$disk"

mkfs.vfat -F 32 -n ALPINE_BOOT "$boot_partition"
mkswap -L ALPINE_SWAP "$swap_partition"
mkfs.ext4 -F -L ALPINE_ROOT "$root_partition"

case "$target" in
	/mnt/home-installer) ;;
	*) die 'unsafe target mount path' ;;
esac
if [ -L "$target" ] || [ -e "$target" ] && [ ! -d "$target" ]; then
	die "target mount path is not a directory: $target"
fi
mkdir -p "$target"
mount "$root_partition" "$target"
root_mounted=1
mkdir -p "$target/boot"
mount "$boot_partition" "$target/boot"
boot_mounted=1

tar -xzf "$archive" -C "$target"

root_uuid=$(blkid -s UUID -o value "$root_partition")
boot_uuid=$(blkid -s UUID -o value "$boot_partition")
swap_uuid=$(blkid -s UUID -o value "$swap_partition")
[ -n "$root_uuid" ] || die 'root partition has no filesystem UUID'
cat > "$target/etc/fstab" <<EOF
UUID=$root_uuid / ext4 defaults 0 1
UUID=$boot_uuid /boot vfat umask=0077 0 2
UUID=$swap_uuid none swap sw 0 0
EOF

rm -f "$target/etc/resolv.conf"
if [ -f /etc/resolv.conf ] || [ -L /etc/resolv.conf ]; then
	cp -L /etc/resolv.conf "$target/etc/resolv.conf"
fi
if [ "$qemu_test_mode" != 1 ]; then
	mkdir -p "$target/etc/wpa_supplicant"
	cp "$wifi_conf" "$target/etc/wpa_supplicant/wpa_supplicant.conf"
	chmod 0600 "$target/etc/wpa_supplicant/wpa_supplicant.conf"
fi
cat > "$target/etc/network/interfaces" <<EOF
auto lo
iface lo inet loopback

auto $wifi_iface
iface $wifi_iface inet dhcp
EOF

mount_dev_tree
mount -t proc proc "$target/proc"
proc_mounted=1
mount_sys_tree
mount_run_tree

chroot "$target" rc-update add networking default
if [ "$qemu_test_mode" != 1 ]; then
	chroot "$target" rc-update add wpa_supplicant default
fi

# The package-owned hook runs only after the root UUID is known and /boot is
# verified as the mounted ESP.  Do not replay a copied package trigger here:
# apk owns its update lifecycle.
sed -i "s/INSTALLER_ROOT_UUID/$root_uuid/g" "$target/etc/kernel-hooks.d/secureboot.conf"
grep -q "root=UUID=$root_uuid" "$target/etc/kernel-hooks.d/secureboot.conf" ||
	die 'root UUID substitution failed'
verify_target_boot_mount
# Reinstall the packaged kernel so apk runs Alpine's real kernel-hooks
# trigger. This is intentionally deferred until the target UUID is in the
# command line and the real ESP is mounted at /boot; no private trigger copy
# is needed in the prepared rootfs.
chroot "$target" /sbin/apk --no-cache fix linux-lts

canonical_efi="$target/boot/EFI/alpine/linux-lts.efi"
fallback_efi="$target/boot/EFI/BOOT/BOOTX64.EFI"
[ -f "$canonical_efi" ] || die 'kernel hooks did not generate the canonical EFI image'
[ -f "$fallback_efi" ] || die 'kernel hooks did not synchronize the EFI fallback image'
cmp "$canonical_efi" "$fallback_efi" >/dev/null || die 'canonical and fallback EFI images differ'

efibootmgr --disk "$disk" --part 1 --create --label Alpine \
	--loader '\EFI\alpine\linux-lts.efi' ||
	echo 'WARNING: could not create NVRAM entry; the fallback EFI path remains authoritative'

echo 'Installation complete. Remove the installer media and reboot.'
