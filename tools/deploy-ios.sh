#!/usr/bin/env bash
#
# One-command incremental build, install, and launch for Plozz on iPhone/iPad.
# Direct USB installation uses libimobiledevice instead of CoreDevice's RSD
# tunnel, which is substantially more reliable on this machine.
#
# Usage:
#   tools/deploy-ios.sh                 # deploy to both configured devices
#   tools/deploy-ios.sh --iphone        # iPhone only
#   tools/deploy-ios.sh --ipad          # iPad only
#   tools/deploy-ios.sh --build-only    # compile, do not install
#   tools/deploy-ios.sh --no-build      # reinstall the latest built app
#   tools/deploy-ios.sh --regen         # regenerate the Xcode project first
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

for arg in "$@"; do
  case "$arg" in
    --iphone) DEPLOY_IPHONE=1; DEPLOY_IPAD=0 ;;
    --ipad) DEPLOY_IPHONE=0; DEPLOY_IPAD=1 ;;
    --build-only) BUILD_ONLY=1 ;;
    --no-build) NO_BUILD=1 ;;
    --regen) REGEN=1 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown flag: $arg (try --help)" >&2; exit 2 ;;
  esac
done

export GIT_CONFIG_PARAMETERS="${GIT_CONFIG_PARAMETERS-'safe.bareRepository=all'}"

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
    build \
    | { command -v xcbeautify >/dev/null 2>&1 && xcbeautify || cat; }
fi

APP_PATH="$(
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -destination "generic/platform=iOS" \
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

IPA=""
TEMP_DIR=""
make_ipa() {
  [[ -n "$IPA" ]] && return
  if ! command -v ideviceinstaller >/dev/null 2>&1; then
    return
  fi

  TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/plozz-ios-deploy.XXXXXX")"
  mkdir "$TEMP_DIR/Payload"
  COPYFILE_DISABLE=1 ditto "$APP_PATH" "$TEMP_DIR/Payload/Plozz.app"
  find "$TEMP_DIR/Payload" -name '._*' -delete
  (
    cd "$TEMP_DIR"
    COPYFILE_DISABLE=1 zip -qry Plozz.ipa Payload
  )
  if zipinfo -1 "$TEMP_DIR/Plozz.ipa" | grep -q '/\._'; then
    echo "✗ IPA contains AppleDouble files; refusing to install a broken signature." >&2
    exit 1
  fi
  IPA="$TEMP_DIR/Plozz.ipa"
}

cleanup() {
  [[ -n "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

install_device() {
  local name="$1"
  local udid="$2"
  local core_id="$3"
  local direct_flag=""

  if grep -qx "$udid" <<<"$USB_DEVICES"; then
    direct_flag=""
    echo "▸ Installing build $BUILD on $name over direct USB…"
  elif grep -qx "$udid" <<<"$NETWORK_DEVICES"; then
    direct_flag="-n"
    echo "▸ Installing build $BUILD on $name over usbmuxd Wi-Fi…"
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

  make_ipa
  if [[ -z "$IPA" ]]; then
    echo "✗ Direct installer unavailable. Run: brew install ideviceinstaller" >&2
    return 1
  fi

  if ideviceinstaller $direct_flag -u "$udid" list --user \
      --bundle-identifier "$BUNDLE_ID" 2>/dev/null \
      | grep -q "$BUNDLE_ID"; then
    ideviceinstaller $direct_flag -u "$udid" upgrade "$IPA"
  else
    ideviceinstaller $direct_flag -u "$udid" install "$IPA"
  fi
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
