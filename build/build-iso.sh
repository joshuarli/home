#!/bin/sh
set -eu

tag=$(cut -d. -f1,2 /etc/alpine-release)
aports=/work/aports

cp /work/iso/mkimg.home_installer.sh "$aports/scripts/mkimg.home_installer.sh"
cp /work/iso/genapkovl-home-installer.sh "$aports/scripts/genapkovl-home-installer.sh"
chmod +x "$aports/scripts/mkimg.home_installer.sh" "$aports/scripts/genapkovl-home-installer.sh"

export HOME_INSTALLER_ROOTFS_ARCHIVE=/work/rootfs.tar.gz
mkdir -p /root/.abuild
if ! find /root/.abuild -maxdepth 1 -type f -name '*.rsa' -print -quit | grep -q .; then
    abuild-keygen -a -n
fi
. /etc/abuild.conf
PACKAGER_PRIVKEY=$(find /root/.abuild -maxdepth 1 -type f -name '*.rsa' -print -quit)
[ -n "$PACKAGER_PRIVKEY" ] || { echo "abuild did not create a signing key" >&2; exit 1; }
PACKAGER_PUBKEY="$PACKAGER_PRIVKEY.pub"
[ -f "$PACKAGER_PUBKEY" ] || { echo "abuild did not create a public signing key" >&2; exit 1; }
export PACKAGER_PRIVKEY PACKAGER_PUBKEY
cp "$PACKAGER_PUBKEY" /etc/apk/keys/
export HOME_INSTALLER_APK_KEY="$PACKAGER_PUBKEY"
mkdir -p /work/out /work/mkimage-work
touch /work/.default_boot_services

cd "$aports/scripts"
sh "$aports/scripts/mkimage.sh" \
    --tag "$tag" \
    --outdir /work/out \
    --workdir /work/mkimage-work \
    --arch x86_64 \
    --profile home_installer \
    --repository "https://dl-cdn.alpinelinux.org/alpine/v$tag/main" \
    --repository "https://dl-cdn.alpinelinux.org/alpine/v$tag/community"

iso=$(find /work/out -maxdepth 1 -type f -name '*.iso' | head -n 1)
[ -n "$iso" ] || { echo "mkimage did not produce an ISO" >&2; exit 1; }
cp "$iso" /work/out/home-installer.iso
