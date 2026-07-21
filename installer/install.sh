#!/bin/sh
set -eu

archive=/root/home-installer/rootfs.tar.gz
target=/mnt/home-installer
is_qemu=${IS_QEMU:-0}
wifi_conf=
wpa_pid=

cleanup() {
    if [ -n "$wpa_pid" ]; then
        kill "$wpa_pid" 2>/dev/null || true
    fi
    if [ -n "$wifi_conf" ]; then
        rm -f "$wifi_conf"
    fi
}
trap cleanup EXIT INT TERM

die() {
    echo "ERROR: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command is missing: $1"
}

for command in awk blkid blockdev chroot efibootmgr findmnt ip lsblk mkfs.ext4 mkfs.vfat mkswap nslookup sfdisk tar wipefs wpa_passphrase; do
    require_command "$command"
done

[ "$(id -u)" -eq 0 ] || die "run this installer as root"
[ "$is_qemu" = 1 ] || [ -d /sys/firmware/efi ] || die "this installer requires UEFI mode"
[ -f "$archive" ] || die "embedded rootfs archive is missing"

secure_boot_var=
if [ "$is_qemu" != 1 ]; then
    for candidate in /sys/firmware/efi/efivars/SecureBoot-*; do
        if [ -f "$candidate" ]; then
            secure_boot_var=$candidate
            break
        fi
    done
    if [ -n "$secure_boot_var" ] && [ "$(od -An -t u1 "$secure_boot_var" | awk '{print $NF}')" = 1 ]; then
        die "Secure Boot is enabled; this unsigned installer requires it to be disabled"
    fi
fi

if [ "$is_qemu" = 1 ]; then
    wifi_iface=${QEMU_NET_IFACE:-}
    if [ -z "$wifi_iface" ]; then
        for sys_iface in /sys/class/net/*; do
            iface=${sys_iface##*/}
            [ "$iface" = lo ] || {
                wifi_iface=$iface
                break
            }
        done
    fi
    [ -n "$wifi_iface" ] || die "no QEMU network interface was found"
    echo "QEMU mode: using DHCP on $wifi_iface; skipping physical Wi-Fi checks."
else
    wifi_interfaces=
    for sys_iface in /sys/class/net/*; do
        iface=${sys_iface##*/}
        [ -d "$sys_iface/wireless" ] || continue
        vendor=
        [ -r "$sys_iface/device/vendor" ] && vendor=$(cat "$sys_iface/device/vendor")
        [ "$vendor" = 0x8086 ] || continue
        wifi_interfaces="$wifi_interfaces $iface"
    done

    set -- $wifi_interfaces
    [ "$#" -gt 0 ] || die "no Intel wireless interface was found"
    if [ "$#" -eq 1 ]; then
        wifi_iface=$1
    else
        echo "Available Intel wireless interfaces:"
        i=1
        for iface do
            echo "  $i) $iface"
            i=$((i + 1))
        done
        printf "Select interface [1]: "
        read -r choice
        choice=${choice:-1}
        eval "wifi_iface=\$$choice"
        [ -n "$wifi_iface" ] || die "invalid wireless interface selection"
    fi

    printf "Wi-Fi SSID: "
    read -r ssid
    [ -n "$ssid" ] || die "SSID cannot be empty"
    printf "Wi-Fi passphrase: "
    stty -echo
    read -r passphrase
    stty echo
    printf "\n"

    wifi_conf=$(mktemp)
    chmod 0600 "$wifi_conf"
    wpa_passphrase "$ssid" "$passphrase" > "$wifi_conf"
    sed -i '/^[[:space:]]*#psk=/d' "$wifi_conf"
    unset passphrase

    echo "Connecting to Wi-Fi on $wifi_iface..."
    ip link set "$wifi_iface" up
    wpa_supplicant -B -i "$wifi_iface" -c "$wifi_conf"
    wpa_pid=$(pidof wpa_supplicant 2>/dev/null | awk '{print $1}' || true)
fi

ip link set "$wifi_iface" up
udhcpc -i "$wifi_iface" -q -n >/dev/null 2>&1 || die "DHCP failed"
nslookup dl-cdn.alpinelinux.org >/dev/null 2>&1 || die "DNS verification failed"
echo "Network preflight passed."

installer_source=$(findmnt -no SOURCE /media/cdrom 2>/dev/null || true)
installer_disk=
if [ -n "$installer_source" ]; then
    installer_parent=$(lsblk -no PKNAME "$installer_source" 2>/dev/null | head -n 1 || true)
    installer_disk=${installer_parent:+/dev/$installer_parent}
fi

echo "Available target disks:"
candidate_count=0
while read -r disk size model type; do
    [ "$type" = disk ] || continue
    if [ "$is_qemu" != 1 ] && [ "$disk" = "$installer_disk" ]; then
        continue
    fi
    echo "  $disk $size $model"
    candidate_count=$((candidate_count + 1))
done <<EOF
$(lsblk -dpno NAME,SIZE,MODEL,TYPE)
EOF
[ "$candidate_count" -gt 0 ] || die "no target disks found"

if [ "$is_qemu" = 1 ] && [ -n "${INSTALLER_DISK:-}" ]; then
    disk=$INSTALLER_DISK
    echo "QEMU mode: selecting $disk."
else
    printf "Target disk (ALL DATA WILL BE ERASED): "
    read -r disk
fi
[ -b "$disk" ] || die "not a block device: $disk"
if [ "$is_qemu" != 1 ] && [ "$disk" = "$installer_disk" ]; then
    die "the installer disk cannot be selected"
fi

disk_type=$(lsblk -dnpo TYPE "$disk")
[ "$disk_type" = disk ] || die "target must be a whole disk: $disk"
if [ "$is_qemu" = 1 ]; then
    confirmation=$disk
else
    printf "Type '%s' again to confirm: " "$disk"
    read -r confirmation
fi
[ "$confirmation" = "$disk" ] || die "disk erase was not confirmed"

sector_size=$(blockdev --getss "$disk")
disk_sectors=$(blockdev --getsz "$disk")
alignment=2048
boot_sectors=$((512 * 1024 * 1024 / sector_size))
ram_kib=$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo)
if [ "$is_qemu" = 1 ]; then
    swap_sectors=$((256 * 1024 * 1024 / sector_size))
else
    swap_sectors=$((ram_kib * 1024 * 2 / sector_size))
fi
swap_sectors=$((swap_sectors + alignment - 1))
swap_sectors=$((swap_sectors / alignment * alignment))
swap_start=$((alignment + boot_sectors))
swap_start=$((swap_start + alignment - 1))
swap_start=$((swap_start / alignment * alignment))
root_start=$((swap_start + swap_sectors))
root_start=$((root_start + alignment - 1))
root_start=$((root_start / alignment * alignment))
root_sectors=$((disk_sectors - root_start))
[ "$root_sectors" -gt $((1024 * 1024 * 1024 / sector_size)) ] || die "disk is too small for the requested layout"

case "$disk" in
    *nvme*|*mmcblk*)
        boot_partition=${disk}p1
        swap_partition=${disk}p2
        root_partition=${disk}p3
        ;;
    *)
        boot_partition=${disk}1
        swap_partition=${disk}2
        root_partition=${disk}3
        ;;
esac

wipefs -af "$disk"
sfdisk --wipe always "$disk" <<EOF
label: gpt
unit: sectors
start=$alignment, size=$boot_sectors, type=U, name="Alpine boot"
start=$swap_start, size=$swap_sectors, type=S, name="Alpine swap"
start=$root_start, size=$root_sectors, type=L, name="Alpine root"
EOF
blockdev --rereadpt "$disk" 2>/dev/null || true
sleep 2

mkfs.vfat -F 32 -n ALPINE_BOOT "$boot_partition"
mkswap -L ALPINE_SWAP "$swap_partition"
mkfs.ext4 -F -L ALPINE_ROOT "$root_partition"

rm -rf "$target"
mkdir -p "$target"
mount "$root_partition" "$target"
mkdir -p "$target/boot"
mount "$boot_partition" "$target/boot"

tar -xzf "$archive" -C "$target"

root_uuid=$(blkid -s UUID -o value "$root_partition")
boot_uuid=$(blkid -s UUID -o value "$boot_partition")
swap_uuid=$(blkid -s UUID -o value "$swap_partition")
cat > "$target/etc/fstab" <<EOF
UUID=$root_uuid / ext4 defaults 0 1
UUID=$boot_uuid /boot vfat umask=0077 0 2
UUID=$swap_uuid none swap sw 0 0
EOF

rm -f "$target/etc/resolv.conf"
cp -L /etc/resolv.conf "$target/etc/resolv.conf"
if [ "$is_qemu" != 1 ]; then
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
mount -t proc proc "$target/proc"
mount --rbind /sys "$target/sys"
mount --make-rslave "$target/sys"
mount --rbind /run "$target/run"
mount --make-rslave "$target/run"

root_partuuid=$(blkid -s PARTUUID -o value "$root_partition")
sed -i "s/INSTALLER_ROOT_PARTUUID/$root_partuuid/" "$target/etc/kernel-hooks.d/secureboot.conf"
chroot "$target" rc-update add networking boot
if [ "$is_qemu" != 1 ]; then
    chroot "$target" rc-update add wpa_supplicant boot
fi
chroot "$target" apk fix kernel-hooks

uki=$(find "$target/boot" -type f -name '*.efi' | head -n 1)
[ -n "$uki" ] || die "kernel hook did not generate an EFI image"
mkdir -p "$target/boot/EFI/alpine" "$target/boot/EFI/BOOT"
cp "$uki" "$target/boot/EFI/alpine/alpine.efi"
cp "$uki" "$target/boot/EFI/BOOT/BOOTX64.EFI"

efibootmgr --disk "$disk" --part 1 --create --label Alpine --loader '\EFI\alpine\alpine.efi' || echo "WARNING: could not create NVRAM entry; fallback EFI path was installed"

umount -R "$target/run"
umount -R "$target/sys"
umount "$target/proc"
umount -R "$target/dev"
umount "$target/boot"
umount "$target"
swapoff "$swap_partition" 2>/dev/null || true

echo "Installation complete. Remove the installer media and reboot."
