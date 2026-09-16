#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

grep -q "foot <&-" "$repo/rootfs/home-session"
grep -q 'root=PARTUUID=INSTALLER_ROOT_PARTUUID' "$repo/rootfs/configure.sh"
grep -q 'BOOTX64.EFI' "$repo/rootfs/configure.sh"
grep -q 'QEMU_MACHINE = "pc-q35-9.2"' "$repo/qemu/harness.py"
grep -q 'Broadwell' "$repo/qemu/harness.py"
grep -q 'ich9-ahci' "$repo/qemu/harness.py"
grep -q 'ide-hd' "$repo/qemu/harness.py"
grep -q 'virtio-gpu-pci' "$repo/qemu/harness.py"
grep -q 'qemu_renderer' "$repo/qemu/harness.py"
grep -q 'name=opt/home-renderer,string=pixman' "$repo/qemu/harness.py"
grep -q 'kernel-hooks.trigger' "$repo/qemu/harness.py"
grep -q 'installed-terminal-before-command.ppm' "$repo/qemu/harness.py"
grep -q 'no_reboot=True' "$repo/qemu/harness.py"
grep -q 'https://codeberg.org/dwl/dwl/archive/v0.8.tar.gz' "$repo/Dockerfile"
grep -q '3080087e7f613bf6a350934231fd9ed478d04cd2a2f30da8a96cdf2066f59412' "$repo/Dockerfile"
grep -q 'COPY --from=patched /work/out/iso-metadata.txt /iso-metadata.txt' "$repo/Dockerfile"
grep -q 'Alt+Shift+Return' "$repo/README.md"
grep -q 'disk.fingerprint.json' "$repo/README.md" "$repo/AGENTS.md"
grep -q 'current_disk_fingerprint' "$repo/qemu/harness.py"
grep -q 'source_sha256' "$repo/qemu/harness.py"
grep -q 'INSTALLER_TEST_MODE' "$repo/installer/install.sh"
grep -q 'active_swap_disk' "$repo/installer/install.sh"
grep -q 'make test' "$repo/README.md"
grep -q 'doas stat -c %s /boot/EFI/alpine/linux-lts.efi' "$repo/qemu/harness.py"

! grep -R -q 'WLR_BACKENDS=headless' "$repo" \
	--exclude-dir=.git --exclude-dir=dist --exclude=plan.md --exclude=AGENTS.md
! test -e "$repo/dwl"
! grep -q 'fetch.fixture' "$repo/Makefile" "$repo/qemu/harness.py"
! grep -q '^nano$\|^less$\|^alsa-lib$\|^intel-media-driver$\|^libva-utils$' "$repo/rootfs-packages.txt"
! grep -q 'for h in /etc/kernel-hooks.d' "$repo/qemu/harness.py"

echo 'static contract tests passed'
