#!/bin/sh

profile_home_installer() {
    profile_base
    profile_abbrev="home"
    title="Home installer"
    desc="Minimal Alpine network bootstrap installer for the home system."
    image_ext="iso"
    output_format="iso"
    arch="x86_64"
    kernel_cmdline="console=ttyS0,115200 console=tty0"
    kernel_flavors="lts"
    modloop_sign="no"
    kernel_addons=
    # linux-lts and firmware are supplied by update-kernel in the boot
    # section. Keep them out of /apks: the live root needs only this small
    # bootstrap closure, while the installed target is fetched after network
    # preflight from the pinned Alpine repositories.
    apks="alpine-base wpa_supplicant ifupdown-ng iproute2 util-linux kmod blkid findmnt lsblk partx sfdisk wipefs dosfstools e2fsprogs efibootmgr bind-tools"
    apkovl="genapkovl-home-installer.sh"
    hostname="home-installer"
}
