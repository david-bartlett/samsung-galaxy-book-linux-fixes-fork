#!/bin/bash
# tune-ccm.sh — Interactive colour-correction (CCM) tuner for the libcamera
# Software ISP, for the OV02C10 sensor on Intel IPU6 (Galaxy Book3/Book4).
#
# Why this script exists
# ----------------------
# Editing /usr/share/libcamera/ipa/simple/ov02c10.yaml "by hand" often appears
# to have NO effect, for two reasons:
#
#   1. The tuning file is read once, when the camera is opened. The camera-relay
#      service and PipeWire keep a libcamera instance alive, so your edit is not
#      picked up until those are restarted (or you reboot).
#   2. There can be TWO copies of the tuning file: the distro one in
#      /usr/share/libcamera/ipa/simple/ and, if you built libcamera from source
#      (the installer does this on Ubuntu and when --force-libcamera-rebuild is
#      used), a second one in /usr/local/share/libcamera/ipa/simple/. Whichever
#      libcamera is actually loaded reads its own copy — edit the wrong one and
#      nothing changes.
#
# This script writes the chosen matrix to *all* installed copies and restarts
# every consumer (camera-relay, pipewire, wireplumber) so the change takes
# effect immediately.
#
# Usage:  ./tune-ccm.sh
#
# Requires: sudo (to write the tuning files). A camera viewer is opened
# automatically — camera-relay's PipeWire output if the relay is running,
# otherwise qcam (sudo pacman -S libcamera-tools / apt install libcamera-tools).

set -e

# ─── Locate every tuning-file directory libcamera might read ───────────────
TUNING_DIRS=()
for d in /usr/local/share/libcamera/ipa/simple /usr/share/libcamera/ipa/simple; do
    [[ -d "$d" ]] && TUNING_DIRS+=("$d")
done
# If the /usr/local libcamera tree exists but the simple/ data dir doesn't yet,
# create it so a source-built libcamera that searches there finds our file.
if [[ -d /usr/local/share/libcamera && ! -d /usr/local/share/libcamera/ipa/simple ]]; then
    sudo mkdir -p /usr/local/share/libcamera/ipa/simple
    TUNING_DIRS=("/usr/local/share/libcamera/ipa/simple" "${TUNING_DIRS[@]}")
fi
if [[ ${#TUNING_DIRS[@]} -eq 0 ]]; then
    echo "ERROR: no libcamera IPA data directory found."
    echo "       Expected /usr/share/libcamera/ipa/simple/ — is libcamera installed?"
    exit 1
fi

TUNING_FILES=()
for d in "${TUNING_DIRS[@]}"; do
    TUNING_FILES+=("$d/ov02c10.yaml")
done

# ─── Sanity-check the libcamera that 'cam' will load (best effort) ─────────
# A missing OV02C10 sensor helper means auto-exposure / AWB run on a generic
# fallback and the colours will be wrong no matter what CCM you pick. The
# warning is emitted when the camera is configured, so we grab one frame in a
# throwaway directory. Skipped if 'cam' isn't installed or the camera is busy.
if command -v cam >/dev/null 2>&1; then
    _camdir=$(mktemp -d 2>/dev/null || echo /tmp)
    _camlog="$_camdir/cam.log"
    ( cd "$_camdir" && LIBCAMERA_LOG_LEVELS=IPASoft:WARN cam -c1 -C1 ) > "$_camlog" 2>&1 || true
    if grep -qi "Failed to create camera sensor helper for ov02c10" "$_camlog" 2>/dev/null; then
        echo ""
        echo "  ⚠  Your active libcamera does NOT have the OV02C10 sensor helper."
        echo "     Auto-exposure / auto-white-balance will misbehave and the image"
        echo "     will look off (often dark or purple) regardless of the CCM."
        echo "     Fix it first:   sudo ./install.sh --force-libcamera-rebuild"
        echo ""
        read -r -p "  Continue tuning anyway? [y/N] " ans
        if [[ ! "$ans" =~ ^[Yy]$ ]]; then [[ "$_camdir" != /tmp ]] && rm -rf "$_camdir"; exit 1; fi
    fi
    [[ "$_camdir" != /tmp ]] && rm -rf "$_camdir"
fi

# ─── Detect libcamera version: <0.6 uses 'Lut', 0.6+ uses 'Adjust' ────────
USE_LUT=false
LIBCAMERA_VER=$(ls -1 /usr/local/lib/*/libcamera.so.* /usr/local/lib/libcamera.so.* \
    /usr/local/lib64/libcamera.so.* /usr/lib/*/libcamera.so.* /usr/lib64/libcamera.so.* \
    /usr/lib/libcamera.so.* 2>/dev/null | grep -oP 'libcamera\.so\.\K[0-9]+\.[0-9]+' | \
    sort -V | tail -1 || true)
if [[ -n "$LIBCAMERA_VER" ]]; then
    LIBCAMERA_MINOR=${LIBCAMERA_VER#*.}
    if [[ "$LIBCAMERA_MINOR" -lt 6 ]] 2>/dev/null; then
        USE_LUT=true
    fi
fi

# ─── Pick a preview mode ───────────────────────────────────────────────────
USE_RELAY=false
VIEWER_PID=""
if systemctl --user is-active camera-relay.service >/dev/null 2>&1; then
    USE_RELAY=true
elif ! command -v qcam >/dev/null 2>&1 && ! command -v gst-launch-1.0 >/dev/null 2>&1; then
    echo "ERROR: nothing to preview with."
    echo "       Start the relay (systemctl --user start camera-relay.service)"
    echo "       or install qcam (libcamera-tools / libcamera-tools)."
    exit 1
fi

# ─── CCM presets ───────────────────────────────────────────────────────────
# NAME|DESCRIPTION|<ccm rows or 'NONE'>.  Rows should each sum to ~1.0 so neutral
# greys stay neutral. The Galaxy Book3/Book4 OV02C10 tends to read green/cool, so
# the "anti-green" presets are the usual starting point.
PRESETS=(
"No CCM (raw baseline)|Debayer + AWB only — washed out, but a clean reference.|NONE"
"Identity CCM|CCM stage active, no colour change. Sanity check.|1.00, 0.00, 0.00, 0.00, 1.00, 0.00, 0.00, 0.00, 1.00"
"Repo default (Arch Wiki)|Conservative matrix the installer ships.|1.05, -0.02, -0.01, -0.03, 0.92, -0.03, -0.01, -0.02, 1.05"
"Anti-green light|Drop green ~10%, lift R/B. Subtle.|1.10, 0.00, -0.10, 0.05, 0.90, 0.05, -0.10, 0.00, 1.10"
"Anti-green medium|Drop green ~20%, lift R/B. Most users land near here.|1.20, 0.00, -0.20, 0.10, 0.80, 0.10, -0.20, 0.00, 1.20"
"Anti-green strong|Drop green ~30%. For a heavy green cast.|1.30, 0.00, -0.30, 0.15, 0.70, 0.15, -0.30, 0.00, 1.30"
"Warm anti-green|Drop green + nudge warm. Good under fluorescent light.|1.25, -0.10, -0.15, 0.10, 0.80, 0.10, -0.20, -0.10, 1.30"
"Saturation boost +20%|Symmetric punchier colour, no hue shift.|1.20, -0.10, -0.10, -0.10, 1.20, -0.10, -0.10, -0.10, 1.20"
"Anti-purple light|Lift green, trim R/B. If the image looks magenta.|1.05, -0.025, -0.025, -0.10, 1.30, -0.20, -0.025, -0.025, 1.05"
"Anti-purple strong|Lift green hard. For a strong purple bias.|0.95, 0.025, 0.025, -0.25, 1.50, -0.25, 0.025, 0.025, 0.95"
"OV2740 community matrix|Strong matrix borrowed from OV2740 tuning. CT 6500.|2.25, -1.00, -0.25, -0.45, 1.35, -0.20, 0.00, -0.60, 1.60"
)

# CT to write per preset (only the OV2740 one is calibrated at 6500K).
preset_ct() {
    case "$1" in
        *"OV2740 community"*) echo 6500 ;;
        *) echo 5000 ;;
    esac
}

build_yaml() {
    # $1 = ccm spec ("NONE" or 9 comma-separated numbers)
    # $2 = colour temperature
    local spec="$1" ct="$2" tail_alg
    if $USE_LUT; then tail_alg="  - Lut:"; else tail_alg="  - Adjust:"; fi
    printf '# SPDX-License-Identifier: CC0-1.0\n'
    printf '# Written by webcam-fix-libcamera/tune-ccm.sh\n'
    printf '%%YAML 1.1\n---\nversion: 1\nalgorithms:\n'
    printf '  - BlackLevel:\n'
    printf '  - Awb:\n'
    if [[ "$spec" != "NONE" ]]; then
        local r=(${spec//,/ })
        printf '  - Ccm:\n      ccms:\n        - ct: %s\n' "$ct"
        printf '          ccm: [ %s, %s, %s,\n                 %s, %s, %s,\n                 %s, %s, %s ]\n' \
            "${r[0]}" "${r[1]}" "${r[2]}" "${r[3]}" "${r[4]}" "${r[5]}" "${r[6]}" "${r[7]}" "${r[8]}"
    fi
    printf '%s\n' "$tail_alg"
    printf '  - Agc:\n...\n'
}

# ─── Back up current tuning files ─────────────────────────────────────────
STAMP=$$
BACKUPS=()
for f in "${TUNING_FILES[@]}"; do
    if [[ -f "$f" ]]; then
        sudo cp "$f" "$f.tunebak.$STAMP"
        BACKUPS+=("$f.tunebak.$STAMP")
    fi
done

SELECTED=-1

restart_consumers() {
    # camera-relay holds a libcamera handle; pipewire/wireplumber cache the
    # libcamera device. Both must be bounced for a new tuning file to be read.
    $USE_RELAY && systemctl --user restart camera-relay.service 2>/dev/null || true
    systemctl --user restart pipewire.service wireplumber.service 2>/dev/null || true
}

kill_viewer() {
    if [[ -n "$VIEWER_PID" ]] && kill -0 "$VIEWER_PID" 2>/dev/null; then
        kill "$VIEWER_PID" 2>/dev/null || true
        wait "$VIEWER_PID" 2>/dev/null || true
    fi
    VIEWER_PID=""
}

start_viewer() {
    [[ -n "$VIEWER_PID" ]] && kill -0 "$VIEWER_PID" 2>/dev/null && return
    if $USE_RELAY && command -v gst-launch-1.0 >/dev/null 2>&1; then
        gst-launch-1.0 pipewiresrc ! videoconvert ! autovideosink >/dev/null 2>&1 &
        VIEWER_PID=$!
    elif command -v qcam >/dev/null 2>&1; then
        qcam >/dev/null 2>&1 &
        VIEWER_PID=$!
    fi
}

cleanup() {
    kill_viewer
    if [[ $SELECTED -lt 0 && ${#BACKUPS[@]} -gt 0 ]]; then
        echo ""
        echo "  Interrupted — restoring original tuning files."
        local i
        for i in "${!BACKUPS[@]}"; do
            sudo cp "${BACKUPS[$i]}" "${TUNING_FILES[$i]}" 2>/dev/null || true
        done
        restart_consumers
    fi
    for b in "${BACKUPS[@]}"; do sudo rm -f "$b" 2>/dev/null || true; done
}
trap cleanup EXIT INT TERM

apply_preset() {
    local idx=$1
    local entry="${PRESETS[$idx]}"
    local name="${entry%%|*}"; local rest="${entry#*|}"
    local desc="${rest%%|*}"; local spec="${rest#*|}"
    local ct; ct=$(preset_ct "$name")

    echo ""
    echo "────────────────────────────────────────────────"
    echo "  [$((idx+1))/${#PRESETS[@]}] $name"
    echo "  $desc"
    [[ "$spec" != "NONE" ]] && echo "  ccm: [ $spec ]  (ct $ct)"
    echo "  → $(IFS=,; echo "${TUNING_FILES[*]}")"
    echo "────────────────────────────────────────────────"

    local yaml; yaml=$(build_yaml "$spec" "$ct")
    local f
    for f in "${TUNING_FILES[@]}"; do
        printf '%s\n' "$yaml" | sudo tee "$f" >/dev/null
    done
    sync

    kill_viewer
    restart_consumers
    sleep 2
    start_viewer
}

# ─── Main loop ─────────────────────────────────────────────────────────────
echo "=================================================="
echo "  OV02C10 CCM tuner (libcamera Software ISP)"
echo "=================================================="
echo "  Tuning files : $(IFS=,; echo "${TUNING_FILES[*]}")"
echo "  libcamera    : ${LIBCAMERA_VER:-unknown}  (algorithm: $($USE_LUT && echo Lut || echo Adjust))"
echo "  Preview      : $($USE_RELAY && echo 'camera-relay → PipeWire' || echo qcam)"
echo "  Presets      : ${#PRESETS[@]}"
echo ""
echo "  Enter/n = next   p = previous   1-${#PRESETS[@]} = jump"
echo "  s = save current & exit          q = quit & restore original"
echo ""
echo "  Each preset restarts the camera (a few seconds). Keep the preview"
echo "  window where you can see it."
echo ""
read -r -p "Press Enter to start..." _

CURRENT=0
apply_preset $CURRENT

while true; do
    echo ""
    read -r -p "  [$((CURRENT+1))/${#PRESETS[@]}]  next(Enter) prev(p) save(s) quit(q) jump(1-${#PRESETS[@]}): " choice
    case "$choice" in
        ""|n|N) CURRENT=$(( (CURRENT+1) % ${#PRESETS[@]} )); apply_preset $CURRENT ;;
        p|P)    CURRENT=$(( (CURRENT-1+${#PRESETS[@]}) % ${#PRESETS[@]} )); apply_preset $CURRENT ;;
        s|S)    SELECTED=$CURRENT; break ;;
        q|Q)    break ;;
        [0-9]*)
            if [[ "$choice" -ge 1 && "$choice" -le ${#PRESETS[@]} ]] 2>/dev/null; then
                CURRENT=$((choice-1)); apply_preset $CURRENT
            else
                echo "  Pick a number from 1 to ${#PRESETS[@]}."
            fi ;;
        *) echo "  Unknown command: $choice" ;;
    esac
done

kill_viewer
echo ""
if [[ $SELECTED -ge 0 ]]; then
    name="${PRESETS[$SELECTED]%%|*}"
    echo "=================================================="
    echo "  Saved preset: $name"
    for f in "${TUNING_FILES[@]}"; do echo "    $f"; done
    echo "=================================================="
    restart_consumers
    echo "  Camera pipeline restarted with the new matrix."
    echo "  (If an app was already open, close and reopen it.)"
    echo ""
    echo "  Tip: don't open the camera with 'cam'/'qcam' while the relay is"
    echo "  running — it resets the sensor flip and the relay image ends up"
    echo "  upside-down until 'systemctl --user restart camera-relay.service'."
else
    if [[ ${#BACKUPS[@]} -gt 0 ]]; then
        for i in "${!BACKUPS[@]}"; do
            sudo cp "${BACKUPS[$i]}" "${TUNING_FILES[$i]}" 2>/dev/null || true
        done
        restart_consumers
        echo "  No preset saved — original tuning files restored."
    fi
fi
