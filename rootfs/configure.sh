#!/bin/sh
set -eu

rootfs=$1
[ -n "$rootfs" ] || { echo "rootfs path is required" >&2; exit 1; }

cp /etc/apk/repositories "$rootfs/etc/apk/repositories"
busybox --install -s "$rootfs/bin"
ln -sf /bin/busybox "$rootfs/sbin/init"

home="$rootfs/home/josh"
mkdir -p "$home"
chown 1000:1000 "$home"

if ! grep -q '^josh:' "$rootfs/etc/passwd"; then
    echo 'josh:x:1000:1000:josh:/home/josh:/bin/ash' >> "$rootfs/etc/passwd"
fi
if ! grep -q '^josh:' "$rootfs/etc/group"; then
    echo 'josh:x:1000:' >> "$rootfs/etc/group"
fi
if ! grep -q '^seat:' "$rootfs/etc/group"; then
    echo 'seat:x:1001:josh' >> "$rootfs/etc/group"
fi
for group in wheel seat; do
    if grep -q "^$group:" "$rootfs/etc/group" && ! grep "^$group:" "$rootfs/etc/group" | grep -q ',josh$'; then
        sed -i "/^$group:/ s/$/,josh/" "$rootfs/etc/group"
    fi
done
if ! grep -q '^josh:' "$rootfs/etc/shadow"; then
    echo 'josh::19000:0:99999:7:::' >> "$rootfs/etc/shadow"
fi
sed -i 's/^root:[^:]*/root:!/' "$rootfs/etc/shadow"

mkdir -p "$rootfs/etc/doas.d"
cat > "$rootfs/etc/doas.d/josh.conf" <<'EOF'
permit nopass josh as root
EOF
chmod 0400 "$rootfs/etc/doas.d/josh.conf"

echo alpine > "$rootfs/etc/hostname"
ln -sf /usr/share/zoneinfo/America/Los_Angeles "$rootfs/etc/localtime"
cat > "$rootfs/etc/profile.d/home-installer.sh" <<'EOF'
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
EOF
chmod 0644 "$rootfs/etc/profile.d/home-installer.sh"

cat > "$rootfs/etc/adjtime" <<'EOF'
0.0 0 0.0
0
UTC
EOF

cat > "$rootfs/etc/hosts" <<'EOF'
127.0.0.1 localhost alpine
::1 localhost alpine
EOF

cat > "$rootfs/etc/network/interfaces" <<'EOF'
auto lo
iface lo inet loopback
EOF

mkdir -p "$rootfs/etc/kernel-hooks.d"
cat > "$rootfs/etc/kernel-hooks.d/secureboot.conf" <<'EOF'
cmdline="console=ttyS0,115200 console=tty0 root=PARTUUID=INSTALLER_ROOT_PARTUUID rootfstype=ext4 rw"
EOF

sed -i '/^tty1::/d; /^tty[2-6]::/d' "$rootfs/etc/inittab"
cat >> "$rootfs/etc/inittab" <<'EOF'
tty1::respawn:/sbin/agetty --autologin josh --noclear 38400 tty1 linux
ttyS0::respawn:/sbin/agetty --autologin josh --noclear 115200 ttyS0 vt100
EOF

mkdir -p "$rootfs/etc/runlevels/boot"
ln -sf /etc/init.d/hwclock "$rootfs/etc/runlevels/boot/hwclock"

rm -rf "$rootfs/var/cache/apk"/*
