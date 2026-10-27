#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
release=$(sed -n 's/^supported_release=//p' install.sh)
iso=alpine-standard-3.24.3-aarch64.iso
mirror=https://dl-cdn.alpinelinux.org/alpine/v$release/releases/aarch64
usr_repo=${USR_REPO:-$HOME/usr}
work=$PWD/.work/vm

[ -z "$(git status --porcelain)" ] || { echo 'vm: commit changes first; the VM provisions HEAD' >&2; exit 1; }
command -v qemu-system-aarch64 >/dev/null || { echo 'vm: qemu-system-aarch64 is required' >&2; exit 1; }
command -v expect >/dev/null || { echo 'vm: expect is required' >&2; exit 1; }
firmware=
for candidate in "$(dirname "$(command -v qemu-system-aarch64)")/../share/qemu/edk2-aarch64-code.fd" \
	/usr/share/qemu/edk2-aarch64-code.fd /usr/share/AAVMF/AAVMF_CODE.fd; do
	[ -f "$candidate" ] && { firmware=$candidate; break; }
done
[ -n "$firmware" ] || { echo 'vm: no aarch64 UEFI firmware found' >&2; exit 1; }
case $(uname -s)-$(uname -m) in
	Darwin-arm64) accel='-accel hvf -cpu host' ;;
	Linux-aarch64) accel='-accel kvm -cpu host' ;;
	*) accel='-accel tcg -cpu max' ;;
esac

mkdir -p "$work/share"
if [ ! -f "$work/$iso" ]; then
	curl -fsS -o "$work/$iso.part" "$mirror/$iso"
	curl -fsS -o "$work/$iso.sha256" "$mirror/$iso.sha256"
	(cd "$work" && sed "s/$iso\$/$iso.part/" "$iso.sha256" | shasum -a 256 -c -s -) || { echo "vm: $iso checksum mismatch" >&2; exit 1; }
	mv "$work/$iso.part" "$work/$iso"
fi

rm -f "$work"/share/* "$work/monitor.sock" "$work/disk.qcow2" "$work/vars.fd" "$work/desktop.ppm"
git bundle create -q "$work/share/home.bundle" HEAD
git -C "$usr_repo" bundle create -q "$work/share/usr.bundle" HEAD
cp tests/answers "$work/share/answers"
qemu-img create -q -f qcow2 "$work/disk.qcow2" 8G
dd if=/dev/zero of="$work/vars.fd" bs=1048576 count=64 2>/dev/null

export VM_QEMU="qemu-system-aarch64 -M virt $accel -m 2048 -smp 2 \
-drive if=pflash,format=raw,readonly=on,file=$firmware -drive if=pflash,format=raw,file=$work/vars.fd \
-drive file=$work/disk.qcow2,if=virtio -drive file=fat:ro:$work/share,format=raw,if=virtio,readonly=on \
-nic user,model=virtio-net-pci -device virtio-gpu-pci -device qemu-xhci -device usb-kbd \
-display none -chardev stdio,id=serial,signal=off -serial chardev:serial \
-monitor unix:$work/monitor.sock,server=on,wait=off"
export VM_ISO="$work/$iso" VM_WORK="$work"
exec expect tests/vm.exp
