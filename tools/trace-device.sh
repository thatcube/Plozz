#!/usr/bin/env bash
#
# trace-device.sh — capture an Instruments trace from the Apple TV to diagnose
# playback CPU cost, leaks, and thermal throttling.
#
# This is a profiling/read-only tool: it ATTACHES to the already-running Plozz
# app (it does NOT install or relaunch, so it never clobbers an installed build).
# Start Plozz on the Apple TV, begin playback, then run this and reproduce the
# lag during the recording window.
#
# Examples:
#   # Default: Time Profiler, 90s, attach to running "Plozz" on "Brando TV"
#   tools/trace-device.sh
#
#   # Hunt the leak (persistent allocations growing across playbacks):
#   tools/trace-device.sh --template Allocations --time-limit 5m
#
#   # GPU/render cost of the mpv gpu-next HDR/DoVi path:
#   tools/trace-device.sh --template "Metal System Trace"
#
#   # Explicit device + leaks pass:
#   tools/trace-device.sh -d "Brando TV" -t Leaks -l 3m
#
# Open the resulting .trace in Instruments (`open <file>`), or summarise from the
# CLI with: xcrun xctrace export --input <file> --toc
#
set -euo pipefail

DEVICE="${PLOZZ_TRACE_DEVICE:-Brando TV}"
TEMPLATE="Time Profiler"
TIME_LIMIT="90s"
ATTACH_TARGET="Plozz"
OUTPUT_DIR="${PLOZZ_TRACE_DIR:-trace-output}"

usage() {
    sed -n '2,30p' "$0"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--template)    TEMPLATE="$2"; shift 2;;
        -l|--time-limit)  TIME_LIMIT="$2"; shift 2;;
        -d|--device)      DEVICE="$2"; shift 2;;
        -p|--attach)      ATTACH_TARGET="$2"; shift 2;;
        -h|--help)        usage; exit 0;;
        *) echo "Unknown argument: $1" >&2; usage; exit 1;;
    esac
done

mkdir -p "$OUTPUT_DIR"
stamp="$(date +%Y%m%d-%H%M%S)"
safe_template="$(echo "$TEMPLATE" | tr ' /' '--')"
output="$OUTPUT_DIR/${safe_template}-${stamp}.trace"

echo "=== Plozz device trace ==="
echo "  Device:     $DEVICE"
echo "  Template:   $TEMPLATE"
echo "  Duration:   $TIME_LIMIT"
echo "  Attaching:  $ATTACH_TARGET (must already be running on the device)"
echo "  Output:     $output"
echo
echo ">> Make sure Plozz is running and playback is underway, then reproduce the"
echo ">> lag now — recording for $TIME_LIMIT. Tip: let it run while you play"
echo ">> several titles so accumulation (leak) shows up."
echo

exec xcrun xctrace record \
    --device "$DEVICE" \
    --template "$TEMPLATE" \
    --time-limit "$TIME_LIMIT" \
    --output "$output" \
    --no-prompt \
    --attach "$ATTACH_TARGET"
