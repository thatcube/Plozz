#!/usr/bin/env bash
#
# device-tunnel.sh — keep Apple-device (iPhone/iPad/Apple TV) CoreDevice tunnels
# healthy and warm so wireless installs are FAST (no cables needed).
#
# BACKGROUND (why this exists)
# On iOS 17+/tvOS, every `devicectl` operation tunnels over CoreDevice. Measured
# on this project's devices:
#   * cold tunnel        ~8–22 s for one query
#   * warm tunnel        <1 s  (a real wireless install ≈ 8 s — effectively instant)
#   * DEGRADED daemons   ~90 s (and installs hang) — happens after killed/abandoned
#                        devicectl processes leave the Mac-side services wedged
# The Apple TV is worst because it's ALWAYS wireless (no USB port).
#
# Two levers fix it, both here:
#   reset   — restart the Mac-side CoreDevice daemons (recovers the 90s-degraded
#             state instantly; this is the big one).
#   warm    — a background heartbeat that pings each device every ~30s so the
#             tunnel never goes cold, making every deploy fast. Leave it running
#             in a terminal (or Xcode's Devices window open does the same thing).
#
# USAGE
#   tools/device-tunnel.sh reset                 # fix a slow/degraded tunnel now
#   tools/device-tunnel.sh warm [udid ...]       # keep tunnels hot (Ctrl-C to stop)
#   tools/device-tunnel.sh status [udid ...]     # time one query per device
#
# With no udids, uses the three project devices below.
set -uo pipefail

# Project devices (CoreDevice identifiers). Override by passing udids explicitly.
DEFAULT_DEVICES=(
  "CACB5C41-FBA6-5DE8-9868-98BBDF897991"   # iPhone
  "D1EB8B46-3CEC-5F68-BCDA-B1C9E0E40600"   # iPad
  "DE913871-CC2D-5F75-B4F2-0D6F44AA30DE"   # Apple TV
)

reset_daemons() {
  echo "▸ Resetting CoreDevice daemons (recovers a degraded/slow tunnel)…"
  local pids
  pids="$(pgrep -f 'CoreDeviceService.xpc/Contents/MacOS/CoreDeviceService' 2>/dev/null
          pgrep -f 'remotepairingd.xpc/Contents/MacOS/remotepairingd' 2>/dev/null)"
  if [[ -z "${pids// }" ]]; then
    echo "  · daemons not currently running (they'll start fresh on next use)."
  else
    for pid in $pids; do kill "$pid" 2>/dev/null && echo "  · killed $pid"; done
  fi
  echo "✓ Done. launchd/XPC respawns them fresh on the next devicectl call."
}

# A cheap per-device probe; also warms the tunnel. Prints seconds taken.
probe() {
  local dev="$1" start end
  start="$(date +%s.%N)"
  xcrun devicectl device info apps --device "$dev" >/dev/null 2>&1
  end="$(date +%s.%N)"
  awk -v s="$start" -v e="$end" 'BEGIN{printf "%.1f", e-s}'
}

CMD="${1:-status}"; shift || true
DEVICES=("$@"); [[ ${#DEVICES[@]} -eq 0 ]] && DEVICES=("${DEFAULT_DEVICES[@]}")

case "$CMD" in
  reset)
    reset_daemons
    ;;
  status)
    for d in "${DEVICES[@]}"; do echo "  $d : $(probe "$d")s"; done
    ;;
  warm)
    echo "▸ Keeping ${#DEVICES[@]} device tunnel(s) warm (Ctrl-C to stop)…"
    echo "  Leave this running while you iterate; deploys stay fast/instant."
    while true; do
      for d in "${DEVICES[@]}"; do probe "$d" >/dev/null 2>&1 || true; done
      sleep 30
    done
    ;;
  *)
    grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 2
    ;;
esac
