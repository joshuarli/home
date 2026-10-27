# home

Post-install provisioner that turns a stock Alpine Linux edge install with
`linux-stable` into a minimal dwl + foot desktop with LLVM/clang 23 or newer. It is not an installer, image, or distribution.
The target is a Dell XPS 13 9343 (x86_64); aarch64 is supported for VM testing.

## 1. Install Alpine

Alpine publishes no edge ISO. Boot the official Alpine 3.24 `standard` ISO and
install edge with the `linux-stable` kernel directly:

```sh
edge=https://dl-cdn.alpinelinux.org/alpine/edge
APKREPOSOPTS="$edge/main $edge/community" DISKOPTS="-m sys -k stable" setup-alpine
```

Choose:

- a disk for the `sys` install (diskless and data modes are rejected),
- networking, which this project never touches,
- an admin user with a password (`setup-user -a`), which configures doas for `wheel`.
- no getty on `tty0` in `/etc/inittab` (installs booted with a VT `console=`,
  such as the virt ISO, add one, and it splits tty1 keystrokes with the login).

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
- builds the pinned dwl 0.9 with clang and lld using `config/dwl.h`, then removes
  the build-only headers,
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
Unchanged files are left alone, dwl is rebuilt only when `build/dwl.sh` or
`config/dwl.h` changes, and ish is installed only if missing (update it with
`~/usr`'s own `make`). A managed path holding something home did not install
stops the run; move it aside or merge it, then rerun.

home recognizes files it installed by comparing them with every committed
version of their source, so it needs a full clone; a shallow clone is refused.
Packages follow the edge repositories, so reruns can upgrade them.

## Not managed

Disks, partitions, filesystems, encryption, bootloader, kernel, initramfs, EFI,
Secure Boot, networking, DNS, passwords, doas policy, root account, audio,
power management and lid handling. The kernel flavor is chosen at install
time; home refuses to run while `linux-lts` is installed.

## Development

`make check` runs syntax, shellcheck and package-name checks. `make test-vm`
installs Alpine edge with `linux-stable` on aarch64 from the virt ISO in QEMU,
provisions it twice, reboots, logs in on tty1 and checks the desktop. It needs `qemu` and `nc`, and provisions
the committed `HEAD` of this repository and of `~/usr` (`USR_REPO`).

## Hardware checklist (XPS 13 9343)

The VM test does not cover these. Check them after provisioning the laptop.

- [ ] Wi-Fi comes up after reboot on edge with `linux-stable` and udev. Edge
      broke XPS Wi-Fi once before, and a past mdev-to-eudev switch lost the
      interface until `iwlwifi` was listed in `/etc/modules`.
- [ ] `intel-ucode` is applied at boot (`dmesg | grep microcode`).
- [ ] i915 drives the panel; dwl starts on tty1 without errors in `dwl.log`.
- [ ] Keyboard, including Super bindings, and touchpad tap and two-finger scroll.
- [ ] dwl renders with GLES on i915 (the VM test forces the pixman renderer).
- [ ] Ctrl+Alt+F2 reaches a login and Ctrl+Alt+F1 returns to dwl.
- [ ] Super+p screenshot lands in the clipboard.
- [ ] Brightness, suspend and resume (not managed; note what is missing).
