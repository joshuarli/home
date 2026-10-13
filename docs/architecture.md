# System architecture

The image is a bootable Alpine 3.24.1 live environment with an installer
overlay. The target root filesystem is installed over the network from
`rootfs-packages.txt`; it is not embedded in the ISO.

## Package and build ownership

- `rootfs-packages.txt` is the direct installed-target package list.
- `iso/mkimg.home_installer.sh` owns the live installer's bootstrap packages.
- `Dockerfile` owns build-only tools and compiles the pinned Codeberg dwl v0.8
  source in a build stage. Its checksum is pinned there; runtime libraries
  remain Alpine packages.
- `build/` owns ISO export and metadata, while `qemu/` owns host-side VM tools.

The build carries the package manifest, repository list, and small setup
assets. After the live DHCP/DNS preflight and disk setup, the installer uses
`apk --root --initdb --no-scripts`. `rootfs/configure.sh` applies accounts,
service links, fonts, and kernel-hook configuration. Alpine's package hook
lifecycle runs after the root UUID is substituted and the EFI system partition
is mounted at `/boot`.

## Boot and session

The target boots through UEFI and Alpine's packaged kernel hooks, without
GRUB. The kernel command line uses `root=UUID=...`. The hook writes
`/boot/EFI/alpine/linux-lts.efi`; `60-home-fallback` copies regenerated images
to `/boot/EFI/BOOT/BOOTX64.EFI`. Both images are unsigned, so Secure Boot is
unsupported.

The session chain is tty1 autologin as `josh`, guarded `home-login`,
`home-session`, dwl, and foot. Only tty1 starts the compositor. Serial and
recovery VTs use ash, and `HOME_SESSION_DISABLE=1` bypasses graphical startup
for a manually launched login shell. `home-runtime` creates
`/run/user/1000` as a private, user-owned directory before the session.

The pinned dwl source receives two build-time configuration edits: `Ctrl+Return`
starts another foot terminal, and the example `wmenu-run` binding is removed
because wmenu is not installed. There is no repository-owned dwl package,
runtime config, wrapper, or hotkey daemon.

## Runtime boundaries

eudev is the target device manager and seatd provides seat access. BusyBox
`mdev` is enabled only in the live installer for early device discovery; it is
not an installed OpenRC device manager. The target does not include Xorg or
XWayland, a display manager, desktop shell, SSH server, PulseAudio, PipeWire,
D-Bus daemon, elogind daemon, or polkit.

The packaged kernel, Intel microcode and firmware, Mesa DRM/EGL/GBM, wlroots,
libinput, seatd, foot terminfo, and one monospace font remain in the target for
the physical laptop even though QEMU does not exercise every component.

Definitions: [`Dockerfile`](../Dockerfile),
[`rootfs/configure.sh`](../rootfs/configure.sh),
[`rootfs/home-login`](../rootfs/home-login),
[`rootfs/home-session`](../rootfs/home-session), and
[`rootfs-packages.txt`](../rootfs-packages.txt).
