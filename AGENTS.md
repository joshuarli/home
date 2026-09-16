# Home installer engineering contract

This repository builds a purpose-specific Alpine `3.24.1` `linux/amd64`
installer for an Intel-only Dell XPS 13 9343. It is not a general Alpine
installer and does not currently support arbitrary hardware.

## Product invariants

- `make build` is the normal artifact build and exports
  `dist/home-installer.iso` plus rootfs/ISO metadata.
- The target boots through UEFI and Alpine's packaged kernel hooks. It does
  not install GRUB. The root command line uses `root=UUID=...`.
- The installed EFI image is written to both
  `/boot/EFI/alpine/linux-lts.efi` and `/boot/EFI/BOOT/BOOTX64.EFI`.
  `/etc/kernel-hooks.d/60-home-fallback` keeps the fallback current after
  later kernel regeneration.
- Secure Boot is unsupported until a signing key and trust model exist.
- The session is `tty1` autologin as `josh` -> guarded `home-session` -> dwl
  -> one foot terminal. The pinned dwl v0.8 build binds `Ctrl+Return` to a
  second foot terminal.
- Alpine 3.24.1 has no `dwl` package. `Dockerfile` makes only two pinned-source
  configuration edits: `Ctrl+Return` launches foot, and the unusable
  `wmenu-run` example binding is removed. Do not add a repository-owned dwl
  package/config, wrapper, hotkey daemon, or moving branch.
- `josh` is passwordless, root is locked, and `doas` is passwordless. These
  are explicit insecure MVP assumptions.
- `home-login` must never start dwl for serial, recovery VTs, or ordinary ash
  invocations. `/run/user/1000` is private and user-owned before the session.
- eudev is the only target device manager; seatd supplies seat access. Do not
  add a second installed device-manager service. BusyBox `mdev` is permitted
  only as the early initramfs/live-installer block-device helper; it is not the
  running target's device manager. D-Bus, elogind, and polkit likewise require
  a demonstrated contract requirement.
- The target has no Xorg/XWayland, PulseAudio, PipeWire, display manager,
  desktop shell, SSH server, or general-purpose distro framework.
- Intel microcode, Intel firmware, the packaged kernel, Mesa DRM/EGL/GBM,
  wlroots, libinput, seatd, foot terminfo and one monospace font are retained
  even when QEMU does not exercise the physical hardware.

## Ownership and boundaries

- `rootfs-packages.txt` is the authoritative direct target package list.
  `iso/mkimg.home_installer.sh` owns live-installer packages. Docker build
  dependencies and host/QEMU tools belong in neither list.
- `Dockerfile` pins the Codeberg `dwl` v0.8 source checksum and builds its
  minimally configured binary in a build-only stage; runtime libraries remain
  Alpine packages in `rootfs-packages.txt`.
- The alternate-root build uses `apk --root --initdb --no-scripts` because the
  initial package transaction must not generate an EFI payload before the
  target filesystem UUID and ESP mount exist. `rootfs/configure.sh` and
  `build/build-rootfs.sh` explicitly recreate required account, service, font,
  BusyBox applet and boot-hook side effects; the installer then uses Alpine's
  package hook lifecycle after UUID substitution. A successful archive alone is
  not proof.
- `installer/install.sh` is the destructive boundary. It must preserve UEFI
  and Secure Boot checks in QEMU, accept only whole disks, exclude installer
  media and mounted/protected disks, require explicit confirmation for a
  physical disk, use bounded partition polling, restore terminal echo, and
  clean up owned processes/mounts on failure.
- The physical target retains Intel Wi-Fi discovery and credential
  persistence. QEMU supplies only an explicitly seeded Ethernet interface and
  disposable disk; it must not bypass generic safety checks.

## QEMU acceptance loop

`make doctor` inspects the installed QEMU's Q35, Broadwell, SATA, virtio GPU/
input and display capabilities. The host uses native x86_64 QEMU with TCG on
macOS arm64; it does not run QEMU inside Docker or claim HVF acceleration.

`make test` boots the actual ISO through a matched OVMF CODE/VARS pair, with
the ISO presented as USB storage and the target as SATA/AHCI. It never uses
`-kernel`/`-initrd`. An explicit fw_cfg seed starts the real installer with
`/dev/sda`, waits for its clean poweroff, then boots the installed disk with
the ISO detached. The harness checks session ownership, seat/DRM/Wayland
facts, screenshots, Ctrl+Return behavior, terminal command output, recovery
VT/session lifecycle, reboot without networking, fresh-vars EFI fallback, and
kernel-hook regeneration on a disposable copy.

The pinned OVMF bundle does not publish a SecureBoot efivar. The test passes
an explicit fw_cfg disabled fact for that firmware limitation; the installer
still requires UEFI, rejects any published enabled variable, and refuses to
run without the explicit fact. This is distinct from bypassing disk safety.

`make run` shares the same VM construction and boots the retained disk with a
native display. Generated VM disks, variables, serial/QEMU logs, invocation
files and screenshots belong under `dist/qemu/`. Host overrides are rejected
when they point at block devices, symlinks, non-regular files or paths outside
that generated directory.

`make run` is a retained-disk iteration shortcut, not fresh-install evidence.
Successful `make test` writes `dist/qemu/disk.fingerprint.json`, binding the
retained disk to the ISO, product-source files, OVMF templates, and QEMU
profile. `make run` must reject a missing or stale fingerprint and direct the
user to `make test` before booting it again.

The installer network preflight is bounded. DHCP and DNS failures are
advisory in both modes because the payload is embedded; physical installation
still requires an Intel wireless interface so its tested Wi-Fi configuration
can be persisted. This is a provisioning policy, not a requirement for the
installed desktop to have network access at boot.

QEMU proves the installer and software session only. It does not certify
i915, Intel wireless firmware, the Dell touchpad/panel, audio, suspend/resume,
or power management; those remain physical-hardware checks.

The QEMU profile is an explicit XPS-like approximation: native x86_64 QEMU
under TCG, a supported Q35 machine, Broadwell-class CPU selection, SATA/AHCI
storage, one explicit std VGA/bochs DRM GPU rendered by pixman, virtio input,
and user-mode Ethernet. Dell's XPS 13 9343
specification identifies fifth-generation Intel Core processors and M.2
removable storage; those facts motivate the CPU/storage approximation but do
not establish the exact physical CPU, memory, panel or wireless PCI ID.
`make doctor` checks the installed QEMU capabilities; unsupported features are
not silently treated as equivalent hardware.

Build metadata separates compressed artifacts from installed filesystem size
and records package/archive/ISO facts. Acceptance metadata records per-run
source/profile/firmware hashes, enabled services, steady-state process count,
idle available memory and boot-to-terminal timing, but does not establish
bit-for-bit reproducibility or a historical before/after baseline. Retained
firmware, kernel, Intel graphics support, and input/network dependencies are
intentional size tradeoffs and must be described with their measured sizes
when measurements are available.

## Change and verification rules

Before editing, inspect definitions, callers, tests and the nearest hard
judge. Keep names and package ownership explicit. For a bug, add the smallest
isolated regression test before changing the cause. Preserve comments that
explain non-obvious boot, security or lifecycle constraints.

Run focused checks first:

```sh
make check
make doctor
make build
make size
make test
```

Do not run formatters, linters, pre-commit hooks, or push to a remote unless
the user explicitly asks. Do not add dependencies without consulting the
user. Keep generated artifacts, credentials, temporary aports trees and
private signing keys out of version control.
