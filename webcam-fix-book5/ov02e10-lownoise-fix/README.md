# OV02E10 low-noise fix — vertical banding in low light

Fixes the **fixed vertical stripes** Galaxy Book5 (OV02E10) users see in dim
rooms. See [#67](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/issues/67).

**Opt-in.** This is not run by `webcam-fix-book5/install.sh` — it replaces the
in-tree sensor driver, and it costs a little SNR. Install it only if the banding
bothers you.

## What's actually wrong

The stripes are **column fixed-pattern noise** in the sensor's *analog* readout —
a small fixed offset that differs from column to column. It is amplified by
**analog gain**, and in a dim room libcamera's AGC drives analog gain to its
**15.5× maximum**, so the FPN gets amplified fifteenfold and the columns become
visible bands.

You cannot fix this in userspace, and it's worth being explicit about why, because
several plausible-looking routes are dead ends:

- **`tune-ccm.sh` / the tuning YAML can't touch it.** libcamera's SoftISP
  algorithms are `BlackLevel`, `Awb`, `Ccm`, `Adjust`, `Agc`. There is no
  per-column stage anywhere, and `BlackLevel` is a single *global* offset. A
  colour matrix cannot express "column 417 reads 3 LSBs high."
- **You can't ask AGC to use less gain.** The soft AGC (`agc.cpp`) is 174 lines of
  hardcoded constants — no tunable target, no gain limit, nothing the tuning file
  reaches. It will chase its brightness target to whatever maximum gain the sensor
  advertises.
- **You can't raise the exposure ceiling from userspace either.** Setting
  `V4L2_CID_VBLANK` with `v4l2-ctl` gets wiped the moment a camera opens: the
  driver resets VBLANK to the mode default on every `set_fmt`, and libcamera calls
  `setFormat()` during `configure()`. Even if you won that race, the soft IPA
  caches `exposureMax` at `configure()` time (`soft_simple.cpp:217`) and ignores
  later changes.

So the sensor driver is the only place this can be fixed.

## The fix

libcamera's soft IPA reads `againMax` straight out of the **V4L2 control range**
(`soft_simple.cpp:224`). So the driver's gain ceiling *is* AGC's gain ceiling.

- **Cap analog gain** at 4× (`max_again=64`). AGC can no longer amplify the column
  FPN fifteenfold.
- **Make the brightness back up with digital gain** (`dgain=1020`, ~4×). Digital
  gain amplifies signal and noise *together*, downstream of the analog column
  chain, so it does not bring the bands back.

Net: **~16× total gain — the same overall brightness as stock — with the banding
gone.**

## Why we know it's a real fix and not just a darker picture

This was the obvious trap: capping analog gain also *dims* the image, and a darker
picture hides noise for free. So it was tested at **matched brightness**
(940XHA, #67):

| config | analog | digital | brightness | result |
|---|---|---|---|---|
| stock | 15.5× | 1× | normal | **heavy vertical banding** |
| `max_again=64` | 4× | 1× | dark | bands gone — but is it just the darkness? |
| `max_again=64 dgain=1020` | 4× | 4× | **normal** | **bands still gone** ✅ |

The third row is the one that matters. At the same brightness as stock, the bands
do not come back. The FPN is genuinely amplified by the *analog* gain path, and
moving amplification to digital sidesteps it.

## Install

```bash
sudo ./install.sh
sudo reboot
```

The driver's own defaults are **stock** — installing it changes nothing on its
own. The low-noise profile is enabled by the modprobe.d file the installer writes:

```
# /etc/modprobe.d/99-ov02e10-lownoise.conf
options ov02e10 max_again=64 dgain=1020
```

Comment that line out to return to stock behaviour without uninstalling.

## Verify

In a **dim** room:

```bash
v4l2-ctl -d /dev/v4l-subdev4 --get-ctrl=analogue_gain,digital_gain
```

Expect `analogue_gain=64` (not 248) and `digital_gain=1020`. If analog gain is
still 248, the module parameters aren't being applied — check that
`modinfo ov02e10 | grep filename` points at `/updates/`.

## Parameters

| param | default | meaning |
|---|---|---|
| `max_again` | 0 (stock, 248 = 15.5×) | Cap analog gain. `64` = 4×, `96` = 6×, `32` = 2×. |
| `dgain` | 0 (stock, 256 = 1×) | Digital gain. `1020` ≈ 4×. |
| `vts` | 0 (stock, 2244 = 30fps) | Frame length. Raises the exposure ceiling at the cost of frame rate. |

### A note on `vts`

`vts` is kept because it's useful for diagnosis, but **it does not fix the banding
on its own** — that was tested. At `vts=4488` (15 fps, a *doubled* 66.5 ms exposure
window) AGC simply consumed the whole window and still went to maximum gain. Twice
the light isn't enough in a genuinely dim room. Don't reach for it expecting a fix.

## Uninstall

```bash
sudo ./uninstall.sh
sudo reboot
```

Removes the DKMS module and the modprobe.d profile; the in-tree driver takes over
again.

## Credits

Diagnosed and confirmed on hardware by
[@hatchlof](https://github.com/hatchlof) ([#67](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/issues/67)),
who ran the controls that ruled out the sensor-helper theory, the CCM theory, the
exposure theory, and finally the "it's just darker" theory.
