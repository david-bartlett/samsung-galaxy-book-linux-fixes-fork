# Issue #54 — Camera OV02C10 not working, Galaxy Book4 Pro (940XGK)

- **Reporter:** Bernardo-Lebron
- **Hardware:** Galaxy Book4 Pro 940XGK, subsystem ID `0x144dca07`
- **Kernel:** 6.17.0-23-generic
- **Distro:** Zorin OS 18.1 (Ubuntu 24.04 base)
- **Sensor:** OmniVision OV02C10 on Intel IPU6 (Raptor Lake)

## Reported symptoms

```
ov02c10: unknown parameter 'clk_freq' ignored
ov02c10 i2c-OVTI02C1:00: error -EINVAL: external clock 26000000 is not supported
ov02c10 i2c-OVTI02C1:00: probe with driver ov02c10 failed with error -22
```

"After running the updated webcam-fix script and rebooting, the camera still
doesn't work."

## Triage — subsystem mapping

This maps to the existing **`ov02c10-26mhz-fix/`** DKMS subsystem, not a new
quirk. The hardware's ACPI/IPU-bridge provides a **26 MHz** sensor clock; the
in-tree `ov02c10` driver only accepts 19.2 MHz, so probe fails with `-EINVAL`
(`-22`). The repo already ships a DKMS-patched driver that accepts both 19.2
and 26 MHz (`ov02c10.c:912`). 940XGK is simply another model in the same
Raptor-Lake-26 MHz class as the previously-known Book3/Book4 Ultra units.

## Root-cause analysis (log-driven; HW repro not available)

The error is reported **after** running the fix and rebooting, which means the
**stock in-tree driver is still the one binding** — the patched DKMS module is
not winning. Two independent findings:

1. **`unknown parameter 'clk_freq' ignored`** — a red herring. Neither this
   driver nor upstream has a `clk_freq` module parameter; the line comes from a
   stale `/etc/modprobe.d/*.conf` (older community workaround). Harmless, but it
   muddied the diagnosis and made it look like a config the fix should honour.

2. **Stock driver still bound after reboot** — most probable causes on an
   Ubuntu/Zorin box with Secure Boot on by default:
   - **Secure Boot rejects the unsigned DKMS module.** The kernel then
     transparently loads the distro-signed in-tree `ov02c10`, which still
     rejects 26 MHz → exact reported symptom. The previous installer only
     printed a weak one-line hint about this at the very end.
   - **DKMS build failed** for `6.17.0-23-generic` (missing matching
     `linux-headers-$(uname -r)` on a fresh HWE/mainline kernel), and the old
     installer's verification (`dmesg` still shows error OR `dkms ... installed`)
     would *falsely report success* because the in-tree probe error is always
     present pre-reboot.
   - The `webcam-fix-libcamera` step `[6/14]` detection itself is sound
     (dmesg/journalctl grep, model-agnostic), so it does fire for 940XGK; the
     failure was in *taking effect*, not in *detection*.

## Fix implemented (working-tree changes)

- **`ov02c10-26mhz-fix/install.sh`** — rewritten to make the override actually
  take effect:
  - Secure Boot detection + MOK signing (apt + dnf) and **automatic MOK
    enrollment queuing**, ported from the proven `speaker-fix` flow.
  - Stale `options ov02c10 ... clk_freq` lines in `/etc/modprobe.d/*.conf` are
    backed up and commented out (kills the confusing dmesg line).
  - Kernel-headers fallback to the generic metapackage; hard error if headers
    for the running kernel are genuinely absent (no silent build failure).
  - `dkms build` failure is caught and the tail of `make.log` is printed
    instead of a misleading "installed successfully".
  - Explicit `depmod -a` + initramfs rebuild so `/updates/` wins on next boot.
  - Honest final verification: reports which `ov02c10.ko` modprobe resolves
    (`/updates/` vs stock) and why it might still be stock.
- **`ov02c10-26mhz-fix/uninstall.sh`** — removes the DKMS signing config and
  refreshes `depmod` (leaves the MOK key/enrollment for other modules).
- **`webcam-fix-libcamera/install.sh` `[6/14]`** — verification no longer
  declares false success; it checks the resolved module path and Secure Boot
  state and gives accurate reboot/MOK guidance.
- **`ov02c10-26mhz-fix/README.md`** — documents the 940XGK model, the Secure
  Boot requirement, and the harmless `clk_freq` message.

## Why this resolves the issue

The reporter's "ran it, rebooted, still broken" is the classic Secure-Boot /
silent-build-failure trap. The hardened installer now (a) signs and enrolls the
module so Secure Boot can't push them back onto the in-tree driver, (b) fails
loudly with the build log instead of a false success, and (c) tells them
exactly which driver is winning and what to do next. The `clk_freq` noise that
made the report look like a parameter issue is removed at its source.

## Diagnostics requested from the reporter

Posted on the issue: `sudo mokutil --sb-state`, `modinfo ov02c10 | grep
filename`, `dkms status`, `ls /etc/modprobe.d/ | xargs grep -l clk_freq`,
`grep -r ov02c10 /etc/modprobe.d/`, and post-reboot `dmesg | grep -i ov02c10`
after re-running `ov02c10-26mhz-fix/install.sh` directly and completing MOK
enrollment.
