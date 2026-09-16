#!/bin/sh
set -eu

rootfs=${1:?rootfs path is required}
assets=${2:-/work}
repositories=${3:-$assets/repositories}

[ -f "$repositories" ] || {
	echo "repository file is missing: $repositories" >&2
	exit 1
}
if [ "$repositories" != "$rootfs/etc/apk/repositories" ]; then
	cp "$repositories" "$rootfs/etc/apk/repositories"
fi
/bin/busybox --install -s "$rootfs/bin"
ln -sf /bin/busybox "$rootfs/sbin/init"

install -m 0755 "$assets/fetch.sh" "$rootfs/bin/fetch.sh"
install -m 0755 "$assets/dwl" "$rootfs/usr/bin/dwl"
install -m 0755 "$assets/home-login" "$rootfs/usr/bin/home-login"
install -m 0755 "$assets/home-session" "$rootfs/usr/bin/home-session"
install -m 0755 "$assets/home-runtime.initd" "$rootfs/etc/init.d/home-runtime"

home="$rootfs/home/josh"
mkdir -p "$home/.config/foot"
install -m 0644 "$assets/foot.ini" "$home/.config/foot/foot.ini"
chown -R 1000:1000 "$home"

next_gid() {
	awk -F: 'BEGIN {max=999} $3 > max {max=$3} END {print max + 1}' "$rootfs/etc/group"
}

ensure_group() {
	group_name=$1
	requested_gid=${2:-}
	group_count=$(awk -F: -v name="$group_name" '$1 == name {count++} END {print count + 0}' "$rootfs/etc/group")
	[ "$group_count" -le 1 ] || {
		echo "group $group_name is defined more than once" >&2
		exit 1
	}
	if grep -q "^$group_name:" "$rootfs/etc/group"; then
		actual_gid=$(awk -F: -v name="$group_name" '$1 == name {print $3; exit}' "$rootfs/etc/group")
		if [ -n "$requested_gid" ] && [ "$actual_gid" != "$requested_gid" ]; then
			echo "group $group_name has GID $actual_gid, expected $requested_gid" >&2
			exit 1
		fi
		return 0
	fi
	group_gid=$requested_gid
	if [ -z "$group_gid" ]; then
		group_gid=$(next_gid)
	fi
	if awk -F: -v gid="$group_gid" '$3 == gid {found=1} END {exit found ? 0 : 1}' "$rootfs/etc/group"; then
		echo "GID $group_gid is already in use while creating $group_name" >&2
		exit 1
	fi
	echo "$group_name:x:$group_gid:" >> "$rootfs/etc/group"
}

ensure_member() {
	group_name=$1
	user_name=$2
	tmp=$(mktemp)
	awk -F: -v OFS=: -v group_name="$group_name" -v user_name="$user_name" '
		$1 == group_name {
			count = split($4, members, ",")
			$4 = ""
			for (i = 1; i <= count; i++) {
				member = members[i]
				if (member == "" || seen[member]++) continue
				$4 = ($4 == "" ? member : $4 "," member)
			}
			if (!seen[user_name]) $4 = ($4 == "" ? user_name : $4 "," user_name)
		}
		{ print }
	' "$rootfs/etc/group" > "$tmp"
	mv "$tmp" "$rootfs/etc/group"
}

ensure_group josh 1000
ensure_group wheel 10
ensure_group seat

if grep -q '^josh:' "$rootfs/etc/passwd"; then
	[ "$(awk -F: '$1 == "josh" {count++} END {print count + 0}' "$rootfs/etc/passwd")" -eq 1 ] || {
		echo 'josh account is defined more than once' >&2
		exit 1
	}
	awk -F: '$1 == "josh" && ($3 != 1000 || $4 != 1000 || $6 != "/home/josh" || $7 != "/usr/bin/home-login") {bad=1} END {exit bad ? 0 : 1}' "$rootfs/etc/passwd" && {
		echo 'existing josh account does not match the target contract' >&2
		exit 1
	}
else
	echo 'josh:x:1000:1000:josh:/home/josh:/usr/bin/home-login' >> "$rootfs/etc/passwd"
fi

ensure_member wheel josh
ensure_member seat josh

if grep -q '^josh:' "$rootfs/etc/shadow"; then
	[ "$(awk -F: '$1 == "josh" {count++} END {print count + 0}' "$rootfs/etc/shadow")" -eq 1 ] || {
		echo 'josh shadow entry is defined more than once' >&2
		exit 1
	}
	sed -i -E 's/^josh:[^:]*/josh:/' "$rootfs/etc/shadow"
else
	echo 'josh::19000:0:99999:7:::' >> "$rootfs/etc/shadow"
fi
sed -i -E 's/^root:[^:]*/root:!/' "$rootfs/etc/shadow"

mkdir -p "$rootfs/etc/doas.d"
cat > "$rootfs/etc/doas.d/josh.conf" <<'EOF'
permit nopass josh as root
EOF
chmod 0400 "$rootfs/etc/doas.d/josh.conf"

echo alpine > "$rootfs/etc/hostname"
ln -sf /usr/share/zoneinfo/America/Los_Angeles "$rootfs/etc/localtime"
mkdir -p "$rootfs/etc/profile.d"
cat > "$rootfs/etc/profile.d/home-installer.sh" <<'EOF'
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
EOF
chmod 0644 "$rootfs/etc/profile.d/home-installer.sh"

cat > "$rootfs/etc/adjtime" <<'EOF'
0.0 0 0.0
0
UTC
EOF

cat > "$rootfs/etc/hosts" <<'EOF'
127.0.0.1 localhost alpine
::1 localhost alpine
EOF

cat > "$rootfs/etc/network/interfaces" <<'EOF'
auto lo
iface lo inet loopback
EOF

# The installer replaces only this root identifier after it has created the
# filesystem. Alpine's stock initramfs resolves UUID= without a private
# initramfs patch, and the hook-generated EFI image and fstab use the same UUID.
mkdir -p "$rootfs/etc/kernel-hooks.d"
cat > "$rootfs/etc/kernel-hooks.d/secureboot.conf" <<'EOF'
cmdline="console=ttyS0,115200 console=tty0 root=UUID=INSTALLER_ROOT_UUID rootfstype=ext4 rw"
signing_disabled=yes
output_dir="/boot/EFI/alpine"
output_name="linux-{flavor}.efi"
backup_old=no
EOF
ln -sf /usr/share/kernel-hooks.d/secureboot.hook "$rootfs/etc/kernel-hooks.d/50-secureboot.hook"
cat > "$rootfs/etc/kernel-hooks.d/60-home-fallback" <<'EOF'
#!/bin/sh
set -eu

flavor=${1:?kernel flavor is required}
canonical="/boot/EFI/alpine/linux-$flavor.efi"
fallback="/boot/EFI/BOOT/BOOTX64.EFI"
[ -f "$canonical" ] || exit 0
mkdir -p "${fallback%/*}"
temporary="$fallback.home-installer.$$"
trap 'rm -f "$temporary"' EXIT HUP INT TERM
umask 022
cp -p "$canonical" "$temporary"
mv -f "$temporary" "$fallback"
trap - EXIT HUP INT TERM
EOF
chmod 0755 "$rootfs/etc/kernel-hooks.d/60-home-fallback"

# secureboot-hook invokes mkinitfs itself while producing the EFI image.  Its
# package documentation directs users to suppress mkinitfs's separate generic
# trigger, which would otherwise build an unused standalone initramfs after
# every kernel change.  Keep the package's stock feature list intact: Alpine
# 3.24.1's base feature already supplies nlplug-findfs and persistent-storage
# support for root=UUID=, so no repository-owned initramfs feature is needed.
mkinitfs_config="$rootfs/etc/mkinitfs/mkinitfs.conf"
[ -f "$mkinitfs_config" ] || {
	echo 'mkinitfs configuration is missing from the installed package' >&2
	exit 1
}
grep -q '^features=' "$mkinitfs_config" || {
	echo 'mkinitfs configuration has no package-provided feature set' >&2
	exit 1
}
if grep -q '^disable_trigger=' "$mkinitfs_config"; then
	sed -i -E 's/^disable_trigger=.*/disable_trigger=yes/' "$mkinitfs_config"
else
	cat >> "$mkinitfs_config" <<'EOF'

# secureboot-hook generates the embedded initramfs for the EFI image.
disable_trigger=yes
EOF
fi

# Keep one device-manager implementation.  These are the services created by
# Alpine's setup-devd udev path, expressed as links because apk scripts do not
# run in the alternate root.
mkdir -p "$rootfs/etc/runlevels/sysinit" "$rootfs/etc/runlevels/boot" "$rootfs/etc/runlevels/default"
for service in devfs procfs sysfs dmesg udev udev-trigger udev-settle hwdrivers; do
	[ -x "$rootfs/etc/init.d/$service" ] || {
		echo "required OpenRC service is missing: $service" >&2
		exit 1
	}
	ln -sf "/etc/init.d/$service" "$rootfs/etc/runlevels/sysinit/$service"
done

for service in hwclock hostname bootmisc modules sysctl; do
	[ -x "$rootfs/etc/init.d/$service" ] || continue
	ln -sf "/etc/init.d/$service" "$rootfs/etc/runlevels/boot/$service"
done
for service in udev-postmount seatd home-runtime networking; do
	[ -x "$rootfs/etc/init.d/$service" ] || {
		echo "required default OpenRC service is missing: $service" >&2
		exit 1
	}
	ln -sf "/etc/init.d/$service" "$rootfs/etc/runlevels/default/$service"
done
rm -f "$rootfs/etc/runlevels/sysinit/mdev" "$rootfs/etc/runlevels/sysinit/mdevd"

# tty1 is the only autologin that enters home-login.  Other VTs and serial
# remain ordinary ash recovery consoles.
sed -i -E '/^tty[1-6]::/d; /^ttyS0::/d' "$rootfs/etc/inittab"
cat >> "$rootfs/etc/inittab" <<'EOF'
tty1::respawn:/sbin/agetty --autologin josh --noclear 38400 tty1 linux
tty2::respawn:/sbin/agetty --noclear 38400 tty2 linux
tty3::respawn:/sbin/agetty --noclear 38400 tty3 linux
tty4::respawn:/sbin/agetty --noclear 38400 tty4 linux
tty5::respawn:/sbin/agetty --noclear 38400 tty5 linux
tty6::respawn:/sbin/agetty --noclear 38400 tty6 linux
ttyS0::respawn:/sbin/agetty --autologin josh --noclear 115200 ttyS0 vt100
EOF

rm -rf "$rootfs/var/cache/apk"/*
