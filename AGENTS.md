# Project guide

This repository builds a network-first Alpine 3.24.1 `linux/amd64` installer for the Intel-only Dell XPS 13 9343; arbitrary hardware is unsupported.

## Commands

- Checks/build/run: `make check`, `make doctor`, `make build`, `make size`, `make test`, and `make run`; the last requires the current `dist/qemu/disk.fingerprint.json` written by `make test`.

## Invariants

- The target rootfs is fetched over the live network, not embedded in the ISO.
- UEFI and Alpine kernel hooks boot the target with `root=UUID=...`, keep both EFI image paths current, and do not install GRUB; Secure Boot is unsupported.
- tty1 autologins as passwordless `josh` into guarded `home-session`; root is locked, `doas` is passwordless, and `/run/user/1000` is private and user-owned.
- `home-login` never starts dwl on serial, recovery VTs, or ordinary ash invocations.
- Pinned dwl v0.8 binds `Ctrl+Return` to a second foot terminal and removes the `wmenu-run` example; Alpine 3.24.1 has no dwl package, so do not add a local package/config, wrapper, hotkey daemon, or moving branch.
- eudev is the sole target device manager and seatd provides seat access; BusyBox `mdev` is limited to the live installer.
- `rootfs-packages.txt` owns target packages, `iso/mkimg.home_installer.sh` owns live packages, and Docker/host dependencies belong in neither list.
- The installer requires UEFI, Secure Boot disabled, successful DHCP/DNS, whole-disk selection, explicit physical confirmation, and the same safety checks in physical and QEMU installs.
- `make test` proves network failure leaves the disk unchanged and runs the real installer with matched OVMF firmware; `make run` rejects a missing or stale disk fingerprint.

## Topic guides

- Installation flow and disk safety: [docs/installation.md](docs/installation.md)
- Boot, session, packages, and runtime boundaries: [docs/architecture.md](docs/architecture.md)
- Build commands and generated artifacts: [docs/development.md](docs/development.md)
- QEMU profile and acceptance evidence: [docs/testing.md](docs/testing.md)
- ISO size report: [docs/size-report.md](docs/size-report.md)
