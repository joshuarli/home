#!/bin/sh
set -eu

# Buildx always invokes this stage as linux/amd64.  Keeping the build and
# target architecture identical means smoke checks execute the actual target
# binaries; there is no copied qemu-x86_64 escape hatch or weaker cross path.
[ "$(uname -m)" = x86_64 ] || {
	echo "rootfs stage must run as x86_64" >&2
	exit 1
}

rootfs=/work/rootfs
mkdir -p "$rootfs/etc/apk/keys" "$rootfs/etc/apk"
cp /etc/apk/repositories "$rootfs/etc/apk/repositories"
cp -a /etc/apk/keys/. "$rootfs/etc/apk/keys/"

packages=$(awk 'NF && $1 !~ /^#/ {print $1}' /work/rootfs-packages.txt | tr '\n' ' ')
apk --root "$rootfs" --initdb --no-scripts \
	--keys-dir "$rootfs/etc/apk/keys" \
	--repositories-file /etc/apk/repositories \
	add --no-cache $packages

# Alpine 3.24.1 has no dwl package.  Install the pinned upstream binary built
# in Docker's separate build-only stage; all of its runtime libraries remain
# ordinary Alpine packages in rootfs-packages.txt.
install -m 0755 /work/dwl "$rootfs/usr/bin/dwl"

/work/configure-rootfs.sh "$rootfs"

# apk --no-scripts is deliberate for the initial alternate-root install: it
# prevents package scripts from being run against a possibly foreign root.
# Recreate every required side effect here.  The font trigger is equivalent
# to the package's normal cache update; kernel hooks are intentionally deferred
# until the installer knows the target disk's PARTUUID and has /boot mounted.
mkdir -p "$rootfs/proc"
proc_mounted=0
if mount -t proc proc "$rootfs/proc" 2>/dev/null; then
	proc_mounted=1
fi
chroot "$rootfs" /usr/bin/fc-cache -f

cat > "$rootfs/tmp/home-installer-smoke.sh" <<'CHROOT'
set -eu

test -L /sbin/init
test "$(readlink /sbin/init)" = /bin/busybox
test -x /bin/fetch.sh
test -x /usr/bin/home-login
test -x /usr/bin/home-session
test -x /etc/init.d/home-runtime
test -x /etc/init.d/udev
test -x /etc/init.d/udev-trigger
test -x /etc/init.d/udev-settle
test -x /etc/init.d/seatd
test -x /usr/bin/dwl
test -x /usr/bin/foot
test -f /usr/share/fonts/dejavu/DejaVuSansMono.ttf
test -f /usr/share/terminfo/f/foot || test -f /usr/share/terminfo/78/foot
test -x /usr/bin/fc-match
test -f /usr/lib/libwayland-server.so.0
test -f /usr/lib/libinput.so.10
test -f /usr/lib/libseat.so.1
test -f /usr/lib/libEGL.so.1
test -f /usr/lib/libgbm.so.1
test -x /sbin/blkid
# mdev is present only as an initramfs helper; eudev owns the installed
# system's device events and no target OpenRC mdev service is enabled.
test -L /sbin/mdev
test "$(readlink /sbin/mdev)" = /bin/busybox
/bin/busybox mdev --help >/dev/null 2>&1
grep -q 'home-installer: resolve PARTUUID' /usr/share/mkinitfs/initramfs-init
test -f /etc/kernel-hooks.d/50-secureboot.hook
test -x /etc/kernel-hooks.d/60-home-fallback
test -x /usr/libexec/home-installer/kernel-hooks.trigger
grep -q 'root=PARTUUID=INSTALLER_ROOT_PARTUUID' /etc/kernel-hooks.d/secureboot.conf
! grep -q 'root=LABEL=' /etc/kernel-hooks.d/secureboot.conf
grep -q '^features="ata base cdrom ext4 home keymap kms mmc nvme raid scsi usb virtio"$' /etc/mkinitfs/mkinitfs.conf
grep -q '^disable_trigger=yes$' /etc/mkinitfs/mkinitfs.conf
kernel_release=$(find /lib/modules -mindepth 1 -maxdepth 1 -type d -name '*-lts' -print -quit | sed 's#.*/##')
[ -n "$kernel_release" ]
mkinitfs -q -o /tmp/home-installer-initramfs "$kernel_release"
gzip -dc /tmp/home-installer-initramfs | cpio -t | grep -qx 'init'
gzip -dc /tmp/home-installer-initramfs | cpio -t | grep -Eq '(^|/)sbin/blkid$'
gzip -dc /tmp/home-installer-initramfs | cpio -t | grep -Eq '(^|/)sbin/mdev$'
gzip -dc /tmp/home-installer-initramfs | cpio -t | grep -Eq '(^|/)lib/mdev/persistent-storage$'
rm -f /tmp/home-installer-initramfs
test -L /etc/runlevels/sysinit/udev
test -L /etc/runlevels/sysinit/udev-trigger
test -L /etc/runlevels/sysinit/udev-settle
! test -L /etc/runlevels/sysinit/mdev
! test -L /etc/runlevels/sysinit/mdevd
test -L /etc/runlevels/default/seatd
test -L /etc/runlevels/default/home-runtime
test -L /etc/runlevels/default/networking

if dwl -v 2>&1 | grep -q '^dwl 0.8'; then :; else
	echo 'dwl version check failed' >&2
	exit 1
fi
foot --version >/dev/null
fc-match 'DejaVu Sans Mono' | grep -q 'DejaVuSansMono'

for forbidden in xorg-server xwayland pulseaudio pipewire dbus polkit elogind \
	mesa-va-gallium intel-media-driver libva-utils nano less; do
	! apk info -e "$forbidden"
done
! test -e /boot/EFI/alpine/linux-lts.efi
! test -e /usr/bin/qemu-x86_64
CHROOT

chroot "$rootfs" /bin/sh -eux /tmp/home-installer-smoke.sh

[ "$proc_mounted" -eq 0 ] || umount "$rootfs/proc"
rm -f "$rootfs/tmp/home-installer-smoke.sh"
rm -f "$rootfs/var/cache/apk"/*

mkdir -p /work/out
installed_db="$rootfs/lib/apk/db/installed"
[ -f "$installed_db" ] || {
	echo 'apk installed database is missing from the rootfs' >&2
	exit 1
}
package_table="$rootfs/tmp/home-installer-packages.txt"
awk -F: '
	function emit() {
		if (name != "")
			print name "\t" version "\t" arch "\t" installed "\t" package "\t" deps
	}
	$0 == "" { emit(); name = version = arch = installed = package = deps = ""; next }
	$1 == "P" { name = $2 }
	$1 == "V" { version = $2 }
	$1 == "A" { arch = $2 }
	$1 == "I" { installed = $2 }
	$1 == "S" { package = $2 }
		$1 == "D" { deps = substr($0, index($0, ":") + 1) }
	END { emit() }
' "$installed_db" | LC_ALL=C sort > "$package_table"
{
	echo 'Home installer rootfs metadata'
	echo 'architecture: x86_64'
	echo 'install mode: apk --root --initdb --no-scripts'
	echo 'deferred package side effects: secureboot kernel hook until installation; fontconfig cache recreated by fc-cache'
	echo "direct package count: $(awk 'NF && $1 !~ /^#/ {count++} END {print count + 0}' /work/rootfs-packages.txt)"
	echo 'dwl source: Codeberg upstream v0.8, stock config.mk/config.def.h, installed outside apk because Alpine 3.24.1 has no package'
	echo "installed package count: $(awk -F: '$1 == "P" {count++} END {print count + 0}' "$installed_db")"
	echo "installed filesystem allocated KiB (du -sk): $(du -sk "$rootfs" | awk '{print $1}')"
	echo 'device-manager boundary: eudev is the installed runtime manager; BusyBox mdev is copied only into the initramfs/live installer'
	echo 'transitive compatibility evidence:'
	awk -F '	' '$1 == "wpa_supplicant" || $1 == "libseat" || $1 == "dbus-libs" || $1 == "libelogind" {print $1 "	" $2 "	depends=" $6}' "$package_table"
	echo 'resolved packages (name	version	arch	installed_bytes	package_bytes	dependencies):'
	cat "$package_table"
	echo 'largest installed package contributors (name	version	arch	installed_bytes	package_bytes	dependencies):'
	sort -t '	' -k4,4nr "$package_table" | head -n 15
} > /work/out/rootfs-metadata.txt

rm -f "$package_table"

tar -czf /work/out/rootfs.tar.gz -C "$rootfs" \
	--numeric-owner --xattrs --acls .
