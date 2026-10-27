# home

Minimal post-install provisioning for a **stock Alpine Linux** machine (x86_64).
This is not an installer, disk image, or distribution.

Install Alpine using its official `setup-alpine` procedure first, including
disk layout, bootloader, networking, an administrator account with a password,
and any desired full-disk encryption. Boot the installed system.

```sh
apk add git make doas
git clone https://github.com/joshuarli/home
cd home
doas make install USER_NAME="$(id -un)"
```

If using a root shell instead, specify `USER_NAME=yourlogin` explicitly.
The target user must already exist and have a nonempty password hash.
`make install` intentionally does **not** configure doas, authentication,
networking, partitions, bootloaders, kernel hooks, or encryption.

After installation, log in on tty1 to start dwl and foot. Ctrl+Return
opens another foot terminal. Other TTYs remain normal login consoles.
Use `HOME_SESSION_DISABLE=1` to bypass session startup.
Run `doas make verify USER_NAME=yourlogin` to inspect the installation.
Re-running installation updates managed files and packages.

This is a prototype. Verify the physical Dell XPS 13 9343's Wi-Fi, i915,
keyboard, touchpad, suspend/resume and power management separately.
