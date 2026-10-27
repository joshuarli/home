# home

Stock Alpine post-install provisioner, not an ISO or OS distribution.

- Keep POSIX sh, apk, OpenRC, seatd, eudev, dwl and foot.
- Never manage disks, bootloaders, kernel hooks, passwords, doas policy or networking.
- No autologin or passwordless privilege escalation.
- Keep installation repeatable, fail on conflicting unmanaged files.
- Verify shell syntax with `make check`.
- Hardware testing is distinct from VM smoke testing.
