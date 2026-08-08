#!/usr/bin/env bash
#
# Capture real Plozz screenshots from a Simulator, at native device resolution.
#
# Why a Simulator and not the Apple TV: a Simulator screenshot comes from the
# framebuffer, so it is exactly 3840x2160 with no capture card, no HDMI, and no
# device to leave plugged in. `xcrun simctl io screenshot` is lossless PNG.
#
# Why it does not need credentials: the app is seeded with brandon's NFS share
# (cubeboi, exported to `*` with no auth), and Plozz enriches share content from
# the keyless metadata tier — so a bare folder of files becomes a library with
# real artwork, overviews, ratings and cast. That is what makes these look like
# the marketing shots rather than a file browser.
#
# The seed goes in through `ScreenshotSeed` (DEBUG-only, inert unless the
# environment asks for it), which calls the same `didConfigureNFSShare` the
# onboarding UI calls and then completes the first-run profile/theme steps. No
# UI driving is needed to reach Home.
#
#   ./tools/capture-shots.sh                 # tvOS, capture to build/shots
#   ./tools/capture-shots.sh --no-build      # reuse the last build
#   ./tools/capture-shots.sh --reset         # wipe app data and rescan
#   ./tools/capture-shots.sh --out DIR
#
# The first run scans and enriches the whole library (~10.5k items) and takes a
# long while. That work persists in the Simulator's container, so later runs
# start already populated — do NOT pass --reset unless you mean it.
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
SIM_NAME="${PLOZZ_SHOTS_SIM:-Apple TV 4K (3rd generation)}"

while [ $# -gt 0 ]; do
  case "$1" in
    --no-build) DO_BUILD=0 ;;
    --reset) DO_RESET=1 ;;
    --out) OUT="$2"; shift ;;
    --sim) SIM_NAME="$2"; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
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
xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
SIMCTL_CHILD_PLOZZ_SHOTS_NFS_HOST="$NFS_HOST" \
SIMCTL_CHILD_PLOZZ_SHOTS_NFS_EXPORT="$NFS_EXPORT" \
SIMCTL_CHILD_PLOZZ_SHOTS_NFS_NAME="$NFS_NAME" \
xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null

# ── Wait for the library to settle ───────────────────────────────────────────
# The scan/enrich badge sits top-right on Home. Rather than parse it, watch for
# the screen to stop changing: when successive captures are identical the rows
# have stopped filling in. Artwork arrives progressively, so this is the honest
# signal that the shot is ready.
settle() {
  local budget="${1:-900}" stable_needed="${2:-4}"
  local previous="" stable=0 waited=0
  while [ "$waited" -lt "$budget" ]; do
    sleep 10
    waited=$((waited + 10))
    xcrun simctl io "$UDID" screenshot "$OUT/.settle.png" >/dev/null 2>&1 || continue
    local hash
    hash="$(shasum -a 256 "$OUT/.settle.png" | cut -c1-16)"
    if [ "$hash" = "$previous" ]; then
      stable=$((stable + 1))
      [ "$stable" -ge "$stable_needed" ] && { rm -f "$OUT/.settle.png"; return 0; }
    else
      stable=0
    fi
    previous="$hash"
    printf '\r  settling… %ss' "$waited"
  done
  printf '\n'
  rm -f "$OUT/.settle.png"
  return 0
}

echo "Waiting for the library to finish scanning and enriching…"
echo "(first run on a fresh container walks ~10.5k items — expect a long wait)"
settle "${PLOZZ_SHOTS_SETTLE:-1800}" 5
printf '\n'

# ── Capture ──────────────────────────────────────────────────────────────────
# Home needs no navigation, so it is taken straight from the framebuffer. That
# path has no XCTest in it at all, which makes it the one capture that cannot be
# broken by a focus change.
shoot() {
  local name="$1"
  xcrun simctl io "$UDID" screenshot "$OUT/$name.png" >/dev/null 2>&1
  printf '  %-30s %s\n' "$name.png" "$(magick identify -format '%wx%h' "$OUT/$name.png" 2>/dev/null || echo '?')"
}

echo "Capturing:"
shoot "plozz-tv-home"

# Everything past Home needs the remote, which only a UI test can press. The
# frames come back as test attachments; xcresulttool writes them out under
# opaque UUID names, so the manifest is used to restore the intended name.
if [ "${PLOZZ_SHOTS_SKIP_UITESTS:-0}" != "1" ]; then
  echo
  echo "Running PlozzShots for the screens that need navigation…"
  RESULT="$OUT/.xcresult"
  rm -rf "$RESULT"

  set +e
  xcodebuild test \
    -project Plozz.xcodeproj \
    -scheme PlozzShots \
    -destination "platform=tvOS Simulator,id=$UDID" \
    -derivedDataPath "$DERIVED" \
    -resultBundlePath "$RESULT" \
    DEVELOPMENT_TEAM="$TEAM" \
    ONLY_ACTIVE_ARCH=YES \
    -quiet > "$OUT/.uitest.log" 2>&1
  UITEST_STATUS=$?
  set -e

  if [ -d "$RESULT" ]; then
    rm -rf "$OUT/.attachments"
    xcrun xcresulttool export attachments \
      --path "$RESULT" --output-path "$OUT/.attachments" >/dev/null 2>&1 || true

    python3 - "$OUT" <<'PYEOF'
import json, os, shutil, sys, re
out = sys.argv[1]
src = os.path.join(out, ".attachments")
manifest = os.path.join(src, "manifest.json")
if os.path.exists(manifest):
    for entry in json.load(open(manifest)):
        for a in entry.get("attachments", []):
            name = a.get("suggestedHumanReadableName") or ""
            exported = a.get("exportedFileName")
            if not exported or not name.endswith(".png"):
                continue
            # "plozz-tv-home_0_<uuid>.png" -> "plozz-tv-home.png"
            stem = re.sub(r"_\d+_[0-9A-Fa-f-]{36}\.png$", "", name)
            shutil.copyfile(os.path.join(src, exported),
                            os.path.join(out, stem + ".png"))
            print(f"  {stem + '.png':<30} (from UI test)")
PYEOF
    rm -rf "$OUT/.attachments" "$RESULT"
  fi

  if [ "$UITEST_STATUS" != "0" ]; then
    echo
    echo "  Some navigated screens did not capture — see $OUT/.uitest.log"
    echo "  Home is unaffected; it is captured without XCTest."
  fi
fi

echo
echo "Wrote to $OUT"
ls -1 "$OUT"/*.png 2>/dev/null | sed 's|.*/|  |'
