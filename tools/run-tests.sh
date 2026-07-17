#!/usr/bin/env bash
# Run Plozz's Swift Package unit tests on a tvOS Simulator — BUILD ONCE, RUN MANY.
#
# `swift test` cannot be used on macOS because AetherEngine's FFmpeg xcframeworks
# are tvOS-only. Instead we drive xcodebuild on a tvOS Simulator destination.
#
# ── Strategy (the speed win) ─────────────────────────────────────────────────
# The old runner looped `xcodebuild test` once PER test target (23 separate
# build + simulator-install + launch cycles ≈ 10–13 min, almost all of it compile
# + simulator orchestration — the tests themselves execute in <1s). This runner
# does ONE build that runs many suites:
#   * Full sweep (no args, or all targets): `xcodebuild test -scheme Plozz-Package`
#     with no `-only-testing` — one compile, one orchestration, every suite.
#   * Subset (≥2 suites, or a single suite whose native scheme isn't materialised):
#     `xcodebuild test -scheme Plozz-Package -only-testing:<S> …` — one build.
#   * Single suite whose native `<Suite>` scheme IS materialised: use it directly
#     (no "move Plozz.xcodeproj aside" dance needed) — the fast inner-loop path.
# The list of test targets is discovered from `swift package dump-package`, so it
# is DATA-DRIVEN and stays correct as targets are added (e.g. the WebDAV work's
# MediaTransportWebDAVTests) — nothing here is hardcoded.
#
# ── Self-heal (preserved) ────────────────────────────────────────────────────
# The always-present `Plozz-Package` scheme is what makes build-once possible, but
# a stray generated `Plozz.xcodeproj` in the working copy shadows the Swift package
# so `Plozz-Package` won't resolve. When we need it and it's shadowed, we move the
# project aside and restore it on exit (normal, error, or signal).
#
# ── Flake handling ───────────────────────────────────────────────────────────
# If the run reports specific failed suite bundles, each failed suite is retried
# ONCE in isolation (covers the ProviderPlexTests StubHTTPClient timing race). A
# suite only counts as failed if it fails twice. A build/compile failure (no
# per-suite result) is NOT retried.
#
# Usage:
#   ./tools/run-tests.sh                       # full matrix, build-once
#   ./tools/run-tests.sh CoreModelsTests …     # named suites, build-once
#   PLOZZ_SIM_ID=<udid> ./tools/run-tests.sh   # pin a specific simulator
#   PLOZZ_PARALLEL=YES ./tools/run-tests.sh    # opt into parallel test execution
#                                              #   (default NO — see docs/testing-policy.md)
set -euo pipefail

cd "$(dirname "$0")/.."

# Keep the git config workaround that the rest of the build chain expects.
export GIT_CONFIG_PARAMETERS="${GIT_CONFIG_PARAMETERS-'safe.bareRepository=all'}"

PARALLEL="${PLOZZ_PARALLEL:-NO}"

# --- Architecture layering guard (fast, data-driven) -------------------------
# Enforce the module-layering invariants before any (slow) compile/simulator
# orchestration. This is the chokepoint both CI and tools/test-fast.sh funnel
# through, so a forbidden module edge fails here too. Set PLOZZ_SKIP_ARCH_GUARD=1
# to bypass (the standalone CI step still runs it). See tools/arch-guard.py.
if [[ "${PLOZZ_SKIP_ARCH_GUARD:-0}" != "1" ]]; then
  python3 "$(dirname "$0")/arch-guard.py" || {
    echo "run-tests.sh: architecture layering guard FAILED — fix the module graph before testing."
    exit 1
  }
fi

# --- Discover all test targets (data-driven) ---------------------------------
ALL_TESTS=()
while IFS= read -r T; do
  [[ -n "$T" ]] && ALL_TESTS+=("$T")
done < <(
  swift package dump-package | python3 -c '
import json,sys
manifest=json.load(sys.stdin)
for target in manifest.get("targets", []):
    if target.get("type") == "test":
        print(target["name"])
'
)
if [[ ${#ALL_TESTS[@]} -eq 0 ]]; then
  echo "run-tests.sh: FAILED to discover any test targets from Package.swift."
  exit 1
fi

SCHEMES=("$@")
if [[ ${#SCHEMES[@]} -eq 0 ]]; then
  SCHEMES=("${ALL_TESTS[@]}")
fi

# --- Pick a tvOS simulator ----------------------------------------------------
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

MOVED_PROJECT=""
restore_project() {
  if [[ -n "$MOVED_PROJECT" && -e "$MOVED_PROJECT" ]]; then
    mv "$MOVED_PROJECT" "Plozz.xcodeproj"
    MOVED_PROJECT=""
  fi
}

LOG_DIR="$(mktemp -d)"
trap 'restore_project; rm -rf "$LOG_DIR"' EXIT

AVAILABLE_SCHEMES="$(list_schemes)"
scheme_exists() { grep -qxF -- "$1" <<<"$AVAILABLE_SCHEMES"; }

# Ensure `Plozz-Package` resolves; move a shadowing generated project aside if it
# blocks resolution (restored on exit). Returns 0 if Plozz-Package is usable.
ensure_package_scheme() {
  scheme_exists "Plozz-Package" && return 0
  if [[ -d "Plozz.xcodeproj" ]]; then
    echo "run-tests.sh: Plozz.xcodeproj is shadowing the Swift package — moving it aside so 'Plozz-Package' resolves (restored on exit)."
    MOVED_PROJECT="$(pwd)/.Plozz.xcodeproj.run-tests-aside"
    rm -rf "$MOVED_PROJECT"
    mv "Plozz.xcodeproj" "$MOVED_PROJECT"
    AVAILABLE_SCHEMES="$(list_schemes)"
  fi
  scheme_exists "Plozz-Package"
}

# --- Run helpers --------------------------------------------------------------
SUMMARY_RE="Test Suite '.*\.xctest'|Executed [0-9]+ test|TEST (SUCCEEDED|FAILED)|Failing tests:|error:|XCTAssert"

# Print the bundle-level test targets that FAILED in a given log (one per line).
failed_bundles_from_log() {
  grep -Eo "Test Suite '[A-Za-z0-9_]+\.xctest' failed" "$1" 2>/dev/null \
    | sed -E "s/Test Suite '([A-Za-z0-9_]+)\.xctest' failed/\1/" | sort -u
}

# xcodebuild_test <log> <xcb-arg>...  -> returns xcodebuild's exit status
xcodebuild_test() {
  local log="$1"; shift
  set +e
  xcodebuild test \
    "$@" \
    -destination "platform=tvOS Simulator,id=$PLOZZ_SIM_ID" \
    -parallel-testing-enabled "$PARALLEL" \
    CODE_SIGNING_ALLOWED=NO 2>&1 \
    | tee "$log" \
    | grep --line-buffered -E "$SUMMARY_RE" | tail -60
  local status=${PIPESTATUS[0]}
  set -e
  return $status
}

# --- Decide the build strategy ------------------------------------------------
# A set is "full" if it equals every discovered test target.
is_full_set() {
  [[ ${#SCHEMES[@]} -eq ${#ALL_TESTS[@]} ]] || return 1
  local sorted_req sorted_all
  sorted_req="$(printf '%s\n' "${SCHEMES[@]}" | sort -u)"
  sorted_all="$(printf '%s\n' "${ALL_TESTS[@]}" | sort -u)"
  [[ "$sorted_req" == "$sorted_all" ]]
}

MAIN_LOG="$LOG_DIR/main.log"
STATUS=0

if [[ ${#SCHEMES[@]} -eq 1 ]] && scheme_exists "${SCHEMES[0]}"; then
  # Fast inner-loop path: a single suite whose native scheme Xcode materialised —
  # build just that target, no shadow-dance.
  echo "=== ${SCHEMES[0]} (native scheme) ==="
  xcodebuild_test "$MAIN_LOG" -scheme "${SCHEMES[0]}" || STATUS=$?
else
  # Build-once via the package scheme (one compile, one orchestration).
  if ! ensure_package_scheme; then
    echo "run-tests.sh: FAILED — 'Plozz-Package' scheme is unavailable and could not be resolved (needed for a build-once run)."
    exit 1
  fi
  XCB=(-scheme "Plozz-Package")
  if is_full_set; then
    echo "=== FULL matrix via Plozz-Package (build once, ${#ALL_TESTS[@]} suites) ==="
  else
    echo "=== ${#SCHEMES[@]} suite(s) via Plozz-Package (build once): ${SCHEMES[*]} ==="
    for S in "${SCHEMES[@]}"; do XCB+=(-only-testing:"$S"); done
  fi
  xcodebuild_test "$MAIN_LOG" "${XCB[@]}" || STATUS=$?
fi

# --- Retry-once for flaky suites ---------------------------------------------
if [[ $STATUS -ne 0 ]]; then
  FAILED=()
  while IFS= read -r S; do
    [[ -n "$S" ]] && FAILED+=("$S")
  done < <(failed_bundles_from_log "$MAIN_LOG")
  if [[ ${#FAILED[@]} -eq 0 ]]; then
    echo "FAILURE: the test run failed but no per-suite result was found (build/compile error, or the run was aborted). Not retrying."
    exit 1
  fi
  echo ""
  echo "run-tests.sh: ${#FAILED[@]} suite(s) failed: ${FAILED[*]} — retrying each once in isolation (flake guard)."
  if ! ensure_package_scheme; then
    echo "FAILURE: cannot retry — 'Plozz-Package' scheme is unavailable."
    exit 1
  fi
  STILL_FAILED=()
  for S in "${FAILED[@]}"; do
    echo "=== retry: $S ==="
    RETRY_LOG="$LOG_DIR/retry-$S.log"
    if xcodebuild_test "$RETRY_LOG" -scheme "Plozz-Package" -only-testing:"$S"; then
      echo "  -> $S PASSED on retry (flake)."
    else
      echo "  -> $S FAILED again."
      STILL_FAILED+=("$S")
    fi
  done
  if [[ ${#STILL_FAILED[@]} -ne 0 ]]; then
    echo "FAILURE: ${#STILL_FAILED[@]} suite(s) failed twice: ${STILL_FAILED[*]}"
    exit 1
  fi
  echo "All previously-failing suites passed on retry."
fi

echo "All test suites passed."
