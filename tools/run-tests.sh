#!/usr/bin/env bash
# Run Plozz's Swift Package unit tests on a tvOS Simulator.
#
# `swift test` cannot be used on macOS because AetherEngine's FFmpeg xcframeworks
# are tvOS-only. Instead we drive the auto-generated per-module *Tests schemes that
# Xcode publishes when it integrates the local Swift Package, via xcodebuild on
# a tvOS Simulator destination.
#
# Usage:
#   ./tools/run-tests.sh                     # run the default test suites
#   ./tools/run-tests.sh CoreModelsTests     # run a specific test scheme
#   PLOZZ_SIM_ID=<udid> ./tools/run-tests.sh # pin to a specific simulator
set -euo pipefail

cd "$(dirname "$0")/.."

# Keep the git config workaround that the rest of the build chain expects.
export GIT_CONFIG_PARAMETERS="${GIT_CONFIG_PARAMETERS-'safe.bareRepository=all'}"

DEFAULT_SCHEMES=(
  CoreModelsTests
  CoreNetworkingTests
  CoreUITests
  MetadataKitTests
  FeatureDiscoveryTests
  ProviderJellyfinTests
  ProviderPlexTests
  ProviderTrailersTests
  RatingsServiceTests
  TraktServiceTests
  SeerServiceTests
  FeatureAuthTests
  FeatureHomeTests
  FeatureSearchTests
  FeatureProfilesTests
  FeatureMusicTests
  FeaturePlaybackTests
)

SCHEMES=("$@")
if [[ ${#SCHEMES[@]} -eq 0 ]]; then
  SCHEMES=("${DEFAULT_SCHEMES[@]}")
fi

# Pick a booted tvOS simulator if none is pinned, else boot one.
if [[ -z "${PLOZZ_SIM_ID-}" ]]; then
  PLOZZ_SIM_ID=$(xcrun simctl list devices booted -j 2>/dev/null \
    | python3 -c 'import json,sys
d=json.load(sys.stdin)
for runtime,devs in d["devices"].items():
  if "tvOS" not in runtime: continue
  for dev in devs:
    if dev.get("state")=="Booted": print(dev["udid"]); sys.exit(0)' || true)
fi
if [[ -z "${PLOZZ_SIM_ID-}" ]]; then
  PLOZZ_SIM_ID=$(xcrun simctl list devices available -j \
    | python3 -c 'import json,sys
d=json.load(sys.stdin)
for runtime,devs in d["devices"].items():
  if "tvOS" not in runtime: continue
  for dev in devs:
    if dev.get("isAvailable") and "Apple TV" in dev["name"]:
      print(dev["udid"]); sys.exit(0)')
fi
echo "Using tvOS Simulator: $PLOZZ_SIM_ID"

FAIL=0
for SCHEME in "${SCHEMES[@]}"; do
  echo "=== $SCHEME ==="
  set +e
  xcodebuild test \
    -scheme "$SCHEME" \
    -destination "platform=tvOS Simulator,id=$PLOZZ_SIM_ID" \
    CODE_SIGNING_ALLOWED=NO 2>&1 \
    | grep -E "Test Suite '.*\.xctest'|Executed [0-9]+ test|TEST (SUCCEEDED|FAILED)|Failing tests:|error:|XCTAssert" \
    | tail -20
  STATUS=${PIPESTATUS[0]}
  set -e
  if [[ $STATUS -ne 0 ]]; then
    FAIL=$((FAIL + 1))
    echo "  -> FAILED ($STATUS)"
  fi
done

if [[ $FAIL -ne 0 ]]; then
  echo "FAILURE: $FAIL scheme(s) failed."
  exit 1
fi
echo "All test schemes passed."
