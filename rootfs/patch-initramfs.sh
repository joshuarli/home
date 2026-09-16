#!/bin/sh
set -eu

initramfs_init=${1:?initramfs init path is required}
[ -f "$initramfs_init" ] || {
	echo "initramfs init is missing: $initramfs_init" >&2
	exit 1
}

# Alpine's BusyBox mount resolves LABEL= and UUID= but not PARTUUID=.  Keep
# PARTUUID= in the EFI command line so the kernel hook's contract remains
# stable, then make the stock initramfs mount the symlink created by mdev after
# nlplug-findfs has discovered the block device.
if grep -q 'home-installer: resolve PARTUUID' "$initramfs_init"; then
	exit 0
fi

temporary="$initramfs_init.home-installer.$$"
trap 'rm -f "$temporary"' EXIT HUP INT TERM

awk '
{
	print
	line = $0
	gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
	if (line == "\"$KOPT_root\"") {
		print "\t# home-installer: resolve PARTUUID after nlplug-findfs has populated /dev links."
		print "\tcase \"$KOPT_root\" in"
		print "\tPARTUUID=*) KOPT_root=\"/dev/disk/by-partuuid/${KOPT_root#PARTUUID=}\" ;;"
		print "\tesac"
		inserted = 1
	}
}
END {
	if (!inserted)
		exit 1
}
' "$initramfs_init" > "$temporary"

chmod 0755 "$temporary"
mv "$temporary" "$initramfs_init"
trap - EXIT HUP INT TERM
