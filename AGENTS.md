# home

Post-install provisioner for stock Alpine edge with linux-stable, not an ISO or OS distribution.

- Keep POSIX sh, apk, OpenRC, seatd, udev, dwl and foot. No display manager, XWayland, D-Bus or session daemons.
- Never manage disks, bootloaders, kernels, initramfs, repositories, passwords, doas policy or networking; check them instead (edge only, no linux-lts).
- No autologin or passwordless privilege escalation; seat access comes from seatd's `seat` group only.
- User dotfiles and ish belong to `~/usr`; home only clones it and runs `make links` and `make tools TOOLS=ish`. The login shell stays ash.
- Check everything before the first change; stage clones until checks pass. A managed path whose content is not a committed version of its source (following renames) is a conflict.
- Reruns must not rewrite unchanged files; dwl rebuilds only when its build id changes.
- Verify with `make check`; run `make test-vm` for behavior changes. Hardware testing is separate from the VM test.
