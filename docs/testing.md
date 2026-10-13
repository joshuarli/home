# Checks and QEMU acceptance

`make check` runs targeted shell, layout, installer-safety, static-contract,
QEMU-path, harness, graphics, size-report, and Python compilation checks.
`make doctor` verifies Docker Buildx and the installed QEMU capabilities needed
for the configured profile.

## Fresh-install acceptance

`make test` builds the ISO and boots it through a matched OVMF CODE/VARS pair.
The ISO is USB storage; the disposable target disk is SATA/AHCI. The harness
first runs the installer with networking disabled and verifies that the
mandatory network preflight fails before disk changes. It then provides an
explicit fw_cfg test seed to the real installer, waits for a clean poweroff,
and boots the installed disk with the ISO detached. It does not use QEMU's
`-kernel` or `-initrd` shortcuts.

The test checks target packages, accounts, services, seat and DRM access,
Wayland session ownership, terminal input and output, screenshots, recovery
VT behavior, reboot without network, EFI fallback boot, and kernel-hook
regeneration. The QEMU test uses a disposable disk under `dist/qemu/`; its
generated disks, variables, logs, screenshots, and stage metadata stay there.

The pinned OVMF bundle does not publish a SecureBoot efivar. For that firmware
limitation, the harness sends an explicit fw_cfg value stating Secure Boot is
disabled. The installer still requires UEFI, rejects an enabled variable, and
requires the explicit test input; generic disk-safety checks remain active.

The profile is a hardware approximation: x86_64 QEMU under TCG, Q35, a
Broadwell-class CPU, SATA/AHCI, std VGA/bochs DRM rendered by pixman, virtio
input, and user-mode Ethernet. On macOS arm64 it runs native x86_64 QEMU, not
QEMU inside Docker and not with HVF acceleration.

## Retained disk and evidence

On success, `make test` writes `dist/qemu/disk.fingerprint.json`, which binds
the retained disk to the ISO, product sources, OVMF templates, and QEMU
profile. `make run` is an iteration shortcut, not fresh-install evidence; it
refuses a missing or stale fingerprint. Run `make test` again after changing
the ISO or a fingerprinted input.

The harness records per-run firmware/source/profile facts, process and session
observations, available memory, and boot-to-terminal timing. These measurements
describe that run only; they are not a historical before/after comparison or
a bit-for-bit reproducibility claim.

QEMU validates the installer and software session. It does not certify Intel
i915 graphics, Intel Wi-Fi firmware or reconnection, the Dell touchpad or
panel, audio, suspend/resume, thermals, or power management. Those require
physical hardware checks.
