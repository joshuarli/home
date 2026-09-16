#!/bin/sh
set -eu

release=$(cat /etc/alpine-release)
tag=${release%.*}
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

update_kernel=$(command -v update-kernel)
sed -i \
    -e 's/-comp xz/-comp zstd -Xcompression-level 3/' \
    -e 's/ -Xbcj//' \
    -e 's/mksfs="-Xbcj[^"]*"/mksfs=/' \
    "$update_kernel"

cd "$aports/scripts"
sh "$aports/scripts/mkimage.sh" \
    --tag "$release" \
    --outdir /work/out \
    --workdir /work/mkimage-work \
    --arch x86_64 \
    --profile home_installer \
    --repository "https://dl-cdn.alpinelinux.org/alpine/v$tag/main" \
    --repository "https://dl-cdn.alpinelinux.org/alpine/v$tag/community"

iso=$(find /work/out -maxdepth 1 -type f -name '*.iso' | head -n 1)
[ -n "$iso" ] || { echo "mkimage did not produce an ISO" >&2; exit 1; }
cp "$iso" /work/out/home-installer.iso

# Keep build facts beside the exported ISO.  This is deliberately metadata,
# not a second distribution artifact: it records the inputs and sizes needed
# to distinguish the compressed ISO from the embedded rootfs payload.
{
	echo 'Home installer ISO metadata'
	echo "alpine release: $release"
	echo "aports branch: ${ALPINE_APORTS_BRANCH:-${tag}-stable}"
	echo "aports revision: $(git -C "$aports" rev-parse HEAD)"
	echo "rootfs archive bytes: $(stat -c '%s' /work/rootfs.tar.gz)"
	echo "rootfs archive sha256: $(sha256sum /work/rootfs.tar.gz | awk '{print $1}')"
	echo "iso bytes: $(stat -c '%s' /work/out/home-installer.iso)"
	echo "iso sha256: $(sha256sum /work/out/home-installer.iso | awk '{print $1}')"
	echo 'kernel flavor: linux-lts'
	echo 'installed EFI image: generated after installation from the target PARTUUID; measured by the QEMU acceptance harness'
} > /work/out/iso-metadata.txt
