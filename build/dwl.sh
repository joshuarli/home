#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
version=0.8
sha=3080087e7f613bf6a350934231fd9ed478d04cd2a2f30da8a96cdf2066f59412
build_id=$(cat build/dwl.sh config/dwl.h | sha256sum | cut -c1-12)
build_version=$version-home.$build_id
target=/usr/local/bin/dwl

case ${1:-} in
	--version) printf 'dwl %s\n' "$build_version"; exit 0 ;;
	'') ;;
	*) echo "usage: $0 [--version]" >&2; exit 2 ;;
esac

if [ -x "$target" ] && [ "$("$target" -v 2>&1)" = "dwl $build_version" ]; then
	echo "home: $target is current ($build_version)"
	exit 0
fi

apk add --quiet --virtual .home-dwl-build build-base pkgconf wayland-dev wayland-protocols \
	libinput-dev libxkbcommon-dev wlroots0.19-dev
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"; apk del --quiet .home-dwl-build' EXIT HUP INT TERM
wget -q -O "$tmp/dwl.tar.gz" "https://codeberg.org/dwl/dwl/archive/v$version.tar.gz"
printf '%s  %s\n' "$sha" "$tmp/dwl.tar.gz" | sha256sum -c -s - || {
	echo "home: dwl $version source does not match the pinned SHA-256" >&2
	exit 1
}
tar -xzf "$tmp/dwl.tar.gz" -C "$tmp"
cp config/dwl.h "$tmp/dwl/config.h"
make -s -C "$tmp/dwl" VERSION="$build_version"
install -o root -g root -m 0755 "$tmp/dwl/dwl" "$target"
echo "home: installed $target ($build_version)"
