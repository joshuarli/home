# Home installer

This repository builds a deliberately narrow Alpine Linux image for the
Intel-only Dell XPS 13 9343 target. The installed system boots an Alpine
kernel-generated unsigned EFI image directly into `dwl`, with one `foot`
terminal already open. Upstream dwl's `Alt+Shift+Return` opens another
terminal.

The image keeps the existing MVP account policy: `josh` is passwordless,
root is locked, and `josh` may use passwordless `doas`. That is an intentional
physical-access assumption, not a secure general-purpose default.

## Build and development loop

The build runs in Docker Buildx as `linux/amd64`, compiling pinned upstream
dwl v0.8 because Alpine 3.24.1 does not package it. QEMU runs natively on the macOS host under TCG; an Intel guest is
not treated as HVF-accelerated on an arm64 Mac.

```sh
make doctor                 # host QEMU/Docker capability checks
make check                  # shell, layout, safety and static contract tests
make build                  # writes dist/home-installer.iso and metadata
make test                   # fresh ISO install, UEFI boot and GUI acceptance
make run                    # graphical boot of the retained installed disk
```

`make test` recreates only `dist/qemu/disk.img` and other generated files
under `dist/qemu/`. It is destructive to that disposable VM state. It never
accepts a block device, symlink, or arbitrary existing file as the test disk.
`make clean` removes `dist/` and therefore removes the retained VM and build
artifacts.

The QEMU test uses a Q35 machine, a Broadwell CPU model, TCG, SATA/AHCI
storage, virtio GPU/input, and user-mode Ethernet. Dell's [XPS 13 9343
Owner's Manual, Specifications](https://www.dell.com/support/manuals/en-us/xps-13-9343-laptop/xps13-9343_om/specifications)
identifies the platform's processor family as fifth-generation Intel Core and
its removable storage as M.2; the QEMU choices are therefore an explicit
Broadwell-class/SATA approximation, not an exact machine model.
The exact installed CPU, memory, panel, and wireless PCI ID remain unknown
until the laptop is inspected. The generated ISO is attached as a CD and
booted through the pinned OVMF CODE/VARS pair; the test
does not use `-kernel` or `-initrd`. An explicit fw_cfg seed supplies the
disposable `/dev/sda` target and test network interface to the real installer
service. No DMI string triggers installation.

The pinned OVMF bundle used by this test does not publish a SecureBoot
efivar. The real installer still requires UEFI and refuses an enabled
SecureBoot variable; for this known OVMF limitation, the explicit test
fw_cfg seed states disabled. Missing or different seed data still fails, as
do all generic disk-safety checks.

If the pinned firmware is absent, `make test` fetches and verifies it with
`fetch-edk2-ovmf.sh`. `OVMF_CODE` and `OVMF_VARS` must be supplied together
when overriding it. `make run` opens the native QEMU display backend when one
is available; set `QEMU_DISPLAY` to select another backend.

## Boot and session chain

The installed path is:

```text
UEFI -> EFI/BOOT/BOOTX64.EFI or EFI/alpine/linux-lts.efi
     -> Alpine kernel/initramfs -> OpenRC/eudev/seatd
     -> tty1 autologin as josh -> home-session -> dwl -> foot + ash
```

The root filesystem is identified by GPT `PARTUUID`. Kernel hooks generate
`/boot/EFI/alpine/linux-lts.efi`; the executable fallback copy at
`/boot/EFI/BOOT/BOOTX64.EFI` is refreshed by the kernel-hook directory after
future kernel regeneration. Secure Boot is intentionally unsupported because
the image is unsigned.

`home-login` starts the compositor only for the tty1 autologin. Serial and
recovery VTs remain ordinary ash shells. `home-runtime` creates
`/run/user/1000` as a private, user-owned directory before `seatd` and the
session starts. Closing every terminal leaves `dwl` alive, and the compositor
exit path returns to a recovery shell instead of an autologin crash loop.

For recovery, switch to `tty2` with `Ctrl+Alt+F2` and log in normally. When
starting a shell manually, set `HOME_SESSION_DISABLE=1` before invoking the
login shell; this is the documented bypass for GUI startup. It prevents an
ordinary ash invocation from starting another compositor. `Alt+Shift+q`
intentionally exits `dwl` and returns to the recovery shell.

Useful bindings are `Alt+Shift+Return` for `foot`, `Alt+j/k` for focus,
`Alt+Shift+c` to close a client, `Alt+Shift+q` to exit dwl, and
`Ctrl+Alt+F2` for a recovery VT. The upstream stock v0.8 configuration also
contains its example `Mod+p` binding for `wmenu-run`; `wmenu` is intentionally
not installed because this image has no launcher. That example is therefore
dormant, and no local dwl config or wrapper is added to change upstream
behavior.

## Runtime boundaries

`rootfs-packages.txt` is the direct installed package manifest. Alpine
resolves its transitive closure; the rootfs and ISO metadata written by the
build record resolved counts, filesystem/archive sizes, versions and the ISO
checksum. Build headers, signing keys, the temporary emulator and installer
tools remain outside the target rootfs. The live ISO has its own package list.

The target intentionally has no Xorg/XWayland, D-Bus daemon, elogind daemon, polkit,
PulseAudio, PipeWire, display manager, desktop shell, SSH server, VA-API
driver stack, or compositor framework beyond dwl/wlroots/libinput/seatd.
The Mesa DRM/EGL/GBM pieces, eudev, Intel firmware/microcode, one DejaVu
monospace font, foot terminfo and the packaged kernel are retained because
they are part of the actual boot/session contract.

The resolved closure currently retains the small `dbus-libs` library required
by Alpine's WPA supplicant build and `libelogind` required by Alpine's
libseat package. Neither D-Bus nor elogind is enabled as a service, and the
build metadata records these transitive exceptions explicitly.

## Recovery and physical installation

The recovery VTs and serial console use ash. If the graphical session exits,
use `Ctrl+Alt+F2`; `HOME_SESSION_DISABLE=1` also bypasses the guarded launcher
when starting a login shell manually. The root account remains locked, so
external media or a rebuilt image is the recovery path for a lost user
account.

The physical installer requires UEFI with Secure Boot disabled, an Intel
wireless adapter, and an explicit whole-disk confirmation. It persists the
tested Wi-Fi credentials with mode `0600`, creates a 512 MiB EFI partition,
1 GiB swap, and an ext4 root partition using the remaining space. DHCP and
DNS are bounded preflight checks: failures are advisory because the prepared
installation payload is embedded, while the tested Wi-Fi configuration is
still persisted for first boot. The laptop disk is intentionally not
selectable as a generic removable target; always use a backed-up or
disposable disk.

The installed target uses eudev and seatd for normal device discovery and
seat access. BusyBox `mdev` is a narrowly scoped initramfs/live-installer
helper for early block-device discovery and is not an installed OpenRC device
manager. It does not replace eudev in the running target.

`make test` always creates a fresh disposable install. On success it writes
`dist/qemu/disk.fingerprint.json`, binding the retained disk to the ISO hash,
product-source hashes, OVMF hashes, and the QEMU profile. `make run` is a
session-iteration shortcut, not fresh-install evidence; it refuses to boot a
missing or stale fingerprint and tells you to run `make test`. `make clean`
removes this retained state.

## Validation boundary

| Evidence | Current scope |
| --- | --- |
| QEMU acceptance test | ISO firmware boot, real installer, GPT/filesystems, rootfs extraction, kernel hook, EFI fallback, dwl/foot session, screenshot, input chord, recovery, reboot, offline boot, fresh-vars fallback, and hook regeneration |
| Static/host checks | shell syntax, partition naming and sector-size layout, generated-file safety, package/boot/session contracts, QEMU capability inspection |
| Physical hardware still required | Intel i915/Mesa behavior, Intel Wi-Fi firmware and reconnection, Dell touchpad/libinput behavior, panel modes/backlight, suspend/resume, audio codec, thermal and power management |

QEMU Ethernet does not test Wi-Fi, virtio graphics does not certify i915,
and virtual input does not reproduce the Dell touchpad. The VM screenshots
and process facts are acceptance evidence for the development loop, not a
claim that the laptop hardware has already been certified.

## Artifacts, measurements, and evidence

The build writes separate metadata for the rootfs and ISO. Rootfs metadata
describes the direct package manifest, resolved package count, installed
filesystem size, largest package contributors, and resolved package names. ISO
metadata records the Alpine release, aports revision, compressed rootfs
archive size, ISO size, and ISO SHA-256. These are build facts, not a
reproducibility claim and not a measure of the installed disk footprint. The
partitioned QEMU disk capacity is also distinct from used filesystem space.

The acceptance harness retains serial/QEMU logs, invocation data, screenshots,
firmware variables, per-run metadata, and other stage artifacts under
`dist/qemu/`. Its metadata captures the ISO and firmware hashes, source/profile
fingerprints, process/session facts, idle available memory, and boot-to-usable-
terminal timing for that run. Screenshots, process/session facts, and
behavioral observations are used together; a timeout, missing observation, or
unavailable required stage is not a pass. No historical before/after baseline
is claimed because this repository has no valid prior measurement. TCG timings
are host- and configuration-dependent and must not be read as laptop
performance. The retained runtime dependencies (including Intel firmware,
Mesa DRM/EGL/GBM, kernel, wlroots/libinput/seatd, foot terminfo, and the font)
are deliberate size tradeoffs for physical hardware coverage; no claim of
minimality is made without a measured comparison.
