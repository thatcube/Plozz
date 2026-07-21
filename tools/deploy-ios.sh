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
IPAD_CORE_ID="${PLOZZ_IPAD_CORE_ID:-57563618-0186-5D3B-81AD-CB884A854DD2}"

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

USB_DEVICES=""
NETWORK_DEVICES=""
if command -v idevice_id >/dev/null 2>&1; then
  USB_DEVICES="$(idevice_id -l 2>/dev/null || true)"
  NETWORK_DEVICES="$(idevice_id -n -l 2>/dev/null || true)"
fi

install_device() {
  local name="$1"
  local udid="$2"
  local core_id="$3"
  local transport_args=()

  if grep -qx "$udid" <<<"$USB_DEVICES"; then
    transport_args+=(--no-wifi)
    echo "▸ Installing build $BUILD on $name over direct USB…"
  elif grep -qx "$udid" <<<"$NETWORK_DEVICES"; then
    echo "▸ Installing build $BUILD on $name over MobileDevice Wi-Fi…"
  else
    echo "▸ $name is not visible through usbmuxd; trying CoreDevice once…"
    if ! xcrun devicectl device install app \
      --device "$core_id" --timeout 45 "$APP_PATH"; then
      echo "✗ $name installation failed. Connect it by USB and retry." >&2
      return 1
    fi
    launch_device "$name" "$core_id"
    return
  fi

  local running_pid
  running_pid="$(
    xcrun devicectl device info processes \
      --device "$core_id" --timeout 20 2>/dev/null \
      | awk '/\/Plozz\.app\/Plozz$/ { print $1; exit }'
  )"
  if [[ -n "$running_pid" ]]; then
    echo "▸ Stopping the existing Plozz process before replacement…"
    xcrun devicectl device process terminate \
      --device "$core_id" --pid "$running_pid" --timeout 20 >/dev/null || true
  fi

  if ! command -v ios-deploy >/dev/null 2>&1; then
    echo "✗ MobileDevice installer unavailable. Run: brew install ios-deploy" >&2
    return 1
  fi

  ios-deploy \
    --id "$udid" \
    --bundle "$APP_PATH" \
    --timeout 30 \
    "${transport_args[@]}"
  launch_device "$name" "$core_id"
}

launch_device() {
  local name="$1"
  local core_id="$2"
  if xcrun devicectl device process launch \
      --device "$core_id" --timeout 30 "$BUNDLE_ID" >/dev/null; then
    echo "✓ $name installed and launched build $BUILD."
  else
    echo "✓ $name installed build $BUILD; unlock it and launch Plozz manually."
  fi
}

STATUS=0
if [[ "$DEPLOY_IPHONE" == "1" ]]; then
  install_device "iPhone" "$IPHONE_UDID" "$IPHONE_CORE_ID" || STATUS=1
fi
if [[ "$DEPLOY_IPAD" == "1" ]]; then
  install_device "iPad" "$IPAD_UDID" "$IPAD_CORE_ID" || STATUS=1
fi
exit "$STATUS"
