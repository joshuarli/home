#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
installer=$repo/installer/install.sh
temporary=$(mktemp -d "/tmp/home-installer-safety.XXXXXX")
trap 'rm -rf "$temporary"' EXIT HUP INT TERM

fake_bin=$temporary/bin
sys_block=$temporary/sys-block
media_root=$temporary/media
mkdir -p "$fake_bin" "$sys_block/target" "$media_root/installer"
printf '%s\n' 0 > "$sys_block/target/removable"

cat > "$fake_bin/lsblk" <<'EOF'
#!/bin/sh
if [ "$1" = -dnro ] && [ "$2" = TYPE ]; then
	case "$3:$TARGET_MODE" in
		/dev/target:unsupported) printf '%s\n' loop ;;
		/dev/target:*) printf '%s\n' disk ;;
		/dev/target1:*|/dev/target2:*) printf '%s\n' part ;;
		*) printf '%s\n' disk ;;
	esac
	exit 0
fi
if [ "$1" = -dnro ] && [ "$2" = PKNAME ]; then
	printf '%s\n' target
	exit 0
fi
if [ "$1" = -nr ] && [ "$2" = -o ] && [ "$3" = PATH ]; then
	printf '%s\n' /dev/target /dev/target1 /dev/target2
	exit 0
fi
exit 1
EOF
cat > "$fake_bin/findmnt" <<'EOF'
#!/bin/sh
if [ "$1" = -rn ] && [ "$2" = -o ] && [ "$3" = SOURCE ]; then
	if [ "$TARGET_MODE" = mounted ]; then
		printf '%s\n' /dev/target2
	else
		printf '%s\n' overlay
	fi
	exit 0
fi
if [ "$1" = -rn ] && [ "$2" = -M ] && [ "$3" = / ] && [ "$4" = -o ] && [ "$5" = SOURCE ]; then
	printf '%s\n' overlay
	exit 0
fi
if [ "$1" = -rn ] && [ "$2" = -M ]; then
	printf '%s\n' /dev/target1
	exit 0
fi
exit 1
EOF
cat > "$fake_bin/swapon" <<'EOF'
#!/bin/sh
[ "${TARGET_MODE-}" = active-swap ] && printf '%s\n' /dev/target2
exit 0
EOF
cat > "$fake_bin/blockdev" <<'EOF'
#!/bin/sh
if [ "$1" = --getro ]; then
	[ "${TARGET_MODE-}" = readonly ] && printf '%s\n' 1 || printf '%s\n' 0
	exit 0
fi
exit 1
EOF
chmod 0755 "$fake_bin/lsblk" "$fake_bin/findmnt" "$fake_bin/swapon" "$fake_bin/blockdev"

cat > "$temporary/validate-target" <<EOF
#!/bin/sh
set -eu
INSTALLER_LIBRARY_ONLY=1 . "$installer"
resolve_device_path() { printf '%s\\n' /dev/target; }
is_block_device() { return 0; }
media_disks=\${MEDIA_DISKS-}
if [ "\${TARGET_MODE-}" = media ]; then
	discover_installer_media_disks
fi
validate_target_disk /dev/target
EOF
chmod 0755 "$temporary/validate-target"

run_target() {
	mode=$1
	set +e
	output=$(PATH="$fake_bin:$PATH" \
		INSTALLER_SYS_BLOCK_ROOT="$sys_block" INSTALLER_MEDIA_ROOT="$media_root" \
		TARGET_MODE="$mode" MEDIA_DISKS= \
		"$temporary/validate-target" 2>&1)
	status=$?
	set -e
	[ "$status" -eq 0 ] || {
		echo "baseline target validation failed for mode $mode: $output" >&2
		exit 1
	}
}

run_rejected_target() {
	mode=$1
	set +e
	output=$(PATH="$fake_bin:$PATH" \
		INSTALLER_SYS_BLOCK_ROOT="$sys_block" INSTALLER_MEDIA_ROOT="$media_root" \
		TARGET_MODE="$mode" MEDIA_DISKS= \
		"$temporary/validate-target" 2>&1)
	status=$?
	set -e
	[ "$status" -ne 0 ] || {
		echo "unsafe target validation unexpectedly passed for mode $mode: $output" >&2
		exit 1
	}
}

run_target normal
run_rejected_target unsupported
run_rejected_target mounted
run_rejected_target active-swap
run_rejected_target readonly
run_rejected_target media

cat > "$temporary/missing-confirmation" <<EOF
#!/bin/sh
set -eu
INSTALLER_LIBRARY_ONLY=1 . "$installer"
require_disk_confirmation /dev/other /dev/target 'confirmation missing'
EOF
chmod 0755 "$temporary/missing-confirmation"
set +e
PATH="$fake_bin:$PATH" "$temporary/missing-confirmation" >/dev/null 2>&1
status=$?
set -e
[ "$status" -ne 0 ] || {
	echo 'missing disk confirmation unexpectedly passed' >&2
	exit 1
}

cat > "$temporary/mount-ownership" <<EOF
#!/bin/sh
set -eu
INSTALLER_LIBRARY_ONLY=1 . "$installer"
target=$temporary/target
mkdir -p "\$target/dev"
mount() {
	if [ "\$1" = --make-rslave ]; then
		return 1
	fi
	return 0
}
dev_mounted=0
set +e
mount_dev_tree
status=\$?
set -e
[ "\$status" -ne 0 ] || exit 1
[ "\$dev_mounted" -eq 1 ] || exit 1
EOF
chmod 0755 "$temporary/mount-ownership"
"$temporary/mount-ownership"

echo 'installer safety behavior tests passed'
