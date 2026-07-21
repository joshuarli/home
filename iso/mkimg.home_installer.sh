#!/bin/sh

profile_home_installer() {
    profile_base
    profile_abbrev="home"
    title="Home installer"
    desc="Minimal Alpine installer for the prebuilt home rootfs."
    image_ext="iso"
    output_format="iso"
    arch="x86_64"
    kernel_cmdline="console=ttyS0,115200 console=tty0"
    kernel_flavors="lts"
    modloop_sign="no"
    kernel_addons=
    apks="alpine-base linux-lts linux-firmware-intel linux-firmware-i915 wpa_supplicant wpa_supplicant-openrc ifupdown-ng ifupdown-ng-wifi iproute2 util-linux blkid findmnt lsblk partx sfdisk wipefs dosfstools e2fsprogs efibootmgr tar gzip bind-tools"
    apkovl="genapkovl-home-installer.sh"
    hostname="home-installer"
}
