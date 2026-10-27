#!/bin/sh
set -eu
[ -f /etc/alpine-release ] || exit 1
for x in /usr/local/bin/dwl /usr/local/bin/home-session /etc/init.d/home-runtime /etc/profile.d/home-session.sh; do
 [ -f "$x" ] || { echo "Missing: $x" >&2; exit 1; }
done
command -v foot >/dev/null
rc-update show default | grep -q seatd
rc-update show default | grep -q home-runtime
echo 'Configuration checks passed (hardware and graphical startup not tested).'
