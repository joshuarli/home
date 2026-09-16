#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
installer=$repo/installer/install.sh
temporary=$(mktemp -d "/tmp/home-installer-efi.XXXXXX")
trap 'rm -rf "$temporary"' EXIT HUP INT TERM

bin=$temporary/bin
mkdir "$bin"
cat > "$bin/findmnt" <<'EOF'
#!/bin/sh
case "${FINDMNT_OUTPUT-}" in
	empty) exit 0 ;;
	extra) printf '%s efivarfs unexpected-extra\n' "$FINDMNT_PATH"; exit 0 ;;
esac
if [ -e "$FINDMNT_STATE_FILE" ]; then
	printf '%s efivarfs\n' "$FINDMNT_PATH"
else
	printf '%s sysfs\n' "$FINDMNT_PARENT"
fi
EOF
cat > "$bin/mount" <<'EOF'
#!/bin/sh
if [ "$MOUNT_RESULT" != success ]; then
	exit 1
fi
touch "$FINDMNT_STATE_FILE"
EOF
cat > "$bin/modprobe" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod 0755 "$bin/findmnt" "$bin/mount" "$bin/modprobe"

new_fixture() {
	name=$1
	root=$temporary/$name
	mkdir -p "$root/efi/efivars"
	printf '%s\n' "$root"
}

write_secure_boot() {
	root=$1
	state=$2
	case "$state" in
		disabled) printf '\001\000\000\000\000' > "$root/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c"; return ;;
		enabled) printf '\001\000\000\000\001' > "$root/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c"; return ;;
		malformed) printf '\001\000\000\000' > "$root/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c"; return ;;
		*) echo "unknown fixture state: $state" >&2; exit 1 ;;
	esac
}

run_preflight() {
	root=$1
	mode=$2
	seed=$3
	expected=$4
	log=$root/result.log
	state_file=$root/mounted
	path=$root/efi/efivars
	set +e
	PATH="$bin:$PATH" \
	FINDMNT_PATH="$path" FINDMNT_PARENT="$root/efi" \
	FINDMNT_STATE_FILE="$state_file" MOUNT_RESULT="$MOUNT_RESULT" \
	FINDMNT_OUTPUT="${FINDMNT_OUTPUT-}" \
	sh -c 'INSTALLER_LIBRARY_ONLY=1 . "$1"; secure_boot_preflight "$2" "$3" "$4"' \
		sh "$installer" "$root/efi" "$mode" "$seed" >"$log" 2>&1
	status=$?
	set -e
	if [ "$status" -ne "$expected" ]; then
		echo "unexpected Secure Boot preflight status $status, expected $expected" >&2
		sed -n '1,120p' "$log" >&2
		exit 1
	fi
}

already_mounted=$(new_fixture already-mounted)
write_secure_boot "$already_mounted" disabled
touch "$already_mounted/mounted"
MOUNT_RESULT=fail run_preflight "$already_mounted" 0 "$temporary/no-seed" 0

enabled=$(new_fixture enabled)
write_secure_boot "$enabled" enabled
touch "$enabled/mounted"
MOUNT_RESULT=fail run_preflight "$enabled" 0 "$temporary/no-seed" 1

malformed=$(new_fixture malformed)
write_secure_boot "$malformed" malformed
touch "$malformed/mounted"
MOUNT_RESULT=fail run_preflight "$malformed" 0 "$temporary/no-seed" 1

parent_only=$(new_fixture parent-only)
write_secure_boot "$parent_only" disabled
MOUNT_RESULT=success run_preflight "$parent_only" 0 "$temporary/no-seed" 0
[ -e "$parent_only/mounted" ] || {
	echo 'efivarfs was not mounted when only the parent sysfs was present' >&2
	exit 1
}

mount_failure=$(new_fixture mount-failure)
write_secure_boot "$mount_failure" disabled
MOUNT_RESULT=fail run_preflight "$mount_failure" 0 "$temporary/no-seed" 1
[ ! -e "$mount_failure/mounted" ] || {
	echo 'mount-failure fixture unexpectedly reported a successful mount' >&2
	exit 1
}

unavailable=$(new_fixture unavailable)
touch "$unavailable/mounted"
MOUNT_RESULT=fail run_preflight "$unavailable" 0 "$temporary/no-seed" 1

malformed_empty=$(new_fixture malformed-empty)
write_secure_boot "$malformed_empty" disabled
MOUNT_RESULT=success FINDMNT_OUTPUT=empty run_preflight "$malformed_empty" 0 "$temporary/no-seed" 1

malformed_extra=$(new_fixture malformed-extra)
write_secure_boot "$malformed_extra" disabled
MOUNT_RESULT=success FINDMNT_OUTPUT=extra run_preflight "$malformed_extra" 0 "$temporary/no-seed" 1

qemu_missing_variable=$(new_fixture qemu-missing-variable)
printf '%s\n' disabled > "$qemu_missing_variable/seed"
MOUNT_RESULT=success FINDMNT_OUTPUT= run_preflight "$qemu_missing_variable" 1 "$qemu_missing_variable/seed" 0
[ -e "$qemu_missing_variable/mounted" ] || {
	echo 'QEMU fixture did not verify its efivarfs mount before using the seed' >&2
	exit 1
}

echo 'installer efivarfs and Secure Boot tests passed'
