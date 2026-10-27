#!/bin/sh
set -u
cd "$(dirname "$0")" || exit 1

failures=0
fail() { printf 'FAIL: %s\n' "$*"; failures=$((failures + 1)); }
pass() { printf 'ok: %s\n' "$*"; }
check() { label=$1; shift; if "$@" >/dev/null 2>&1; then pass "$label"; else fail "$label"; fi; }

in_runlevel() { rc-update show "$2" | awk -v s="$1" '$1 == s { found = 1 } END { exit !found }'; }
managed() { cmp -s "$1" "$2" && [ "$(stat -c %u:%g:%a "$2")" = "0:0:$3" ]; }
no_match() { ! grep -Eqs "$@"; }
major_at_least() { [ "$("$2" --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 | cut -d. -f1)" -ge "$1" ] 2>/dev/null; }

[ "$(id -u)" -eq 0 ] || { echo 'verify: run as root' >&2; exit 1; }
user=${USER_NAME:-}
[ -n "$user" ] || { echo 'verify: set USER_NAME' >&2; exit 1; }
uid=$(id -u "$user") || { echo "verify: no user $user" >&2; exit 1; }
home=$(getent passwd "$user" | cut -d: -f6)

check 'home-session matches config/home-session, root 0755' managed config/home-session /usr/local/bin/home-session 755
check 'home-runtime service matches services/home-runtime, root 0755' managed services/home-runtime /etc/init.d/home-runtime 755
check 'tty1 hook matches config/profile.sh, root 0644' managed config/profile.sh /etc/profile.d/home-session.sh 644
check "home-runtime configured for $user" grep -qx "home_user=\"$user\"" /etc/conf.d/home-runtime
check 'dwl build matches build/dwl.sh and config/dwl.h' test "$(/usr/local/bin/dwl -v 2>&1)" = "$(sh build/dwl.sh --version)"
check 'dwl shared libraries resolve' sh -c '! ldd /usr/local/bin/dwl 2>&1 | grep -q "not found"'
check 'dwl build dependencies removed' sh -c '! apk info -e .home-dwl-build'
for cmd in foot bemenu-run grim slurp wl-copy; do check "$cmd installed" command -v "$cmd"; done
check 'Hack font installed' sh -c 'fc-list | grep -q Hack'
for tool in clang ld.lld llc; do check "$tool is version 23 or newer" major_at_least 23 "$tool"; done
check 'linux-lts not installed' sh -c '! apk info -e linux-lts'
check 'running linux-stable' sh -c 'uname -r | grep -q -- -stable$'

check 'udev manages devices' in_runlevel udev sysinit
check 'mdev disabled' sh -c '! rc-update show sysinit | grep -qw mdev'
for service in seatd home-runtime; do
	check "$service enabled" in_runlevel "$service" default
	check "$service started" rc-service "$service" status
done
check "$user in seat" sh -c "id -Gn '$user' | tr ' ' '\n' | grep -qx seat"
check "/run/user/$uid private to $user" test "$(stat -c %U:%a "/run/user/$uid" 2>/dev/null)" = "$user:700"

check "$user has a password" sh -c "awk -F: '\$1 == \"$user\" { exit !(\$2 ~ /^\\$/) }' /etc/shadow"
check 'no getty autologin' no_match -- '--autologin|[[:space:]]-a[[:space:]]' /etc/inittab
check 'no passwordless doas' sh -c '! cat /etc/doas.conf /etc/doas.d/*.conf 2>/dev/null | sed "s/#.*//" | grep -qw nopass'

check "ish installed for $user" test -x "$home/.local/bin/ish"
check 'sudo not installed' sh -c '! apk info -e sudo'
check "$home/usr dotfiles linked" sh -c "su -s /bin/sh '$user' -c 'cd ~ && make -s -C usr plan' | awk '/^(LINK|CONFLICT|PRUNE)/ { found = 1 } END { exit found }'"

if [ "$failures" -ne 0 ]; then
	echo "verify: $failures check(s) failed"
	exit 1
fi
echo 'verify: all checks passed (graphical session and hardware not exercised)'
