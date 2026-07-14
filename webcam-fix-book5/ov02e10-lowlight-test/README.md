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

## The measurement

In the **same dim scene** each time, open the camera and read back what AGC
settles on:

```bash
v4l2-ctl -d /dev/v4l-subdev4 --get-ctrl=analogue_gain,exposure
```

(Your subdev number may differ — find it with `v4l2-ctl --list-devices`.)

Stock, in a dim room, AGC pegs at **analogue_gain = 248** (the 15.5× maximum). The
experiment is simple:

- **Gain drops and the stripes visibly recede** → confirmed. Trading frame rate
  for exposure is a real mitigation, and we can ship it as an opt-in low-light mode.
- **Gain drops but the stripes stay** → the FPN is not gain-dominated, and the only
  real fix is a per-column correction stage in libcamera's SoftISP (which does not
  currently exist — its algorithms are `BlackLevel`, `Awb`, `Ccm`, `Adjust`, `Agc`,
  and `BlackLevel` is a single *global* offset, not per-column).

Both outcomes are worth knowing. Report the `analogue_gain` value either way — that
number *is* the experiment.

## Restore

```bash
sudo rmmod ov02e10 && sudo modprobe ov02e10
```

The stock in-tree driver comes back. This module is never installed, never
DKMS-registered, and doesn't survive a reboot.
