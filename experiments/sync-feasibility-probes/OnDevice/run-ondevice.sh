#!/usr/bin/env bash
# Build + deploy the throwaway on-device Bonjour pairing probe to a real iPhone
# and Apple TV, then observe discovery. ISOLATED probe — not the Plozz app.
#
# Prereqs: xcodegen, a paired iPhone (unlocked!) + Apple TV on the SAME Wi-Fi,
# team N8Z5T4AK3X signing, and the ASC API key for automatic provisioning.
#
# Usage: ./run-ondevice.sh
set -euo pipefail
export GIT_CONFIG_PARAMETERS="'safe.bareRepository=all'"

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

# Devices (Brandon's environment):
TV_DEVICECTL="DE913871-CC2D-5F75-B4F2-0D6F44AA30DE"      # Brando TV
IPHONE_DEVICECTL="CACB5C41-FBA6-5DE8-9868-98BBDF897991"  # Brando's iPhone (must be UNLOCKED)

KEY="/Users/brandon/Development/.appstoreconnect/keys/AuthKey_37FS6MVHMJ.p8"
KEY_ID="37FS6MVHMJ"
ISSUER="22389112-b204-4681-b921-ee9edc4afe6f"
SIGN=(-allowProvisioningUpdates -authenticationKeyPath "$KEY" -authenticationKeyID "$KEY_ID" -authenticationKeyIssuerID "$ISSUER")

echo "== generate =="; xcodegen generate >/dev/null
echo "== build tvOS =="; xcodebuild -project PlozzPairProbe.xcodeproj -scheme PlozzPairProbeTV  -configuration Debug -destination 'generic/platform=tvOS' "${SIGN[@]}" -derivedDataPath ./dd build >/dev/null
echo "== build iOS =="; xcodebuild -project PlozzPairProbe.xcodeproj -scheme PlozzPairProbeiOS -configuration Debug -destination 'generic/platform=iOS'  "${SIGN[@]}" -derivedDataPath ./dd build >/dev/null

TVAPP="dd/Build/Products/Debug-appletvos/PlozzPairProbeTV.app"
IOSAPP="dd/Build/Products/Debug-iphoneos/PlozzPairProbeiOS.app"

retry() { # retry a devicectl op up to 5x through the flaky CoreDevice tunnel
  local n=0; until "$@"; do n=$((n+1)); [ $n -ge 5 ] && return 1; echo "  retry $n…"; sleep 5; done
}

echo "== install + launch advertiser on Apple TV =="
retry xcrun devicectl device install app --device "$TV_DEVICECTL" "$TVAPP"
retry xcrun devicectl device process launch --device "$TV_DEVICECTL" com.thatcube.PlozzPairProbeTV

echo "== quick cross-check: browse for the TV's service from THIS Mac =="
swift run --package-path .. BonjourProbe --browse || true

echo "== install + launch browser on iPhone (must be UNLOCKED; tap Allow on the Local Network prompt) =="
retry xcrun devicectl device install app --device "$IPHONE_DEVICECTL" "$IOSAPP"
retry xcrun devicectl device process launch --device "$IPHONE_DEVICECTL" com.thatcube.PlozzPairProbe
echo "Watch the iPhone screen: it should show 'BROWSER discovered ... / got beacon ... OK'."
echo "Console: log stream --predicate 'subsystem == \"com.thatcube.pairprobe\"' on each device."

echo "== cleanup (optional) =="
echo "  xcrun devicectl device uninstall app --device $TV_DEVICECTL com.thatcube.PlozzPairProbeTV"
echo "  xcrun devicectl device uninstall app --device $IPHONE_DEVICECTL com.thatcube.PlozzPairProbe"
