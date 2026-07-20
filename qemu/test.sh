#!/bin/sh
set -eu

iso=${1:?ISO path is required}
disk=${QEMU_DISK:-dist/qemu/disk.qcow2}
vm_dir=${disk%/*}
log="$vm_dir/test.log"
vars="$vm_dir/OVMF_VARS.fd"

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "required host command is missing: $1" >&2
        exit 1
    }
}

find_file() {
    for candidate do
        [ -f "$candidate" ] && {
            printf '%s\n' "$candidate"
            return 0
        }
    done
    return 1
}

require_command qemu-system-x86_64
require_command qemu-img
[ -f "$iso" ] || { echo "ISO not found: $iso" >&2; exit 1; }

code=${OVMF_CODE:-}
if [ -z "$code" ]; then
    code=$(find_file \
        $(find dist/qemu/firmware -type f -path '*/x64/code.fd' -print -quit 2>/dev/null || true) \
        /opt/homebrew/share/qemu/edk2-x86_64-code.fd \
        /opt/homebrew/share/qemu/OVMF_CODE.fd \
        /usr/local/share/qemu/edk2-x86_64-code.fd \
        /usr/local/share/qemu/OVMF_CODE.fd) || {
        echo "OVMF_CODE is not set and no common UEFI firmware path was found" >&2
        echo "Install UEFI firmware and run: make test OVMF_CODE=/path/to/code.fd OVMF_VARS=/path/to/vars.fd" >&2
        exit 1
    }
fi
[ -f "$code" ] || { echo "OVMF_CODE not found: $code" >&2; exit 1; }

template=${OVMF_VARS:-}
if [ -z "$template" ]; then
    template=$(find_file \
        $(find dist/qemu/firmware -type f -path '*/x64/vars.fd' -print -quit 2>/dev/null || true) \
        /opt/homebrew/share/qemu/edk2-i386-vars.fd \
        /opt/homebrew/share/qemu/edk2-x86_64-vars.fd \
        /opt/homebrew/share/qemu/OVMF_VARS.fd \
        /usr/local/share/qemu/edk2-i386-vars.fd \
        /usr/local/share/qemu/edk2-x86_64-vars.fd \
        /usr/local/share/qemu/OVMF_VARS.fd) || {
        echo "OVMF_VARS is not set and no common UEFI variable template was found" >&2
        exit 1
    }
fi
[ -f "$template" ] || { echo "OVMF_VARS not found: $template" >&2; exit 1; }

mkdir -p "$vm_dir"
rm -f "$disk" "$vars" "$log"
cp "$template" "$vars"
qemu-img create -f qcow2 "$disk" 8G >/dev/null

echo "Booting the installer in QEMU..."
qemu-system-x86_64 \
    -machine q35,accel=tcg \
    -cpu max \
    -m 2048 \
    -smp 2 \
    -drive if=pflash,format=raw,readonly=on,file="$code" \
    -drive if=pflash,format=raw,file="$vars" \
    -cdrom "$iso" \
    -drive if=virtio,format=qcow2,file="$disk" \
    -netdev user,id=net0 \
    -device virtio-net-pci,netdev=net0 \
    -display none \
    -serial "file:$log" \
    -monitor none \
    -no-reboot >/dev/null 2>&1 &
qemu_pid=$!
trap 'kill "$qemu_pid" 2>/dev/null || true' EXIT INT TERM

attempt=0
while kill -0 "$qemu_pid" 2>/dev/null; do
    if grep -q 'Installation complete\.' "$log" 2>/dev/null; then
        echo "QEMU installer test passed. Disk left at $disk"
        kill "$qemu_pid" 2>/dev/null || true
        wait "$qemu_pid" 2>/dev/null || true
        trap - EXIT INT TERM
        exit 0
    fi
    attempt=$((attempt + 1))
    [ "$attempt" -lt 180 ] || {
        echo "QEMU installer test timed out; serial log: $log" >&2
        tail -80 "$log" >&2 2>/dev/null || true
        exit 1
    }
    sleep 1
done

echo "QEMU exited before installation completed; serial log: $log" >&2
tail -80 "$log" >&2 2>/dev/null || true
exit 1
