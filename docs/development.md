# Build and development commands

The standard artifact build uses Docker Buildx for `linux/amd64` and exports
`dist/home-installer.iso` with `dist/iso-metadata.txt`. The ISO contains the
live installer and setup assets, not the installed target root filesystem.

## Commands

| Command | Result |
| --- | --- |
| `make doctor` | Checks Docker Buildx and the installed QEMU profile. |
| `make check` | Runs shell syntax, installer safety/layout, static contract, QEMU harness, and size-report checks. |
| `make build` | Builds and exports the ISO plus metadata. |
| `make size` | Runs the ISO build, then writes a size report. |
| `make fetch-edk2-ovmf` | Fetches the pinned OVMF bundle under `dist/qemu/firmware`. |
| `make test` | Builds and runs the fresh-install QEMU acceptance loop. |
| `make run` | Boots the retained QEMU disk with a graphical display. |
| `make clean` | Deletes `dist/`, including ISO and retained QEMU state. |

The host needs Docker with Buildx, Python 3, `qemu-system-x86_64`, and
`qemu-img`. `make doctor` checks the required QEMU devices and display backend.
On macOS arm64 the harness uses native x86_64 QEMU with TCG; it does not use
HVF acceleration. The `make size` host requirement is documented in the
[size-report guide](size-report.md).

`make test` and `make run` accept `OVMF_CODE` and `OVMF_VARS` only as a pair.
`QEMU_DISPLAY` selects a display backend for `make run`. `QEMU_TEST_DIR` and
`QEMU_DISK` can redirect generated VM paths only within the repository's
`dist/qemu/` directory; the harness rejects block devices, symlinks,
non-regular files, and paths outside that generated tree.

For the acceptance contract and retained-disk rules, see
[QEMU testing](testing.md). For the exact size-report files, see
[size reporting](size-report.md).
