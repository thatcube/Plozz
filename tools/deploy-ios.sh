#!/usr/bin/env bash
#
# One-command incremental build, install, and launch for Plozz on iPhone/iPad.
# Installation uses ios-deploy/MobileDevice instead of CoreDevice's RSD tunnel,
# which is substantially more reliable on this machine.
#
# Usage:
#   tools/deploy-ios.sh                 # deploy to both configured devices
#   tools/deploy-ios.sh --iphone        # iPhone only
#   tools/deploy-ios.sh --ipad          # iPad only
#   tools/deploy-ios.sh --build-only    # compile, do not install
#   tools/deploy-ios.sh --no-build      # reinstall the latest built app
#   tools/deploy-ios.sh --regen         # regenerate the Xcode project first
#   tools/deploy-ios.sh --metadata-keys # explicitly include TMDb/OMDb keys
#   tools/deploy-ios.sh --branded       # install a SEPARATE per-branch app
#                                       #   ("Plozz <branch-slug>") side-by-side
#                                       #   with the canonical one
#
# Per-branch builds (--branded)
#   Installs com.thatcube.Plozz.<slug> named "Plozz <slug>", where <slug> comes
#   from the current branch. Use it to test a branch on a device WITHOUT
#   replacing the real app — the two coexist on the home screen.
#
#   Two consequences worth knowing before you use it:
#     * It signs against App/PlozziOS/PlozziOS.branded.entitlements (stripped),
#       because a brand-new App ID can't auto-provision iCloud/Push/Associated
#       Domains. So the branded app has NO cloud sync: it won't inherit servers
#       or profiles from the canonical app, and you'll sign in again. That's the
#       intended isolation, not a bug.
#     * A per-branch App ID needs a provisioning profile that includes your
#       device. This script now builds against the concrete target device and
#       verifies the profile before installing, so a missing device fails with
#       an explanation instead of the opaque install error 0xe8008012.
#
set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="Plozz.xcodeproj"
SCHEME="PlozziOS"
CONFIG="Debug"
IPHONE_CORE_ID="${PLOZZ_IPHONE_CORE_ID:-CACB5C41-FBA6-5DE8-9868-98BBDF897991}"
IPAD_CORE_ID="${PLOZZ_IPAD_CORE_ID:-D1EB8B46-3CEC-5F68-BCDA-B1C9E0E40600}"

DEPLOY_IPHONE=1
DEPLOY_IPAD=1
BUILD_ONLY=0
NO_BUILD=0
# Regenerate + re-bake the git-commit-count build number by DEFAULT so every deploy
# carries a distinct, verifiable CFBundleVersion (a stale number lets the install
# verifier false-positive; see install-verified.sh). --no-regen skips it; --no-build
# implies it (nothing new is compiled).
REGEN=1
# Metadata provider keys ship on EVERY platform. iOS used to blank them by
# default, which silently left iPhone and iPad with no provider that covers
# films (TheTVDB and TMDb are the only two; the keyless sources are anime- or
# TV-only and Wikipedia's API withholds non-free images), so half a mainstream
# library rendered blank there while the Apple TV — whose script has no such
# override — looked perfect. Parity with tvOS is the default; --keyless opts out
# for a deliberate no-key test build.
INCLUDE_METADATA_KEYS=1
BRANDED=0

for arg in "$@"; do
  case "$arg" in
    --iphone) DEPLOY_IPHONE=1; DEPLOY_IPAD=0 ;;
    --ipad) DEPLOY_IPHONE=0; DEPLOY_IPAD=1 ;;
    --build-only) BUILD_ONLY=1 ;;
    --no-build) NO_BUILD=1; REGEN=0 ;;
    --regen) REGEN=1 ;;
    --no-regen) REGEN=0 ;;
    --branded) BRANDED=1 ;;
    --metadata-keys) INCLUDE_METADATA_KEYS=1 ;;
    --keyless) INCLUDE_METADATA_KEYS=0 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown flag: $arg (try --help)" >&2; exit 2 ;;
  esac
done

export GIT_CONFIG_PARAMETERS="${GIT_CONFIG_PARAMETERS-'safe.bareRepository=all'}"

# --- Opt-in per-branch app (--branded) ---------------------------------------
# Installs a SEPARATE app `com.thatcube.Plozz.<slug>` named "Plozz <slug>" so this
# branch lives side-by-side with the canonical app (and other branches') on the
# device. Off by default → canonical `com.thatcube.Plozz`. Forces a regen and
# restores the canonical project + tracked Info.plists on exit (xcodegen writes the
# branded name into them) so the working tree stays clean.
if [[ "$BRANDED" == "1" ]]; then
  SLUG="$(git rev-parse --abbrev-ref HEAD 2>/dev/null \
    | sed 's/^thatcube-//' | tr '[:upper:]' '[:lower:]' \
    | tr -c 'a-z0-9-' '-' | sed 's/-\{2,\}/-/g; s/^-//; s/-$//' | cut -c1-24)"
  [[ -z "$SLUG" ]] && SLUG="branch"
  export PLOZZ_ID_SUFFIX=".$SLUG"
  export PLOZZ_NAME_SUFFIX=" $SLUG"
  # A fresh per-branch App ID can't auto-provision the canonical app's Push /
  # iCloud / Associated Domains capabilities, so sign against the stripped
  # entitlements (all three degrade gracefully — see the branded plist).
  export PLOZZ_IOS_APP_ENTITLEMENTS="App/PlozziOS/PlozziOS.branded.entitlements"
  REGEN=1
  echo "▸ Branded build: installing separate app com.thatcube.Plozz.$SLUG (\"Plozz $SLUG\")"
  restore_canonical() {
    echo "▸ Restoring canonical project + Info.plists (keeping the tree clean)…"
    git checkout -- App/Resources/Info.plist App/PlozziOS/Info.plist 2>/dev/null || true
    ( unset PLOZZ_ID_SUFFIX PLOZZ_NAME_SUFFIX PLOZZ_IOS_APP_ENTITLEMENTS; tools/generate-project.sh >/dev/null 2>&1 ) || true
  }
  trap restore_canonical EXIT
fi

# App Store Connect API key for provisioning. When present, xcodebuild can enable
# NEW App ID capabilities (e.g. Associated Domains) and regenerate profiles via
# -allowProvisioningUpdates. Without it, only already-enabled capabilities work.
# Override via ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH (or .env.fastlane).
ASC_KEY_ID="${ASC_KEY_ID:-37FS6MVHMJ}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-22389112-b204-4681-b921-ee9edc4afe6f}"
ASC_KEY_PATH="${ASC_KEY_PATH:-/Users/brandon/Development/.appstoreconnect/keys/AuthKey_${ASC_KEY_ID}.p8}"
AUTH_FLAGS=()
if [[ -f "$ASC_KEY_PATH" ]]; then
  AUTH_FLAGS=(
    -authenticationKeyPath "$ASC_KEY_PATH"
    -authenticationKeyID "$ASC_KEY_ID"
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"
  )
fi

BUILD_SETTING_OVERRIDES=()
if [[ "$INCLUDE_METADATA_KEYS" != "1" ]]; then
  # Only when --keyless is passed explicitly, to exercise the fallback path the
  # app must always keep working (TheTVDB/TVmaze/AniList/Kitsu/Wikidata + server art).
  BUILD_SETTING_OVERRIDES+=("TMDB_BEARER_TOKEN=" "OMDB_API_KEY=")
fi

if [[ "$REGEN" == "1" ]]; then
  tools/generate-project.sh
fi

# --- Build destination -------------------------------------------------------
# Resolve the hardware UDIDs of the devices we're about to deploy to, and build
# against a CONCRETE one rather than `generic/platform=iOS`.
#
# Why it matters: with a generic destination, xcodebuild has no target device to
# provision for, so `-allowProvisioningUpdates` can hand back a stale wildcard
# profile. For the canonical app id that profile already exists and covers every
# registered device, so nobody noticed. For a FRESH per-branch App ID (--branded)
# Xcode mints a new profile, and the one it produced contained a single device —
# the install then died with the famously unhelpful:
#
#     Failed to install embedded profile ... 0xe8008012
#     (This provisioning profile cannot be installed on this device.)
#
# Naming the real device makes Xcode provision for it. Falls back to the generic
# destination when a UDID can't be resolved (device asleep/offline), so this can
# only ever improve on the old behaviour.
#
# BOUNDED, and skipped entirely for a build-only run.
#
# `devicectl device info details` talks to the hardware, so an asleep or absent
# iPhone/iPad leaves it waiting — with two devices that stalled the script for
# minutes before the first compile, looking for all the world like a hung build.
# A compile needs no device at all (this is exactly what deploy-tv.sh already
# does: build the generic slice, name the device only to install), so
# `--build-only` never asks, and when we do ask we give up quickly and fall back
# to the generic destination rather than blocking.
device_udid() {
  local reply
  reply="$(
    xcrun devicectl device info details --device "$1" --timeout 10 2>/dev/null \
      | awk -F': ' '/• UDID:/ { gsub(/^[ \t]+/, "", $2); print $2; exit }'
  )" || return 0
  printf '%s' "$reply"
}

TARGET_UDIDS=()
if [[ "$BUILD_ONLY" != "1" ]]; then
  if [[ "$DEPLOY_IPHONE" == "1" ]]; then
    udid="$(device_udid "$IPHONE_CORE_ID")"; [[ -n "$udid" ]] && TARGET_UDIDS+=("$udid")
  fi
  if [[ "$DEPLOY_IPAD" == "1" ]]; then
    udid="$(device_udid "$IPAD_CORE_ID")"; [[ -n "$udid" ]] && TARGET_UDIDS+=("$udid")
  fi
fi

BUILD_DESTINATION="generic/platform=iOS"
if [[ ${#TARGET_UDIDS[@]} -gt 0 ]]; then
  BUILD_DESTINATION="platform=iOS,id=${TARGET_UDIDS[0]}"
fi

PREBUILD_APP_PATH="$(
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -destination "$BUILD_DESTINATION" \
    ${BUILD_SETTING_OVERRIDES[@]+"${BUILD_SETTING_OVERRIDES[@]}"} \
    -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/ CODESIGNING_FOLDER_PATH / { print $2; exit }'
)"
if [[ -n "$PREBUILD_APP_PATH" ]]; then
  tools/l10n-prune-stale-products.sh "$PREBUILD_APP_PATH"
fi

if [[ "$NO_BUILD" != "1" ]]; then
  echo "▸ Building universal iPhone/iPad app…"
  set -o pipefail
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -destination "$BUILD_DESTINATION" \
    -allowProvisioningUpdates \
    ${AUTH_FLAGS[@]+"${AUTH_FLAGS[@]}"} \
    ${BUILD_SETTING_OVERRIDES[@]+"${BUILD_SETTING_OVERRIDES[@]}"} \
    build \
    | { command -v xcbeautify >/dev/null 2>&1 && xcbeautify || cat; }
  # State the outcome in one greppable line. xcbeautify's own summary varies with
  # whether stdout is a terminal, so a piped run could finish successfully and
  # still look like silence to whatever was reading it.
  echo "✓ Build succeeded."
fi

APP_PATH="$(
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -destination "$BUILD_DESTINATION" \
    ${BUILD_SETTING_OVERRIDES[@]+"${BUILD_SETTING_OVERRIDES[@]}"} \
    -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/ CODESIGNING_FOLDER_PATH / { print $2; exit }'
)"

if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
  echo "✗ Could not locate the built Plozz.app." >&2
  exit 1
fi

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Info.plist")"
codesign --verify --deep --strict "$APP_PATH"

# Verify the build carries what was asked for. The failure this catches is
# silent at runtime: a provider without its key returns nothing forever, with no
# error and no log line.
TMDB_VALUE="$(
  /usr/libexec/PlistBuddy -c 'Print :TMDBBearerToken' \
    "$APP_PATH/Info.plist" 2>/dev/null || true
)"
TVDB_VALUE="$(
  /usr/libexec/PlistBuddy -c 'Print :TVDBAPIKey' \
    "$APP_PATH/Info.plist" 2>/dev/null || true
)"
if [[ "$INCLUDE_METADATA_KEYS" == "1" ]]; then
  if [[ -z "$TVDB_VALUE" ]]; then
    echo "✗ TVDBAPIKey is empty — films will have no poster source." >&2
    echo "  Check TVDB_API_KEY in Config/Secrets.local.xcconfig." >&2
    exit 1
  fi
  if [[ -z "$TMDB_VALUE" ]]; then
    echo "✗ TMDBBearerToken is empty — films lose their primary poster source." >&2
    echo "  Check TMDB_BEARER_TOKEN in Config/Secrets.local.xcconfig." >&2
    exit 1
  fi
elif [[ -n "$TMDB_VALUE" ]]; then
  echo "✗ Expected a --keyless build, but TMDBBearerToken is populated." >&2
  exit 1
fi

echo "✓ Build $BUILD ready ($(du -sh "$APP_PATH" | awk '{print $1}'))."

# --- Provisioning pre-flight -------------------------------------------------
# Confirm the embedded profile actually covers every device we're about to
# install on. Without this the failure surfaces at install time as:
#
#     Failed to install embedded profile for <bundle id> : 0xe8008012
#     (This provisioning profile cannot be installed on this device.)
#
# …which names neither the device nor the profile, and reads like a signing or
# trust problem rather than "this UDID isn't in the profile". Checking here costs
# milliseconds and turns it into an actionable message. Same spirit as the
# metadata-key verification above: catch the silent/cryptic case at build time.
if [[ ${#TARGET_UDIDS[@]} -gt 0 && -f "$APP_PATH/embedded.mobileprovision" ]]; then
  PROFILE_PLIST="$(mktemp -t plozz-profile)"
  if security cms -D -i "$APP_PATH/embedded.mobileprovision" > "$PROFILE_PLIST" 2>/dev/null; then
    PROVISIONED="$(/usr/libexec/PlistBuddy -c 'Print :ProvisionedDevices' "$PROFILE_PLIST" 2>/dev/null || true)"
    # An empty list means a distribution profile (no device list at all) — not
    # something to second-guess here.
    if [[ -n "$PROVISIONED" ]]; then
      for udid in "${TARGET_UDIDS[@]}"; do
        if ! grep -q "$udid" <<< "$PROVISIONED"; then
          echo "✗ The provisioning profile doesn't include device $udid." >&2
          echo "  Installing would fail with 0xe8008012 ('profile cannot be installed')." >&2
          echo "  Usually a stale cached profile. Try, in order:" >&2
          echo "    1. Make sure the device is connected and unlocked, then re-run." >&2
          echo "    2. rm -rf ~/Library/Developer/Xcode/UserData/Provisioning\\ Profiles" >&2
          echo "    3. Confirm the device is registered on the developer portal." >&2
          rm -f "$PROFILE_PLIST"
          exit 1
        fi
      done
    fi
  fi
  rm -f "$PROFILE_PLIST"
fi

if [[ "$BUILD_ONLY" == "1" ]]; then
  exit 0
fi

install_device() {
  local name="$1"
  local core_id="$2"
  echo "▸ Installing build $BUILD on $name (verified)…"
  # --force: we just built fresh code; always (re)install rather than skip on a
  # matching build number (git-commit-count versioning can't tell it apart from
  # changed-but-uncommitted code). The verified installer warms the tunnel, uses
  # a generous timeout, and confirms success by querying the device instead of
  # trusting the install command's exit code (which lies on wireless links).
  "$(dirname "$0")/install-verified.sh" "$core_id" "$APP_PATH" --force
}

STATUS=0
if [[ "$DEPLOY_IPHONE" == "1" ]]; then
  install_device "iPhone" "$IPHONE_CORE_ID" || STATUS=1
fi
if [[ "$DEPLOY_IPAD" == "1" ]]; then
  install_device "iPad" "$IPAD_CORE_ID" || STATUS=1
fi
exit "$STATUS"
