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

makefile root:root 0644 "$tmp/etc/apk/keys/$(basename "$HOME_INSTALLER_APK_KEY")" < "$HOME_INSTALLER_APK_KEY"
touch "$tmp/etc/.default_boot_services"

makefile root:root 0644 "$tmp/etc/hostname" <<EOF
home-installer
EOF

makefile root:root 0644 "$tmp/etc/apk/world" <<EOF
alpine-base
linux-lts
linux-firmware-intel
linux-firmware-i915
wpa_supplicant
wpa_supplicant-openrc
ifupdown-ng
ifupdown-ng-wifi
iproute2
util-linux
dosfstools
e2fsprogs
efibootmgr
tar
gzip
EOF

makefile root:root 0755 "$tmp/root/home-installer/install.sh" < "$HOME_INSTALLER_INSTALL_SCRIPT"
makefile root:root 0644 "$tmp/root/home-installer/rootfs.tar.gz" < "$HOME_INSTALLER_ROOTFS_ARCHIVE"

rc_add devfs sysinit
rc_add dmesg sysinit
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

description="Run the installer automatically in QEMU smoke tests"

depend() {
    after modules bootmisc
}

start() {
    grep -qw home_installer_qemu=1 /proc/cmdline || return 0
    while [ ! -f /root/home-installer/install.sh ]; do
        sleep 1
    done
    IS_QEMU=1 INSTALLER_DISK=/dev/vda QEMU_NET_IFACE= \
        /root/home-installer/install.sh </dev/ttyS0 >/dev/ttyS0 2>&1 || return 1
    poweroff -f
}
EOF
rc_add home-installer-qemu boot

tar -czf home-installer.apkovl.tar.gz -C "$tmp" etc root
