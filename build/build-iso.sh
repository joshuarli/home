#!/bin/sh
set -eu

tag=$(cut -d. -f1,2 /etc/alpine-release)
branch="$tag-stable"
aports=/work/aports

git clone --depth 1 --branch "$branch" https://gitlab.alpinelinux.org/alpine/aports.git "$aports"
# apk 3.x removed --no-chown; the current mkimage script still passes it.
sed -i 's/ --no-chown//' "$aports/scripts/mkimage.sh"
cp /work/iso/mkimg.home_installer.sh "$aports/scripts/mkimg.home_installer.sh"
cp /work/iso/genapkovl-home-installer.sh "$aports/scripts/genapkovl-home-installer.sh"
chmod +x "$aports/scripts/mkimg.home_installer.sh" "$aports/scripts/genapkovl-home-installer.sh"

export HOME_INSTALLER_INSTALL_SCRIPT=/work/installer/install.sh
export HOME_INSTALLER_ROOTFS_ARCHIVE=/work/rootfs.tar.gz
abuild-keygen -a -n
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
