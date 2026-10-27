#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
iso=alpine-virt-3.24.3-aarch64.iso
mirror=https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/aarch64
edge=https://dl-cdn.alpinelinux.org/alpine/edge
usr_repo=${USR_REPO:-$HOME/usr}
work=$PWD/.work/vm
rootpw=homevmroot
userpw=homevmuser
console=$work/console.log

fail() {
	printf 'vm: FAIL: %s (console: %s)\n' "$*" "$console" >&2
	if [ -n "${diagnose:-}" ] && qemu_running; then
		send "$diagnose"
		monitor "screendump $work/failure.ppm"
		sleep 3
	fi
	stop_vm
	exit 1
}

say() { printf 'vm: %s\n' "$*"; }

qemu_running() { [ -f "$work/qemu.pid" ] && kill -0 "$(cat "$work/qemu.pid")" 2>/dev/null; }

stop_vm() {
	exec 3>&-
	! qemu_running || kill "$(cat "$work/qemu.pid")"
	[ -z "${bridge:-}" ] || kill "$bridge" 2>/dev/null || :
	bridge=
}

size() { echo $(($(wc -c < "$console"))); }

since() { tail -c "+$(($1 + 1))" "$console"; }

wait_for() {
	start=$1 pattern=$2 limit=$3
	while [ "$limit" -gt 0 ]; do
		since "$start" | grep -aq -- "$pattern" && return 0
		qemu_running || fail "vm exited while waiting for: $pattern"
		sleep 1
		limit=$((limit - 1))
	done
	fail "timed out waiting for: $pattern"
}

send() { printf '%s\r' "$1" >&3; }

run() {
	start=$(size)
	printf 'vm: + %s\n' "$1" >&2
	send "$1; echo RC=\$?:$start:"
	wait_for "$start" "RC=[0-9]*:$start:" "${2:-300}"
	since "$start" | grep -ao "RC=[0-9]*:$start:" | head -n 1 | sed 's/RC=\([0-9]*\):.*/\1/'
}

must() {
	rc=$(run "$@")
	[ "$rc" = 0 ] || fail "exit $rc: $1"
}

poll() { must "for i in \$(seq 90); do $1 && break; sleep 1; done; $1" 120; }

monitor() { { printf '%s\n' "$1"; sleep 1; } | nc -U "$work/monitor.sock" >/dev/null; }

type_tty1() {
	{
		printf '%s\n' "$1" | fold -w 1 | while read -r ch; do printf 'sendkey %s\n' "$ch"; sleep 0.2; done
		printf 'sendkey ret\n'
		sleep 1
	} | nc -U "$work/monitor.sock" >/dev/null
}

tty1_prompt() { poll "tr -s ' ' < /dev/vcs1 | sed 's/ *\$//' | grep -q '$1\$'"; }

boot() {
	rm -f "$work/serial.sock" "$work/qemu.pid" "$work/console.fifo"
	: > "$console"
	# shellcheck disable=SC2086
	$qemu "$@" || fail 'qemu did not start'
	mkfifo "$work/console.fifo"
	nc -U "$work/serial.sock" < "$work/console.fifo" >> "$console" &
	bridge=$!
	exec 3> "$work/console.fifo"
	wait_for 0 'login:' 180
}

login() {
	start=$(size)
	send root
	sleep 2
	! since "$start" | grep -aq 'Password:' || send "$rootpw"
	send "stty -echo; PS1='VM# '"
	wait_for "$start" 'VM# ' 30
}

poweroff() {
	send poweroff
	i=0
	while qemu_running && [ "$i" -lt 120 ]; do sleep 1; i=$((i + 1)); done
	qemu_running && fail 'vm did not power off'
	stop_vm
}

[ -z "$(git status --porcelain)" ] || { echo 'vm: commit changes first; the VM provisions HEAD' >&2; exit 1; }
command -v qemu-system-aarch64 >/dev/null || { echo 'vm: qemu-system-aarch64 is required' >&2; exit 1; }
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

rm -f "$work"/share/* "$work/qemu.log" "$work/monitor.sock" "$work/disk.qcow2" "$work/vars.fd" "$work/desktop.ppm" "$work/failure.ppm"
git bundle create -q "$work/share/home.bundle" HEAD
git -C "$usr_repo" bundle create -q "$work/share/usr.bundle" HEAD
cp tests/answers "$work/share/answers"
qemu-img create -q -f qcow2 "$work/disk.qcow2" 8G
dd if=/dev/zero of="$work/vars.fd" bs=1048576 count=64 2>/dev/null
trap stop_vm EXIT INT TERM

qemu="qemu-system-aarch64 -M virt $accel -m 2048 -smp 2
-drive if=pflash,format=raw,readonly=on,file=$firmware -drive if=pflash,format=raw,file=$work/vars.fd
-drive file=$work/disk.qcow2,if=virtio -drive file=fat:ro:$work/share,format=raw,if=virtio,readonly=on
-nic user,model=virtio-net-pci -device virtio-gpu-pci -device qemu-xhci -device usb-kbd -display none
-serial unix:$work/serial.sock,server=on,wait=off -monitor unix:$work/monitor.sock,server=on,wait=off
-pidfile $work/qemu.pid -daemonize -D $work/qemu.log -trace runstate_set -trace chr_socket_*"

say 'installing stock Alpine'
boot -drive "file=$work/$iso,if=virtio,media=cdrom,readonly=on"
login
must 'mkdir -p /media/share && mount -t vfat -o ro /dev/vdb1 /media/share'
start=$(size)
send "APKREPOSOPTS='$edge/main $edge/community' DISKOPTS='-m sys -k stable /dev/vda' ERASE_DISKS=/dev/vda setup-alpine -f /media/share/answers; echo SETUP=\$?:"
answered=0
key_answered=
until since "$start" | grep -aq 'SETUP=[0-9]*:'; do
	prompts=$(since "$start" | grep -ao 'New password:\|Retype password:' | wc -l)
	if [ "$prompts" -gt "$answered" ]; then
		answered=$((answered + 1))
		if [ "$answered" -le 2 ]; then send "$rootpw"; else send "$userpw"; fi
	fi
	if [ -z "$key_answered" ] && since "$start" | grep -aq 'ssh key or URL'; then send none; key_answered=1; fi
	qemu_running || fail 'vm exited during setup-alpine'
	sleep 1
done
since "$start" | grep -aq 'SETUP=0:' || fail 'setup-alpine failed'
poweroff

say 'provisioning'
boot
login
must 'mkdir -p /media/share && mount -t vfat -o ro /dev/vdb1 /media/share'
must 'apk add -q git make' 600
must "su josh -c 'cd ~ && git clone -q /media/share/home.bundle home && git clone -q /media/share/usr.bundle usr && git -C usr remote set-url origin https://github.com/joshuarli/usr'"
must 'cp /etc/apk/world /root/world.before'

[ "$(run 'make -s -C /home/josh/home install USER_NAME=josh > /root/nopass.log 2>&1')" != 0 ] ||
	fail 'install accepted a user without a password'
must "grep -q 'josh has no usable password' /root/nopass.log && cmp /etc/apk/world /root/world.before"
must "echo 'josh:$userpw' | chpasswd"

[ "$(run 'make -s -C /home/josh/home install USER_NAME=josh > /root/tty0.log 2>&1')" != 0 ] ||
	fail 'install accepted a tty0 getty that shares tty1'
must "grep -q 'getty on tty0 shares the tty1 console' /root/tty0.log && cmp /etc/apk/world /root/world.before"
must "sed -i 's/^tty0::/#tty0::/' /etc/inittab && kill -HUP 1"
must "echo 'export WLR_RENDERER=pixman' > /etc/profile.d/00-vm-renderer.sh"
must 'find /boot /etc/network /etc/fstab /etc/inittab /etc/doas.conf /etc/doas.d /etc/apk/repositories /etc/hostname -type f 2>/dev/null | sort | xargs sha256sum > /root/baseline'

must "echo 'echo unmanaged' > /etc/profile.d/home-session.sh"
[ "$(run 'make -s -C /home/josh/home install USER_NAME=josh > /root/conflict.log 2>&1')" != 0 ] ||
	fail 'install accepted an unmanaged conflicting file'
must "grep -q 'home-session.sh exists and was not installed by home' /root/conflict.log || { cat /root/conflict.log; false; }"
must "grep -qx 'echo unmanaged' /etc/profile.d/home-session.sh && cmp /etc/apk/world /root/world.before"
must 'rm /etc/profile.d/home-session.sh'

managed='/usr/local/bin/dwl /usr/local/bin/home-session /etc/init.d/home-runtime /etc/conf.d/home-runtime /etc/profile.d/home-session.sh'
must 'make -s -C /home/josh/home install USER_NAME=josh > /root/install.log 2>&1 || { cat /root/install.log; false; }' 2400
must 'make -s -C /home/josh/home verify USER_NAME=josh' 120
must "stat -c '%n %Y %a' $managed > /root/mtimes && cp /etc/apk/world /root/world.first"
must 'make -s -C /home/josh/home install USER_NAME=josh > /root/rerun.log 2>&1 || { cat /root/rerun.log; false; }' 600
must "! grep -E '^home: (installed|added|cloned)' /root/rerun.log && grep -q 'dwl is current' /root/rerun.log"
must "stat -c '%n %Y %a' $managed | cmp - /root/mtimes && cmp /etc/apk/world /root/world.first"
must 'sha256sum -c -s /root/baseline'
poweroff

say 'booting provisioned system'
boot
login
must 'make -s -C /home/josh/home verify USER_NAME=josh' 120

say 'graphical session'
diagnose='ps -o user,tty,args | grep -v "\\["; tail -20 /run/user/1000/dwl.log'
tty1_prompt 'login:'
type_tty1 josh
tty1_prompt 'Password:'
type_tty1 "$userpw"
poll 'pidof dwl >/dev/null && pidof foot >/dev/null && pidof ish >/dev/null'
must "test \"\$(stat -c %U /run/user/\$(id -u josh)/wayland-0)\" = josh"
monitor 'sendkey meta_l-ret'
poll 'test $(pidof foot | wc -w) -eq 2'
monitor 'sendkey ctrl-ret'
poll 'test $(pidof foot | wc -w) -eq 3'
monitor 'sendkey shift-ret'
poll 'pidof bemenu-run >/dev/null'
monitor "screendump $work/desktop.ppm"
must '! pidof Xwayland >/dev/null'

say 'session recovery'
must 'kill $(pidof dwl)'
poll '! pidof dwl >/dev/null && ps -o user,tty,args | grep -q "^josh *4,1 *-sh"'
poweroff
say PASS
