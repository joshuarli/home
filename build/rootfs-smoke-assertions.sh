#!/bin/sh

# Shared assertions for the target-root smoke check and its host-side
# regression test. Keep these small: the build runs them inside the target
# chroot, while tests/test-rootfs-smoke.sh executes the same behavior against
# disposable fixtures.

require_file() {
	[ -f "$1" ] || {
		echo "required file is missing: $1" >&2
		return 1
	}
}

require_executable() {
	[ -x "$1" ] || {
		echo "required executable is missing: $1" >&2
		return 1
	}
}

require_symlink() {
	[ -L "$1" ] || {
		echo "required symlink is missing: $1" >&2
		return 1
	}
	if [ "$#" -ge 2 ]; then
		[ "$(readlink "$1")" = "$2" ] || {
			echo "symlink target is wrong: $1" >&2
			return 1
		}
	fi
}

require_absent() {
	[ ! -e "$1" ] && [ ! -L "$1" ] || {
		echo "unexpected path: $1" >&2
		return 1
	}
}

require_not_symlink() {
	[ ! -L "$1" ] || {
		echo "unexpected symlink: $1" >&2
		return 1
	}
}

require_no_match() {
	if grep -q "$1" "$2"; then
		echo "unexpected text in $2: $1" >&2
		return 1
	fi
}

require_not_installed() {
	if apk info -e "$1" >/dev/null 2>&1; then
		echo "unexpected installed package: $1" >&2
		return 1
	fi
}
