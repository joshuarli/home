# Home installer

This is a network installer and minimal Alpine desktop for the Intel-only Dell
XPS 13 9343. It is not a general-purpose Alpine installer. The target system
boots to dwl with a foot terminal open; `Ctrl+Return` opens another terminal.

## Install

Use a current project build of `dist/home-installer.iso`. This repository has
no documented download channel; source-build instructions are in
[the development guide](docs/development.md).

1. Boot the ISO in UEFI mode with Secure Boot disabled.
2. At the live root shell, run `/root/home-installer/install.sh`.
3. Select the Intel wireless adapter if prompted, then enter the Wi-Fi SSID
   and passphrase. The installer requires working DHCP and DNS before it will
   list or modify disks.
4. Select the whole target disk and confirm its path twice. **All data on the
   selected disk will be erased.** The installer creates a 512 MiB EFI
   partition, 1 GiB swap partition, and an ext4 root partition using the rest
   of the disk.
5. When installation completes, remove the ISO and reboot.

The Wi-Fi passphrase is saved in `/etc/wpa_supplicant/wpa_supplicant.conf`
with mode `0600`. Internet access is required during installation to fetch the
target packages; the desktop can boot without a network connection.

## Use and recovery

The installed system starts `josh` on `tty1` and opens dwl with foot. The EFI
boot command uses `root=UUID=...`; Alpine's kernel hooks maintain both
`/boot/EFI/alpine/linux-lts.efi` and the removable-media fallback at
`/boot/EFI/BOOT/BOOTX64.EFI`.

Use `Ctrl+Alt+F2` to switch to a recovery console. When starting a login shell
manually, set `HOME_SESSION_DISABLE=1` to skip graphical startup. The `josh`
account has no password, root is locked, and `doas` permits passwordless root
access; these are insecure MVP choices for a physically controlled laptop.

The QEMU `make test` run writes `dist/qemu/disk.fingerprint.json` on success;
`make run` requires a current fingerprint before it boots the retained disk.
`make size` reports the ISO members and installer overlay.

## Support boundary

Secure Boot is unsupported. QEMU checks the installer and software session,
but does not certify the laptop's Intel graphics, wireless firmware,
touchpad, panel, audio, suspend/resume, or power management. See
[installation details](docs/installation.md) and the
[QEMU testing guide](docs/testing.md).

For hardware reports, run `/bin/fetch.sh`; it writes `/tmp/fetch.log` and
redacts Wi-Fi secrets. This repository does not specify a support contact.

## License

This checkout contains no license file, so it does not declare a license.
