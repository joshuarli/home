#!/bin/sh
set -eu

iso=${1:?ISO path is required}
disk=${QEMU_DISK:-dist/qemu/disk.img}
vm_dir=${disk%/*}
log="$vm_dir/test.log"
kernel="$vm_dir/vmlinuz-lts"
initrd="$vm_dir/initramfs-lts"
fixture=${QEMU_FETCH_FIXTURE:-qemu/fetch.fixture}
normalizer=${QEMU_FETCH_NORMALIZER:-qemu/normalize-fetch.sh}

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "required host command is missing: $1" >&2
        exit 1
    }
}

require_command qemu-system-x86_64
require_command qemu-img
require_command bsdtar
[ -f "$iso" ] || { echo "ISO not found: $iso" >&2; exit 1; }
[ -f "$fixture" ] || { echo "QEMU fetch fixture not found: $fixture" >&2; exit 1; }
[ -x "$normalizer" ] || { echo "QEMU fetch normalizer is not executable: $normalizer" >&2; exit 1; }

validate_fetch_fixture() {
    normalized="$vm_dir/fetch.normalized.log"
    "$normalizer" "$log" > "$normalized"
    diff -u "$fixture" "$normalized"
}

report_pass() {
    validate_fetch_fixture || {
        echo "QEMU diagnostics fixture did not match serial output: $log" >&2
        tail -80 "$log" >&2 2>/dev/null || true
        exit 1
    }
    echo "QEMU installer test passed. Disk left at $disk"
}

mkdir -p "$vm_dir"
rm -f "$disk" "$kernel" "$initrd" "$log"
bsdtar -xOf "$iso" boot/vmlinuz-lts > "$kernel"
bsdtar -xOf "$iso" boot/initramfs-lts > "$initrd"
qemu-img create -f raw "$disk" 8G >/dev/null

echo "Booting the installer in QEMU..."
qemu-system-x86_64 \
    -machine pc \
    -accel tcg,thread=multi \
    -cpu max \
    -m 1024 \
    -smp 4 \
    -kernel "$kernel" \
    -initrd "$initrd" \
    -append "console=ttyS0,115200 console=tty0 home_installer_qemu=1" \
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
        report_pass
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
    report_pass
    exit 0
fi

echo "QEMU exited before installation completed; serial log: $log" >&2
tail -80 "$log" >&2 2>/dev/null || true
exit 1
