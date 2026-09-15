Implement and verify this scope change; do not stop at a proposal. Preserve
unrelated working-tree changes. Do not push changes unless separately asked.

DEVELOPMENT HOST: macOS arm64.
INSTALLED TARGET: x86_64 Dell XPS 13 9343, retaining this repository's
explicit Intel-wireless target assumption.

MISSION

Refactor this into the smallest straightforward, maintainable Alpine system
that cold-boots into dwl with one usable foot terminal already open.

Ctrl+Return must open another foot terminal.

The repository should become simpler, not acquire a general-purpose distro
framework, desktop environment, or elaborate test platform.

Build a dependable QEMU development loop on the Mac, with automated tests
that boot the actual installer, install onto a disposable virtual disk,
boot that installed disk through UEFI, and exercise the graphical session.

This request supersedes the old console-only MVP and its prohibition on
building dwl from source. It does not authorize unrelated features.

1. ESTABLISH THE CURRENT STATE

Read AGENTS.md and the actual implementation before editing. In particular:

- Dockerfile and Makefile
- rootfs-packages.txt
- build/
- rootfs/configure.sh and rootfs/fetch.sh
- installer/install.sh
- iso/
- qemu/
- fetch-edk2-ovmf.sh

Treat executable behavior, not historical documentation, as the description
of the current implementation.

Investigate these specific areas:

- The direct-kernel installer test and separate manual UEFI login path.
- The large normalized diagnostic golden fixture.
- Repeated or inconsistent boot command lines and root identifiers.
- Prebuilt EFI images versus documentation describing installer-time
  generation.
- The manual rootfs setup necessitated by apk --no-scripts.
- Architecture handling and the temporary qemu-x86_64 binary.
- Installer-only, runtime, and test-only dependencies mixed together.
- QEMU branches that bypass real installer safety or boot checks.
- The late installer-script insertion into the ISO: preserve its useful
  caching properties if they still justify its implementation.

Record a brief implementation plan and establish a baseline where possible.
Then proceed. Write focused failing tests before fixing testable behavior.
Do not introduce a documentation/approval ceremony for routine decisions.

2. KEEP THE PRODUCT NARROW

The normal boot path should be:

UEFI
  -> Alpine kernel/initramfs
  -> BusyBox/OpenRC, device initialization and seat access
  -> tty1 autologin as josh
  -> small guarded session launcher
  -> dwl
  -> one foot terminal running the user's shell

Retain:

- Alpine's supported packaged kernel and normal package management.
- The existing unprivileged josh account, home directory and ash shell.
- The existing locked-root/passwordless-josh/passwordless-doas policy,
  explicitly documented as an insecure physical-access assumption.
- Working UTF-8, America/Los_Angeles timezone and UTC RTC.
- The existing intended Intel Wi-Fi capability and credential persistence.
- UEFI installation with an EFI fallback boot path.
- An uncomplicated local recovery console.

Do not add a display manager, desktop shell, bar, launcher, notification
daemon, browser, audio server, SSH server, network-management GUI, or
general-purpose user-service manager.

Do not introduce Xorg or XWayland. Disable XWayland in the dwl build.

Avoid D-Bus, elogind and polkit unless you demonstrate an actual requirement
that cannot reasonably be met by the intended seatd-based session.

Do not introduce a custom kernel, firmware flashing, coreboot, encryption,
hibernation, or a second operating-system target.

3. MINIMIZE THE ACTUAL RUNTIME, NOT JUST THE PACKAGE LIST

Audit the complete dependency closure and installed sizes. Merely deleting
names from /etc/apk/world does not establish that their dependencies vanished.

Keep explicit, understandable ownership of:
  a. installed runtime dependencies;
  b. live-installer dependencies;
  c. build dependencies;
  d. host/test dependencies.

Remove direct packages unrelated to reaching a usable dwl + foot session.
Specifically reassess:

- mesa-va-gallium
- intel-media-driver
- libva-utils
- alsa-lib as an explicit dependency
- nano and less where existing BusyBox functionality is sufficient
- wayland-protocols and other build-time-only requirements
- unnecessary locale, utility and graphics packages

Keep any genuinely required transitive libraries. An X11 protocol library
pulled in by a packaged dependency is not the same thing as installing an
X server; do not rebuild half the graphics stack merely to remove its name.

Provide the minimum working graphics/input stack, including:

- wlroots/libseat/libinput and their required runtime dependencies;
- correct device discovery, permissions, input classification and rules;
- seatd and its actual OpenRC integration;
- the appropriate Intel DRM/Mesa support for the physical target;
- foot, its terminfo, keyboard data and one explicit monospace font.

Verify the device-manager choice. Do not assume that installing a libudev
library or running mdev alone provides everything libinput needs. Prefer a
small, proven Alpine eudev configuration over homemade device rules unless
a smaller solution is demonstrated to work correctly. Avoid competing
device-manager setups.

Retain appropriate Intel microcode and firmware. Do not remove hardware
drivers or firmware because the virtual machine does not use them. Do not
pretend the existing QEMU diagnostic fixture identifies my physical laptop.

Prefer Alpine packages and appropriate subpackages over custom builds.
Build dwl because its configuration requires it. Do not turn shaving minor
dependencies into a custom Mesa/wlroots distribution project.

If a large dependency remains, quantify it and explain the tradeoff rather
than silently declaring the image minimal.

Keep build tools, development headers, temporary emulators, package caches
and test tools out of the installed image.

4. BUILD A SMALL, EXPLICIT DWL CONFIGURATION

Choose and pin an upstream dwl release or immutable commit compatible with
the wlroots ABI available in the selected stable Alpine branch. Verify this
compatibility from the actual sources and package metadata.

Use the current upstream location, not an obsolete mirror by accident.
Record source checksums and the chosen versions. Do not follow an unpinned
master branch or mix edge packages into stable to make a build succeed.

Build in a separate build-only stage. Prefer a tiny local APK with tracked
runtime dependencies over unmanaged files copied into /usr/bin. Do not
globally weaken APK signature verification.

Keep the local configuration and any patch very small and reviewable.
Do not vendor an unrelated dwl fork or add a patch collection.

Configure the terminal command to run ordinary foot. Bind exactly
Ctrl+Return to spawning it—not Super+Return, not Ctrl+Shift+Return.

Use the chosen release's correct keybinding types/constants. The intended
binding is the equivalent of:

    WLR_MODIFIER_CTRL + XKB_KEY_Return -> spawn {"foot", NULL}

Do not invent a runtime dwl configuration format.

Use dwl's native startup-command mechanism to launch the initial foot
after the compositor is ready. Start exactly one terminal per session.
Do not add a separate autostart daemon or enable foot-server by default.

Check the selected release's startup-command stdin/status-stream behavior.
Close or redirect unused status input as appropriate so it cannot stall
the compositor. Do not introduce a status bar merely to consume it.

Remove bindings that invoke absent applications. Keep and document a small
usable set for focus, closing a window, exiting dwl and console recovery.

Keep foot configuration minimal: a real installed monospace font, sensible
size, working UTF-8 and correct terminfo. Avoid themes, font collections and
unnecessary configuration copied wholesale from examples.

5. MAKE LOGIN AND SESSION LIFECYCLE CORRECT

Run dwl and foot as josh, never as root.

Set up XDG_RUNTIME_DIR before launching dwl. Use a securely created,
user-owned directory under /run, mode 0700, with correct lifecycle and
ownership checks. Do not use a globally writable shared directory or an
unsafe mkdir/chown sequence vulnerable to symlinks.

Ensure HOME, USER, SHELL and the session environment are correct.
Let dwl provide the Wayland display to its children.

Autostart only from the intended tty1 login. A foot shell, subshell, serial
login, recovery-console login or another invocation of ash must not launch
another compositor. Do not put an unconditional dwl invocation in .ashrc.

Use one small launcher and straightforward login integration. Do not
invent a session manager.

Ensure device initialization and seat access are ready before the session
starts. Verify actual socket permissions and group membership; fix the
existing account/group setup to be idempotent without duplicate members
or arbitrary GID collisions.

A session failure or intentional exit must leave a usable recovery path,
not a black screen or a rapid autologin/crash/respawn loop. Prefer returning
to a working shell with a useful error and an explicit restart command.
Provide a documented way to bypass GUI startup for recovery.

Capture useful bounded diagnostics without adding a logging daemon.

Closing the initial terminal must not kill dwl. With no terminals open,
Ctrl+Return must still work.

The desktop must start when Wi-Fi is unavailable. Network acquisition must
not indefinitely block reaching the terminal.

6. SIMPLIFY BUILD AND INSTALLATION WITHOUT HIDING FAILURES

Keep Docker/Buildx as the Linux image builder and native macOS QEMU as the
VM runner. Make the architecture model explicit.

Prefer a coherent linux/amd64 build stage over duplicated pseudo-cross-build
paths. Determine whether the manually copied qemu-x86_64 binary serves any
real purpose; remove it if it does not.

Audit apk --no-scripts carefully. Package installation scripts, triggers,
groups, service setup, module metadata and font configuration must either
run correctly or be deliberately replaced. A successful archive build is
not proof of a correctly initialized rootfs.

Centralize boot configuration. Choose one consistent root-identification
scheme and make the generated EFI image, installer, update hooks, tests
and documentation agree. Do not claim PARTUUID boot while shipping a
LABEL-based command line.

Prefer the simplest tested solution; do not redesign boot merely to match
stale documentation.

Preserve the packaged-kernel/EFI-stub approach unless a concrete failure
requires a change. Keep GRUB out of the installed system. Installer-media
bootloader dependencies are a separate budget.

Ensure both the canonical EFI image and EFI/BOOT/BOOTX64.EFI remain current
after kernel/initramfs regeneration. A fallback image copied only during
installation must not silently become stale after an update.

Keep the filesystem layout uncomplicated. Reassess the existing 2xRAM swap
policy and its separate QEMU-only sizing rather than preserving divergent
code by inertia. Hibernation is not a requirement. Choose and document one
simple policy; do not build a configurable partition-layout framework.

Retain useful Intel Wi-Fi setup while separating network provisioning from
the common disk installation steps. Virtual Ethernet must not require a
second installer implementation. Reassess mandatory internet/DNS checks
when all installation payloads are already embedded.

Harden the destructive boundary:

- Physical installation retains explicit target confirmation.
- Resolve installer partitions to their parent disk when excluding media.
- Reject inappropriate, mounted or otherwise protected targets.
- QEMU mode must not disable UEFI checks or generic disk-safety checks.
- Never select a disk merely because its enumeration happened to be vdb.
- Restore terminal echo and clean up only owned network processes.
- Clean up mounts and temporary state on failure and interruption.
- Replace blind sleeps with bounded readiness checks.
- Test partition naming, size calculations and relevant sector-size cases.

Host tests may write only newly created, owned regular image files inside
the designated generated test directory. Reject block devices, unsafe
symlinks and arbitrary existing files supplied through environment
overrides. Never touch macOS /dev/disk* devices.

7. BUILD ONE HONEST X86_64 QEMU PROFILE FOR THE MAC

The primary VM is an XPS-like platform approximation, not a Dell emulator.

Use native qemu-system-x86_64 with TCG on macOS arm64. Do not try to use HVF
for the Intel guest, run system QEMU inside Docker, or describe userspace
translation as x86 system hardware acceleration.

Start with:

- a supported, versioned Q35 machine;
- matched x86_64 OVMF CODE and VARS;
- a Broadwell-class CPU model, subject to actual TCG support;
- modest configurable memory/CPU allocation;
- SATA/AHCI storage for the main platform test;
- a virtual DRM-capable display;
- virtual keyboard and pointer devices;
- user-mode Ethernet networking.

Verify the proposed CPU and storage approximation against Dell's published
documentation. Do not invent my exact CPU SKU, memory size, panel resolution
or wireless PCI ID. Mark unknown physical details explicitly.

Inspect the installed QEMU's supported machines, CPU features, devices and
display backends. Do not suppress unsupported-feature warnings and call
the result an exact Broadwell environment. Avoid build flags that allow
newer instructions than the target should have.

Use a 2D virtio display and a verified software-rendering route as the
portable Mac baseline. Prefer the selected wlroots version's pixman
renderer if it works correctly with DRM/KMS. Verify rather than assume.

Confine VM-specific renderer selection to explicit test/VM configuration.
Do not force software rendering on the physical Intel machine just to make
tests pass. Avoid requiring virgl, Vulkan passthrough or special host GPU
infrastructure for the baseline.

The automated VM may have no host display window, but it must still expose
a guest DRM device and exercise the normal VT/input/compositor path.
WLR_BACKENDS=headless is not an acceptable substitute for this E2E test.

Provide an interactive graphical mode using an available native display
backend, or a documented localhost-only alternative. Keep QMP and serial
control separate from the graphical display.

Reuse and improve the firmware-fetching helper where appropriate. Verify
checksums, keep CODE read-only, and give each run its own writable VARS.
Do not independently auto-select incompatible CODE/VARS files.

Use explicit opt-in for unattended testing, such as a narrowly scoped
fw_cfg test seed or automation of the real installer interface. Do not
trigger destructive installation simply from a QEMU/Dell DMI string.

Require an explicitly identified disposable virtual target. Keep ordinary
physical-image behavior interactive.

Document that virtual Ethernet does not test Wi-Fi, virtio graphics does
not test i915, and virtual input does not reproduce the Dell's touchpad.

8. REPLACE THE GOLDEN TRANSCRIPT WITH REAL ACCEPTANCE TESTS

Use focused shell tests for pure configuration/installer behavior and a
small host harness for VM orchestration. Python standard library is fine
for QMP, serial control, timeouts and assertions. Do not install Python,
SSH or a persistent guest agent in the target solely for testing.

The authoritative E2E sequence must:

A. Boot the actual generated installer image through OVMF.
   Prefer the USB-media presentation used for physical installation if the
   image supports it. State which media path was tested.
   Do not use QEMU -kernel/-initrd to bypass firmware in this test.

B. Install onto a fresh disposable virtual disk using the real installer.
   Exercise UEFI detection, partitioning, filesystems, extraction, target
   configuration and EFI installation. Only hardware-specific network
   provisioning and explicit test input may differ.

C. Wait for successful completion and clean shutdown. Do not declare
   success and kill QEMU as soon as a log contains "Installation complete."

D. Boot the installed disk with the installer detached, through firmware,
   without direct-kernel boot or a replacement test initramfs.

E. Verify the normal tty1 autologin/session path:
   josh owns the compositor, seat access works, a Wayland socket exists,
   the DRM/input backend is active, and exactly one foot window is mapped.

F. Capture and inspect a screenshot showing the terminal and rendered text.
   Process existence alone is insufficient.

G. Inject an actual Ctrl+Return chord through QEMU's input interface.
   Verify exactly one additional usable foot terminal appears.
   Do not test this by manually spawning foot from serial or only grepping
   the compiled configuration.

H. Type a shell command through the graphical terminal that produces a
   unique per-run result. Observe the result independently through the
   test transport and inspect graphical output.
   Establish that the command ran in a terminal PTY, not the serial shell.
   Avoid false passes from echoed test commands or static marker strings.

I. Verify ordinary Return does not create another terminal. Close terminals,
   including the original one, and verify Ctrl+Return still opens a new one.

J. Verify a serial/recovery login does not start an extra compositor.
   Exercise compositor exit/failure and recovery without a respawn storm.
   A new explicit desktop session should autostart one foot, not duplicates.

K. Reboot and verify the behavior again, including a boot without usable
   networking.

L. Boot with a fresh firmware variable store to prove the EFI fallback path
   works independently of the install-created NVRAM entry.

M. Exercise kernel/initramfs/EFI regeneration on a disposable installed-disk
   copy and verify the canonical and fallback paths still boot the updated
   result. Use the real update hooks, not a manual test-only copy operation.

Keep test observations in the installed system where that is what is being
claimed. A diagnostic script executed in the live ISO cannot prove the
installed desktop works.

Use screenshots, process/session facts and behavioral assertions together.
Do not replace the old huge text fixture with a fragile whole-screen pixel
golden or an OCR framework.

Retain useful diagnostics as on-demand/failure artifacts. Remove the
172KB-style normalized fetch transcript as the main correctness contract.

Use explicit deadlines, bounded polling, reliable process cleanup and
separate stage results. Preserve QEMU stderr, serial logs, screenshots,
invocation/configuration and relevant guest logs on failure.

A timeout, missing observation or unavailable required test is not a pass.

9. MAKE ITERATION FAST WITHOUT ADDING A SECOND PRODUCT

Keep a small public command surface, approximately:

    make doctor   # validate host prerequisites and capabilities
    make build    # build the installer and useful build metadata
    make check    # focused static/unit/rootfs checks
    make test     # authoritative install -> firmware boot -> GUI tests
    make run      # interact with the retained installed VM

Existing names may be retained as cheap aliases when useful. Document
destructive reset/clean behavior.

Share VM configuration between test and interactive operation. Avoid
separate large launcher scripts that drift.

Exploit Docker cache boundaries so editing the installer or dwl config
does not unnecessarily rebuild unrelated layers.

A retained installed disk or qcow2 overlay may support faster session
iteration. Clearly distinguish that shortcut from a fresh-install test.
Associate cached state with the relevant build/source fingerprints and
invalidate it when necessary. Never silently test a stale image.

Do not add an ARM guest as another supported product or a large VM/profile
framework. The x86_64 path is the acceptance target.

10. MEASURE, DOCUMENT AND FINISH

Report before/after, where a valid baseline can be obtained:

- direct packages and resolved package count;
- installed filesystem size and largest dependency contributors;
- rootfs payload, EFI image and installer ISO sizes separately;
- enabled services and steady-state processes;
- idle memory with the measurement method stated;
- boot-to-usable-terminal timing under the documented QEMU configuration.

Distinguish allocated disk capacity from used filesystem space, compressed
artifacts from installed size, and TCG timing from laptop performance.

Keep the runtime package manifest authoritative and record resolved build
versions. Pin important source/firmware inputs. Do not claim full
bit-for-bit reproducibility merely because the base image has a version tag.

Rewrite AGENTS.md into concise, current engineering invariants. Put human
build/run/recovery instructions in a concise README without duplicating a
large historical specification.

Explain the boot/session chain, remaining dependencies, keybindings,
firmware/root-identifier choice, installer safety boundary, VM test stages
and cache invalidation.

Include a short validation matrix separating:
- proven in QEMU;
- checked statically for the target;
- still requiring physical-hardware validation.

The latter should include actual Intel graphics, Wi-Fi/firmware, touchpad,
panel behavior and power management. The development loop must not require
the laptop, but do not misrepresent VM success as hardware certification.

Finish with the implemented changes, exact verification commands/results,
size tradeoffs and any remaining blockers. Distinguish tests actually run
from tests merely written. Do not claim success from static checks alone.

Make the result smaller and easier to understand. Do not replace the old
complexity with a new abstraction layer.
