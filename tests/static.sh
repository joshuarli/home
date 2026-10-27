#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
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

provided() {
	awk -v want="$1" -v min="$2" '
		function ok(version) { return min == "" || version + 0 >= min }
		/^P:/ { name = substr($0, 3) }
		/^V:/ { version = substr($0, 3) }
		/^p:/ {
			n = split(substr($0, 3), provides, " ")
			for (i = 1; i <= n; i++) {
				split(provides[i], pair, "=")
				if (pair[1] == want && ok(pair[2])) found = 1
			}
		}
		/^$/ { if (name == want && ok(version)) found = 1; name = version = "" }
		END { if (name == want && ok(version)) found = 1; exit !found }
	' "$3"
}

index=.work/tmp/apkindex-edge
for arch in x86_64 aarch64; do
	mkdir -p "$index"
	for repo in main community; do
		curl -fsS "https://dl-cdn.alpinelinux.org/alpine/edge/$repo/$arch/APKINDEX.tar.gz" | tar -xzOf - APKINDEX
		echo
	done > "$index/$arch"
	missing=$(cat packages.txt "packages-$arch.txt" 2>/dev/null | sed -e 's/#.*//' -e '/^[[:space:]]*$/d' |
		while read -r package; do
			name=${package%%>=*}
			min=
			[ "$name" = "$package" ] || min=${package#*>=}
			provided "$name" "$min" "$index/$arch" || echo "$package"
		done)
	[ -z "$missing" ] || { printf 'static: not in Alpine edge %s: %s\n' "$arch" "$missing" >&2; exit 1; }
done
echo 'static: ok'
