# Home Installer

This repository builds a purpose-specific Alpine Linux installer for an amd64
Intel laptop. It is deliberately narrower than a general Alpine installer:
the installed system is preconfigured at build time, and the live ISO exists
only to boot the machine, establish temporary network access, partition the
selected disk, and unpack the prepared system.

The current target hardware is an Intel-only Dell XPS 13 9343. The project is
not intended to support arbitrary hardware yet. In particular, the installer
expects UEFI boot, an Intel wireless adapter, and an x86_64 target.

## Product goals

The primary command is:

```sh
make build
```

This builds an amd64 `home-installer.iso` using Alpine `3.24.1` as the Docker
build environment. The resulting artifact is written to `dist/`.

The installed system should:

- boot through Alpine's kernel and OpenRC userspace;
- use an EFI System Partition and an EFI-stub/UKI-style boot image generated
  by Alpine's kernel hooks;
- have a minimal home directory for the user `josh`;
- auto-login `josh` on tty1 into `/bin/ash`;
- provide `doas` instead of `sudo`;
- lock the root account;
- use a passwordless `josh` account for this MVP;
- use DHCP networking over the selected Wi-Fi interface;
- use `America/Los_Angeles` and `en_US.UTF-8`;
- treat the hardware RTC as UTC;
- provide ALSA libraries only for audio;
- provide the foundational Wayland, libinput, seat management, Mesa, and Intel
  VA-API packages without installing a compositor yet;
- contain no PulseAudio, PipeWire, Xorg server, or XWayland package.

The passwordless account and passwordless `doas` rule are intentional MVP
choices, not secure defaults. Do not use this image on a machine or network
where those assumptions are unacceptable.

## Repository structure

### `Makefile`

The Makefile is intentionally small. `make build` invokes Docker Buildx with
`--platform linux/amd64` and exports the final scratch-stage artifact into
`dist/`. This makes the build work from an arm64 development host while
producing an amd64 ISO.

`make clean` removes only `dist/`.

### `Dockerfile`

The Dockerfile has three conceptual stages:

1. `rootfs` starts from Alpine `3.24.1`, installs the tools needed to assemble
   an x86_64 filesystem, installs the target package list into an alternate
   root, configures it, runs smoke checks, and creates `/work/out/rootfs.tar.gz`.
2. `iso` starts from Alpine `3.24.1`, installs Alpine's image-building tools,
   clones the matching Alpine `aports` branch, builds the custom ISO profile,
   and creates `/work/out/home-installer.iso`.
3. `artifact` is a scratch stage containing only `/home-installer.iso`.

The build intentionally uses the current Alpine package repositories rather
than compiling software locally. Alpine's kernel, firmware, initramfs,
modloop, Syslinux, and GRUB assets are supplied by Alpine packages and the
official `mkimage.sh` workflow.

The ISO build includes two compatibility measures for modern Alpine:

- Alpine's current `apk` no longer accepts the historical `--no-chown`
  argument still present in the checked-out `mkimage.sh`, so the build removes
  that argument before invoking the script.
- A temporary `abuild` signing key is generated inside the ISO build stage so
  Alpine can create the live package index. The key is ephemeral and is not
  included in the repository or installed target system.

### `rootfs-packages.txt`

This is the authoritative direct package list for the installed system. Keep
it explicit and small. Dependencies are resolved by `apk`, but packages should
not be added merely because they are convenient during development.

The list is grouped conceptually as follows:

- Alpine base, kernel, Intel microcode, and Intel firmware;
- account and console tools: `doas`, `agetty`, `less`, and `nano`;
- DHCP/networking: `iproute2`, `ifupdown-ng`, Wi-Fi integration, and
  `wpa_supplicant`;
- locale and time configuration: `musl-locales` and `tzdata`;
- ALSA library only;
- Wayland protocol/runtime foundations, `libinput`, and `seatd`;
- Mesa EGL/GBM/DRI/VA-API pieces;
- Intel media driver and `libva-utils`;
- Alpine EFI-stub and kernel-hook packages.

There is deliberately no audio server, Wayland compositor, desktop shell,
display manager, X server, SSH server, editor suite, NTP daemon, or general
development toolchain in the target package list.

Some transitive dependencies may contain X11 protocol libraries. That does not
mean X is supported or installed: the project policy is specifically to avoid
X servers and XWayland. Do not remove a harmless transitive library without
checking which VA-API or graphics package requires it.

### `rootfs/configure.sh`

This script performs target filesystem configuration after packages have been
installed into the alternate root. It runs on the build host, not inside the
target chroot, because the build may be cross-architecture.

It is responsible for:

- installing BusyBox links and setting `/sbin/init`;
- creating `/home/josh` with UID/GID 1000;
- creating the `josh` account and adding it to `wheel` and `seat` where
  available;
- creating a passwordless `josh` shadow entry and locking root;
- installing the `doas` rule permitting `josh` to become root without a
  password;
- setting hostname, timezone, locale environment, `/etc/adjtime`, and hosts;
- creating the initial network configuration containing loopback only;
- writing the kernel-hook command line template;
- replacing the default tty entries with tty1 auto-login;
- enabling the Alpine `hwclock` service in the boot runlevel;
- installing `/bin/fetch.sh`, which captures hardware, kernel, graphics,
  audio, networking, firmware, storage, package, and Alpine service diagnostics
  to `/tmp/fetch.log` while also printing them to the terminal;
- removing the target APK cache.

The placeholder `INSTALLER_ROOT_PARTUUID` is replaced by the installer after
partitioning. It must not be replaced during the image build because the
target disk does not exist yet.

After booting the installed system, run `/bin/fetch.sh` to collect a broad
hardware and software diagnostic report. It prints the report and writes it to
`/tmp/fetch.log`; use `doas /bin/fetch.sh` when unrestricted kernel and device
access is needed. Wi-Fi credentials are redacted from the report.

### `build/build-rootfs.sh`

This script creates the target root filesystem at `/work/rootfs`.

Packages are installed with `apk --root`, `--initdb`, and `--no-scripts`. This
keeps the build deterministic and avoids executing target-architecture package
scripts during a cross build. The configuration script then supplies the
small amount of machine-independent setup needed before first boot.

The smoke test has two paths:

- native builds chroot into the rootfs and execute Alpine commands inside it;
- cross builds use the target `apk` and filesystem inspection without trying to
  execute amd64 binaries on the build host.

Both paths check the init symlink, account, shell, home directory, agetty,
Wayland library, ALSA library, VA-API utility, doas configuration, and absence
of the explicitly forbidden package names. A temporary `qemu-x86_64` binary is
used only if needed by the build process and is deleted before the archive is
created.

The final archive is a gzip-compressed tarball with numeric ownership, ACLs,
and extended attributes preserved. It is embedded into the ISO rather than
being copied as a separate distribution artifact.

### `iso/mkimg.home_installer.sh`

This is the custom Alpine `mkimage` profile. It starts from `profile_base`,
not the broad Alpine standard profile, so the live environment does not pull
in unrelated services and utilities.

The profile adds only the live installer requirements:

- the Alpine base and x86_64 LTS kernel;
- Intel firmware;
- Wi-Fi and DHCP support;
- partitioning, filesystem, EFI, archive, and networking tools.

The profile disables modloop signing because this repository does not carry a
trusted private signing key. The resulting installer therefore requires
Secure Boot to be disabled. The profile retains Alpine's normal ISO boot
generation, including the official initramfs, modloop, Syslinux path, and EFI
GRUB path.

The profile name uses an underscore (`home_installer`) because `mkimage.sh`
turns profile names into shell function names. Do not change it to a hyphenated
profile name without also changing Alpine's profile-loading behavior.

### `iso/genapkovl-home-installer.sh`

This generates the Alpine overlay loaded by the live ISO. It embeds:

- `/root/home-installer/install.sh`;
- `/root/home-installer/rootfs.tar.gz`;
- the live image's minimal package world;
- the basic OpenRC runlevel links required for a usable live boot.

The overlay is created under `fakeroot` by Alpine's `mkimage.sh`, so its
ownership and permissions must be specified explicitly. Keep the installer
script executable and the rootfs archive readable only as needed by root.

### `installer/install.sh`

The installer is intentionally linear and interactive. It does not invoke
`setup-alpine`.

Its flow is:

1. Verify root, UEFI mode, required commands, the embedded archive, and
   disabled Secure Boot.
2. Discover Intel wireless interfaces by checking the PCI vendor ID and the
   wireless sysfs directory.
3. Ask for the Wi-Fi SSID and passphrase without echoing the passphrase.
4. Start temporary `wpa_supplicant`, obtain a DHCP lease, and verify DNS before
   touching any disk.
5. Identify the installation media and list whole-disk target candidates.
6. Require the user to enter the target device path twice before destructive
   operations.
7. Wipe the target, create a GPT, and create:
   - a 512 MiB FAT32 EFI System Partition;
   - a swap partition sized to twice the live system's detected RAM;
   - an ext4 root partition using the remaining space.
8. Mount root and `/boot`, extract the prepared rootfs, write `fstab`, and
   persist the tested Wi-Fi configuration and DHCP interface.
9. Bind-mount `/dev`, `/sys`, `/run`, and `/proc` into the target chroot.
10. Add networking and Wi-Fi OpenRC services, substitute the root partition
    PARTUUID into the kernel-hook configuration, and run
    `apk fix kernel-hooks` to generate the target EFI image.
11. Copy the generated EFI image to both an Alpine-specific EFI path and the
    removable-media fallback path, then attempt to create an EFI NVRAM entry.
12. Unmount the target and report completion.

The installer only accepts whole disks, handles the `p1` naming convention for
NVMe and MMC devices, and refuses to select the detected installer disk. The
disk layout is intentionally not configurable in this MVP.

## Boot architecture

The current boot design is intentionally conservative: use the laptop's
existing UEFI firmware, Alpine's official kernel/initramfs construction for
the live ISO, and a direct EFI-stub/UKI image for the installed system. This
keeps the project focused on prebuilding userspace rather than replacing
firmware or maintaining a general-purpose boot menu.

There are three separate boot layers:

1. **Platform firmware.** The laptop's built-in UEFI firmware initializes the
   machine and loads an EFI executable from the EFI System Partition.
2. **Live installer boot.** Alpine's `mkimage.sh` creates the ISO using
   Alpine's kernel, initramfs, modloop, and official ISO boot assets. The live
   ISO is a temporary environment and is not copied onto the installed disk.
3. **Installed-system boot.** Alpine's `kernel-hooks` package generates an EFI
   image containing the target kernel and boot data. The installer copies that
   image to:

   ```text
   /boot/EFI/alpine/alpine.efi
   /boot/EFI/BOOT/BOOTX64.EFI
   ```

   The second path is the removable-media/default EFI fallback path and means
   the system can boot even if creating a persistent UEFI NVRAM entry fails.

The installer attempts to create an `Alpine` NVRAM entry with `efibootmgr`, but
that is an optimization rather than a boot requirement. The fallback EFI path
is authoritative for recovery and portability.

### Why the installed system does not use GRUB

The target package list does not include GRUB. The installed system boots the
EFI image directly, so it does not need a boot menu, filesystem drivers in a
separate bootloader, or a second configuration language. This is the smallest
reasonable path for the current single-kernel, single-rootfs design.

The live ISO may still contain GRUB because Alpine's standard `mkimage.sh`
workflow uses it for the ISO's UEFI boot path. That is an installer-media
dependency, not an installed-system dependency. Removing it from the ISO is a
possible later optimization, but it should be treated separately from the
installed boot design and verified against both UEFI and BIOS boot paths.

### Why coreboot and U-Boot are out of scope

Coreboot is platform firmware, not a universal replacement for a laptop's
UEFI implementation. A coreboot image is board-specific and can require
vendor firmware blobs, exact chipset initialization, and careful flashing and
recovery procedures. U-Boot can be used as a coreboot payload on some x86
systems, but that does not make the combination broadly portable across
consumer laptops.

Adopting coreboot would turn this repository into a firmware-porting project
and would introduce a substantially higher-risk operation before the Alpine
userspace installation is validated. It must not be added as an installer
feature without an explicit hardware-specific project decision.

### Why SeaBIOS is not the current default

SeaBIOS provides legacy BIOS services. It does not provide UEFI NVRAM boot
entries, and a SeaBIOS installation would require a separate legacy boot path,
such as MBR/GPT boot code plus Syslinux/extlinux. That path is useful for
legacy-only machines but is not interchangeable with the current UEFI EFI
stub path.

Supporting both would require a deliberate dual-mode layout and two boot
validation paths. It would also make the fixed UEFI-first design less clear.
For now, the project requires UEFI and keeps legacy BIOS support as a future
profile rather than adding it to the MVP.

If legacy support becomes necessary, Syslinux/extlinux is the first candidate
to investigate because Alpine already supports it and it is materially simpler
than introducing GRUB into the installed system. It should be implemented as a
separate boot profile, not by weakening or replacing the existing UEFI path.

### Boot invariants

Changes to the boot implementation should preserve these properties unless the
project scope changes explicitly:

- the installed target does not depend on GRUB;
- the installed target can boot through the EFI fallback path without an NVRAM
  entry;
- the kernel command line identifies the root filesystem by PARTUUID;
- `/boot` remains a 512 MiB FAT32 EFI System Partition;
- the target kernel image is generated by Alpine's kernel hooks rather than by
  a custom kernel build;
- the live ISO and installed target remain separate artifacts with separate
  dependency budgets;
- Secure Boot remains explicitly unsupported until signing keys and a trust
  model are designed.

The Wi-Fi passphrase is stored in the installed `wpa_supplicant.conf` because
the target is expected to reconnect automatically. The generated `#psk`
comment is removed so the plaintext passphrase is not duplicated in the
configuration file. The file remains protected with mode 0600.

## Build and verification

Run the syntax checks and build from the repository root:

```sh
sh -n installer/install.sh \
  rootfs/configure.sh \
  build/build-rootfs.sh \
  build/build-iso.sh \
  iso/mkimg.home_installer.sh \
  iso/genapkovl-home-installer.sh

make build
```

The build requires Docker with Buildx and network access to Alpine package
repositories and the Alpine `aports` Git repository. The build may take several
minutes because Alpine's kernel modloop and the final ISO are compressed from
scratch.

The artifact should be inspected before writing it to removable media. A
successful build proves package assembly, cross-architecture filesystem
checks, ISO generation, and overlay embedding. It does not prove that the
installer has been run on physical hardware.

The first hardware test should use a disposable or fully backed-up target
disk. The installer is intentionally destructive after the explicit disk
confirmation, and the current project has no recovery or rollback mechanism.

## Security and operational assumptions

- Secure Boot must be disabled. The live image and generated target EFI image
  are not signed by a project-controlled key.
- The `josh` account has no password and can use `doas` without a password.
- Root is locked, so recovery should be performed from external media or by
  changing the image configuration before rebuilding.
- The installer obtains the Wi-Fi secret interactively and persists it on the
  installed disk.
- No NTP service is installed or enabled. The hardware clock is treated as
  UTC, and Alpine's `hwclock` service is enabled at boot.
- No remote administration service is enabled. SSH is intentionally out of
  scope for the MVP.
- The installer does not encrypt the disk, configure TPM measured boot, or
  implement secure boot signing.

## Deliberate non-goals

The following should not be added casually:

- PulseAudio or PipeWire;
- Xorg, XWayland, or an X compatibility session;
- a Wayland compositor or desktop environment before the console-first MVP is
  validated;
- a display manager;
- NTP/chrony/openntpd;
- LVM, RAID, encryption, Btrfs, or selectable partition layouts;
- arbitrary Wi-Fi hardware support;
- password prompts or interactive account setup during installation;
- software compilation as part of the image build;
- general-purpose system administration features that belong in a later image
  profile.

When expanding the system, prefer adding a small, explicit package or feature
and a corresponding smoke test. Keep installer-only dependencies in the ISO
profile and target-system dependencies in `rootfs-packages.txt`; putting a
package in both lists increases bloat and obscures ownership.

## Change guidance

Changes to the rootfs configuration can affect first boot, kernel-hook output,
and the installer archive. Changes to the ISO profile can affect the live
environment, boot chain, package index, and final artifact size. Changes to
the installer can erase data or leave a partially installed disk, so review
those changes especially carefully.

Do not replace the official Alpine kernel or boot-chain generation with a
locally built kernel unless the project goals change explicitly. The purpose of
this repository is to prebuild the userspace and streamline installation, not
to become a kernel or software distribution project.

Keep generated artifacts under `dist/`; do not commit Docker build caches,
temporary `aports` checkouts, extracted ISO contents, Wi-Fi credentials, or
private signing keys.

## QEMU integration test

The project has two host-side QEMU commands in addition to the Docker build:

```sh
make test
make login
```

These commands intentionally do not run QEMU inside Docker. Docker remains the
reproducible ISO/rootfs builder; QEMU runs on the developer's macOS host using
the host's `qemu-system-x86_64` and `qemu-img` binaries.

`make test` first checks for the required host QEMU tools, builds the ISO, and
creates a fresh 8 GiB raw test disk at `dist/qemu/disk.img`. It extracts the
official Alpine kernel and initramfs
from that ISO and boots them directly with QEMU while attaching the ISO as
read-only virtio installer media. This keeps the installer test focused on the
live system and avoids a known interaction between Alpine's generated UEFI
GRUB ISO path and the embedded `.apkovl` payload. The test uses:

- x86_64 emulation;
- a `pc` machine with four virtual CPUs and 1 GiB RAM;
- a fixed 256 MiB swap partition, rather than the physical installer's 2×RAM
  policy;
- a virtio target disk, which appears to the guest as `/dev/vda`;
- QEMU user-mode networking, which appears as `eth0` and supplies DHCP;
- serial output captured in `dist/qemu/test.log`.

The live overlay contains a one-shot OpenRC service that detects QEMU through
the DMI identity and invokes the real installer with:

```text
IS_QEMU=1 INSTALLER_DISK=/dev/vda QEMU_NET_IFACE=eth0
```

The QEMU overlay also sets `FETCH_FIXTURE=1`. Before touching the target disk,
the installer extracts the prepared `/bin/fetch.sh` from the rootfs archive and
runs it against the live QEMU environment. It requires `/tmp/fetch.log` and a
completed diagnostic summary, so `make test` exercises the diagnostic tool as
well as the installer. This fixture is gated by both `IS_QEMU=1` and
`FETCH_FIXTURE=1` and cannot run during a physical installation.
The checked-in `qemu/fetch.fixture` is a detailed normalized golden transcript,
not just a presence check. `qemu/normalize-fetch.sh` canonicalizes only known
runtime noise such as timestamps, PIDs, UUIDs, MAC addresses, CPU calibration,
lease countdowns, and volatile memory counters; the remaining report must
match the fixture exactly. This keeps the QEMU diagnostic contract detailed
while avoiding false failures from runtime timing.

The test mode therefore skips only physical assumptions that QEMU cannot
represent in this test: Intel wireless discovery, WPA credential entry, and
the physical Secure Boot state. It still exercises the installer command
itself, DHCP/DNS through the virtual network, disk wiping and partitioning,
filesystem creation, rootfs extraction, target chroot setup, OpenRC service
registration, kernel-hook execution, EFI image creation, and EFI fallback/NVRAM
handling as far as the virtual firmware permits.

On successful installation, the live test service powers off the guest. The
raw disk is retained so the installed system can be booted independently.

`make login` boots that retained disk without the installer ISO and connects
the QEMU serial port to the terminal. It uses the pinned OVMF firmware and
boots the installed EFI-stub image, so this is the separate check of the
installed UEFI path. If the variable store is absent, `make login` creates a
fresh one from the pinned template. The target rootfs has a serial tty
auto-login entry, so it should present a `josh` ash shell after the EFI boot
path and root filesystem have been exercised.

QEMU uses a pinned EDK2 OVMF nightly fetched by `fetch-edk2-ovmf.sh`. The script
verifies the archive's pinned SHA256 checksum, downloads it only when the
verified archive and source marker are absent, and installs the x86_64 code and
variable templates under
`dist/qemu/firmware/edk2-ovmf-nightly/`. A local firmware pair under that path
is preferred; otherwise, if it is not available, provide
explicit paths:

```sh
make login \
  OVMF_CODE=/path/to/OVMF_CODE.fd
```

`make test` deliberately recreates the test disk on each run. The path is
inside `dist/qemu/`, but it is still a destructive test operation against the
previous test VM state. It does not touch physical disks. `make login` creates
or reuses only the generated variable store in that same directory.

The QEMU test does not validate real laptop hardware. It cannot establish that
the installed machine has an Intel wireless adapter, that the adapter's
firmware works, that the laptop's Broadcom/Intel configuration matches the
assumption, or that the laptop's display, keyboard, touchpad, audio codec, or
power-management behavior is correct. Those remain hardware validation steps.
