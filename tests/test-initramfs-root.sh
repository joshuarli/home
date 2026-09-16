#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
configure=$repo/rootfs/configure.sh
build_rootfs=$repo/build/build-rootfs.sh

fail() {
	echo "initramfs UUID contract: $*" >&2
	exit 1
}

contains() {
	file=$1
	text=$2
	grep -Fq "$text" "$file" || fail "missing text in $file: $text"
}

not_contains() {
	file=$1
	text=$2
	if grep -Fq "$text" "$file"; then
		fail "unexpected text in $file: $text"
	fi
}

missing() {
	[ ! -e "$1" ] || fail "obsolete path remains: $1"
}

contains "$configure" 'root=UUID=INSTALLER_ROOT_UUID'
not_contains "$configure" 'PARTUUID'
contains "$configure" 'ln -sf /usr/share/kernel-hooks.d/secureboot.hook'
contains "$configure" 'disable_trigger=yes'
not_contains "$configure" 'kernel_trigger_archive='
not_contains "$configure" 'kernel-hooks.trigger'
not_contains "$configure" 'patch-initramfs'
not_contains "$configure" 'features.d/home.files'
not_contains "$build_rootfs" 'patch-initramfs'
missing "$repo/rootfs/patch-initramfs.sh"

echo 'initramfs UUID contract tests passed'
