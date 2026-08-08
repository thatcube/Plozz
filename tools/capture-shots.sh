#!/usr/bin/env bash
#
# Capture Plozz screenshots from a Simulator, at native device resolution.
#
# Why a Simulator and not a physical device: a Simulator screenshot comes from the
# framebuffer, so it is exactly the device's native resolution with no capture
# card, no HDMI, and no device to leave plugged in. `xcrun simctl io screenshot`
# is lossless PNG.
#
# Why it needs no credentials: the app is seeded with the NFS share (exported to
# `*` with no auth), and Plozz enriches share content from the keyless metadata
# tier — so a bare folder of files becomes a library with real artwork, overviews,
# ratings and cast. That is what makes these look like marketing shots rather than
# a file browser.
#
# How a screen is reached: NOT by pressing the remote or simulating taps. Focus /
# tap order changes with what has been watched, so a run that walks it silently
# photographs the wrong title. Instead the app is asked for a screen *by name* —
# see `ScreenshotDirector` (tvOS) / `PlozziOSScreenshotDirector` (iOS). Requests go
# through a file in the app's own container, and the app writes back an ack, so
# this script waits for the request to be taken rather than sleeping and hoping.
#
# One launch serves the whole session, so the library is scanned once.
#
#   ./tools/capture-shots.sh                          # tvOS, to build/shots
#   ./tools/capture-shots.sh --platform ios           # iPhone + iPad, to build/shots-ios
#   ./tools/capture-shots.sh --no-build               # reuse the last build
#   ./tools/capture-shots.sh --only tv-home           # one shot, by name
#   ./tools/capture-shots.sh --platform ios --sim "iPhone 17 Pro Max"   # one device
#   ./tools/capture-shots.sh --list                   # what it can capture
#   ./tools/capture-shots.sh --reset                  # wipe app data and rescan (slow)
#   ./tools/capture-shots.sh --out DIR
#
# The first run against a fresh container scans and enriches the whole library and
# takes a long while. That work persists in the Simulator's container, so later
# runs start populated — do NOT pass --reset unless you mean it.
#
set -euo pipefail

# The package resolve needs this or it fails with "cannot use bare repository".
export GIT_CONFIG_PARAMETERS="'safe.bareRepository=all'"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

BUNDLE_ID="com.thatcube.Plozz"
TEAM="${PLOZZ_TEAM:-N8Z5T4AK3X}"

# The media source. Exported to `*`, so no credentials.
NFS_HOST="${PLOZZ_SHOTS_NFS_HOST:-192.168.68.71}"
NFS_EXPORT="${PLOZZ_SHOTS_NFS_EXPORT:-/mnt/user/Media}"
NFS_NAME="${PLOZZ_SHOTS_NFS_NAME:-Brandoland}"

PLATFORM="tvos"
DO_BUILD=1
DO_RESET=0
ONLY=""
SIM_OVERRIDE=""
OUT=""

# ── The shot lists ───────────────────────────────────────────────────────────
# `name|request`, in the order they are taken. A third field, when present, is a
# capture delay in seconds *instead of* waiting for the screen to settle. Needed
# for the player: its transport bar is deliberately still moving, so a shot that
# waits for stillness is a shot of bare video with no UI in it at all.
#
# The titles are deliberately well-known and exercise different shapes — a film,
# an epic, an animated film, a prestige series, a long-running sitcom — so the
# gallery is not five variations of one page.
TVOS_SHOTS=(
  "tv-home|home"
  "tv-oppenheimer|detail?title=Oppenheimer"
  "tv-lotr|detail?title=The%20Lord%20of%20the%20Rings%3A%20The%20Fellowship%20of%20the%20Ring"
  "tv-mario|detail?title=The%20Super%20Mario%20Bros.%20Movie"
  "tv-lastofus|detail?title=The%20Last%20of%20Us"
  "tv-office|detail?title=The%20Office"
  "tv-dune|detail?title=Dune%3A%20Part%20Two"
  "tv-cast|person?title=Oppenheimer&person=Cillian%20Murphy"
  "tv-library|library?name=TV"
  "tv-player|play?title=The%20Office&at=600|35"
  "tv-subtitles|play?title=Oppenheimer&at=2400|75"
  # Last on purpose. Switching tabs is performed by a different router than the
  # one that performs navigation, and each router acks independently — so a tab
  # request in the middle of the list would ack the *next* shot early. Nothing
  # needs the Home tab after this, so the ordering removes the problem instead
  # of coordinating the two.
  "tv-settings|tab?name=settings"
)

# Same requests, device-agnostic labels — the capture loop prefixes each with the
# device slug (iphone / ipad), so the two runs never overwrite each other.
IOS_SHOTS=(
  "home|home"
  "oppenheimer|detail?title=Oppenheimer"
  "lotr|detail?title=The%20Lord%20of%20the%20Rings%3A%20The%20Fellowship%20of%20the%20Ring"
  "mario|detail?title=The%20Super%20Mario%20Bros.%20Movie"
  "lastofus|detail?title=The%20Last%20of%20Us"
  "office|detail?title=The%20Office"
  "dune|detail?title=Dune%3A%20Part%20Two"
  "cast|person?title=Oppenheimer&person=Cillian%20Murphy"
  "library|library?name=TV"
  "search|tab?name=search"
  "player|play?title=The%20Office&at=600|35"
  "subtitles|play?title=Oppenheimer&at=2400|75"
)

usage() { sed -n '2,40p' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --platform) PLATFORM="$2"; shift ;;
    --no-build) DO_BUILD=0 ;;
    --reset) DO_RESET=1 ;;
    --only) ONLY="$2"; shift ;;
    --out) OUT="$2"; shift ;;
    --sim) SIM_OVERRIDE="$2"; shift ;;
    --list)
      case "$PLATFORM" in
        ios) printf '%s\n' "${IOS_SHOTS[@]}" ;;
        *) printf '%s\n' "${TVOS_SHOTS[@]}" ;;
      esac | cut -d'|' -f1 | sed 's/^/  /'
      exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

# ── Platform parameters ──────────────────────────────────────────────────────
# The two shells are separate schemes (Plozz / PlozziOS) but the same bundle id,
# so a device can hold at most one at a time — which is fine, the runs are serial.
case "$PLATFORM" in
  tvos)
    SCHEME="Plozz"
    SIM_PLATFORM="tvOS"
    DEST_PLATFORM="tvOS Simulator"
    DERIVED="${PLOZZ_SHOTS_DERIVED:-$REPO_ROOT/build/shots-dd}"
    OUT="${OUT:-${PLOZZ_SHOTS_OUT:-$REPO_ROOT/build/shots}}"
    # A single device. `-4K` matters: the "(at 1080p)" variants capture at
    # 1920x1080, below what the App Store wants for Apple TV.
    SIMS=("${SIM_OVERRIDE:-${PLOZZ_SHOTS_SIM:-Apple TV 4K (3rd generation)}}")
    ;;
  ios)
    SCHEME="PlozziOS"
    SIM_PLATFORM="iOS"
    DEST_PLATFORM="iOS Simulator"
    DERIVED="${PLOZZ_SHOTS_DERIVED:-$REPO_ROOT/build/shots-ios-dd}"
    OUT="${OUT:-${PLOZZ_SHOTS_OUT:-$REPO_ROOT/build/shots-ios}}"
    # Two devices whose native resolution matches Apple's current App Store
    # Connect spec exactly: iPhone 6.9" = 1320x2868, iPad 13" = 2064x2752. Pick
    # the Pro Max / 13-inch so no downscale or letterboxing is needed.
    if [ -n "$SIM_OVERRIDE" ]; then
      SIMS=("$SIM_OVERRIDE")
    else
      SIMS=("iPhone 17 Pro Max" "iPad Pro 13-inch (M5)")
    fi
    ;;
  *)
    echo "unknown platform: $PLATFORM (want tvos or ios)" >&2
    exit 2 ;;
esac

mkdir -p "$OUT"

# Resolves the newest available Simulator UDID for a device name on this
# platform's runtime.
resolve_udid() {
  local name="$1"
  xcrun simctl list devices available -j | python3 -c '
import json,sys
name=sys.argv[1]
want=sys.argv[2]
data=json.load(sys.stdin)["devices"]
best=None
for runtime, devices in data.items():
    if want not in runtime: continue
    for d in devices:
        if d["name"] == name and d["isAvailable"]:
            best = d["udid"]
print(best or "")' "$name" "$SIM_PLATFORM"
}

# ── Build ────────────────────────────────────────────────────────────────────
# Signing must stay ON. With CODE_SIGNING_ALLOWED=NO the app ships without
# entitlements, the Keychain returns errSecMissingEntitlement (-34018), and the
# media-share credential vault cannot initialise — the share then fails to save
# and the app sits on "Something went wrong". That failure looks nothing like a
# signing problem, so it is worth stating plainly.
#
# A Simulator build is generic across devices of the same platform, so one build
# serves both the iPhone and the iPad runs.
BUILD_UDID="$(resolve_udid "${SIMS[0]}")"
if [ -z "$BUILD_UDID" ]; then
  echo "No available simulator named '${SIMS[0]}'." >&2
  exit 1
fi

if [ "$DO_BUILD" = "1" ]; then
  echo "Generating project…"
  ./tools/generate-project.sh >/dev/null

  echo "Building $SCHEME for the $SIM_PLATFORM Simulator…"
  xcodebuild build \
    -project Plozz.xcodeproj \
    -scheme "$SCHEME" \
    -destination "platform=$DEST_PLATFORM,id=$BUILD_UDID" \
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

# ── Per-device capture helpers ───────────────────────────────────────────────
# Watches for the screen to stop changing: when successive captures are
# identical, rows have stopped filling in. Artwork arrives progressively, so this
# is the honest signal that a shot is ready.
settle() {
  local udid="$1" budget="${2:-90}" stable_needed="${3:-3}" interval="${4:-2}"
  local previous="" stable=0 waited=0 hash
  while [ "$waited" -lt "$budget" ]; do
    sleep "$interval"
    waited=$((waited + interval))
    xcrun simctl io "$udid" screenshot "$OUT/.settle.png" >/dev/null 2>&1 || continue
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

# Asks the app for a screen and waits for it to say it got there. The app acks
# only once it has *reached* the screen, so `notFound` means the library genuinely
# has no such title — not that the request was malformed.
request() {
  local channel="$1" verb="$2"
  rm -f "$channel/.plozz-shots-ack"
  printf '%s\n' "$verb" > "$channel/.plozz-shots-request"
  for _ in $(seq 1 120); do
    if [ -f "$channel/.plozz-shots-ack" ]; then
      cat "$channel/.plozz-shots-ack"
      return 0
    fi
    sleep 0.5
  done
  echo "timeout"
  return 1
}

# Captures the whole shot list on one booted, installed device.
#   $1 udid   $2 slug (filename prefix, empty for tvOS)   $3.. shot entries
capture_device() {
  local udid="$1" slug="$2"; shift 2
  local shots=("$@")

  xcrun simctl terminate "$udid" "$BUNDLE_ID" 2>/dev/null || true
  SIMCTL_CHILD_PLOZZ_SHOTS_NFS_HOST="$NFS_HOST" \
  SIMCTL_CHILD_PLOZZ_SHOTS_NFS_EXPORT="$NFS_EXPORT" \
  SIMCTL_CHILD_PLOZZ_SHOTS_NFS_NAME="$NFS_NAME" \
  SIMCTL_CHILD_PLOZZ_SHOTS_HOLD_CONTROLS=1 \
  xcrun simctl launch "$udid" "$BUNDLE_ID" >/dev/null

  # The command channel lives in the app's own Documents directory, which the
  # host can write to directly — no entitlement, no port, and no "Open in Plozz?"
  # alert (which is what rules out `simctl openurl` for an unattended run).
  local container=""
  for _ in $(seq 1 30); do
    container="$(xcrun simctl get_app_container "$udid" "$BUNDLE_ID" data 2>/dev/null || true)"
    [ -n "$container" ] && break
    sleep 1
  done
  if [ -z "$container" ]; then
    echo "Could not find the app container for $udid." >&2
    return 1
  fi
  local channel="$container/Documents"
  mkdir -p "$channel"
  rm -f "$channel/.plozz-shots-request" "$channel/.plozz-shots-ack"

  echo "Waiting for the library to finish scanning and enriching…"
  echo "(a fresh container walks the whole share — expect a long wait)"
  settle "$udid" "${PLOZZ_SHOTS_SETTLE:-1800}" 5 10 || true

  echo
  echo "Capturing:"
  local entry name verb delay outcome file
  for entry in "${shots[@]}"; do
    IFS='|' read -r name verb delay <<< "$entry"

    if [ -n "$ONLY" ] && [ "$name" != "$ONLY" ]; then continue; fi

    outcome="$(request "$channel" "$verb" || true)"
    if [ "$outcome" != "ok" ]; then
      FAILED=$((FAILED + 1))
      printf '  %-28s %s\n' "${slug:+$slug-}$name" "SKIPPED ($outcome)"
      continue
    fi

    if [ -n "${delay:-}" ]; then
      sleep "$delay"
    else
      # A push animates, then artwork loads. Settling covers both, but a page
      # that legitimately never stops moving will never settle — so a timeout
      # still takes the shot. The app only acks once the pushed page has actually
      # appeared, so the page under this settle is already the requested one.
      settle "$udid" 60 3 2 || true
    fi

    file="$OUT/plozz-${slug:+$slug-}$name.png"
    xcrun simctl io "$udid" screenshot "$file" >/dev/null 2>&1

    # simctl writes RGBA. The alpha is fully opaque and so carries nothing, but
    # App Store Connect rejects a screenshot that has an alpha channel at all,
    # and it also wrecks any DSSIM comparison against an encoder that drops it
    # (0.13 against a true 0.005). Flattening here means neither consumer of
    # these files has to remember to.
    magick "$file" -alpha off -colorspace sRGB "$file" 2>/dev/null || true

    printf '  %-28s %s\n' "plozz-${slug:+$slug-}$name.png" \
      "$(magick identify -format '%wx%h' "$file" 2>/dev/null || echo '?')"

    # Leave the player rather than letting it run under the next request.
    case "$verb" in play*) request "$channel" "home" >/dev/null 2>&1 || true ;; esac
  done
}

# ── Drive each device ────────────────────────────────────────────────────────
FAILED=0
for sim in "${SIMS[@]}"; do
  udid="$(resolve_udid "$sim")"
  if [ -z "$udid" ]; then
    echo "No available simulator named '$sim' — skipping." >&2
    FAILED=$((FAILED + 1))
    continue
  fi

  # A short, device-type slug for the filename: iphone / ipad. tvOS is a single
  # device and keeps its historical un-prefixed names.
  slug=""
  if [ "$PLATFORM" = "ios" ]; then
    case "$sim" in
      *iPad*) slug="ipad" ;;
      *) slug="iphone" ;;
    esac
  fi

  echo
  echo "════════════════════════════════════════════════════════════════"
  echo "Device: $sim ($udid)"
  echo "════════════════════════════════════════════════════════════════"
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || true

  if [ "$DO_RESET" = "1" ]; then
    echo "Resetting app data (a full rescan will follow, this is slow)…"
    xcrun simctl uninstall "$udid" "$BUNDLE_ID" 2>/dev/null || true
  fi

  xcrun simctl install "$udid" "$APP"

  if [ "$PLATFORM" = "ios" ]; then
    capture_device "$udid" "$slug" "${IOS_SHOTS[@]}"
  else
    capture_device "$udid" "$slug" "${TVOS_SHOTS[@]}"
  fi
done

echo
echo "Wrote to $OUT"
if [ "$FAILED" != "0" ]; then
  echo "$FAILED shot(s) skipped. 'notFound' means the library has no such title —"
  echo "check the exact name with the app's own search and edit the shot list above."
fi
exit 0
