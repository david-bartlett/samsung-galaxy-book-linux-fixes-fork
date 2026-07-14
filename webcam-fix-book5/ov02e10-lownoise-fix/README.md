# OV02E10 low-light test — does more exposure kill the vertical lines?

**Experimental. Not part of any install. Not a fix — a test.** See
[#67](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/issues/67).

## The question

Book5 (OV02E10) users see **vertical stripes in low light**. That's column
fixed-pattern noise in the sensor's analog readout, and it scales with **analog
gain**. In a dim room AGC pegs at the sensor's maximum gain (**15.5×**) — because
it has already run out of *exposure time* — so the FPN gets amplified fifteenfold.

Exposure is capped at `vts_def - 2` = **2242 lines**. If we raise that ceiling,
AGC should be able to hold the shutter open longer and use **less gain** — which
should make the stripes recede. This module exists to find out whether that's true.

## Why it needs a kernel module at all

You cannot do this from userspace. Setting `V4L2_CID_VBLANK` with `v4l2-ctl` gets
wiped the instant a camera opens, and even if it didn't, it wouldn't help:

- The stock driver **resets VBLANK to the mode default on every `set_fmt`**
  (`__v4l2_ctrl_modify_range(..., vblank_def)`), and libcamera calls `setFormat()`
  during `configure()`.
- libcamera's **simple pipeline never touches VBLANK** and has no frame-duration
  control.
- libcamera's soft IPA **caches `exposureMax` at `configure()` time**
  (`soft_simple.cpp:217`), so a later VBLANK change is ignored anyway.

So the mode's VTS has to be bigger *before* libcamera configures. Hence a module
parameter.

## Build and run

```bash
make
sudo rmmod ov02e10
sudo insmod ./ov02e10.ko vts=4488
```

`vts=0` (the default) is stock behaviour, byte-for-byte. Nothing changes unless
you opt in.

| `vts` | frame rate | exposure ceiling |
|-------|-----------|------------------|
| 2244 (stock) | 30.0 fps | 2242 lines (33.3 ms) |
| 3366 | 20.0 fps | 3364 lines (49.9 ms) |
| 4488 | 15.0 fps | 4486 lines (66.5 ms) |

Frame rate is `SCLK / (hts × vts)` = `36 MHz / (534 × vts)`.

### Result: `vts` alone is not enough

Tested on 940XHA (#67). At `vts=4488` — 15 fps, a **doubled** 66.5 ms exposure
window — AGC consumed the entire window and *still* settled at `analogue_gain =
248`, the 15.5× maximum. So in a genuinely dim scene, twice the exposure does not
buy enough light to let AGC back off. The exposure lever, on its own, is exhausted.

## Second lever: `max_again`

Since AGC won't voluntarily use less gain, take the choice away from it.

libcamera's soft IPA reads `againMax` straight out of the V4L2 control range at
`configure()` time (`soft_simple.cpp:224`), and its AGC has **no tunable target and
no gain limit of its own** — `agc.cpp` is 174 lines of hardcoded constants, and
nothing in the tuning YAML reaches it. So the driver's gain ceiling *is* AGC's gain
ceiling.

```bash
sudo rmmod ov02e10
sudo insmod ./ov02e10.ko vts=4488 max_again=64    # 15fps, gain capped at 4x
```

| `max_again` | gain cap |
|---|---|
| 248 (stock) | 15.5× |
| 96 | 6× |
| 64 | 4× |
| 32 | 2× |

## The measurement

In the **same dim scene** each time, open the camera and read back what AGC
settles on:

```bash
v4l2-ctl -d /dev/v4l-subdev4 --get-ctrl=analogue_gain,exposure
```

(Your subdev number may differ — find it with `v4l2-ctl --list-devices`.)

This is the experiment that decides whether anything is fixable here:

- **The stripes recede and the image is merely darker** → the FPN *is*
  gain-amplified, a cap is a real mitigation, and we can ship it as an opt-in
  low-noise mode (optionally clawing brightness back with digital gain, which
  amplifies signal and noise equally and so doesn't reintroduce the stripes).
- **The image just gets darker and the stripes stay in proportion** → this is
  plain low-light SNR: the FPN is fixed, the signal is small, and gain isn't the
  culprit — it's merely the messenger. In that case *no* gain or exposure setting
  will ever help, and the only real fix is a per-column correction stage in
  libcamera's SoftISP. That does not exist today (its algorithms are `BlackLevel`,
  `Awb`, `Ccm`, `Adjust`, `Agc`, and `BlackLevel` is a single **global** offset,
  not per-column), so it would be upstream work.

Both outcomes are worth knowing, and the second one is a legitimate answer. Report
the `analogue_gain` value and whether the stripes changed — that *is* the experiment.

## Restore

```bash
sudo rmmod ov02e10 && sudo modprobe ov02e10
```

The stock in-tree driver comes back. This module is never installed, never
DKMS-registered, and doesn't survive a reboot.
