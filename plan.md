Finish the current implementation through a focused correctness and
simplification pass. Do not rewrite the project or add desktop features.

Read AGENTS.md, README.md, the implementation and its
tests. Where this request contradicts the current stock-dwl-only policy or
the insistence on PARTUUID, this request takes precedence.

PRODUCT GOAL

Cold boot -> unprivileged josh session -> dwl -> exactly one usable foot.
Ctrl+Return opens another foot.

Keep the installed system lean, package-maintainable and understandable.
Preserve the existing account policy, Intel hardware support, UEFI/fallback
boot architecture, Wi-Fi provisioning and local recovery path.

No display manager, desktop environment, hotkey daemon, XWayland, audio
server, persistent guest agent, SSH requirement or new distro framework.

Implement the fixes and run verification. Do not stop at a proposal.
Use small failing regression tests first. Do not push.

PRIORITY 1 — MAKE THE TESTS CAPABLE OF DETECTING FAILURE

The existing test results are not sufficient evidence because their
observation mechanisms can falsely succeed.

1. Repair qemu/harness.py's serial_command() and its callers.

   It currently:
   - sends COMMAND followed by a marker regardless of COMMAND's status;
   - never reports COMMAND's exit status;
   - returns the entire historical serial transcript;
   - permits expected markers to match echoed input or earlier commands.

   Replace this with one small, reliable command transport:
   - unique per-command framing;
   - output limited to that invocation;
   - an explicit captured exit status;
   - checked success by default;
   - an explicit opt-out for intentionally expected failures;
   - bounded deadlines and useful failure diagnostics.

   Separate the append-only diagnostic transcript from the command result.
   Do not use the rolling transcript as a response object.

   Ensure frame recognition cannot be satisfied by terminal echo of the
   command that prints the frame. Establish the serial shell once and
   handle echo deliberately. Avoid repeated dependence on a hard-coded
   "~ $ " prompt after the control channel has been established.

   Check failure propagation inside multi-command guest operations too.
   Capturing only the final successful command must not conceal an earlier
   failed apk invocation, hook, comparison, mount or deletion.

2. Add host-side regression tests that establish:
   - a guest command returning false fails a checked invocation;
   - expected nonzero results can be inspected explicitly;
   - echoed marker text is not accepted as command output;
   - markers in previous commands are not accepted;
   - missing files and empty output do not satisfy marker checks;
   - fragmented reads, timeout and EOF cannot produce success;
   - a command failure is not overwritten by cleanup failure.

   Use standard-library fixtures or a small local PTY test where useful.
   Do not introduce a large test dependency.

3. Audit shell assertions throughout tests/ and build smoke checks.

   Standalone "! command" is not a fatal assertion under set -e.
   Replace intended assertions with explicit failure handling or a small
   assertion helper. Preserve legitimate uses of negation in conditions.

   Demonstrate that the negative checks actually fail when a forbidden
   package, unwanted service, missing required file or prohibited setting
   is deliberately introduced.

   Do not confuse grepping for safety-check source text with exercising
   the safety behavior.

4. Repair the graphical-command and recovery-console tests.

   Require exact, fresh output from a command whose exit status succeeded.
   Prove the graphical command ran in a /dev/pts/* terminal belonging to a
   foot session, not the serial console or a recovery VT.

   Use a per-run challenge/result that cannot pass merely because its
   filename appeared in an echoed serial command.

   Combine that evidence with the existing graphical input and screenshot
   observations. Verify rendered command output, not only typed input.
   Do not add OCR or brittle whole-screen golden images.

   Include negative controls: withholding graphical input or preventing the
   intended command from executing must make the relevant test fail.

PRIORITY 2 — FIX EFI DETECTION AND SIMPLIFY BOOT MAINTENANCE

5. Correct efivarfs detection in installer/install.sh.

   findmnt -T reports the containing filesystem, not necessarily a mount at
   the requested path. Verify the exact mountpoint and filesystem type.

   Mount efivarfs when necessary, check the mount result, and then read
   firmware variables. Do not suppress a mount failure and misreport it as
   a firmware capability limitation.

   Add tests covering:
   - only parent sysfs mounted;
   - efivarfs already mounted;
   - mount failure;
   - Secure Boot enabled;
   - Secure Boot disabled;
   - genuinely unavailable or malformed state.

   Reassess the QEMU "disabled" seed after this correction. Remove the
   exception if it only worked around the mount-check bug. Any genuinely
   necessary firmware-specific exception must be supported by observations
   from a correctly mounted efivarfs and documented accurately.

   Keep physical installation fail-closed when the required state cannot
   be established. Do not weaken disk checks in test mode.

6. Remove fragile build-time modifications from the normal boot path.

   Audit:
   - rootfs/patch-initramfs.sh;
   - mutation of /usr/share/mkinitfs/initramfs-init;
   - the extracted kernel-hooks.trigger copy;
   - the reason for apk --no-scripts in an amd64 stage that already executes
     amd64 chroot commands;
   - normal package-trigger behavior after installation.

   Prefer a root=UUID=... configuration supported by the selected Alpine
   release if it eliminates the local PARTUUID patch and related machinery.
   PARTUUID is not a product requirement worth maintaining a fragile patch.

   Keep the EFI command line, fstab, installer, update hooks, tests and docs
   consistent. Do not change identifiers in only one layer.

   Use Alpine's supported package/hook interfaces rather than a permanently
   copied private trigger implementation. Preserve any truly necessary
   deferred setup, but make its ownership and update lifecycle explicit.

   A normal supported package replacement or upgrade must not silently
   remove a boot requirement. If a modification remains necessary, prove
   that it survives package replacement; do not merely document the risk.

7. Strengthen update and fallback verification.

   On disposable installed-disk overlays:
   - verify /boot is the actual mounted ESP before modifying EFI files;
   - exercise the real package/hook path;
   - enforce every command's exit status;
   - establish that a new EFI payload was generated;
   - establish that the new payload was actually booted.

   A harmless, unique test-only kernel-command-line token observed in
   /proc/cmdline after reboot is one possible freshness witness.

   Exercise replacement of the package supplying the initramfs logic, not
   just repeated invocation of the already-modified installed script.
   Test an actual kernel package update/reinstallation where supported.

   Verify canonical and fallback paths independently. Explicitly check
   that the path intentionally removed for each test is really absent.

   A no-op regeneration, failed hook, stale fallback, or two matching old
   images must fail the test.

   Preserve the existing atomic fallback replacement where appropriate.
   Keep generated EFI images and normal update hooks synchronized.

PRIORITY 3 — MAKE INTERACTIVE AND AUTOMATED QEMU MATCH

8. Use one common installed-VM graphics configuration.

   Currently installed_session_stage() enables qemu_renderer, while
   interactive_run() does not. Remove that divergence.

   Except for display visibility, control transport and narrowly scoped
   test inputs, make run and installed-system acceptance must use the same:
   - virtual GPU;
   - renderer selection;
   - DRM-device selection;
   - input devices;
   - CPU/machine/firmware configuration.

   Define defaults once and test the generated commands for parity.

9. Make the virtual GPU explicit.

   The current configuration adds virtio-gpu but relies on the implicit
   default Bochs device and hard-codes /dev/dri/card0.

   Choose the simplest proven single-GPU software-rendering configuration.
   Explicit Bochs is acceptable if it is the reliable Mac baseline.
   Virtio is acceptable if the complete selected rendering path works.

   Do not retain two GPUs accidentally. Do not select a driver merely by
   assuming a card number. Disable unwanted default devices or resolve the
   intended device through stable identity.

   Assert which DRM driver/device the compositor actually uses, not merely
   that /dev/dri/card0 exists. Ensure screenshots observe that same output.

   Update doctor, profile metadata and documentation to describe reality.

   Keep software-renderer overrides confined to the VM. The physical Intel
   machine must retain its intended native renderer selection.

10. Verify the actual development entrypoints.

   Test doctor against output from the installed QEMU, including CPU-list
   formatting and supported display backends. A substring in "-device help"
   is not a substitute for a successful supported VM launch.

   Record relevant QEMU version and CPU-feature limitations. Do not suppress
   unsupported-feature warnings and claim exact Dell emulation.

   Run the interactive command and inspect its visible desktop, not only the
   headless acceptance path.

   Exercise the installer image as USB storage through UEFI, matching the
   intended physical installation route. The existing CD boot test alone
   does not validate the USB route. Reuse the same installer and core profile;
   do not create a family of separate installer implementations.

   Maintain explicit identification of the disposable writable target when
   changing media presentation. Do not depend on disk enumeration order.

11. Improve offline and recovery coverage without expanding the product.

   In addition to a missing NIC, test a present NIC with unavailable
   connectivity/DHCP. Reaching the desktop must remain bounded.

   Verify tty2 recovery, returning to tty1, intentional dwl exit, compositor
   failure and explicit session restart. Require fresh observations and
   exactly the expected compositor/client counts.

   Recovery must not depend on the compositor still being healthy.
   Document an actionable way to restart the desktop from its tty1 recovery
   shell and the real boot-time recovery bypass.

PRIORITY 4 — HARDEN THE DESTRUCTIVE BOUNDARIES

12. Correct disk geometry at its source.

   blockdev --getsz always reports 512-byte units; the installer currently
   treats that count as logical sectors.

   Prefer deriving logical-sector count from --getsize64 / --getss with
   explicit divisibility and range validation.

   Test the real caller as well as the pure layout function for 512-byte and
   4096-byte logical sectors. Verify all byte sizes, alignment, non-overlap,
   GPT limits and the final partition end against actual disk capacity.

   Either support a geometry correctly or reject it before any destructive
   operation. Do not silently compute an impossible layout.

   Validate the complete layout before wipefs. Add a regression test proving
   that invalid geometry or an undersized target invokes no destructive tool.

13. Replace safety-text tests with focused behavioral tests.

   Exercise installer-media parent-disk exclusion, mounted descendants,
   active swap, read-only targets, unsupported device types and missing
   confirmation. Fail closed when required inspection cannot be completed.

   Keep unsupported storage arrangements out of scope rather than adding
   LVM/RAID support to make a test convenient.

   Audit cleanup flags around bind mounts: record ownership immediately
   after a successful mount, so a subsequent propagation-setting failure
   cannot leave an untracked mount.

   Required cleanup failures must be reported. Keep terminal restoration,
   process ownership and mount cleanup correct under interruption.

14. Make host-side safety self-contained.

   Validate generated-path ancestors from the trusted repository root,
   including dist itself. The Python harness must not depend on the firmware
   fetch script having rejected a symlink earlier.

   Test direct harness invocation with symlinked dist, nested symlinks,
   non-regular outputs and paths outside the generated directory.

   Do not delete arbitrary files or follow aliases outside the designated
   generated tree. Preserve the explicit disposable-disk restriction.

   Ensure partial VM startup failures close sockets, file handles and the
   QEMU process. installed_session_stage() must not leak a VM if connection
   setup fails before its caller enters a try/finally block.

   Reject unexpected QEMU exit statuses at every stage.

   Invalidate prior success reports at the start of a new test attempt.
   Publish a fresh success verdict only after every required stage succeeds.
   Do not leave old "passed" metadata looking like the current run's result.

PRIORITY 5 — COMPLETE THE REQUEST WITHOUT ADDING MACHINERY

15. Implement Ctrl+Return.

   Keep the pinned upstream dwl build, but make the smallest auditable
   build-time configuration change needed to bind Ctrl+Return to ordinary
   foot. No hotkey daemon, wrapper-based key interception or patch collection.

   Remove the dormant binding to the uninstalled wmenu-run instead of
   documenting a broken binding as an intentional feature.

   Keep the remaining useful upstream behavior unless a requirement demands
   otherwise. Maintain explicit XWayland-disabled verification.

   Update the real injected-key acceptance test, README and AGENTS.md.
   Do not redefine the requirement to match the stock configuration.

   Verify:
   - one foot after cold boot;
   - Ctrl+Return creates exactly one additional usable terminal;
   - ordinary Return does not;
   - closing every terminal leaves dwl alive;
   - Ctrl+Return works again with no terminals open.

16. Do a measured simplification pass after correctness.

   Remove obsolete workaround code, redundant configuration, stale planning
   transcripts and tests that only freeze an implementation detail.

   Prefer deleting unnecessary mechanisms over moving them into abstractions.
   Do not split the harness into a framework merely to shorten one file.

   Audit the remaining --no-scripts side effects, including boot/shutdown
   services, device initialization, fonts and package triggers. Prefer
   supported Alpine behavior to duplicated package internals where practical.

   Keep runtime, installer, builder and host-test dependencies separate.
   Do not add a target daemon or development tool for testing convenience.

   Record the actual installed closure and major size contributors. Include
   the manually installed dwl binary in software/version accounting even
   though APK does not own it.

   Describe installed fonts and graphics/firmware packages accurately.
   Do not claim a single font file or hardware-specific minimal closure merely
   because one font is configured or one package name appears in world.

   Do not rebuild Mesa, wlroots or the kernel just to win a marginal size
   reduction. Quantify meaningful remaining tradeoffs.

FINAL ACCEPTANCE

Run on the macOS arm64 development environment:

    make check
    make doctor
    make build
    make test
    make run

Adapt command names only where the existing interface genuinely improves.

Required evidence:
- focused regressions fail before the relevant fixes and pass afterward;
- deliberately broken command results cannot produce a passing verdict;
- firmware installation and installed-system boot use the real media;
- graphical input, executed PTY commands and visible output agree;
- interactive and automated graphics configurations agree;
- recovery and offline startup work;
- canonical and fallback EFI boot consume newly generated payloads;
- package replacement does not discard a required boot modification;
- unsafe or impossible installation targets are rejected before writes;
- no test requires the physical laptop.

Finish with the exact revision, commands/results, observed remaining
limitations and measured size changes. Distinguish executed tests from
tests merely written. Do not claim physical i915/Wi-Fi/touchpad validation
from virtual hardware.

The goal is a smaller implementation whose tests can be trusted—not more
features, more documentation volume or more ways to declare success.
