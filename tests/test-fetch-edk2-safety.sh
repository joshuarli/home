#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
script=$repo/fetch-edk2-ovmf.sh

grep -q 'EDK2_OVMF_DIR must be beneath dist/qemu/firmware' "$script"
grep -q 'EDK2_OVMF_DIR must not contain parent-directory components' "$script"
grep -q 'refusing symlink directory' "$script"
grep -q 'refusing symlink installation directory' "$script"
grep -q 'refusing non-directory installation target' "$script"
grep -q 'rm -rf -- "\$install_dir"' "$script"
! grep -q 'rm -rf -- "\$firmware_dir"' "$script"

echo 'EDK2 OVMF path-safety tests passed'
