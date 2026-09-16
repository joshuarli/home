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

# Physical invocations reject both unattended environment inputs.  QEMU gets
# them only after the authenticated fw_cfg test seed has enabled test mode.
contains "$installer" '[ -z "${INSTALLER_DISK-}" ]'
contains "$installer" '[ -z "${INSTALLER_CONFIRM-}" ]'
contains "$installer" '[ "${INSTALLER_TEST_MODE-}" = 1 ]'
contains "$installer" '[ -r "$qemu_seed_file" ]'
contains "$installer" '[ "$confirmation" = "$disk" ] || die'

# A mounted swap partition is resolved to its parent before the destructive
# target check; checking only the swap child would permit erasing its disk.
contains "$installer" 'active_swap_disk=$(parent_disk "$active_swap"'
contains "$installer" '[ "$active_swap_disk" != "$disk" ] || die "target disk has active swap: $disk"'

# The real Alpine trigger is extracted into the prepared rootfs and replayed
# only after the installer has substituted the target PARTUUID and mounted
# the ESP.
contains "$configure" 'kernel_trigger_entry=$(tar -tzf "$kernel_trigger_archive"'
contains "$configure" 'tar -xOzf "$kernel_trigger_archive" "$kernel_trigger_entry"'
contains "$installer" 'chroot "$target" /bin/sh "$kernel_hook_trigger"'

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
contains "$session" 'WLR_DRM_DEVICES=/dev/dri/card0'
! grep -R -q 'home-session' "$repo/rootfs" --exclude=home-login --exclude=home-session

# Alpine has no dwl package in this release.  The build consumes a pinned
# upstream tarball with its stock config, whose XWayland flags are disabled by
# default; no repository-owned dwl package or config may be required here.
contains "$dockerfile" 'https://codeberg.org/dwl/dwl/archive/v0.8.tar.gz'
contains "$dockerfile" 'install -m 0755 dwl /work/dwl'
[ ! -e "$repo/dwl" ]
! grep -R -q 'COPY dwl' "$repo" --exclude-dir=.git --exclude-dir=dist

echo 'installer safety and session contract tests passed'
