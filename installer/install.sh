#!/bin/sh
set -eu

archive=/root/home-installer/rootfs.tar.gz
target=/mnt/home-installer
is_qemu=${IS_QEMU-0}
qemu_test_mode=0
wifi_conf=
wpa_pid=
wpa_log=/tmp/home-installer-wpa.$$.log
stty_state=
root_mounted=0
boot_mounted=0
dev_mounted=0
sys_mounted=0
run_mounted=0
proc_mounted=0

die() {
	echo "ERROR: $*" >&2
	exit 1
}

align_up() {
	value=$1
	alignment=$2
	printf '%s\n' $(( (value + alignment - 1) / alignment * alignment ))
}

partition_layout() {
	disk_sectors=$1
	sector_size=$2
	case "$sector_size" in
		512|4096) ;;
		*) die "unsupported logical sector size: $sector_size" ;;
	esac
	case "$disk_sectors" in
		''|*[!0-9]*) die "invalid disk sector count: $disk_sectors" ;;
	esac

	alignment=2048
	boot_sectors=$((512 * 1024 * 1024 / sector_size))
	swap_sectors=$((1024 * 1024 * 1024 / sector_size))
	swap_start=$(align_up $((alignment + boot_sectors)) "$alignment")
	root_start=$(align_up $((swap_start + swap_sectors)) "$alignment")
	gpt_tail_sectors=34
	root_sectors=$((disk_sectors - gpt_tail_sectors - root_start))
	root_sectors=$((root_sectors / alignment * alignment))
	[ "$root_sectors" -ge $((2 * 1024 * 1024 * 1024 / sector_size)) ] ||
		die "disk is too small for the fixed 512 MiB ESP, 1 GiB swap and 2 GiB root minimum"

	printf 'alignment_sectors=%s\n' "$alignment"
	printf 'boot_start=%s\n' "$alignment"
	printf 'boot_sectors=%s\n' "$boot_sectors"
	printf 'swap_start=%s\n' "$swap_start"
	printf 'swap_sectors=%s\n' "$swap_sectors"
	printf 'root_start=%s\n' "$root_start"
	printf 'root_sectors=%s\n' "$root_sectors"
	printf 'gpt_tail_sectors=%s\n' "$gpt_tail_sectors"
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

if [ "${INSTALLER_LAYOUT_ONLY-0}" = 1 ]; then
	[ "$#" -eq 2 ] || die 'usage: INSTALLER_LAYOUT_ONLY=1 install.sh DISK_SECTORS SECTOR_SIZE'
	partition_layout "$1" "$2"
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
		stty "$stty_state" 2>/dev/null || stty echo 2>/dev/null || true
		stty_state=
	fi
}

cleanup() {
	status=$?
	set +e
	restore_terminal
	if [ -n "$wpa_pid" ]; then
		if [ -r "/proc/$wpa_pid/cmdline" ] &&
			tr '\000' ' ' < "/proc/$wpa_pid/cmdline" | grep -q wpa_supplicant; then
			kill "$wpa_pid" 2>/dev/null || true
		fi
		wait "$wpa_pid" 2>/dev/null || true
		wpa_pid=
	fi
	[ -n "$wifi_conf" ] && rm -f -- "$wifi_conf"
	rm -f -- "$wpa_log"
	[ "$run_mounted" -eq 1 ] && umount -R "$target/run" 2>/dev/null || true
	[ "$sys_mounted" -eq 1 ] && umount -R "$target/sys" 2>/dev/null || true
	[ "$proc_mounted" -eq 1 ] && umount "$target/proc" 2>/dev/null || true
	[ "$dev_mounted" -eq 1 ] && umount -R "$target/dev" 2>/dev/null || true
	[ "$boot_mounted" -eq 1 ] && umount "$target/boot" 2>/dev/null || true
	[ "$root_mounted" -eq 1 ] && umount "$target" 2>/dev/null || true
	trap - EXIT INT TERM
	exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for command_name in awk blkid blockdev chroot cmp cp efibootmgr find findmnt grep \
	ip lsblk mkfs.ext4 mkfs.vfat mktemp mkswap mount nslookup od partx \
	readlink sed sfdisk stat stty tar timeout umount udhcpc wipefs \
	wpa_passphrase wpa_supplicant modprobe; do
	require_command "$command_name"
done

[ "$(id -u)" -eq 0 ] || die 'run this installer as root'
[ -d /sys/firmware/efi ] || die 'this installer requires UEFI mode'
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

efivars=/sys/firmware/efi/efivars
if [ -d /sys/firmware/efi ]; then
	modprobe efivarfs 2>/dev/null || true
	mkdir -p "$efivars"
	if ! findmnt -rn -T "$efivars" >/dev/null 2>&1; then
		mount -t efivarfs efivarfs "$efivars" 2>/dev/null || true
	fi
fi
secure_boot_var=$(find /sys/firmware/efi/efivars -maxdepth 1 -type f -name 'SecureBoot-*' -print -quit 2>/dev/null || true)
if [ -n "$secure_boot_var" ]; then
	[ "$(od -An -t u1 "$secure_boot_var" | awk '{print $NF}')" != 1 ] ||
		die 'Secure Boot is enabled; this unsigned installer requires it to be disabled'
else
	qemu_secure_boot_file=/sys/firmware/qemu_fw_cfg/by_name/opt/home-secure-boot/raw
		if [ "$qemu_test_mode" = 1 ] && [ -r "$qemu_secure_boot_file" ] &&
		[ "$(cat "$qemu_secure_boot_file")" = disabled ]; then
		echo 'WARNING: OVMF did not publish SecureBoot in efivarfs; accepting the explicit disabled test seed.' >&2
	else
		die 'Secure Boot state is unavailable; refusing to install an unsigned image'
	fi
fi

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

media_disks=
parent_disk() {
	device=$1
	[ -n "$device" ] || return 1
	parent=$(lsblk -dnro PKNAME "$device" 2>/dev/null | awk 'NF {print $1; exit}')
	if [ -n "$parent" ]; then
		printf '/dev/%s\n' "$parent"
	else
		printf '%s\n' "$device"
	fi
}
for media_mount in /media/*; do
	[ -d "$media_mount" ] || continue
	media_source=$(findmnt -no SOURCE "$media_mount" 2>/dev/null || true)
	[ -n "$media_source" ] || continue
	media_disk=$(parent_disk "$media_source" 2>/dev/null || true)
	[ -n "$media_disk" ] || continue
	media_disks="$media_disks $media_disk"
done

is_media_disk() {
	for media_disk in $media_disks; do
		[ "$1" = "$media_disk" ] && return 0
	done
	return 1
}

disk_is_mounted() {
	device=$1
	findmnt -rn -S "$device" >/dev/null 2>&1 && return 0
	while read -r child_device; do
		[ -n "$child_device" ] || continue
		findmnt -rn -S "$child_device" >/dev/null 2>&1 && return 0
	done <<EOF
$(lsblk -nr -o PATH "$device" 2>/dev/null)
EOF
	return 1
}

validate_target_disk() {
	disk=$1
	disk=$(readlink -f "$disk" 2>/dev/null || true)
	case "$disk" in
		/dev/*) ;;
		*) die 'target must resolve to a /dev device' ;;
	esac
	[ -b "$disk" ] || die "not a block device: $disk"
	[ "$(lsblk -dnro TYPE "$disk" 2>/dev/null || true)" = disk ] ||
		die "target must be a whole disk: $disk"
	base=$(basename "$disk")
	[ -d "/sys/block/$base" ] || die "target is not a kernel whole-disk device: $disk"
	[ "$(cat "/sys/block/$base/removable" 2>/dev/null || echo 1)" = 0 ] ||
		die "refusing removable target disk: $disk"
	[ "$(blockdev --getro "$disk")" = 0 ] || die "target disk is read-only: $disk"
	is_media_disk "$disk" && die "the installer media resolves to the target disk: $disk"
	disk_is_mounted "$disk" && die "target disk or one of its partitions is mounted: $disk"
	root_source=$(findmnt -no SOURCE / 2>/dev/null || true)
	root_disk=$(parent_disk "$root_source" 2>/dev/null || true)
	[ "$disk" != "$root_disk" ] || die "refusing the live system's root disk: $disk"
	if command -v swapon >/dev/null 2>&1; then
		while read -r active_swap; do
			[ -n "$active_swap" ] || continue
			active_swap_disk=$(parent_disk "$active_swap" 2>/dev/null || true)
			[ "$active_swap_disk" != "$disk" ] || die "target disk has active swap: $disk"
		done <<EOF
$(swapon --show=NAME --noheadings 2>/dev/null || true)
EOF
	fi
	printf '%s\n' "$disk"
}

echo 'Available whole-disk target candidates:'
candidate_count=0
for sys_disk in /sys/block/*; do
	base=$(basename "$sys_disk")
	disk=/dev/$base
	case "$base" in
		fd*|loop*|ram*|sr*|dm-*) continue ;;
	esac
	[ -b "$disk" ] || continue
	[ "$(lsblk -dnro TYPE "$disk" 2>/dev/null || true)" = disk ] || continue
	is_media_disk "$disk" && continue
	echo "  $disk $(blockdev --getsize64 "$disk") bytes"
	candidate_count=$((candidate_count + 1))
done
[ "$candidate_count" -gt 0 ] || die 'no target disks found'

disk=${INSTALLER_DISK-}
if [ "$qemu_test_mode" = 1 ]; then
	[ -n "$disk" ] || die 'QEMU test mode requires INSTALLER_DISK'
	confirmation=${INSTALLER_CONFIRM-}
	[ "$confirmation" = "$disk" ] || die 'QEMU test target was not explicitly confirmed'
else
	printf 'Target disk (ALL DATA WILL BE ERASED): '
	read -r disk
fi
disk=$(validate_target_disk "$disk")

if [ "$qemu_test_mode" != 1 ]; then
	printf "Type '%s' again to confirm: " "$disk"
	read -r confirmation
fi
[ "$confirmation" = "$disk" ] || die 'disk erase was not confirmed'

sector_size=$(blockdev --getss "$disk")
disk_sectors=$(blockdev --getsz "$disk")
layout=$(partition_layout "$disk_sectors" "$sector_size")
alignment=$(printf '%s\n' "$layout" | awk -F= '$1 == "alignment_sectors" {print $2}')
boot_sectors=$(printf '%s\n' "$layout" | awk -F= '$1 == "boot_sectors" {print $2}')
swap_start=$(printf '%s\n' "$layout" | awk -F= '$1 == "swap_start" {print $2}')
swap_sectors=$(printf '%s\n' "$layout" | awk -F= '$1 == "swap_sectors" {print $2}')
root_start=$(printf '%s\n' "$layout" | awk -F= '$1 == "root_start" {print $2}')
root_sectors=$(printf '%s\n' "$layout" | awk -F= '$1 == "root_sectors" {print $2}')

partition_names=$(partition_device_names "$disk")
boot_partition=$(printf '%s\n' "$partition_names" | sed -n '1p')
swap_partition=$(printf '%s\n' "$partition_names" | sed -n '2p')
root_partition=$(printf '%s\n' "$partition_names" | sed -n '3p')

wipefs -af "$disk"
sfdisk --wipe always "$disk" <<EOF
label: gpt
unit: sectors
start=$alignment, size=$boot_sectors, type=U, name="Alpine boot"
start=$swap_start, size=$swap_sectors, type=S, name="Alpine swap"
start=$root_start, size=$root_sectors, type=L, name="Alpine root"
EOF
blockdev --rereadpt "$disk" 2>/dev/null || true
partx -u "$disk" 2>/dev/null || true
if command -v mdev >/dev/null 2>&1; then
	mdev -s 2>/dev/null || true
fi

partition_table_ready() {
	dump=$(sfdisk --dump "$disk" 2>/dev/null) || return 1
	printf '%s\n' "$dump" | grep -Fq "$boot_partition :" || return 1
	printf '%s\n' "$dump" | grep -Fq "$swap_partition :" || return 1
	printf '%s\n' "$dump" | grep -Fq "$root_partition :" || return 1
}

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

root_partuuid=$(blkid -s PARTUUID -o value "$root_partition")
boot_uuid=$(blkid -s UUID -o value "$boot_partition")
swap_uuid=$(blkid -s UUID -o value "$swap_partition")
[ -n "$root_partuuid" ] || die 'root partition has no GPT PARTUUID'
cat > "$target/etc/fstab" <<EOF
PARTUUID=$root_partuuid / ext4 defaults 0 1
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

mount --rbind /dev "$target/dev"
mount --make-rslave "$target/dev"
dev_mounted=1
mount -t proc proc "$target/proc"
proc_mounted=1
mount --rbind /sys "$target/sys"
mount --make-rslave "$target/sys"
sys_mounted=1
mount --rbind /run "$target/run"
mount --make-rslave "$target/run"
run_mounted=1

chroot "$target" rc-update add networking default
if [ "$qemu_test_mode" != 1 ]; then
	chroot "$target" rc-update add wpa_supplicant default
fi

sed -i "s/INSTALLER_ROOT_PARTUUID/$root_partuuid/g" "$target/etc/kernel-hooks.d/secureboot.conf"
grep -q "root=PARTUUID=$root_partuuid" "$target/etc/kernel-hooks.d/secureboot.conf" ||
	die 'root PARTUUID substitution failed'
chroot "$target" /sbin/apk --no-network fix kernel-hooks

canonical_efi="$target/boot/EFI/alpine/linux-lts.efi"
fallback_efi="$target/boot/EFI/BOOT/BOOTX64.EFI"
kernel_module_dir=
for candidate in "$target"/lib/modules/*-lts; do
	[ -d "$candidate" ] || continue
	kernel_module_dir=$candidate
	break
done
[ -n "$kernel_module_dir" ] || die 'installed linux-lts module directory is missing'
kernel_module_name=$(printf '%s\n' "$kernel_module_dir" | sed 's#.*/##')
[ -n "$kernel_module_name" ] || die 'could not determine the installed kernel module name'
kernel_hook_trigger=/usr/libexec/home-installer/kernel-hooks.trigger
[ -x "$target$kernel_hook_trigger" ] || die 'kernel-hooks trigger is missing from the installed rootfs'
chroot "$target" /bin/sh "$kernel_hook_trigger" "/lib/modules/$kernel_module_name"
[ -f "$canonical_efi" ] || die 'kernel hook did not generate the canonical EFI image'
[ -f "$canonical_efi" ] || die 'kernel hooks did not generate the canonical EFI image'
[ -f "$fallback_efi" ] || die 'kernel hooks did not synchronize the EFI fallback image'
cmp "$canonical_efi" "$fallback_efi" >/dev/null || die 'canonical and fallback EFI images differ'

efibootmgr --disk "$disk" --part 1 --create --label Alpine \
	--loader '\EFI\alpine\linux-lts.efi' ||
	echo 'WARNING: could not create NVRAM entry; the fallback EFI path remains authoritative'

echo 'Installation complete. Remove the installer media and reboot.'
