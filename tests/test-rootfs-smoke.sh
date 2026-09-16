#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
assertions=$repo/build/rootfs-smoke-assertions.sh
temporary=$(mktemp -d "/tmp/home-rootfs-smoke.XXXXXX")
trap 'rm -rf "$temporary"' EXIT HUP INT TERM

. "$assertions"

fail() {
	echo "rootfs smoke assertion test: $*" >&2
	exit 1
}

expect_failure() {
	set +e
	"$@" >/dev/null 2>&1
	status=$?
	set -e
	[ "$status" -ne 0 ] || fail "expected failure: $*"
}

required=$temporary/usr/bin/required
expect_failure require_executable "$required"
mkdir -p "$(dirname "$required")"
touch "$required"
expect_failure require_executable "$required"
chmod 0755 "$required"
require_executable "$required"

forbidden_service=$temporary/etc/runlevels/default/unwanted
mkdir -p "$(dirname "$forbidden_service")"
ln -s /etc/init.d/unwanted "$forbidden_service"
expect_failure require_absent "$forbidden_service"
rm -f "$forbidden_service"
require_absent "$forbidden_service"

setting=$temporary/etc/kernel-hooks.d/secureboot.conf
mkdir -p "$(dirname "$setting")"
printf '%s\n' 'root=PARTUUID=forbidden' > "$setting"
expect_failure require_no_match 'root=PARTUUID=' "$setting"
printf '%s\n' 'root=UUID=allowed' > "$setting"
require_no_match 'root=PARTUUID=' "$setting"

fake_bin=$temporary/bin
mkdir "$fake_bin"
cat > "$fake_bin/apk" <<'EOF'
#!/bin/sh
case "$*" in
*forbidden-package*) exit 0 ;;
*) exit 1 ;;
esac
EOF
chmod 0755 "$fake_bin/apk"
PATH="$fake_bin:$PATH"
expect_failure require_not_installed forbidden-package
require_not_installed allowed-package

echo 'rootfs smoke assertion behavior tests passed'
