#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
release=$(sed -n 's/^supported_release=//p' install.sh)
scripts='install.sh verify.sh build/dwl.sh config/home-session config/profile.sh tests/static.sh tests/vm.sh'
services=services/home-runtime

for script in $scripts $services; do
	sh -n "$script"
	! command -v dash >/dev/null || dash -n "$script"
done
if command -v shellcheck >/dev/null; then
	shellcheck -s sh -S warning $scripts
	shellcheck -s sh -S warning -e SC2034 $services
else
	echo 'static: shellcheck not installed, skipped' >&2
fi

index=.work/tmp/apkindex
for arch in x86_64 aarch64; do
	for repo in main community; do
		mkdir -p "$index/$arch-$repo"
		[ -s "$index/$arch-$repo/APKINDEX" ] ||
			curl -fsS "https://dl-cdn.alpinelinux.org/alpine/v$release/$repo/$arch/APKINDEX.tar.gz" |
			tar -xzf - -C "$index/$arch-$repo" APKINDEX
	done
	wanted=$(cat packages.txt "packages-$arch.txt" 2>/dev/null | sed -e 's/#.*//' -e '/^[[:space:]]*$/d')
	missing=$(printf '%s\n' "$wanted" | while read -r package; do
		cat "$index/$arch"-*/APKINDEX | grep -qx "P:$package" || echo "$package"
	done)
	[ -z "$missing" ] || { printf 'static: missing from Alpine v%s %s: %s\n' "$release" "$arch" "$missing" >&2; exit 1; }
done
echo 'static: ok'
