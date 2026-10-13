# Installation and recovery

The physical installer is for the Intel-only Dell XPS 13 9343. It requires
UEFI with Secure Boot disabled, an Intel wireless adapter, and access to
Alpine's v3.24 repositories. Secure Boot is unsupported because the generated
EFI image is unsigned.

## Install flow

Boot the project ISO in UEFI mode. From the live root shell, run
`/root/home-installer/install.sh`. The physical path discovers Intel wireless
interfaces, asks for the SSID and passphrase, and starts DHCP. It verifies DNS
before listing target disks; DHCP or DNS failure stops with the disk untouched.

The installer accepts only whole disks. It excludes its own media and disks
that are mounted, in use as swap, or otherwise protected. It displays target
candidates, prompts for a disk, then requires the selected device path to be
entered again before writing. It does not accept environment variables as a
physical disk-selection or confirmation bypass.

The fixed GPT layout is a 512 MiB FAT32 EFI system partition, 1 GiB swap, and
an ext4 root partition using the remaining aligned space. The installer saves
the entered Wi-Fi credentials in `/etc/wpa_supplicant/wpa_supplicant.conf`
with mode `0600`. It installs target packages from Alpine repositories after
network and disk validation, then substitutes the new root filesystem UUID
before running Alpine's kernel hook lifecycle.

On success, remove the installer media and reboot. The target's root command
line uses `root=UUID=...`; the installer writes the canonical EFI image and
fallback path, then attempts to add an Alpine UEFI boot entry. If firmware
does not retain that entry, the fallback path remains available.

## Recovery

The graphical session runs only on tty1. Use `Ctrl+Alt+F2` for an ash recovery
console. When launching a login shell manually, set `HOME_SESSION_DISABLE=1`
to bypass graphical startup. The serial console and other recovery VTs do not
start dwl.

The root account is locked. If the `josh` account is unusable, recovery
requires booting external media or rebuilding the installer. The passwordless
`josh` and `doas` configuration is an explicit insecure MVP assumption.

Installer implementation and safety checks live in
[`installer/install.sh`](../installer/install.sh); target setup is in
[`rootfs/configure.sh`](../rootfs/configure.sh).
