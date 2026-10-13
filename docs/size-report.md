# ISO size report

Run `make size` to build the ISO and write a member-level size report. The
host needs `bsdtar` with libarchive; macOS includes it, while Linux hosts may
need to install it.

The report is written under `dist/`:

- `size-report.txt` summarizes ISO categories, live kernel and modloop,
  bootstrap APK repository, installer assets, and the network-installed
  target package manifest.
- `size-report/iso-members.tsv` lists each ISO member with logical size and
  2048-byte-sector allocation size.
- `size-report/overlay-members.tsv` lists each installer-overlay member.
- `size-report/target-package-manifest.tsv` lists the direct target packages
  carried in the ISO.

The report distinguishes compressed archive bytes from ISO member bytes. It
does not treat the target root filesystem as embedded: the live media carries
the package manifest, repository list, and setup assets, while installation
fetches target packages over the network.

Implementation: [`build/size-report.py`](../build/size-report.py) and the
[`make size` target](../Makefile).
