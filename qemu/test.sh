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
        $(find dist/qemu/firmware/edk2-ovmf-nightly -type f -path '*/x64/code.fd' -print -quit 2>/dev/null || true) \
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
        $(find dist/qemu/firmware/edk2-ovmf-nightly -type f -path '*/x64/vars.fd' -print -quit 2>/dev/null || true) \
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
qemu-img create -f raw "$disk" 8G >/dev/null

echo "Booting the installer in QEMU..."
qemu-system-x86_64 \
    -machine pc \
    -accel tcg,thread=multi \
    -cpu max \
    -m 1024 \
    -smp 4 \
    -drive if=pflash,format=raw,readonly=on,file="$code" \
    -drive if=pflash,format=raw,file="$vars" \
    -drive if=none,id=installer,format=raw,readonly=on,file="$iso" \
    -device virtio-blk-pci,drive=installer \
    -drive if=none,id=target,format=raw,file="$disk" \
    -device virtio-blk-pci,drive=target \
    -netdev user,id=net0 \
    -device virtio-net-pci,netdev=net0 \
    -display none \
    -serial "file:$log" \
    -monitor none \
    -no-reboot >/dev/null 2>&1 &
qemu_pid=$!
trap 'kill "$qemu_pid" 2>/dev/null || true' EXIT INT TERM

attempt=0
while [ "$(ps -p "$qemu_pid" -o stat= 2>/dev/null | tr -d ' ')" != "" ] &&
    ! ps -p "$qemu_pid" -o stat= 2>/dev/null | tr -d ' ' | grep -q '^Z'; do
    if grep -q 'Installation complete\.' "$log" 2>/dev/null; then
        echo "QEMU installer test passed. Disk left at $disk"
        kill "$qemu_pid" 2>/dev/null || true
        wait "$qemu_pid" 2>/dev/null || true
        trap - EXIT INT TERM
        exit 0
    fi
    attempt=$((attempt + 1))
    [ "$attempt" -lt 300 ] || {
        echo "QEMU installer test timed out; serial log: $log" >&2
        tail -80 "$log" >&2 2>/dev/null || true
        exit 1
    }
    sleep 1
done

if grep -q 'Installation complete\.' "$log" 2>/dev/null; then
    echo "QEMU installer test passed. Disk left at $disk"
    exit 0
fi

echo "QEMU exited before installation completed; serial log: $log" >&2
tail -80 "$log" >&2 2>/dev/null || true
exit 1
