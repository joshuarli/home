#!/bin/sh -e

cleanup() {
    rm -rf "$tmp"
}

makefile() {
    owner=$1
    perms=$2
    filename=$3
    cat > "$filename"
    chown "$owner" "$filename"
    chmod "$perms" "$filename"
}

rc_add() {
    mkdir -p "$tmp/etc/runlevels/$2"
    ln -sf "/etc/init.d/$1" "$tmp/etc/runlevels/$2/$1"
}

tmp=$(mktemp -d)
trap cleanup EXIT

mkdir -p "$tmp/etc/apk/keys" "$tmp/etc" "$tmp/root/home-installer"

assets=${HOME_INSTALLER_ASSETS:?HOME_INSTALLER_ASSETS is required}
for asset in configure.sh fetch.sh foot.ini home-login home-runtime.initd \
	home-session repositories rootfs-packages.txt dwl; do
	[ -f "$assets/$asset" ] || {
		echo "missing installer asset: $assets/$asset" >&2
		exit 1
	}
done

makefile root:root 0644 "$tmp/etc/apk/keys/$(basename "$HOME_INSTALLER_APK_KEY")" < "$HOME_INSTALLER_APK_KEY"
touch "$tmp/etc/.default_boot_services"

makefile root:root 0644 "$tmp/etc/hostname" <<EOF
home-installer
EOF

makefile root:root 0644 "$tmp/etc/apk/world" <<'EOF'
alpine-base
bind-tools
blkid
dosfstools
e2fsprogs
efibootmgr
findmnt
ifupdown-ng
iproute2
kmod
lsblk
partx
sfdisk
util-linux
wipefs
wpa_supplicant
EOF

makefile root:root 0755 "$tmp/root/home-installer/configure.sh" < "$assets/configure.sh"
makefile root:root 0755 "$tmp/root/home-installer/fetch.sh" < "$assets/fetch.sh"
makefile root:root 0644 "$tmp/root/home-installer/foot.ini" < "$assets/foot.ini"
makefile root:root 0755 "$tmp/root/home-installer/home-login" < "$assets/home-login"
makefile root:root 0755 "$tmp/root/home-installer/home-runtime.initd" < "$assets/home-runtime.initd"
makefile root:root 0755 "$tmp/root/home-installer/home-session" < "$assets/home-session"
makefile root:root 0644 "$tmp/root/home-installer/repositories" < "$assets/repositories"
makefile root:root 0644 "$tmp/root/home-installer/rootfs-packages.txt" < "$assets/rootfs-packages.txt"
makefile root:root 0755 "$tmp/root/home-installer/dwl" < "$assets/dwl"

makefile root:root 0755 "$tmp/root/home-installer/install.sh" <<'EOF'
#!/bin/sh
set -eu

attempt=0
while [ "$attempt" -lt 60 ]; do
    for media in /media/cdrom /media/*; do
        if [ -x "$media/home-installer/install.sh" ]; then
            exec "$media/home-installer/install.sh" "$@"
        fi
    done
    attempt=$((attempt + 1))
    sleep 1
done

echo "home-installer install script is not available on the installer media" >&2
exit 1
EOF

rc_add devfs sysinit
rc_add dmesg sysinit
# The live installer is intentionally smaller than the installed rootfs and
# uses BusyBox mdev for early media discovery.  This is a live-media boundary;
# the installed target uses eudev and never enables an mdev OpenRC service.
rc_add mdev sysinit
rc_add hwdrivers sysinit
rc_add modloop sysinit
rc_add hwclock boot
rc_add modules boot
rc_add sysctl boot
rc_add hostname boot
rc_add bootmisc boot
rc_add networking boot
rc_add mount-ro shutdown
rc_add killprocs shutdown
rc_add savecache shutdown

mkdir -p "$tmp/etc/init.d" "$tmp/etc/runlevels/default"
makefile root:root 0755 "$tmp/etc/init.d/home-installer-qemu" <<'EOF'
#!/sbin/openrc-run

description="Run the installer automatically for an explicit QEMU test seed"

depend() {
    after modloop modules bootmisc networking
}

start() {
    seed=/sys/firmware/qemu_fw_cfg/by_name/opt/home-installer-test/raw
    [ -r "$seed" ] || return 0
    seed_value=$(cat "$seed")
    expected_network_failure=0
    case "$seed_value" in
        home-installer-qemu-v1) ;;
        home-installer-qemu-no-network-v1) expected_network_failure=1 ;;
        *) return 1 ;;
    esac
    attempt=0
    while [ "$attempt" -lt 60 ] && [ ! -x /root/home-installer/install.sh ]; do
        attempt=$((attempt + 1))
        sleep 1
    done
    if [ ! -x /root/home-installer/install.sh ]; then
        echo 'home-installer: install script is not available after 60 seconds' >&2
        return 1
    fi
    # This is the same installer interface used by a physical install.  The
    # seed supplies explicit test input; it does not disable UEFI, Secure Boot,
    # target validation, confirmation, or cleanup checks.
    if [ "$expected_network_failure" -eq 1 ]; then
        if IS_QEMU=1 INSTALLER_TEST_MODE=1 INSTALLER_DISK=/dev/sda \
            INSTALLER_CONFIRM=/dev/sda QEMU_NET_IFACE=eth0 \
            /root/home-installer/install.sh </dev/ttyS0 >/dev/ttyS0 2>&1; then
            echo 'home-installer: expected network preflight failure did not occur' >&2
            return 1
        fi
        echo 'home-installer: expected network preflight failure observed'
        poweroff
        return 0
    fi
    IS_QEMU=1 INSTALLER_TEST_MODE=1 INSTALLER_DISK=/dev/sda \
        INSTALLER_CONFIRM=/dev/sda QEMU_NET_IFACE=eth0 \
        /root/home-installer/install.sh </dev/ttyS0 >/dev/ttyS0 2>&1 || return 1
    poweroff
}
EOF
rc_add home-installer-qemu default

tar -czf home-installer.apkovl.tar.gz -C "$tmp" etc root
