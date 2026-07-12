#!/usr/bin/env bash
# Run Plozz's Swift Package unit tests on a tvOS Simulator.
#
# `swift test` cannot be used on macOS because AetherEngine's FFmpeg xcframeworks
# are tvOS-only. Instead we drive the auto-generated per-module *Tests schemes that
# Xcode publishes when it integrates the local Swift Package, via xcodebuild on
# a tvOS Simulator destination.
#
# Self-heal for fresh worktrees / CI: those per-module *Tests schemes
# (MetadataKitTests, ...) are Xcode-*autocreated* user data (gitignored), so a
# checkout that hasn't been opened in Xcode won't have them and a bare
# `-scheme MetadataKitTests` would fail with "does not contain a scheme named".
# When a requested *Tests scheme isn't materialised we transparently fall back to
# the always-present Swift-package scheme `Plozz-Package` with
# `-only-testing:<Suite>`, which runs the exact same test target. A stray
# generated `Plozz.xcodeproj` in the working copy shadows the Swift package (so
# neither the *Tests schemes nor `Plozz-Package` resolve); if that blocks the
# fallback we temporarily move it aside and restore it on exit.
#
# Usage:
#   ./tools/run-tests.sh                     # run the default test suites
#   ./tools/run-tests.sh CoreModelsTests     # run a specific test scheme
#   PLOZZ_SIM_ID=<udid> ./tools/run-tests.sh # pin to a specific simulator
set -euo pipefail

cd "$(dirname "$0")/.."

# Keep the git config workaround that the rest of the build chain expects.
export GIT_CONFIG_PARAMETERS="${GIT_CONFIG_PARAMETERS-'safe.bareRepository=all'}"

DEFAULT_SCHEMES=()
while IFS= read -r SCHEME; do
  [[ -n "$SCHEME" ]] && DEFAULT_SCHEMES+=("$SCHEME")
done < <(
  swift package dump-package | python3 -c '
import json,sys
manifest=json.load(sys.stdin)
for target in manifest.get("targets", []):
    if target.get("type") == "test":
        print(target["name"])
'
)
if [[ ${#DEFAULT_SCHEMES[@]} -eq 0 ]]; then
  echo "run-tests.sh: FAILED to discover any test targets from Package.swift."
  exit 1
fi

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

# --- Scheme resolution + self-heal -------------------------------------------
# Discover which schemes xcodebuild can actually resolve in this checkout, so we
# can fall back to `Plozz-Package -only-testing:<Suite>` for any *Tests scheme
# Xcode hasn't materialised (see the header note).
list_schemes() {
  xcodebuild -list -json 2>/dev/null | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(0)
for container in ("project","workspace"):
    info=d.get(container) or {}
    for s in info.get("schemes",[]):
        print(s)
'
}

# A shadowing generated project is moved aside only if it actually blocks the
# package fallback, and always restored on exit (normal, error, or signal).
MOVED_PROJECT=""
restore_project() {
  if [[ -n "$MOVED_PROJECT" && -e "$MOVED_PROJECT" ]]; then
    mv "$MOVED_PROJECT" "Plozz.xcodeproj"
    MOVED_PROJECT=""
  fi
}
trap restore_project EXIT

AVAILABLE_SCHEMES="$(list_schemes)"
scheme_exists() { grep -qxF -- "$1" <<<"$AVAILABLE_SCHEMES"; }

# If any requested scheme is missing AND the package fallback itself can't be
# resolved because a generated Plozz.xcodeproj is shadowing the Swift package,
# move the project aside so `Plozz-Package` resolves, then re-list.
need_fallback=0
for SCHEME in "${SCHEMES[@]}"; do
  scheme_exists "$SCHEME" || { need_fallback=1; break; }
done
if [[ $need_fallback -eq 1 ]] && ! scheme_exists "Plozz-Package" && [[ -d "Plozz.xcodeproj" ]]; then
  echo "run-tests.sh: a *Tests scheme isn't materialised and Plozz.xcodeproj is shadowing the Swift package — moving it aside so 'Plozz-Package' resolves (restored on exit)."
  MOVED_PROJECT="$(pwd)/.Plozz.xcodeproj.run-tests-aside"
  rm -rf "$MOVED_PROJECT"
  mv "Plozz.xcodeproj" "$MOVED_PROJECT"
  AVAILABLE_SCHEMES="$(list_schemes)"
fi

FAIL=0
for SCHEME in "${SCHEMES[@]}"; do
  echo "=== $SCHEME ==="
  # Prefer the native *Tests scheme when Xcode has materialised it; otherwise run
  # the same test target through the package scheme.
  if scheme_exists "$SCHEME"; then
    XCB_ARGS=(-scheme "$SCHEME")
  elif scheme_exists "Plozz-Package"; then
    echo "  ('$SCHEME' scheme not materialised — running via Plozz-Package -only-testing:$SCHEME)"
    XCB_ARGS=(-scheme "Plozz-Package" -only-testing:"$SCHEME")
  else
    echo "  -> FAILED: no '$SCHEME' scheme and no 'Plozz-Package' fallback available."
    FAIL=$((FAIL + 1))
    continue
  fi
  set +e
  xcodebuild test \
    "${XCB_ARGS[@]}" \
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
