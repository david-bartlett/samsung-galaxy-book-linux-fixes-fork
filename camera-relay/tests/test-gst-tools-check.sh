#!/usr/bin/env bash
# Regression tests for issue #65 — camera-relay reported
#   "GStreamer 'libcamerasrc' element not found. Install it: ... gstreamer1.0-libcamera"
# on a system where that package was already installed and libcamerasrc worked
# fine under gst-launch-1.0. The real cause is that gst-inspect-1.0 (and
# gst-launch-1.0, which IS the relay pipeline) live in a separate package that
# nothing pulls in, so the probe exited 127 and got misreported.
#
# Usage: ./test-gst-tools-check.sh
# Requires no camera hardware and touches no system state.

set -uo pipefail

RELAY="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/camera-relay"
PASS=0
FAIL=0

ok()   { echo "  ✓ $*"; PASS=$((PASS + 1)); }
bad()  { echo "  ✗ $*"; FAIL=$((FAIL + 1)); }
skip() { echo "  – skipped: $*"; }

# Pull a single function out of the relay script so we can exercise it directly
# without running the whole command dispatcher.
extract_fn() {
    sed -n "/^$1()/,/^}/p" "$RELAY"
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "test-gst-tools-check ($RELAY)"

# ── 1. Missing gst tools must be reported as missing gst tools ────────────────
# An empty PATH guarantees gst-inspect-1.0/gst-launch-1.0 are unreachable.
# XDG_RUNTIME_DIR points at an empty dir so is_running() finds no PID file and
# start proceeds straight into setup_environment.
mkdir -p "$TMP/emptybin" "$TMP/run"
out=$(PATH="$TMP/emptybin" XDG_RUNTIME_DIR="$TMP/run" "$BASH" "$RELAY" start 2>&1)
rc=$?

if [[ $rc -ne 0 ]]; then
    ok "start fails when the GStreamer tools are absent (exit $rc)"
else
    bad "start returned 0 with no gst-launch-1.0 available"
fi

if grep -q "gstreamer1.0-tools" <<<"$out"; then
    ok "error names the package that actually provides the tools"
else
    bad "error does not mention gstreamer1.0-tools; got:
$out"
fi

# The exact issue #65 dead end: telling the user to install the libcamera
# GStreamer plugin when that is not what is missing.
if grep -q "gstreamer1.0-libcamera" <<<"$out"; then
    bad "error still points at gstreamer1.0-libcamera (the issue #65 dead end)"
else
    ok "error no longer blames the libcamera plugin package"
fi

# ── 2. Locating an installed libcamera GStreamer plugin ──────────────────────
eval "$(extract_fn find_libcamera_gst_plugin)"
if plugin_so=$(find_libcamera_gst_plugin); then
    if [[ -f "$plugin_so" ]]; then
        ok "find_libcamera_gst_plugin located $plugin_so"
    else
        bad "find_libcamera_gst_plugin returned a non-file: $plugin_so"
    fi
else
    skip "no libgstlibcamera.so installed on this host"
fi

# ── 3. plugin present but unloadable is diagnosed, not called "missing" ───────
# Stub tools: gst-launch-1.0 exists (so require_gst_tools passes) and
# gst-inspect-1.0 always fails, simulating a plugin GStreamer refuses to load.
# XDG_CACHE_HOME is redirected because the recovery ladder clears the registry
# cache — the test must not blow away the real one.
if find_libcamera_gst_plugin >/dev/null; then
    mkdir -p "$TMP/fakebin" "$TMP/cache" "$TMP/run3"
    printf '#!/bin/sh\necho "no such element or plugin '\''libcamerasrc'\''" >&2\nexit 1\n' \
        > "$TMP/fakebin/gst-inspect-1.0"
    printf '#!/bin/sh\nexit 0\n' > "$TMP/fakebin/gst-launch-1.0"
    chmod +x "$TMP/fakebin"/*

    out=$(PATH="$TMP/fakebin:$PATH" XDG_CACHE_HOME="$TMP/cache" XDG_RUNTIME_DIR="$TMP/run3" \
          "$BASH" "$RELAY" start 2>&1)

    if grep -q "the plugin IS installed" <<<"$out"; then
        ok "unloadable plugin is reported as unloadable, not as missing"
    else
        bad "unloadable plugin still reported as a missing package; got:
$out"
    fi
    # The old message threw GStreamer's own error away; that is what left
    # issue #65 with nothing to go on.
    if grep -q "no such element or plugin" <<<"$out"; then
        ok "gst-inspect-1.0's actual stderr is surfaced to the user"
    else
        bad "gst-inspect-1.0's stderr was swallowed; got:
$out"
    fi
else
    skip "no libgstlibcamera.so installed; cannot test the unloadable-plugin path"
fi

# ── 4. status must not claim the loopback is absent when it is present ────────
eval "$(extract_fn detect_loopback_device)"
if dev=$(detect_loopback_device 2>/dev/null); then
    line=$(XDG_RUNTIME_DIR="$TMP/run" "$BASH" "$RELAY" status 2>/dev/null | grep 'Loopback:')
    if grep -q "$dev" <<<"$line"; then
        ok "status reports the live loopback device ($dev)"
    else
        bad "status hides the loopback device present at $dev; got: $line"
    fi
else
    skip "no v4l2loopback device present on this host"
fi

echo "  $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
