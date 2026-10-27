#!/bin/sh
set -eu
# Source checksum is from the original home Dockerfile.
version=0.8
sha=3080087e7f613bf6a350934231fd9ed478d04cd2a2f30da8a96cdf2066f59412
apk add --virtual .home-dwl-build build-base pkgconf wayland-dev wayland-protocols libinput-dev libxkbcommon-dev wlroots0.19-dev wget
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"; apk del .home-dwl-build' EXIT HUP INT TERM
wget -q -O "$tmp/dwl.tar.gz" "https://codeberg.org/dwl/dwl/archive/v$version.tar.gz"
printf '%s  %s\n' "$sha" "$tmp/dwl.tar.gz" | sha256sum -c -
mkdir "$tmp/src"
tar -xzf "$tmp/dwl.tar.gz" -C "$tmp/src"
cd "$tmp/src/dwl"
sed -i -e '/static const char \*menucmd\[\] = { "wmenu-run", NULL };/d' \
  -e '/{ MODKEY,                    XKB_KEY_p,           spawn,            {.v = menucmd} },/d' \
  -e 's/{ MODKEY|WLR_MODIFIER_SHIFT, XKB_KEY_Return,      spawn,            {.v = termcmd} },/{ WLR_MODIFIER_CTRL,          XKB_KEY_Return,      spawn,            {.v = termcmd} },/' config.def.h
grep -Fq 'WLR_MODIFIER_CTRL,          XKB_KEY_Return' config.def.h || { echo 'dwl patch failed' >&2; exit 1; }
make
install -m 0755 dwl /usr/local/bin/dwl
