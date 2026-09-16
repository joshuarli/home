#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
temporary=$(mktemp -d "${TMPDIR:-/tmp}/home-initramfs-test.XXXXXX")
trap 'rm -rf "$temporary"' EXIT HUP INT TERM

cat > "$temporary/init" <<'EOF'
#!/bin/sh
nlplug-findfs -p /sbin/mdev \
	"$KOPT_root"

if [ "$SINGLEMODE" = "yes" ]; then
	sh
fi

mount -t ext4 "$KOPT_root" /sysroot
EOF
chmod 0755 "$temporary/init"

sh "$repo/rootfs/patch-initramfs.sh" "$temporary/init"
grep -q 'home-installer: resolve PARTUUID' "$temporary/init"
grep -q 'PARTUUID=.*disk/by-partuuid' "$temporary/init"
grep -q 'mount -t ext4 "\$KOPT_root" /sysroot' "$temporary/init"

cp "$temporary/init" "$temporary/init.before-second-patch"
sh "$repo/rootfs/patch-initramfs.sh" "$temporary/init"
cmp "$temporary/init.before-second-patch" "$temporary/init"

echo 'initramfs PARTUUID patch test passed'
