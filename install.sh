#!/bin/sh
set -eu
cd "$(dirname "$0")"

supported_release=3.24
usr_url=https://github.com/joshuarli/usr

die() { printf 'home: %s\n' "$*" >&2; exit 1; }
say() { printf 'home: %s\n' "$*"; }

as_user() { su -s /bin/sh "$user" -c "cd ~ && $1"; }

matches_committed() {
	for rev in $(git -c safe.directory="$PWD" log --format=%H -- "$1"); do
		git -c safe.directory="$PWD" show "$rev:$1" 2>/dev/null | cmp -s - "$2" && return 0
	done
	return 1
}

check_managed() {
	[ -e "$2" ] || return 0
	[ -f "$2" ] && [ ! -L "$2" ] || die "$2 exists and is not a regular file; move it aside"
	cmp -s "$1" "$2" || matches_committed "$1" "$2" ||
		die "$2 exists and was not installed by home; move it aside or merge it into $1"
}

install_managed() {
	if cmp -s "$1" "$2" 2>/dev/null; then
		[ "$(stat -c %u:%g:%a "$2")" = "0:0:${3#0}" ] || { chown root:root "$2"; chmod "$3" "$2"; }
	else
		install -o root -g root -m "$3" "$1" "$2"
		say "installed $2"
	fi
}

[ "$(id -u)" -eq 0 ] || die 'run as root, for example: doas make install USER_NAME=yourlogin'
[ -r /etc/os-release ] && . /etc/os-release
[ "${ID:-}" = alpine ] || die 'this provisioner supports only Alpine Linux'
case ${VERSION_ID:-} in
	"$supported_release" | "$supported_release".*) ;;
	*) die "Alpine ${VERSION_ID:-unknown} is not supported; this provisioner targets Alpine $supported_release" ;;
esac
arch=$(apk --print-arch)
case $arch in x86_64 | aarch64) ;; *) die "architecture $arch is not supported" ;; esac
rootfs=$(awk '$2 == "/" { t = $3 } END { print t }' /proc/mounts)
case $rootfs in tmpfs | ramfs | '') die "root filesystem is $rootfs; install Alpine to disk (sys mode) first" ;; esac
command -v git >/dev/null && command -v make >/dev/null || die 'git and make are required: apk add git make'

user=${USER_NAME:-}
[ -n "$user" ] || die 'set USER_NAME to the desktop login, for example: doas make install USER_NAME="$(id -un)"'
[ "$user" != root ] || die 'USER_NAME must be a regular user, not root'
entry=$(getent passwd "$user") || die "user $user does not exist; create it with setup-user or adduser"
uid=$(printf '%s\n' "$entry" | cut -d: -f3)
home=$(printf '%s\n' "$entry" | cut -d: -f6)
[ "$uid" -ge 1000 ] || die "user $user has uid $uid; a regular login (uid >= 1000) is required"
[ -d "$home" ] && [ "$(stat -c %u "$home")" = "$uid" ] || die "home directory $home of $user is missing or not owned by $user"
hash=$(awk -F: -v u="$user" '$1 == u { print $2 }' /etc/shadow)
case $hash in '$'*) ;; *) die "user $user has no usable password; set one with: passwd $user" ;; esac

[ -s /etc/apk/repositories ] || die '/etc/apk/repositories is empty; run setup-apkrepos'
repos=$(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' /etc/apk/repositories)
case $repos in */edge/* | */testing*) die "remove edge and testing repositories; this provisioner targets Alpine v$supported_release" ;; esac
printf '%s\n' "$repos" | grep -q "/v$supported_release/community/*\$" ||
	die "enable the v$supported_release community repository: setup-apkrepos -c"

for script in install.sh verify.sh build/dwl.sh config/home-session config/profile.sh services/home-runtime; do
	sh -n "$script" || die "$script has a syntax error"
done

conf=$(mktemp)
trap 'rm -f "$conf"' EXIT HUP INT TERM
printf 'home_user="%s"\n' "$user" > "$conf"
check_managed config/home-session /usr/local/bin/home-session
check_managed services/home-runtime /etc/init.d/home-runtime
check_managed config/profile.sh /etc/profile.d/home-session.sh
if [ -e /etc/conf.d/home-runtime ] && ! cmp -s "$conf" /etc/conf.d/home-runtime; then
	die "/etc/conf.d/home-runtime configures a different user or was not written by home; remove it to provision $user"
fi
if [ -e /usr/local/bin/dwl ]; then
	case $(/usr/local/bin/dwl -v 2>&1) in
		'dwl '*-home.*) ;;
		*) die '/usr/local/bin/dwl was not built by home; move it aside' ;;
	esac
fi
if [ -e "$home/usr" ]; then
	origin=$(as_user 'git -C usr remote get-url origin' 2>/dev/null) || die "$home/usr exists but is not a git checkout"
	case $origin in
		"$usr_url" | "$usr_url.git" | git@github.com:joshuarli/usr | git@github.com:joshuarli/usr.git) ;;
		*) die "$home/usr is a checkout of $origin, not $usr_url" ;;
	esac
fi

say 'checking network and repositories'
apk update --quiet || die 'apk update failed; check networking and /etc/apk/repositories'

if [ ! -e "$home/usr" ]; then
	say "cloning $usr_url into $home/usr"
	as_user "git clone --quiet $usr_url usr" || die "could not clone $usr_url"
fi
as_user 'make -s -C usr plan >/dev/null' ||
	die "dotfile links conflict with existing files; run make -C ~/usr plan as $user and resolve each CONFLICT"

packages=$(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' packages.txt)
[ ! -f "packages-$arch.txt" ] || packages="$packages $(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "packages-$arch.txt")"
# shellcheck disable=SC2086
apk add --quiet $packages

rc-update show sysinit | awk '$1 == "udev" { found = 1 } END { exit !found }' || setup-devd udev

sh build/dwl.sh
install_managed config/home-session /usr/local/bin/home-session 0755
install_managed services/home-runtime /etc/init.d/home-runtime 0755
install_managed "$conf" /etc/conf.d/home-runtime 0644
install_managed config/profile.sh /etc/profile.d/home-session.sh 0644

id -Gn "$user" | tr ' ' '\n' | grep -qx seat || { addgroup "$user" seat; say "added $user to seat"; }
for service in seatd home-runtime; do
	rc-update show default | awk -v s="$service" '$1 == s { found = 1 } END { exit !found }' || rc-update add "$service" default
	rc-service --ifstopped "$service" start
done

as_user 'make -s -C usr links >/dev/null' || die "linking dotfiles from $home/usr failed"
as_user 'make -s -C usr tools TOOLS=ish' || die "installing ish from $home/usr failed"

say "provisioned. Log out, then log in as $user on tty1. Run: doas make verify USER_NAME=$user"
