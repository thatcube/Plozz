#!/usr/bin/env bash
#
# Capture Plozz screenshots from a Simulator, at native device resolution.
#
# Why a Simulator and not the Apple TV: a Simulator screenshot comes from the
# framebuffer, so it is exactly 3840x2160 with no capture card, no HDMI, and no
# device to leave plugged in. `xcrun simctl io screenshot` is lossless PNG.
#
# Why it needs no credentials: the app is seeded with the NFS share (exported
# to `*` with no auth), and Plozz enriches share content from the keyless
# metadata tier — so a bare folder of files becomes a library with real
# artwork, overviews, ratings and cast. That is what makes these look like
# marketing shots rather than a file browser.
#
# How a screen is reached: NOT by pressing the remote. tvOS focus moves one
# cell at a time and the shelf order changes with what has been watched, so a
# run that walks focus silently photographs the wrong title. Instead the app is
# asked for a screen *by name* — see `ScreenshotDirector`. Requests go through a
# file in the app's own container, and the app writes back an ack, so this
# script waits for the request to be taken rather than sleeping and hoping.
#
# One launch serves the whole session, so the library is scanned once.
#
#   ./tools/capture-shots.sh                  # everything, to build/shots
#   ./tools/capture-shots.sh --no-build       # reuse the last build
#   ./tools/capture-shots.sh --only tv-home   # one shot, by name
#   ./tools/capture-shots.sh --list           # what it can capture
#   ./tools/capture-shots.sh --reset          # wipe app data and rescan (slow)
#   ./tools/capture-shots.sh --out DIR
#
# The first run against a fresh container scans and enriches the whole library
# and takes a long while. That work persists in the Simulator's container, so
# later runs start populated — do NOT pass --reset unless you mean it.
#
set -euo pipefail

# The package resolve needs this or it fails with "cannot use bare repository".
export GIT_CONFIG_PARAMETERS="'safe.bareRepository=all'"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

BUNDLE_ID="com.thatcube.Plozz"
DERIVED="${PLOZZ_SHOTS_DERIVED:-$REPO_ROOT/build/shots-dd}"
OUT="${PLOZZ_SHOTS_OUT:-$REPO_ROOT/build/shots}"
TEAM="${PLOZZ_TEAM:-N8Z5T4AK3X}"

# The media source. Exported to `*`, so no credentials.
NFS_HOST="${PLOZZ_SHOTS_NFS_HOST:-192.168.68.71}"
NFS_EXPORT="${PLOZZ_SHOTS_NFS_EXPORT:-/mnt/user/Media}"
NFS_NAME="${PLOZZ_SHOTS_NFS_NAME:-Brandoland}"

DO_BUILD=1
DO_RESET=0
ONLY=""
SIM_NAME="${PLOZZ_SHOTS_SIM:-Apple TV 4K (3rd generation)}"

# ── The shot list ────────────────────────────────────────────────────────────
# `name|request`, in the order they are taken.
#
# The titles are deliberately well-known: a marketing shot of an unrecognisable
# title tells a visitor nothing about the app. They also exercise different
# shapes — a film, an epic, an animated film, a prestige series, a long-running
# sitcom — so the gallery is not five variations of one page.
# A third field, when present, is a capture delay in seconds *instead of*
# waiting for the screen to settle. Needed for anything that is deliberately
# still moving: the player's transport bar fades a few seconds after playback
# starts, so a shot that waits for stillness is a shot of bare video with no UI
# in it at all.
SHOTS=(
  "tv-home|home"
  "tv-detail-oppenheimer|detail?title=Oppenheimer"
  "tv-detail-lotr|detail?title=The%20Lord%20of%20the%20Rings%3A%20The%20Fellowship%20of%20the%20Ring"
  "tv-detail-mario|detail?title=The%20Super%20Mario%20Bros.%20Movie"
  "tv-show-lastofus|detail?title=The%20Last%20of%20Us"
  "tv-show-office|detail?title=The%20Office"
  "tv-person|person?title=Oppenheimer&person=Cillian%20Murphy"
  "tv-library|library?name=TV"
  "tv-player|play?title=The%20Office&at=600|35"
  "tv-subtitles|play?title=Oppenheimer&at=2400|75"
)

usage() { sed -n '2,34p' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --no-build) DO_BUILD=0 ;;
    --reset) DO_RESET=1 ;;
    --only) ONLY="$2"; shift ;;
    --out) OUT="$2"; shift ;;
    --sim) SIM_NAME="$2"; shift ;;
    --list) printf '%s\n' "${SHOTS[@]}" | cut -d'|' -f1 | sed 's/^/  /'; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

mkdir -p "$OUT"

# ── Simulator ────────────────────────────────────────────────────────────────
# Pick the newest runtime's instance of the requested device. `-4K` matters:
# the "(at 1080p)" variants capture at 1920x1080, which is below what the App
# Store wants for Apple TV and below the website's 2296px hero rung.
UDID="$(xcrun simctl list devices available -j \
  | python3 -c '
import json,sys
name=sys.argv[1]
data=json.load(sys.stdin)["devices"]
best=None
for runtime, devices in data.items():
    if "tvOS" not in runtime: continue
    for d in devices:
        if d["name"] == name and d["isAvailable"]:
            best = (runtime, d["udid"])
print(best[1] if best else "")' "$SIM_NAME")"

if [ -z "$UDID" ]; then
  echo "No available simulator named '$SIM_NAME'." >&2
  echo "Create one, e.g.:" >&2
  echo "  xcrun simctl create '$SIM_NAME' com.apple.CoreSimulator.SimDeviceType.Apple-TV-4K-3rd-generation-4K" >&2
  exit 1
fi

echo "Simulator: $SIM_NAME ($UDID)"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true

# ── Build ────────────────────────────────────────────────────────────────────
# Signing must stay ON. With CODE_SIGNING_ALLOWED=NO the app ships without
# entitlements, the Keychain returns errSecMissingEntitlement (-34018), and the
# media-share credential vault cannot initialise — the share then fails to save
# and the app sits on "Something went wrong". That failure looks nothing like a
# signing problem, so it is worth stating plainly.
if [ "$DO_BUILD" = "1" ]; then
  echo "Generating project…"
  ./tools/generate-project.sh >/dev/null

  echo "Building for the Simulator…"
  xcodebuild build \
    -project Plozz.xcodeproj \
    -scheme Plozz \
    -destination "platform=tvOS Simulator,id=$UDID" \
    -derivedDataPath "$DERIVED" \
    DEVELOPMENT_TEAM="$TEAM" \
    ONLY_ACTIVE_ARCH=YES \
    -quiet
fi

APP="$(find "$DERIVED/Build/Products" -maxdepth 3 -name "Plozz.app" -path "*simulator*" | head -1)"
if [ -z "$APP" ]; then
  echo "No built Plozz.app under $DERIVED — run without --no-build." >&2
  exit 1
fi

if [ "$DO_RESET" = "1" ]; then
  echo "Resetting app data (a full rescan will follow, this is slow)…"
  xcrun simctl uninstall "$UDID" "$BUNDLE_ID" 2>/dev/null || true
fi

xcrun simctl install "$UDID" "$APP"

# ── Launch, seeded ───────────────────────────────────────────────────────────
# NOTE on the library shot: it browses TV Shows, not Movies, and that is
# deliberate. A file share cannot be re-sorted — `CatalogReadQueries` pages with
# a fixed `ORDER BY sort_title` — so the grid is always alphabetical, and the
# Movies library's first tile is a file with no artwork that sorts before "A".
# Setting the sort menu's stored choice changes only its label. TV Shows leads
# with real posters, so it is the honest grid that also photographs well.

xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
SIMCTL_CHILD_PLOZZ_SHOTS_NFS_HOST="$NFS_HOST" \
SIMCTL_CHILD_PLOZZ_SHOTS_NFS_EXPORT="$NFS_EXPORT" \
SIMCTL_CHILD_PLOZZ_SHOTS_NFS_NAME="$NFS_NAME" \
SIMCTL_CHILD_PLOZZ_SHOTS_HOLD_CONTROLS=1 \
xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null

# The command channel lives in the app's own Documents directory, which the
# host can write to directly — no entitlement, no port, and no "Open in Plozz?"
# alert (which is what rules out `simctl openurl` for an unattended run).
CONTAINER=""
for _ in $(seq 1 30); do
  CONTAINER="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data 2>/dev/null || true)"
  [ -n "$CONTAINER" ] && break
  sleep 1
done
if [ -z "$CONTAINER" ]; then
  echo "Could not find the app container." >&2
  exit 1
fi
CHANNEL="$CONTAINER/Documents"
mkdir -p "$CHANNEL"
rm -f "$CHANNEL/.plozz-shots-request" "$CHANNEL/.plozz-shots-ack"

# ── Waiting ──────────────────────────────────────────────────────────────────
# Rather than parse the scan badge, watch for the screen to stop changing: when
# successive captures are identical, rows have stopped filling in. Artwork
# arrives progressively, so this is the honest signal that a shot is ready.
settle() {
  local budget="${1:-90}" stable_needed="${2:-3}" interval="${3:-2}"
  local previous="" stable=0 waited=0
  while [ "$waited" -lt "$budget" ]; do
    sleep "$interval"
    waited=$((waited + interval))
    xcrun simctl io "$UDID" screenshot "$OUT/.settle.png" >/dev/null 2>&1 || continue
    local hash
    hash="$(shasum -a 256 "$OUT/.settle.png" | cut -c1-16)"
    if [ "$hash" = "$previous" ]; then
      stable=$((stable + 1))
      if [ "$stable" -ge "$stable_needed" ]; then
        rm -f "$OUT/.settle.png"
        return 0
      fi
    else
      stable=0
    fi
    previous="$hash"
  done
  rm -f "$OUT/.settle.png"
  return 1
}

# Asks the app for a screen and waits for it to say it got there.
#
# The app acks only once it has *reached* the screen, so `notFound` here means
# the library genuinely has no such title — not that the request was malformed.
# Echoes the outcome so the caller can report it.
request() {
  local verb="$1"
  rm -f "$CHANNEL/.plozz-shots-ack"
  printf '%s\n' "$verb" > "$CHANNEL/.plozz-shots-request"
  for _ in $(seq 1 120); do
    if [ -f "$CHANNEL/.plozz-shots-ack" ]; then
      cat "$CHANNEL/.plozz-shots-ack"
      return 0
    fi
    sleep 0.5
  done
  echo "timeout"
  return 1
}

echo "Waiting for the library to finish scanning and enriching…"
echo "(a fresh container walks the whole share — expect a long wait)"
settle "${PLOZZ_SHOTS_SETTLE:-1800}" 5 10 || true

# ── Capture ──────────────────────────────────────────────────────────────────
echo
echo "Capturing:"
FAILED=0
for entry in "${SHOTS[@]}"; do
  IFS='|' read -r name verb delay <<< "$entry"

  if [ -n "$ONLY" ] && [ "$name" != "$ONLY" ]; then continue; fi

  OUTCOME="$(request "$verb" || true)"
  if [ "$OUTCOME" != "ok" ]; then
    FAILED=$((FAILED + 1))
    printf '  %-26s %s\n' "plozz-$name.png" "SKIPPED ($OUTCOME)"
    continue
  fi

  if [ -n "${delay:-}" ]; then
    sleep "$delay"
  else
    # A push animates, then artwork loads. Settling covers both, but a page
    # that legitimately never stops moving will never settle — so a timeout
    # still takes the shot.
    settle 60 3 2 || true
  fi

  xcrun simctl io "$UDID" screenshot "$OUT/plozz-$name.png" >/dev/null 2>&1
  printf '  %-26s %s\n' "plozz-$name.png" \
    "$(magick identify -format '%wx%h' "$OUT/plozz-$name.png" 2>/dev/null || echo '?')"

  # Leave the player rather than letting it run under the next request.
  case "$verb" in play*) request "home" >/dev/null 2>&1 || true ;; esac
done

echo
echo "Wrote to $OUT"
if [ "$FAILED" != "0" ]; then
  echo "$FAILED shot(s) skipped. 'notFound' means the library has no such title —"
  echo "check the exact name with the app's own search and edit SHOTS above."
fi
exit 0
