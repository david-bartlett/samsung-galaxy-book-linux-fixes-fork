# Reply posted to PR #60 (ang3lo-azevedo)

Status: **POSTED 2026-07-13** as a `CHANGES_REQUESTED` review. Kept here as the
record of what was said.

---

Thanks — both of the blocking notes are properly addressed, and I checked the code rather than the thread:

- **`ov02c10.yaml` CCM edits: dropped.** Confirmed *both* copies (`webcam-fix-book5/` and `webcam-fix-libcamera/`) are byte-identical to `main` now, so nothing snuck through in only one of them. 👍
- **Rebase: done**, README conflict from #58 is gone, GitHub says `MERGEABLE`.
- **`bayer-fix-v0.7.patch`**: I test-applied it against upstream libcamera **v0.6.0 and v0.7.0** — clean on both, so the Nix overlay is safe whichever version nixpkgs pins. The `videoFormat`/`ispFormat` split is exactly the right shape for the IPU7 link-validation EPIPE.
- **`camera-relay-monitor.c`: the stutter concern is dead — you were right.** I said I'd test this on hardware, then realised I didn't need to: the frame loop reads a *pipe* and writes an *fd*, so it's testable anywhere. I added `camera-relay/tests/relay-loop-bench.c`, which drives both the old blocking loop and your poll loop with a synthetic 30 fps 1080p YUY2 producer:

  ```
  30fps streaming — the poll loop must not stutter (baseline: blocking read)
    blocking       frames=149  mean= 33.33ms  p99= 35.31ms  max= 35.86ms  late(>40ms)=0
    poll loop      frames=149  mean= 33.33ms  p99= 36.78ms  max= 36.86ms  late(>40ms)=0

  2500ms pipeline startup — the device must not go silent past OBS's timeout
    blocking       black_frames=0    longest_silence=  2506ms  OBS(166ms) -> DISCONNECTS
    poll loop      black_frames=24   longest_silence=   102ms  OBS(166ms) -> stays connected
  ```

  Indistinguishable at 30 fps, and your pump does exactly what you said it does. For the record on why 9525152 doesn't repeat here: *that* `poll()` sat between `read_full()` and `write()`, adding a wakeup to every frame's delivery. Yours sits before each read, where the thread was going to block anyway — so it costs one extra syscall per 64 KB pipe chunk and adds nothing to delivery latency. Good instinct putting it there. The bench fails non-zero on either regression, so this is now a standing test rather than something a maintainer has to remember to eyeball.
- **NixOS module**: dropping `RELAY_COLOR_FILTER=videoflip` when `videoFlip=true` is right, and I agree with your reasoning — both v0.6 and v0.7 compose `Transform::Rot180`, so libcamera already flips the sensor and the old relay `videoflip` was a second (and only VFlip-partial) flip on top. `relayColorFilter` as an opt-in string is a nice generalisation.

**One thing I need reverted before merge: `webcam-fix-book5/libcamera-bayer-fix/build-patched-libcamera.sh`.**

I know I flagged the shell-installer port as a follow-up, and I appreciate you taking a run at it — but it needs to land as its own PR, because it changes behaviour for users neither of us can test from here. NixOS consumes the `.patch` through the Nix overlay and never runs this script; this script is the shipped path for every **Ubuntu / Fedora / Arch** Book5 user.

I ran both patchers against real libcamera sources, and they emit **different Bayer orders**:

| | ISP Bayer order | for `Rot180` |
|---|---|---|
| `main` today | `native ^ (combinedTransform & 1)` — HFlip bit **only** | `native ^ 1` |
| this PR | `sensor_->bayerOrder(...)` → `BayerFormat::transform()`, XORs bit0 on HFlip **and** bit1 on VFlip | `native ^ 3` |

That `^1` isn't arbitrary — it's empirically derived (the comment in `main` records that OV02E10 only shifts its Bayer pattern on HFlip, *not* VFlip), and it's the version confirmed working on **940XHA/Fedora** and **960XHA/Ubuntu**. Switching those users to `^3` untested is a straight purple-tint regression risk for the existing base. It may well turn out that `^3` is the correct value and the old comment is wrong — but that's a question to settle *with OV02E10 hardware running the shell installer*, which is precisely what the follow-up issue is for.

The same hunk also drops two things from the primary patch path (they survive only in the legacy v0.5 branch):

1. the `LIBCAMERA_BAYER_ORDER=0..3` manual override — the escape hatch when auto-detection picks the wrong order;
2. the `[BAYER-FIX] transform=… origOrder=… newOrder=…` log line — which is the line I ask users to grep for to prove the patched libcamera is actually loaded (see #49). The `[BAYER-FIX] dispatch:` log survives, but not the order one.

So:

```bash
git checkout origin/main -- webcam-fix-book5/libcamera-bayer-fix/build-patched-libcamera.sh
git commit -m "revert: keep shell installer's bayer patcher out of this PR"
git push
```

…and I'll merge as soon as that lands — nothing else is outstanding. I'll open the shell-installer port as its own issue and tag you on it, with the `^1`-vs-`^3` question written up, since your v0.7 work is what makes it answerable. If you want to take that one too it's yours; it just needs an OV02E10 tester on a non-NixOS distro to settle which XOR is actually right.

Really nice work on this — the v0.7 patch and the OBS keepalive are both solid. Thanks for sticking with it.
