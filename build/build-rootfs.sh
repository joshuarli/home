#!/bin/sh
set -eu

rootfs=/work/rootfs
mkdir -p "$rootfs"

packages=$(awk 'NF && $1 !~ /^#/' /work/rootfs-packages.txt | tr '\n' ' ')
apk --root "$rootfs" --initdb --no-scripts --keys-dir /etc/apk/keys --repositories-file /etc/apk/repositories add --no-cache $packages
mkdir -p "$rootfs/proc"
mount -t proc proc "$rootfs/proc" 2>/dev/null || true

/work/configure-rootfs.sh "$rootfs"
cp /usr/bin/qemu-x86_64 "$rootfs/usr/bin/qemu-x86_64"

kernel_release=
for module_dir in "$rootfs"/lib/modules/*; do
    [ -d "$module_dir" ] || continue
    kernel_release=${module_dir##*/}
    break
done
[ -n "$kernel_release" ] || { echo "rootfs kernel module directory is missing" >&2; exit 1; }
mkdir -p "$rootfs/boot/EFI/alpine"
SYSCONFDIR="$rootfs/etc/mkinitfs" DATADIR="$rootfs/usr/share/mkinitfs" \
"$rootfs/sbin/mkinitfs" \
    -b "$rootfs" \
    -o "$rootfs/tmp/home-installer-initramfs" \
    "$kernel_release"
"$rootfs/usr/bin/efi-mkuki" \
    -c "console=ttyS0,115200 console=tty0 root=LABEL=ALPINE_ROOT rootfstype=ext4 rw" \
    -k "$kernel_release" \
    -s /dev/null \
    -S "$rootfs/usr/lib/systemd/boot/efi/linuxx64.efi.stub" \
    -o "$rootfs/boot/EFI/alpine/linux-lts.efi" \
    "$rootfs/boot/vmlinuz-lts" \
    "$rootfs/tmp/home-installer-initramfs"
rm -f "$rootfs/tmp/home-installer-initramfs"

cat > "$rootfs/tmp/home-installer-smoke.sh" <<'CHROOT'
test -x /sbin/init
apk --version
id josh
test "$(getent passwd josh | cut -d: -f7)" = /bin/ash
test -d /home/josh
test -x /sbin/agetty
test -f /usr/lib/libwayland-client.so.0
test -f /usr/lib/libasound.so.2
test -x /usr/bin/vainfo
test -f /boot/EFI/alpine/linux-lts.efi
doas -C /etc/doas.d/josh.conf
! apk info -e xorg-server
! apk info -e xwayland
! apk info -e pulseaudio
! apk info -e pipewire
CHROOT

if [ "$BUILDARCH" = "$TARGETARCH" ]; then
    chroot "$rootfs" /bin/sh -eux /tmp/home-installer-smoke.sh
else
    test -x "$rootfs/sbin/init"
    "$rootfs/sbin/apk" --root "$rootfs" --print-arch
    grep -q '^josh:' "$rootfs/etc/passwd"
    grep -q '^josh:x:1000:1000:.*:/bin/ash$' "$rootfs/etc/passwd"
    test -d "$rootfs/home/josh"
    test -x "$rootfs/sbin/agetty"
    test -f "$rootfs/usr/lib/libwayland-client.so.0"
    test -f "$rootfs/usr/lib/libasound.so.2"
    test -x "$rootfs/usr/bin/vainfo"
    test -f "$rootfs/boot/EFI/alpine/linux-lts.efi"
    "$rootfs/sbin/apk" --root "$rootfs" info -e xorg-server && exit 1 || true
    "$rootfs/sbin/apk" --root "$rootfs" info -e xwayland && exit 1 || true
    "$rootfs/sbin/apk" --root "$rootfs" info -e pulseaudio && exit 1 || true
    "$rootfs/sbin/apk" --root "$rootfs" info -e pipewire && exit 1 || true
fi

umount "$rootfs/proc" 2>/dev/null || true
rm -f "$rootfs/usr/bin/qemu-x86_64"
rm -f "$rootfs/tmp/home-installer-smoke.sh"

mkdir -p /work/out
tar -czf /work/out/rootfs.tar.gz -C "$rootfs" --numeric-owner --xattrs --acls .
