# home

Post-install provisioner that turns a stock Alpine Linux 3.24 install into a
minimal dwl + foot desktop. It is not an installer, image, or distribution.
The target is a Dell XPS 13 9343 (x86_64); aarch64 is supported for VM testing.

## 1. Install Alpine

Boot the official Alpine 3.24 `standard` ISO and run `setup-alpine`. Choose:

- a `sys` disk install (diskless and data modes are rejected),
- networking, which this project never touches,
- the `community` repository (`setup-apkrepos -c`), with no `edge` or `testing` repositories,
- an admin user with a password (`setup-user -a`), which configures doas for `wheel`.

Reboot into the installed system and log in as that user.

## 2. Provision

```sh
doas apk add git make
git clone https://github.com/joshuarli/home
cd home
doas make install USER_NAME="$(id -un)"
```

`make install` checks the system before changing anything and stops with an
explanation if a check fails. It then:

- installs the packages in `packages.txt` (and `packages-x86_64.txt` on x86_64),
- switches the device manager to udev with `setup-devd udev`,
- builds the pinned dwl 0.8 with `config/dwl.h`, then removes the build toolchain,
- installs `home-session`, the `home-runtime` service, and a tty1 login hook,
- adds the user to the `seat` group and starts `seatd` and `home-runtime`,
- clones https://github.com/joshuarli/usr to `~/usr` if absent and runs its
  `make links` and `make tools TOOLS=ish` as the user. It does not run the rest
  of `~/usr`'s `dl` or its `setup-linux`.

Log out, then log in on tty1. dwl starts with a foot terminal running ish.
The login shell stays `/bin/ash`: ish has no `-c` command mode and reads no
profile, so it cannot serve ssh commands or start the desktop.

| Keys | Action |
| --- | --- |
| Super+Return, Ctrl+Return | foot |
| Shift+Return | bemenu-run |
| Super+p | screenshot a region to the clipboard |
| Super+k | close window |
| Super+m | fullscreen |
| Super+f | toggle floating |
| Super+e | toggle previous layout |
| Super+j | focus next window |
| Super+1..5, Super+Shift+1..5 | view tag, move window to tag |
| Super+Escape | quit dwl |

## 3. Verify

```sh
doas make verify USER_NAME="$(id -un)"
```

## 4. Recover

Quitting or crashing dwl returns tty1 to a normal shell; the exit status and
log path (`/run/user/$UID/dwl.log`) are printed. tty2 to tty6 are ordinary
logins (Ctrl+Alt+F2). The desktop starts only for an interactive tty1 login of
a `seat` member, so `doas delgroup "$USER" seat` disables it.

## 5. Reapply

Pull or edit this checkout and run `doas make install USER_NAME=...` again.
Unchanged files are left alone and dwl is rebuilt only when `build/dwl.sh` or
`config/dwl.h` changes. A managed path holding something home did not install
stops the run; move it aside or merge it, then rerun.

## Not managed

Disks, partitions, filesystems, encryption, bootloader, kernel, initramfs, EFI,
Secure Boot, networking, DNS, passwords, doas policy, root account, audio,
power management and lid handling.

## Development

`make check` runs syntax, shellcheck and package-name checks. `make test-vm`
installs stock Alpine aarch64 (virt ISO) in QEMU, provisions it twice, reboots, logs in
on tty1 and checks the desktop. It needs `qemu` and `nc`, and provisions
the committed `HEAD` of this repository and of `~/usr` (`USR_REPO`).

## Hardware checklist (XPS 13 9343)

The VM test does not cover these. Check them after provisioning the laptop.

- [ ] Wi-Fi comes up after reboot with udev (a past mdev-to-eudev switch lost
      the interface until `iwlwifi` was listed in `/etc/modules`).
- [ ] i915 drives the panel; dwl starts on tty1 without errors in `dwl.log`.
- [ ] Keyboard, including Super bindings, and touchpad tap and two-finger scroll.
- [ ] Ctrl+Alt+F2 reaches a login and Ctrl+Alt+F1 returns to dwl.
- [ ] Super+p screenshot lands in the clipboard.
- [ ] Brightness, suspend and resume (not managed; note what is missing).
