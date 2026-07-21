# Issue #65 — "Webcam doesn't work on Galaxy Book5 Pro 360 960QHA" (@seshf)

**Status:** fix implemented, **unverified on the reporter's hardware**. Reply
**posted** 2026-07-21 with maintainer sign-off —
[comment-5039649723](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/issues/65#issuecomment-5039649723).
Awaiting the reporter's `dpkg -l gstreamer1.0-tools` output and confirmation
that the camera appears in Firefox.

Hardware: Galaxy Book5 Pro 360 **960QHA**, IPU7 + **OV02E10**, Kubuntu 26.04,
kernel 7.1.1-070101-generic, Wayland.

---

## What the thread actually established

The reporter's own commands rule out every layer we'd normally suspect:

| Evidence | Conclusion |
| --- | --- |
| `bind ov02e10 3-0010`, `All sensor registration completed` | kernel + IPU7 fine |
| `cam -l` → `1: Internal front camera (\_SB_.LNK0)` | libcamera enumerates fine |
| `[BAYER-FIX] transform=3 … override=auto` | our patched libcamera **is** loaded |
| `gst-launch-1.0 libcamerasrc ! videoconvert ! autovideosink` → **working picture**, 30 fps | the whole camera stack works |
| `gst-inspect-1.0 libcamerasrc` → found, `/usr/lib/x86_64-linux-gnu/gstreamer-1.0/libgstlibcamera.so` | the plugin is installed |
| `lsmod` → `v4l2loopback 61440 0` | loopback module loaded |
| Firefox/Brave/Chromium → `NotFoundError` | **nothing is feeding the loopback** |

And the failure itself:

```
$ camera-relay start
ERROR: GStreamer 'libcamerasrc' element not found. Install it:
  ...
  Ubuntu/Debian: sudo apt install gstreamer1.0-libcamera

$ sudo apt install gstreamer1.0-libcamera
gstreamer1.0-libcamera ist schon die neueste Version (0.7.0-1ubuntu2).
```

So the relay refused to start, claiming a package was missing that was already
installed — and the element it claimed was missing demonstrably worked.

The `intel-ipu7-psys … -22` and `Unable to get rectangle` messages in the
original report are noise; they appear on working systems (already answered in
the thread).

## Root cause

`gst-inspect-1.0` and `gst-launch-1.0` ship in **`gstreamer1.0-tools`** on
Debian/Ubuntu (`gstreamer1` on Fedora, `gstreamer` on Arch). Verified locally:

```
$ dpkg -S $(command -v gst-inspect-1.0)   → gstreamer1.0-tools
$ dpkg -S $(command -v gst-launch-1.0)    → gstreamer1.0-tools
$ apt-cache depends gstreamer1.0-libcamera   → no dependency on gstreamer1.0-tools
```

**No installer in this repo ever installs that package**, and nothing else in
the dependency graph pulls it in. Yet `gst-launch-1.0` *is* the relay pipeline
(`camera-relay/camera-relay:456`), and `gst-inspect-1.0` is how the relay and
both installers probe for `libcamerasrc`.

When the binary is absent, `gst-inspect-1.0 libcamerasrc &>/dev/null` exits
**127**, which is indistinguishable from "element not found" to a bare `if !`.
The recovery ladder in `setup_environment()` then retries three times — clear
the registry cache, drop the `/usr/local` overrides — and all three fail
identically, because none of them make the missing binary appear. The relay dies
pointing at the wrong package, which is the dead end the reporter spent the
thread in.

### Why the reporter's paste pins this down

Their output is *only* the `ERROR:` block — no `[camera-relay] Using GStreamer
plugin: …` and no `WARNING: Source-built libcamerasrc … failed to load`. Those
two lines are emitted whenever `detect_gst_plugin_path` / `detect_libcamera_lib_path`
find anything under `/usr/local`. Their absence proves there were **no
`/usr/local` overrides in play**, so all three ladder attempts ran in a pristine
environment — the same environment in which their own `gst-inspect-1.0
libcamerasrc` succeeded 90 minutes later. A missing binary is the only
explanation that fails in that environment and is unaffected by all three
recovery steps.

Reproduced locally by running the pre-fix `camera-relay` with an empty `PATH`;
it emits the reporter's error text verbatim.

**Residual uncertainty:** the reporter's later commands show `gst-inspect-1.0`
working, so they installed `gstreamer1.0-tools` at some point between 20:13 and
21:56 UTC without pasting it (their pasted `apt install gstreamer1.0-libcamera`
installed nothing). The reply asks them to confirm with
`dpkg -l gstreamer1.0-tools`. If it turns out to have been installed all along,
the diagnostics added here will print GStreamer's real complaint on the next
attempt, which is the information the current message throws away.

## Fix

**`camera-relay/camera-relay`**

- `require_gst_tools()` — checks `gst-inspect-1.0` **and** `gst-launch-1.0` up
  front and names `gstreamer1.0-tools` / `gstreamer1` / `gstreamer`. Called
  from `setup_environment()` and `cmd_enable_persistent()` (the latter also
  probes with `gst-inspect-1.0`; with the tools missing it silently baked
  system-only paths into a unit for a relay that could not run).
- `find_libcamera_gst_plugin()` — when `libcamerasrc` genuinely won't load but
  `libgstlibcamera.so` is on disk, say *that* and print `gst-inspect-1.0`'s real
  stderr plus the three commands worth running, instead of telling the user to
  install a package they already have.
- `cmd_status()` — the `Loopback:` line read only the runtime cache, so it
  printed `(not loaded)` whenever the relay had never started, even with the
  module loaded and a device present. Now falls back to
  `detect_loopback_device`, mirroring the `Camera:` line. This actively misled
  the reporter, whose `lsmod` contradicted it.

**`webcam-fix-book5/install.sh`, `webcam-fix-libcamera/install.sh`**

- Install the GStreamer CLI tools before any `gst-inspect-1.0` probe. In
  `webcam-fix-libcamera` this is `ensure_gst_tools()`, called before the
  `verify_libcamerasrc` gate — that gate is a hard `exit 1`, so a host without
  the tools previously aborted the whole install with a false diagnosis.
- Corrected the Ubuntu/Debian remedy package for a genuinely missing
  `libcamerasrc`: `gstreamer1.0-libcamera` (was `gstreamer1.0-plugins-bad`,
  which does not contain the element on Ubuntu), keeping the old package as a
  fallback.

NixOS needs no change — `nixos/webcam-fix-book5.nix:130` already wraps the relay
with `pkgs.gst_all_1.gstreamer`, which provides both binaries.

## Verification

`camera-relay/tests/test-gst-tools-check.sh` (new, 7 assertions, no camera
hardware required, no system state touched — it redirects `XDG_CACHE_HOME` so the
recovery ladder cannot clear the real GStreamer registry):

1. with the tools unreachable, `start` fails naming `gstreamer1.0-tools` and
   **not** `gstreamer1.0-libcamera`;
2. `find_libcamera_gst_plugin` locates an installed plugin;
3. with a stub `gst-inspect-1.0` that always fails, the error says the plugin
   *is* installed and echoes GStreamer's own stderr;
4. `status` reports the live loopback device instead of `(not loaded)`.

Results — **7/7 pass** on the fixed code. Against `HEAD:camera-relay/camera-relay`
the suite fails, and the old run reproduces the reporter's error text verbatim
(including the absence of the `WARNING: Source-built libcamerasrc …` line when no
`/usr/local` build is present). All modified scripts pass `bash -n`.

Running the new diagnostic branch caught a `set -euo pipefail` bug in the fix
itself: `inspect_err=$(gst-inspect-1.0 … | tail -5)` aborted the script before it
could print, since `gst-inspect-1.0` exits non-zero there by definition. Fixed
with `|| true`; the branch was only proven by executing it, not by reading it.

**Not verified:** nothing here was run on a 960QHA. There is no Book5 hardware
in this environment, so "the reporter's camera now works in Firefox" is a
hypothesis, not a result. What is verified is that the relay no longer
misdiagnoses a missing `gstreamer1.0-tools`, and that new installs get the
package.

## Reply posted to #65 (2026-07-21, signed off)

> Your last three comments cracked it — thank you, that was exactly the missing
> signal.
>
> `gst-launch-1.0 libcamerasrc ! videoconvert ! autovideosink` giving you a good
> picture means the camera, the kernel, IPU7, our patched libcamera and the bayer
> fix are all working. The only broken piece is `camera-relay`, the little daemon
> that copies frames into the v4l2loopback device that Firefox/Brave/Chromium
> actually look at. It refused to start, so nothing was feeding that device —
> hence `NotFoundError` in every browser.
>
> **And it refused to start for a silly reason: our own bug.**
>
> `camera-relay` checks for `libcamerasrc` by running `gst-inspect-1.0`. On
> Debian/Ubuntu that binary — and `gst-launch-1.0`, which *is* the relay's
> pipeline — comes from **`gstreamer1.0-tools`**, a package that
> `gstreamer1.0-libcamera` does not depend on and that **none of our installers
> ever installed**. When it's missing, the check exits 127, which our code could
> not tell apart from "element not found", so it told you to install
> `gstreamer1.0-libcamera` — which you already had. Sorry for the runaround; you
> were being sent to fix the one thing that wasn't broken.
>
> **On your machine, right now:**
>
> ```bash
> sudo apt install gstreamer1.0-tools
> camera-relay start
> ```
>
> Then reload the webcam test page. If `camera-relay start` prints
> `Relay started (PID …)`, you should have a camera in Firefox and Chromium.
> To have it come back automatically at login: `camera-relay enable-persistent`.
>
> Could you also paste `dpkg -l gstreamer1.0-tools` before you install anything?
> Your later comments show `gst-inspect-1.0` working, so you may have installed
> it in between — if it was there all along my diagnosis is wrong and I want to
> know that rather than guess.
>
> **What I've fixed** (in review, landing on `main` shortly — the install
> commands pull from `main`, so re-running the installer once it's pushed will
> pick all of this up):
>
> - both installers now install `gstreamer1.0-tools` / `gstreamer1` / `gstreamer`
>   before they probe for anything, so this can't happen on a fresh install;
> - `camera-relay` now reports a missing `gst-inspect-1.0`/`gst-launch-1.0` as
>   exactly that, and when `libcamerasrc` really won't load it prints GStreamer's
>   own error plus the plugin path it found instead of guessing a package name;
> - `camera-relay status` no longer says `Loopback: (not loaded)` when the module
>   is loaded — your `lsmod` output disagreed with it, and `lsmod` was right;
> - fixed the Ubuntu remedy package for a genuinely missing `libcamerasrc`
>   (`gstreamer1.0-libcamera`, not `gstreamer1.0-plugins-bad`).
>
> **Honesty note:** I have no Book5 to test on, so I have verified this against
> the failure mode, not against your laptop. I reproduced your exact error text
> locally by hiding `gst-inspect-1.0`, and there's a regression test covering it —
> but whether your camera appears in Firefox afterwards is the part only you can
> confirm. Please report back either way.
