# Open PR Review — approve/merge recommendation

Reviewed: 2026-06-15. Repo: `Andycodeman/samsung-galaxy-book-linux-fixes`.
Two PRs open. No CI configured on the repo (status check rollup empty), so
mergeability rests on manual review + the maintainer's own hardware test.

## Actions taken — 2026-07-03 (maintainer authorized "merge if you approve")
- **PR #58 — MERGED** (merge commit `a20fe91`). Clean approve; unblocks the
  404-ing install URLs.
- **PR #60 — held, `CHANGES_REQUESTED` review posted.** Asked the author to drop
  the two `ov02c10.yaml` CCM edits (untested on OV02C10 hardware) and flagged the
  reintroduced `poll()` in the camera-relay hot loop for a 30fps stutter test on
  real hardware before merge. Follow-up (port v0.7 into the non-NixOS shell
  patcher) still to be filed.

| PR | Author | Subsystem | Verdict |
|----|--------|-----------|---------|
| #58 | LucasDondo | docs + install scripts (repo rename) | **Approve & merge** (merge this first) |
| #60 | ang3lo-azevedo | webcam-fix-book5 (Bayer/NixOS/relay) | **Approve with changes** — split out the CCM edits, then merge |

Both branches are `MERGEABLE` against `main` today, but **they overlap in
`README.md` and `webcam-fix-book5/README.md`**, so whichever lands second will
need a trivial rebase. Recommended order: **#58 first, then #60.**

---

## PR #58 — "Updated repo's name/URL" — ✅ APPROVE & MERGE

**What it does.** The repository was renamed `samsung-galaxy-book4-linux-fixes`
→ `samsung-galaxy-book-linux-fixes` (it now covers Book3/Book4/Book5). This PR
sweeps the stale URLs out of the docs and install scripts.

**Why it matters (not cosmetic).** Two of the changed lines are in **install
scripts**, not just prose:
- `mic-fix/install.sh` — the "file an issue" URL.
- `webcam-fix-libcamera/install.sh` — **4 occurrences**, including the
  `raw.githubusercontent.com/.../ov02c10-26mhz-fix` and `ipu-bridge-fix`
  download URLs the installer `curl`s at runtime. The old name **404s**, so on
  a fresh `curl | tar | install` run those fetches fail.

This is the exact breakage that bit the reporter in issue #51 (they had to
hand-correct the `book4` → `book` curl URL). The `speaker-fix/README.md`
one-liner `curl ... | tar xz && cd samsung-galaxy-book4-...-main/...` is also a
copy-paste-and-fail today.

**Coverage check.** I grepped the tree for `samsung-galaxy-book4-linux-fixes`:
#58 fixes every shipped occurrence (all 4 in `webcam-fix-libcamera/install.sh`,
plus the single hits in `mic-fix/install.sh` and each README). The only
remaining match is `docs/triage/issue-51-notes.md`, which is an internal triage
note, not a shipped artifact — correctly out of scope.

**Risk.** Essentially none. URL string substitutions plus some
blank-line-after-heading markdown reflow (harmless lint churn — mild scope
creep, not worth blocking on). No code logic touched.

**Recommendation:** Approve and merge as-is. Land this one first; it's the
lowest-risk, highest-value PR and it unblocks broken installs in the wild.

---

## PR #60 — "book5: NixOS support, Bayer fix v0.7, V4L2 monitor improvements" — ⚠️ APPROVE WITH CHANGES

A substantive, well-documented PR. Most of it is good. There is **one change I'd
carve out before merging** and **one gap worth a follow-up**. Tested by the
author on Galaxy Book5 Pro 16" (960XHA), NixOS, kernel 7.0.10-cachyos.

### Part-by-part

**1. `bayer-fix-v0.7.patch` (new) — GOOD, but only reaches NixOS users.**
The patch fixes the "Broken pipe / Inappropriate ioctl" failure on newer IPU7
kernels that enforce V4L2 link validation. The approach is sound and matches
what we already know is the right layer: keep the kernel-facing `videoFormat`
matching the bus code (so link validation passes), and pass the *true flipped
Bayer order* only to the SoftwareISP via a separate `ispFormat`. This is the
correct fix for the EPIPE class of problems we've hit before (changing the
media-bus format to express the flip is what angered the driver).

> **Gap to flag:** the `.patch` files are consumed **only** by the NixOS overlay
> (`nixos/webcam-fix-book5.nix` `overrideAttrs { patches = [...] }`). The
> non-NixOS installer applies the Bayer fix through an **embedded Python
> patcher inside `webcam-fix-book5/libcamera-bayer-fix/build-patched-libcamera.sh`**,
> which this PR does **not** update. So Ubuntu/Fedora/Arch users on newer IPU7
> kernels still hit the broken pipe — they don't get the v0.7 logic. This is
> *not a regression* (their path is unchanged), but the headline fix is only
> half-delivered. Recommend a follow-up issue: port the v0.7 "keep videoFormat,
> feed flipped order to ISP only" logic into the shell installer's patcher.

Minor: the v0.7 rotation-override hunk broadens the env-var gate from
`ov02e10` to `ov02e10 || ov02c10`. Harmless in practice (`LIBCAMERA_FORCE_OV02E10_ROTATION`
is only ever set by the Book5 module, and Book5 sensors are ov02e10), but it
contradicts the PR's own doc text that says "restricted to ov02e10." Cosmetic.

**2. `camera-relay-monitor.c` — black-frame pumping during startup — GOOD, but
needs the maintainer's stutter test before trusting it.**
Reintroduces `poll()` (100 ms timeout) into `read_full()` to pump black frames
during the ~2–3 s pipeline startup, so strict clients like OBS (166 ms
`select()` timeout) don't disconnect before the first real frame.

The logic is careful: the black-frame branch only fires on `poll()` timeout
(`ret == 0`) **when no partial frame is in flight** (`total == 0`) and the
output fd is writable (non-blocking `POLLOUT` check). During normal 30 fps
streaming, frames arrive every 33 ms < 100 ms, so `poll()` returns `>0`
immediately and the read proceeds — the pump never triggers.

> **Caution:** this directly re-touches the hot frame loop that was
> *deliberately changed to remove `poll()`* (commit 9525152, because `poll()`
> between `read_full()`/`write()` caused periodic stutter). The author is aware
> and the reasoning addresses it, but this contradicts a hard-won past fix.
> **Before merging, the maintainer should re-run the 30 fps stutter test on
> real hardware** to confirm no regression. If clean, it's a genuine
> improvement for OBS users.

**3. NixOS module (`webcam-fix-book5.nix`) — GOOD.**
- Generalises the hardcoded `RELAY_COLOR_FILTER="videoflip method=vertical-flip"`
  into a user-settable `relayColorFilter` option (default `""`). Consistent with
  the shared `camera-relay` script, which already consumes `RELAY_COLOR_FILTER`
  as an env var (`camera-relay:385-390, 559-560`). Cleaner than the old
  hardcoded flip.
- Adds `GST_PLUGIN_SYSTEM_PATH_1_0` so the relay finds gstreamer plugins under
  Nix. Reasonable.
- Renames the v4l2loopback `card_label` to "Built-in Front Camera" (NixOS only)
  and teaches `detect_loopback_device()` in the shared script to recognise that
  label (additive — it still matches "Camera Relay"). Cosmetic and safe.

> **Note (not a blocker):** the non-NixOS installer's Chrome-visibility udev
> rule matches `ATTR{name}=="Camera Relay"` (`webcam-fix-book5/install.sh:936`).
> The rename is NixOS-only and the NixOS module doesn't ship that udev rule, so
> nothing breaks. But the two paths now use different card labels — worth
> keeping in mind if the capabilities rule is ever ported to NixOS.

**4. `ov02c10.yaml` CCM changes (both copies) — 🔴 CARVE THIS OUT.**
The PR rewrites the colour-correction matrix in **both**
`webcam-fix-book5/ov02c10.yaml` and `webcam-fix-libcamera/ov02c10.yaml`
(green row `-0.03, 0.92, -0.03` → `-0.10, 1.30, -0.20`, etc. — a much more
aggressive green-boost/saturation matrix).

Two problems:
- **The author can't have validated it on the affected sensor.** Their test
  device (960XHA) uses the **OV02E10** sensor, and the PR does **not** touch
  `ov02e10.yaml`. The OV02C10 matrix is the default for **Book3/Book4** users
  (via `webcam-fix-libcamera`) plus OV02C10-variant Lunar Lake machines.
- **It overrides a deliberately conservative shipped default.** The repo ships a
  near-identity OV02C10 matrix on purpose (the sensor is uncalibrated upstream)
  and hands users `tune-ccm.sh` to dial in their own. Changing the global
  default based on an unrelated device risks regressing colour for every
  existing OV02C10 user who's happy with the current output.

**Recommendation for #60:** ask the author to drop the two `ov02c10.yaml` hunks
(they're orthogonal to "Book5 NixOS + Bayer v0.7"). If they have a genuinely
better OV02C10 matrix, it belongs in its own PR with OV02C10-hardware
confirmation, or as a `tune-ccm.sh` preset rather than the shipped default.
Everything else in #60 is mergeable.

### Net recommendation for #60
Approve **after**: (a) removing the two `ov02c10.yaml` CCM edits, and (b) the
maintainer's 30 fps no-stutter test on the monitor change. Open a follow-up to
port v0.7 into the shell installer's Python patcher so non-NixOS users get the
newer-kernel fix too.

---

## Suggested actions for the maintainer
1. Merge **#58** now (fixes broken install URLs; lowest risk).
2. On **#60**: request dropping the `ov02c10.yaml` CCM hunks; run the monitor
   stutter test; rebase onto post-#58 `main` (README overlap). Then merge.
3. File a follow-up: "Port bayer-fix v0.7 logic into
   `build-patched-libcamera.sh` so Ubuntu/Fedora/Arch get the newer-IPU7-kernel
   broken-pipe fix, not just NixOS."

> Merging is outward-facing and hard to reverse — these are recommendations for
> the maintainer's final call, not self-merge instructions. Nothing here was
> committed or merged.

---

# Re-review of PR #60 — 2026-07-12 (after ang3lo-azevedo's fixes)

**Verdict: ⚠️ Approve with ONE change — revert `build-patched-libcamera.sh` out of
this PR, then merge.** The two blocking notes from the 2026-07-03 review are both
addressed. But the author also went ahead and did the *follow-up* (porting v0.7
into the non-NixOS shell patcher), which was explicitly scoped as **not blocking
this PR** — and that port silently changes the Bayer order for every existing
Ubuntu/Fedora/Arch Book5 user, on a code path he cannot have tested.

Net diff against current `origin/main` is 7 files; `MERGEABLE`.

## Review note → what actually landed

| Review note | Verdict | Evidence |
|---|---|---|
| 1. Drop both `ov02c10.yaml` CCM edits | ✅ **Done** | Reverted in `ec0f130`. `git diff origin/main...pr60 -- '*ov02c10.yaml' '*ov02e10*.yaml'` is empty — *both* copies untouched, so the "landed in one copy only" failure mode did not occur. |
| 2. `poll()` back in the relay hot loop → needs a 30 fps stutter test | ✅ **Cleared — no hardware needed** | Automated: `camera-relay/tests/relay-loop-bench.c`. No stutter, and the black-frame pump is confirmed to do its job. Numbers below. |
| 3. Rebase onto post-#58 `main` (README conflict) | ✅ **Done** | Merge `9106954`; README conflict resolved; GitHub reports `MERGEABLE`. |
| (follow-up, *not requested*) port v0.7 into the shell installer | ❌ **Blocker** | Done anyway in `ec0f130` — see below. |

## Verified good

- **`bayer-fix-v0.7.patch`** applies **cleanly** to libcamera **v0.6.0 and v0.7.0**
  (`patch -p1 --dry-run` against both upstream trees), so the Nix overlay is safe
  whichever libcamera nixpkgs pins. The `videoFormat`/`ispFormat` split is the
  right fix for the IPU7 link-validation EPIPE.
- **`camera-relay-monitor.c` — the stutter gate is cleared, and it did not need a
  Galaxy Book.** The frame loop reads a *pipe* and writes an *fd*; neither end
  cares that the bytes came from an OV02E10. So the whole question is testable on
  any machine, and I wrote `camera-relay/tests/relay-loop-bench.c` to do it: it
  drives both the old blocking loop and the PR's poll loop with a synthetic 30 fps
  1080p YUY2 producer and fails (non-zero exit) on either regression.

  ```
  30fps streaming — the poll loop must not stutter (baseline: blocking read)
    blocking       frames=149  mean= 33.33ms  p99= 35.31ms  max= 35.86ms  late(>40ms)=0
    poll loop      frames=149  mean= 33.33ms  p99= 36.78ms  max= 36.86ms  late(>40ms)=0

  2500ms pipeline startup — the device must not go silent past OBS's timeout
    blocking       black_frames=0    longest_silence=  2506ms  OBS(166ms) -> DISCONNECTS
    poll loop      black_frames=24   longest_silence=   102ms  OBS(166ms) -> stays connected
  ```

  **No stutter** — the two loops are indistinguishable, and run-to-run variance
  exceeds the difference between them. Worth knowing *why* 9525152 doesn't repeat
  here: that commit's `poll()` sat between `read_full()` and `write()`, adding a
  wakeup to every frame's *delivery*. This `poll()` sits *before each read*, where
  the thread was already going to block anyway — so it costs one extra syscall per
  64 KB pipe chunk (~1,900/sec, unmeasurable) and adds no latency to delivery.

  **And the pump earns its keep:** the old loop leaves a client staring at 2.5 s of
  silence during pipeline startup, which is exactly why OBS drops out. Static
  review is clean too — `<poll.h>`/`<errno.h>` already included, `black_frame` is
  `malloc(frame_size)` and `read_full()` is only ever called with `n ==
  frame_size` (so the pump can't over-read), the pump is gated on `total == 0` (so
  it never fires mid-frame), and the `POLLOUT` check is non-blocking (so it can't
  stall the pipeline).

  One accepted behaviour change, worth knowing but not blocking: if the camera
  hiccups mid-stream for >100 ms, the client now sees a black frame rather than a
  frozen last frame. That's the deliberate trade for keeping OBS attached.
- **NixOS module.** Dropping `RELAY_COLOR_FILTER=videoflip` when `videoFlip=true`
  is *correct*, not a regression: both v0.6 and v0.7 compose
  `combinedTransform_ * Transform::Rot180`, so libcamera already flips the sensor
  via its V4L2 flip controls and the frame leaves `libcamerasrc` upright. The old
  relay `videoflip method=vertical-flip` was a second — and only *partial*
  (VFlip-only, not Rot180) — flip on top. Replacing it with the opt-in
  `relayColorFilter` string is a clean generalisation, and he owns/tests this module.

## ❌ The blocker: `webcam-fix-book5/libcamera-bayer-fix/build-patched-libcamera.sh`

This is the shipped path for **every non-NixOS Book5 user**. NixOS consumes the
`.patch` through the Nix overlay and *never runs this script* — so nothing in the
author's testing exercises the code he changed here.

I ran both patchers against real upstream libcamera sources. They produce
**different Bayer orders**:

| | ISP Bayer order | For `Rot180` |
|---|---|---|
| **`main` today (v0.6)** | `native ^ (combinedTransform & 1)` — HFlip bit **only** | `native ^ 1` |
| **This PR (v0.7)** | `sensor_->bayerOrder(combinedTransform)` → `BayerFormat::transform()`, which XORs bit0 on HFlip **and** bit1 on VFlip | `native ^ 3` |

`^1` and `^3` are different orders, i.e. different colours. The `^1` value is not
arbitrary — main's code comment records it as empirically derived ("*OV02E10 only
shifts the bayer pattern for HFlip, not VFlip*") and it is the version confirmed
working on **940XHA/Fedora** (david-bartlett) and **960XHA/Ubuntu** (jn-simonnet).
This PR would flip all of them to `^3` with no OV02E10-on-Ubuntu/Fedora/Arch
confirmation. If the recorded comment is right, that is a straight purple-tint
regression for the existing user base.

Two further losses, both in the **primary** patch path (they survive only in the
legacy v0.5 branch):

1. **`LIBCAMERA_BAYER_ORDER=0..3`** — the manual escape hatch when auto-detection
   picks the wrong order.
2. **The `[BAYER-FIX] transform=… origOrder=… newOrder=…` log line** — this is the
   line we ask users to grep for to prove the patched lib is actually loaded (it's
   in the reply on #49). The separate `[BAYER-FIX] dispatch:` log survives, but the
   order log does not.

**Ask:** `git checkout origin/main -- webcam-fix-book5/libcamera-bayer-fix/build-patched-libcamera.sh`,
force-push, merge the rest. Keep the port as the already-planned follow-up issue,
where the `^1`-vs-`^3` question can be settled on OV02E10 hardware running the
shell installer — and where the two diagnostics can be carried across.

**Nit (non-blocking):** `bayer-fix-v0.6.patch` is now referenced by nothing. Fine
to leave as a fallback record; worth deleting if you'd rather not keep dead files.

## Do we need more testers?

**No — not for anything this PR should merge with.** Once
`build-patched-libcamera.sh` is reverted out, every remaining change is either
(a) machine-verified here, or (b) NixOS-only, where the author *is* the tester
and the blast radius is his own module:

| Change | Blast radius | Confidence | Rests on |
|---|---|---|---|
| `camera-relay-monitor.c` poll/pump | **All users** | **High** | Measured on this machine (bench above), not opinion |
| `bayer-fix-v0.7.patch` | NixOS only | **High** | Applies cleanly to libcamera 0.6.0 + 0.7.0; confirmed on his 960XHA |
| `nixos/webcam-fix-book5.nix` | NixOS only | **High** | Author owns/tests the module; relay double-flip removal is logically sound |
| `camera-relay` loopback regex | All users | **High** | Purely additive — one more name matched |
| `build-patched-libcamera.sh` | **All non-NixOS Book5** | **Low — drop it** | Untested on the path it changes; contradicts the confirmed `^1` |

The **only** thing that genuinely needs a tester is the `^1`-vs-`^3` Bayer
question — and that's precisely why it belongs in the follow-up issue and not in
this PR. When we get there, the tester needs to be someone with an **OV02E10 on a
non-NixOS distro running the shell installer**: david-bartlett (940XHA/Fedora),
jn-simonnet (960XHA/Ubuntu), or noopduck (Book5/Fedora, already mid-thread on #49).

## Actions taken — 2026-07-13 (maintainer authorized posting)

- **PR #60 — `CHANGES_REQUESTED` review posted** (as `Andycodeman`, 2026-07-13).
  Contents of `docs/triage/pr-60-reply.md`: both original notes confirmed
  addressed, monitor change cleared with the bench numbers, and the single ask to
  revert `build-patched-libcamera.sh` out of the PR.
- **Issue #69 opened** — ["Port bayer-fix v0.7 into the shell installer (non-NixOS)
  — and settle the OV02E10 ^1-vs-^3 Bayer order"](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/issues/69).
  Writes up the `^1`-vs-`^3` contradiction, tags @david-bartlett / @jn-simonnet /
  @noopduck as candidate testers, and makes "keep `LIBCAMERA_BAYER_ORDER` and the
  `[BAYER-FIX]` order log" an explicit acceptance criterion. Notes that the
  existing `LIBCAMERA_BAYER_ORDER=0..3` override makes the question cheap to test
  without a rebuild.
- **Not merged.** #60 stays open until he pushes the one-file revert. Merging is
  yours to do.

## Still open

1. Wait for ang3lo-azevedo to revert `build-patched-libcamera.sh`, then **merge #60**.
   Nothing else is outstanding on it.
2. Recruit a tester on #69 to settle `^1` vs `^3`.
