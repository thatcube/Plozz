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
#
set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="Plozz.xcodeproj"
SCHEME="PlozziOS"
CONFIG="Debug"
IPHONE_UDID="${PLOZZ_IPHONE_UDID:-00008140-000955C40A0B001C}"
IPHONE_CORE_ID="${PLOZZ_IPHONE_CORE_ID:-CACB5C41-FBA6-5DE8-9868-98BBDF897991}"
IPAD_UDID="${PLOZZ_IPAD_UDID:-00008027-000331D81A62802E}"
IPAD_CORE_ID="${PLOZZ_IPAD_CORE_ID:-D1EB8B46-3CEC-5F68-BCDA-B1C9E0E40600}"

DEPLOY_IPHONE=1
DEPLOY_IPAD=1
BUILD_ONLY=0
NO_BUILD=0
REGEN=0
INCLUDE_METADATA_KEYS=0

for arg in "$@"; do
  case "$arg" in
    --iphone) DEPLOY_IPHONE=1; DEPLOY_IPAD=0 ;;
    --ipad) DEPLOY_IPHONE=0; DEPLOY_IPAD=1 ;;
    --build-only) BUILD_ONLY=1 ;;
    --no-build) NO_BUILD=1 ;;
    --regen) REGEN=1 ;;
    --metadata-keys) INCLUDE_METADATA_KEYS=1 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown flag: $arg (try --help)" >&2; exit 2 ;;
  esac
done

export GIT_CONFIG_PARAMETERS="${GIT_CONFIG_PARAMETERS-'safe.bareRepository=all'}"

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
  # Device builds are keyless by default. Account-level integrations such as
  # Trakt remain available through Secrets.xcconfig; only optional metadata keys
  # are blanked unless the caller explicitly opts in.
  BUILD_SETTING_OVERRIDES+=("TMDB_BEARER_TOKEN=" "OMDB_API_KEY=")
fi

if [[ "$REGEN" == "1" ]]; then
  tools/generate-project.sh
fi

if [[ "$NO_BUILD" != "1" ]]; then
  echo "▸ Building universal iPhone/iPad app…"
  set -o pipefail
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -destination "generic/platform=iOS" \
    -allowProvisioningUpdates \
    ${AUTH_FLAGS[@]+"${AUTH_FLAGS[@]}"} \
    ${BUILD_SETTING_OVERRIDES[@]+"${BUILD_SETTING_OVERRIDES[@]}"} \
    build \
    | { command -v xcbeautify >/dev/null 2>&1 && xcbeautify || cat; }
fi

APP_PATH="$(
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -destination "generic/platform=iOS" \
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

if [[ "$INCLUDE_METADATA_KEYS" != "1" ]]; then
  TMDB_VALUE="$(
    /usr/libexec/PlistBuddy -c 'Print :TMDBBearerToken' \
      "$APP_PATH/Info.plist" 2>/dev/null || true
  )"
  if [[ -n "$TMDB_VALUE" ]]; then
    echo "✗ Expected a keyless build, but TMDBBearerToken is populated." >&2
    exit 1
  fi
fi

echo "✓ Build $BUILD ready ($(du -sh "$APP_PATH" | awk '{print $1}'))."

if [[ "$BUILD_ONLY" == "1" ]]; then
  exit 0
fi

install_device() {
  local name="$1"
  local core_id="$3"   # arg 2 (usbmux udid) is no longer needed — devicectl uses
                       # the CoreDevice id and picks USB automatically when present.
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
  install_device "iPhone" "$IPHONE_UDID" "$IPHONE_CORE_ID" || STATUS=1
fi
if [[ "$DEPLOY_IPAD" == "1" ]]; then
  install_device "iPad" "$IPAD_UDID" "$IPAD_CORE_ID" || STATUS=1
fi
exit "$STATUS"
