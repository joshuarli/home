#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
installer=$repo/installer/install.sh
configure=$repo/rootfs/configure.sh
login=$repo/rootfs/home-login
session=$repo/rootfs/home-session
runtime=$repo/rootfs/home-runtime.initd
dockerfile=$repo/Dockerfile

contains() {
	file=$1
	text=$2
	grep -Fq "$text" "$file" || {
		echo "missing contract text in $file: $text" >&2
		exit 1
	}
}

not_contains() {
	file=$1
	text=$2
	if grep -Fq "$text" "$file"; then
		echo "unexpected contract text in $file: $text" >&2
		exit 1
	fi
}

missing() {
	[ ! -e "$1" ] || {
		echo "obsolete path remains: $1" >&2
		exit 1
	}
}

# Physical invocations reject both unattended environment inputs.  QEMU gets
# them only after the authenticated fw_cfg test seed has enabled test mode.
contains "$installer" '[ -z "${INSTALLER_DISK-}" ]'
contains "$installer" '[ -z "${INSTALLER_CONFIRM-}" ]'
contains "$installer" '[ "${INSTALLER_TEST_MODE-}" = 1 ]'
contains "$installer" '[ -r "$qemu_seed_file" ]'
contains "$installer" 'require_disk_confirmation "$confirmation" "$disk"'

# A mounted swap partition is resolved to its parent before the destructive
# target check; checking only the swap child would permit erasing its disk.
contains "$installer" 'active_swap_disk=$(parent_disk "$active_swap"'
contains "$installer" 'target disk has active swap: $disk'

# Alpine 3.24.1's packaged initramfs resolves a filesystem UUID directly.
# The installer must substitute that one identifier before it runs the
# package-owned kernel hook after mounting the ESP; it must not retain a
# copied trigger dispatcher or an initramfs source patch.
contains "$configure" 'root=UUID=INSTALLER_ROOT_UUID'
contains "$installer" 'root_uuid=$(blkid -s UUID -o value "$root_partition")'
contains "$installer" 'UUID=$root_uuid / ext4 defaults 0 1'
contains "$installer" 'INSTALLER_ROOT_UUID'
not_contains "$configure" 'PARTUUID'
not_contains "$configure" 'kernel-hooks.trigger'
not_contains "$installer" 'kernel-hooks.trigger'
missing "$repo/rootfs/patch-initramfs.sh"

# GUI startup is restricted to tty1 and has an explicit recovery bypass;
# session environment and runtime ownership are established by the guarded
# launcher rather than by an unconditional shell startup file.
contains "$login" '[ "$tty_name" = /dev/tty1 ]'
contains "$login" '[ "${HOME_SESSION_DISABLE:-0}" != 1 ]'
contains "$session" 'export XDG_RUNTIME_DIR=$runtime'
contains "$session" 'export XDG_SESSION_TYPE=wayland'
contains "$runtime" 'modprobe qemu_fw_cfg'
contains "$runtime" 'renderer_flag=/run/home-installer-qemu-renderer'
contains "$session" 'renderer_file=/run/home-installer-qemu-renderer'
contains "$session" 'find_qemu_drm_device()'
contains "$session" '/dev/dri/by-path/*-card'
contains "$session" '[ "${driver##*/}" = bochs-drm ]'
contains "$session" 'export WLR_DRM_DEVICES=$qemu_drm_device'
if grep -R -q 'exec /usr/bin/home-session' "$repo/rootfs" --exclude=home-login --exclude=home-session; then
	echo 'home-session is invoked outside its guarded login path' >&2
	exit 1
fi

# Alpine has no dwl package in this release.  The build consumes a pinned
# upstream tarball with only the Ctrl+Return terminal binding and wmenu-run
# removal; no repository-owned dwl package, config, or runtime daemon exists.
contains "$dockerfile" 'https://codeberg.org/dwl/dwl/archive/v0.8.tar.gz'
contains "$dockerfile" 'install -m 0755 dwl /work/dwl'
contains "$dockerfile" 'WLR_MODIFIER_CTRL,          XKB_KEY_Return,      spawn,            {.v = termcmd}'
contains "$dockerfile" 'wmenu-run'
missing "$repo/dwl"
if grep -R -q 'COPY dwl' "$repo" --exclude-dir=.git --exclude-dir=dist --exclude=test-installer-safety.sh; then
	echo 'repository-owned dwl source is copied into the build' >&2
	exit 1
fi

echo 'installer safety and session contract tests passed'
