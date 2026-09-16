#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

fail() {
	echo "static contract: $*" >&2
	exit 1
}

contains() {
	file=$1
	text=$2
	grep -Fq "$text" "$file" || fail "missing text in $file: $text"
}

not_contains() {
	file=$1
	text=$2
	if grep -Fq "$text" "$file"; then
		fail "unexpected text in $file: $text"
	fi
}

missing() {
	[ ! -e "$1" ] || fail "unexpected path: $1"
}

contains "$repo/rootfs/home-session" 'foot <&-'
contains "$repo/rootfs/configure.sh" 'root=UUID=INSTALLER_ROOT_UUID'
not_contains "$repo/rootfs/configure.sh" 'PARTUUID'
contains "$repo/rootfs/configure.sh" 'BOOTX64.EFI'
contains "$repo/qemu/harness.py" 'QEMU_MACHINE = "pc-q35-9.2"'
contains "$repo/qemu/harness.py" Broadwell
contains "$repo/qemu/harness.py" ich9-ahci
contains "$repo/qemu/harness.py" ide-hd
contains "$repo/qemu/harness.py" qemu-xhci
contains "$repo/qemu/harness.py" 'QEMU_GPU = "std"'
contains "$repo/qemu/harness.py" usb-storage
contains "$repo/qemu/harness.py" qemu_renderer
contains "$repo/qemu/harness.py" QEMU_RENDERER
contains "$repo/qemu/harness.py" 'opt/home-renderer'
contains "$repo/qemu/harness.py" installed-terminal-before-command.ppm
contains "$repo/qemu/harness.py" no_reboot=True
contains "$repo/Dockerfile" 'https://codeberg.org/dwl/dwl/archive/v0.8.tar.gz'
contains "$repo/Dockerfile" '3080087e7f613bf6a350934231fd9ed478d04cd2a2f30da8a96cdf2066f59412'
contains "$repo/Dockerfile" 'WLR_MODIFIER_CTRL,          XKB_KEY_Return,      spawn,            {.v = termcmd}'
contains "$repo/Dockerfile" 'wmenu-run'
contains "$repo/Dockerfile" 'COPY --from=patched /work/out/iso-metadata.txt /iso-metadata.txt'
contains "$repo/README.md" Ctrl+Return
contains "$repo/AGENTS.md" Ctrl+Return
contains "$repo/README.md" 'root=UUID=...'
contains "$repo/AGENTS.md" 'root=UUID=...'
contains "$repo/README.md" disk.fingerprint.json
contains "$repo/AGENTS.md" disk.fingerprint.json
contains "$repo/qemu/harness.py" current_disk_fingerprint
contains "$repo/qemu/harness.py" source_sha256
contains "$repo/installer/install.sh" INSTALLER_TEST_MODE
contains "$repo/installer/install.sh" active_swap_disk
contains "$repo/README.md" 'make test'
contains "$repo/qemu/harness.py" 'doas stat -c %s /boot/EFI/alpine/linux-lts.efi'

if rg -q 'WLR_BACKENDS=headless' "$repo" \
	--glob '!.git/**' --glob '!dist/**' --glob '!plan.md' --glob '!AGENTS.md' \
	--glob '!tests/test-contract.sh'; then
	fail 'headless wlroots backend is configured'
fi
missing "$repo/dwl"
missing "$repo/rootfs/patch-initramfs.sh"
not_contains "$repo/Makefile" fetch.fixture
not_contains "$repo/qemu/harness.py" fetch.fixture
if grep -Eq '^nano$|^less$|^alsa-lib$|^intel-media-driver$|^libva-utils$' "$repo/rootfs-packages.txt"; then
	fail 'forbidden direct target package is listed'
fi
not_contains "$repo/qemu/harness.py" 'for h in /etc/kernel-hooks.d'

echo 'static contract tests passed'
