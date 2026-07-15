#!/usr/bin/env bash
# Explicit, non-shipping SearchIndex benchmark for Brando TV.
# Builds/installs the standalone SearchIndexSpikeHost, captures aggregate metrics,
# and uninstalls it. Never installs or launches Plozz.
set -euo pipefail

cd "$(dirname "$0")/.."
export GIT_CONFIG_PARAMETERS="${GIT_CONFIG_PARAMETERS-\"'safe.bareRepository=all'\"}"

DEVICE_NAME="${PLOZZ_DEVICE_NAME:-Brando TV}"
DEVICE_ID="${PLOZZ_DEVICE_ID:-DE913871-CC2D-5F75-B4F2-0D6F44AA30DE}"

tools/generate-project.sh >/dev/null
xcodebuild \
  -project Plozz.xcodeproj \
  -scheme SearchIndexSpikeHost \
  -destination "platform=tvOS,name=$DEVICE_NAME" \
  build -quiet

APP_PATH=$(xcodebuild \
  -project Plozz.xcodeproj \
  -scheme SearchIndexSpikeHost \
  -destination "platform=tvOS,name=$DEVICE_NAME" \
  -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ CODESIGNING_FOLDER_PATH/ {print $2; exit}')
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Info.plist")

cleanup() {
  xcrun devicectl device uninstall app \
    --device "$DEVICE_ID" "$BUNDLE_ID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH" >/dev/null
xcrun devicectl device process launch \
  --console \
  --terminate-existing \
  --timeout 900 \
  --device "$DEVICE_ID" \
  "$BUNDLE_ID" 2>&1 \
  | grep -E 'SEARCH_INDEX_'
