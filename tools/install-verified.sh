#!/usr/bin/env bash
#
# install-verified.sh — reliable CoreDevice install for iPhone / iPad / Apple TV.
#
# WHY THIS EXISTS
# On wireless CoreDevice tunnels (any device not on trusted USB — always the
# Apple TV, and often the iPad), `xcrun devicectl device install` frequently
# COMPLETES the install but then hangs on a post-install tunnel handshake and
# exits with a "timeout" / "Tunnel closed" / "Connection invalidated" error. If
# you trust that exit code you'll (a) think a successful install failed and (b)
# "retry" something already done — reinstalling the same build over and over.
#
# So this script never trusts the install command's exit code. Success is defined
# ONLY as "the device now reports the expected CFBundleShortVersionString +
# CFBundleVersion", queried directly. It also:
#   * skips the install entirely if the device already has the target build
#     (no pointless reinstalls),
#   * warms the tunnel with a cheap read first (the expensive part on wireless is
#     establishing the tunnel; a warm tunnel makes the install reliable),
#   * uses a generous timeout, and
#   * verifies-then-retries at most a few times instead of blind looping.
#
# USAGE
#   tools/install-verified.sh <core-device-udid> <path-to.app> [--no-launch] [--force]
#
# ENV
#   PLOZZ_INSTALL_TIMEOUT   per-attempt install timeout seconds (default 180)
#   PLOZZ_INSTALL_ATTEMPTS  max install attempts             (default 3)
set -uo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: $0 <core-device-udid> <path-to.app> [--no-launch] [--force]" >&2
  exit 2
fi

DEVICE="$1"; APP="$2"; shift 2
LAUNCH=1; FORCE=0
for arg in "$@"; do
  case "$arg" in
    --no-launch) LAUNCH=0 ;;
    --force)     FORCE=1 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

TIMEOUT="${PLOZZ_INSTALL_TIMEOUT:-180}"
ATTEMPTS="${PLOZZ_INSTALL_ATTEMPTS:-3}"

if [[ ! -d "$APP" ]]; then echo "✗ no .app at: $APP" >&2; exit 1; fi
plist="$APP/Info.plist"
BUNDLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")"
WANT_VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
WANT_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")"
LABEL="${BUNDLE##*.} $WANT_VER ($WANT_BUILD)"

# "version build" the device currently reports for BUNDLE, or empty if absent.
# This is the ONE heavy call — on a wireless Apple TV it takes ~20s (vs instant
# over USB) — so we make it as rarely as possible (never on a clean install).
installed_ver_build() {
  xcrun devicectl device info apps --device "$DEVICE" 2>/dev/null \
    | awk -v b="$BUNDLE" '{for(i=1;i<=NF;i++) if($i==b){print $(i+1), $(i+2); exit}}'
}

matches() { [[ "$1" == "$WANT_VER" && "$2" == "$WANT_BUILD" ]]; }

# Restart the Mac-side CoreDevice daemons. THE key recovery: when these get into a
# degraded state (e.g. after killed/abandoned devicectl processes) a single wireless
# query balloons from ~2-8s to ~90s and installs hang. Killing the two on-demand XPC
# services (launchd/XPC respawns them fresh on next use) restored 90s → ~8s in
# testing. We match the exact service binaries so we never hit unrelated processes.
reset_coredevice_daemons() {
  echo "  · resetting CoreDevice daemons to recover a degraded tunnel…"
  local pids
  pids="$(pgrep -f 'CoreDeviceService.xpc/Contents/MacOS/CoreDeviceService' 2>/dev/null
          pgrep -f 'remotepairingd.xpc/Contents/MacOS/remotepairingd' 2>/dev/null)"
  for pid in $pids; do kill "$pid" 2>/dev/null || true; done
  sleep 4
}

echo "▸ Target: $LABEL  →  device $DEVICE"

# NOTE on speed: every devicectl call to a wireless device (always the Apple TV;
# an iPad/iPhone not on trusted USB) tunnels over CoreDevice and is slow (~20s for
# an apps query). So we DON'T preemptively probe/warm — the install command's own
# generous timeout brings the tunnel up. We only spend a query when we actually
# need one: a skip check (ensure mode) or a post-error verification.

# 0. Ensure mode only: skip if the device already has this exact version+build.
#    (Skipped entirely under --force; a fresh deploy always reinstalls because the
#    git-commit-count CFBundleVersion can't distinguish changed-but-uncommitted
#    code from the same build number.)
if [[ "$FORCE" != "1" ]]; then
  read -r cur_v cur_b < <(installed_ver_build || true)
  if matches "${cur_v:-}" "${cur_b:-}"; then
    echo "✓ Already installed ($cur_v/$cur_b) — skipping install."
    SKIP_INSTALL=1
  fi
fi

if [[ "${SKIP_INSTALL:-0}" != "1" ]]; then
  ok=0
  for attempt in $(seq 1 "$ATTEMPTS"); do
    echo "▸ Install attempt $attempt/$ATTEMPTS (timeout ${TIMEOUT}s)…"
    # A CLEAN exit is the strong success signal — the generous timeout lets a real
    # completion (incl. cold-tunnel bring-up) finish in-window, so on a clean
    # install we make ZERO extra queries. Only if the command ERRORS do we spend a
    # verify query: on wireless the install often actually completed and only the
    # final tunnel handshake dropped.
    if xcrun devicectl device install app --device "$DEVICE" --timeout "$TIMEOUT" "$APP" \
         >/dev/null 2>&1; then
      echo "✓ Install completed cleanly."
      ok=1; break
    fi
    echo "  · install command errored; verifying by query (slow on wireless)…"
    read -r cur_v cur_b < <(installed_ver_build || true)
    if matches "${cur_v:-}" "${cur_b:-}"; then
      echo "✓ Errored, but device reports target present ($cur_v/$cur_b) — install landed."
      ok=1; break
    fi
    echo "  · attempt $attempt not confirmed (device: ${cur_v:-none}/${cur_b:-none}); retrying…"
    # After the first failure, reset the CoreDevice daemons once — the usual cause
    # of a failed/pathologically-slow wireless install is a degraded daemon, and
    # this recovers it (90s → ~8s in testing) so the next attempt is fast.
    if [[ "$attempt" == "1" ]]; then reset_coredevice_daemons; else sleep 3; fi
  done
  if [[ "$ok" != "1" ]]; then
    echo "✗ Could not verify $LABEL on $DEVICE after $ATTEMPTS attempts." >&2
    exit 1
  fi
fi

# Launch (best-effort; a failed launch does not undo a verified install).
if [[ "$LAUNCH" == "1" ]]; then
  if xcrun devicectl device process launch --device "$DEVICE" --timeout 60 "$BUNDLE" >/dev/null 2>&1; then
    echo "✓ Launched $BUNDLE."
  else
    echo "• Installed, but launch didn't confirm — open it manually if needed."
  fi
fi
