#!/bin/sh
set -eu

disk=${QEMU_DISK:-dist/qemu/disk.qcow2}
vars="${disk%/*}/OVMF_VARS.fd"

command -v qemu-system-x86_64 >/dev/null 2>&1 || {
    echo "required host command is missing: qemu-system-x86_64" >&2
    exit 1
}
[ -f "$disk" ] || { echo "QEMU disk not found: $disk; run make test first" >&2; exit 1; }

code=${OVMF_CODE:-}
if [ -z "$code" ]; then
    for candidate in \
        $(find dist/qemu/firmware/edk2-ovmf-nightly -type f -path '*/x64/code.fd' -print -quit 2>/dev/null || true) \
        $(find dist/qemu/firmware -type f -path '*/x64/code.fd' -print -quit 2>/dev/null || true) \
        /opt/homebrew/share/qemu/edk2-x86_64-code.fd \
        /opt/homebrew/share/qemu/OVMF_CODE.fd \
        /usr/local/share/qemu/edk2-x86_64-code.fd \
        /usr/local/share/qemu/OVMF_CODE.fd; do
        [ -f "$candidate" ] && { code=$candidate; break; }
    done
fi
[ -f "$code" ] || { echo "set OVMF_CODE to a UEFI firmware code image" >&2; exit 1; }
[ -f "$vars" ] || { echo "QEMU variable store not found: $vars; run make test first" >&2; exit 1; }

exec qemu-system-x86_64 \
    -machine pc,accel=tcg \
    -cpu max \
    -m 1024 \
    -smp 4 \
    -drive if=pflash,format=raw,readonly=on,file="$code" \
    -drive if=pflash,format=raw,file="$vars" \
    -drive if=none,id=target,format=raw,file="$disk" \
    -device virtio-blk-pci,drive=target \
    -netdev user,id=net0 \
    -device virtio-net-pci,netdev=net0 \
    -display none \
    -serial stdio \
    -monitor none \
    -no-reboot
