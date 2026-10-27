#!/bin/sh
set -eu
cd "$(dirname "$0")"
[ "$(id -u)" -eq 0 ] || { echo 'Root required' >&2; exit 1; }
[ -f /etc/alpine-release ] && command -v apk >/dev/null && command -v rc-update >/dev/null || exit 1
[ "$(uname -m)" = x86_64 ] || exit 1
[ -d /etc/runlevels ] && [ -d /var/lib/apk ] || exit 1
user=${USER_NAME:-}
[ -n "$user" ] && [ "$user" != root ] || { echo 'Specify USER_NAME' >&2; exit 1; }
entry=$(getent passwd "$user") || exit 1
uid=$(printf '%s\n' "$entry" | cut -d: -f3)
home=$(printf '%s\n' "$entry" | cut -d: -f6)
case "$uid" in ''|*[!0-9]*) exit 1;; esac
[ "$uid" -ge 1000 ] && [ -d "$home" ] || exit 1
shadow=$(awk -F: -v u="$user" '$1==u {print $2}' /etc/shadow)
case "$shadow" in ''|'!'|'*'|'!!') echo 'User must have a password' >&2; exit 1;; esac
[ -s /etc/apk/repositories ] || exit 1
packages=$(sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d' packages.txt)
# shellcheck disable=SC2086
apk add $packages
sh build/dwl.sh
install -m 0755 config/home-session /usr/local/bin/home-session
install -m 0755 config/home-runtime.initd /etc/init.d/home-runtime
printf '%s\n' "$uid" > /etc/home-session-uid
chmod 0644 /etc/home-session-uid
mkdir -p "$home/.config/foot" /etc/profile.d
install -m 0644 config/foot.ini "$home/.config/foot/foot.ini"
chown "$(id -u "$user"):$(id -g "$user")" "$home/.config/foot" "$home/.config/foot/foot.ini"
cat > /etc/profile.d/home-session.sh <<'EOF'
if [ -z "${HOME_SESSION_DISABLE:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ] && [ -z "${SSH_CONNECTION:-}" ] && [ "$(tty 2>/dev/null)" = /dev/tty1 ]; then
 /usr/local/bin/home-session
fi
EOF
chmod 0644 /etc/profile.d/home-session.sh
rc-update add seatd default
rc-update add home-runtime default
echo 'Provisioned. Log in on tty1.'
