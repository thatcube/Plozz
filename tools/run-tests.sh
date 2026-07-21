#!/usr/bin/env bash
# Run Plozz's Swift Package unit tests on a tvOS Simulator — BUILD ONCE, RUN MANY.
#
# `swift test` cannot be used on macOS because AetherEngine's FFmpeg xcframeworks
# are tvOS-only. Instead we drive xcodebuild on a tvOS Simulator destination.
#
# ── Strategy (the speed win) ─────────────────────────────────────────────────
# The tests themselves execute in <1s; essentially all wall-clock is compile +
# simulator orchestration. Two things dominate a subset run's cost, and this
# runner cuts both:
#   1. Build scope. `xcodebuild -only-testing:<S>` filters which tests EXECUTE
#      but still BUILDS the whole `Plozz-Package` scheme (~30 modules + ~29 test
#      bundles + every heavy external dep). So a 2-suite run used to compile the
#      entire graph — ~90% of it wasted.
#   2. Redundant per-worktree work (dSYMs, index store, inactive archs).
# Strategy:
#   * Full sweep (no args, or every target): `xcodebuild test -scheme
#     Plozz-Package` — one compile, one orchestration, every suite (CI gate).
#   * Subset (any 1..N suites): synthesise an ephemeral SCOPED scheme whose
#     build+test actions list exactly the requested test targets, then
#     `xcodebuild test -scheme <scoped>`. Only those suites' dependency subtrees
#     compile — e.g. `CoreModelsTests ProviderPlexTests` builds ~7 targets, not
#     ~96. The scheme lives in the gitignored `.swiftpm/` and is removed on exit.
#   * All builds also pass lean settings (no dSYM / no index store / active arch
#     only); set PLOZZ_LEAN=0 to opt out.
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

# --- Lean build settings for the test build (P3) ------------------------------
# These trim work that a simulator test build never needs: the index-while-
# building store (COMPILER_INDEX_STORE_ENABLE=NO), dSYM generation
# (DEBUG_INFORMATION_FORMAT=dwarf, not dwarf-with-dsym), and building for
# inactive architectures (ONLY_ACTIVE_ARCH=YES). They shave cold-build time and
# reduce CPU/IO footprint (which matters most when several worktrees build in
# parallel). Set PLOZZ_LEAN=0 to opt out (e.g. to profile with a dSYM).
LEAN_SETTINGS=()
if [[ "${PLOZZ_LEAN:-1}" != "0" ]]; then
  LEAN_SETTINGS=(
    COMPILER_INDEX_STORE_ENABLE=NO
    DEBUG_INFORMATION_FORMAT=dwarf
    ONLY_ACTIVE_ARCH=YES
  )
fi

# --- Hang watchdog + isolated DerivedData ------------------------------------
# xcodebuild can WEDGE indefinitely (0% CPU, no output) when it inherits a
# poisoned/contended build database — most often the shared
# ~/Library/Developer/Xcode/DerivedData when several worktrees or a previously
# force-killed build left it in a bad state. Because `xcodebuild test` has no
# built-in timeout, that manifests as a "build" that silently hangs forever.
#
# Two defenses, both here:
#   1. A per-worktree DerivedData dir (PLOZZ_DERIVED_DATA) so this checkout never
#      contends with another worktree's build DB, and so a wedge can be cleared
#      by nuking just this dir — never the shared cache.
#   2. A no-progress watchdog: if the build log stops growing for
#      PLOZZ_HANG_SECS, the xcodebuild process tree is killed, this worktree's
#      DerivedData is cleared, and the invocation is retried ONCE from clean.
PLOZZ_DERIVED_DATA="${PLOZZ_DERIVED_DATA:-$PWD/.build/test-derived-data}"
PLOZZ_HANG_SECS="${PLOZZ_HANG_SECS:-180}"

# Recursively kill a process and all its descendants (xcodebuild's swift-frontend
# children don't die with the parent otherwise).
kill_tree() {
  local pid="$1" child
  for child in $(pgrep -P "$pid" 2>/dev/null || true); do kill_tree "$child"; done
  kill "$pid" 2>/dev/null || true
}


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

# --- Scoped-scheme support (the subset speed win) ----------------------------
# `xcodebuild ... -only-testing:<S>` filters which tests EXECUTE but still BUILDS
# the entire `Plozz-Package` scheme (all ~30 library modules + all ~29 test
# bundles + every heavy external dep: swift-nio, swift-crypto/BoringSSL,
# AetherEngine, SMBClient, …). For a subset run that is ~90% wasted compile.
# SwiftPM only auto-exposes per-PRODUCT schemes (no per-test-target scheme), so
# to build ONLY the requested suites' dependency subtrees we synthesise an
# ephemeral shared scheme whose Build + Test actions list exactly those test
# targets; their subtrees resolve automatically. `.swiftpm/` is gitignored and
# each scheme is removed on exit, so nothing is left behind or committed.
SCOPED_SCHEME_DIR=".swiftpm/xcode/xcshareddata/xcschemes"
CREATED_SCHEMES=()
cleanup_scoped_schemes() {
  local s
  for s in "${CREATED_SCHEMES[@]:-}"; do
    [[ -n "$s" ]] && rm -f "$SCOPED_SCHEME_DIR/$s.xcscheme"
  done
  return 0   # never let the loop's last (possibly-false) test set the EXIT status
}

# make_scoped_scheme <scheme-name> <test-target>...
# Writes an ephemeral shared scheme that builds+tests only the given test
# targets (and, transitively, only the modules they depend on).
make_scoped_scheme() {
  local name="$1"; shift
  mkdir -p "$SCOPED_SCHEME_DIR"
  local build_entries="" testables="" s
  for s in "$@"; do
    build_entries+="         <BuildActionEntry buildForTesting = \"YES\" buildForRunning = \"NO\" buildForProfiling = \"NO\" buildForArchiving = \"NO\" buildForAnalyzing = \"NO\">
            <BuildableReference BuildableIdentifier = \"primary\" BlueprintIdentifier = \"${s}\" BuildableName = \"${s}\" BlueprintName = \"${s}\" ReferencedContainer = \"container:\"></BuildableReference>
         </BuildActionEntry>
"
    testables+="         <TestableReference skipped = \"NO\">
            <BuildableReference BuildableIdentifier = \"primary\" BlueprintIdentifier = \"${s}\" BuildableName = \"${s}\" BlueprintName = \"${s}\" ReferencedContainer = \"container:\"></BuildableReference>
         </TestableReference>
"
  done
  cat > "$SCOPED_SCHEME_DIR/$name.xcscheme" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "1600" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
${build_entries}      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
${testables}      </Testables>
   </TestAction>
</Scheme>
EOF
  CREATED_SCHEMES+=("$name")
}

# True if every argument is a known test target (safe to build a scoped scheme).
all_are_test_targets() {
  local want found t
  for want in "$@"; do
    found=0
    for t in "${ALL_TESTS[@]}"; do [[ "$t" == "$want" ]] && { found=1; break; }; done
    [[ $found -eq 1 ]] || return 1
  done
  return 0
}

LOG_DIR="$(mktemp -d)"
trap 'restore_project; cleanup_scoped_schemes; rm -rf "$LOG_DIR"' EXIT

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

# _xcb_once <log> <xcb-arg>...  -> runs one xcodebuild test invocation with a
# no-progress watchdog. Returns xcodebuild's exit status, or 124 if the watchdog
# killed it for making no progress for PLOZZ_HANG_SECS.
_xcb_once() {
  local log="$1"; shift
  : > "$log"
  xcodebuild test \
    "$@" \
    -destination "platform=tvOS Simulator,id=$PLOZZ_SIM_ID" \
    -parallel-testing-enabled "$PARALLEL" \
    -derivedDataPath "$PLOZZ_DERIVED_DATA" \
    "${LEAN_SETTINGS[@]}" \
    CODE_SIGNING_ALLOWED=NO > "$log" 2>&1 &
  local xcb_pid=$!

  # Live-stream the summary lines so the run always shows progress (never a
  # silent multi-minute hang with no feedback).
  ( tail -n +1 -F "$log" 2>/dev/null | grep --line-buffered -E "$SUMMARY_RE" || true ) &
  local tail_pid=$!

  # Watchdog: poll the log size; if it doesn't grow for PLOZZ_HANG_SECS, the
  # build is wedged — kill the tree and report a hang (124).
  local last_size=-1 stalled=0 hung=0 size
  while kill -0 "$xcb_pid" 2>/dev/null; do
    sleep 10
    size=$(stat -f%z "$log" 2>/dev/null || echo 0)
    if [[ "$size" == "$last_size" ]]; then
      stalled=$(( stalled + 10 ))
      if [[ $stalled -ge $PLOZZ_HANG_SECS ]]; then
        echo "" ; echo "run-tests.sh: WATCHDOG — no build output for ${PLOZZ_HANG_SECS}s; xcodebuild is wedged. Killing it." >&2
        kill_tree "$xcb_pid"
        hung=1
        break
      fi
    else
      stalled=0
      last_size="$size"
    fi
  done

  local status
  wait "$xcb_pid" 2>/dev/null; status=$?
  kill "$tail_pid" 2>/dev/null || true
  wait "$tail_pid" 2>/dev/null || true
  [[ $hung -eq 1 ]] && return 124
  return $status
}

# xcodebuild_test <log> <xcb-arg>...  -> returns xcodebuild's exit status. Self-
# heals a wedged build once: on a watchdog kill, clears this worktree's
# DerivedData and retries from clean.
xcodebuild_test() {
  local log="$1"; shift
  local attempt status
  for attempt in 1 2; do
    set +e
    _xcb_once "$log" "$@"
    status=$?
    set -e
    if [[ $status -eq 124 && $attempt -eq 1 ]]; then
      echo "run-tests.sh: clearing DerivedData ($PLOZZ_DERIVED_DATA) and retrying the build once from clean." >&2
      rm -rf "$PLOZZ_DERIVED_DATA"
      continue
    fi
    [[ $status -eq 124 ]] && echo "run-tests.sh: FAILURE — xcodebuild wedged twice; the simulator/toolchain likely needs attention." >&2
    return $status
  done
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

if is_full_set; then
  # Full matrix (CI / pre-merge gate): build the whole package once — one
  # compile, one orchestration, every suite.
  if ! ensure_package_scheme; then
    echo "run-tests.sh: FAILED — 'Plozz-Package' scheme is unavailable and could not be resolved (needed for a build-once run)."
    exit 1
  fi
  echo "=== FULL matrix via Plozz-Package (build once, ${#ALL_TESTS[@]} suites) ==="
  xcodebuild_test "$MAIN_LOG" -scheme "Plozz-Package" || STATUS=$?
elif all_are_test_targets "${SCHEMES[@]}"; then
  # Subset: build ONLY the requested suites' dependency subtrees via an
  # ephemeral scoped scheme. Skips the ~90% of the module graph (and all the
  # heavy external deps) that the requested suites don't touch. The scoped
  # scheme lives in the package's .swiftpm dir, so the package must be the
  # resolved container — move a shadowing generated Plozz.xcodeproj aside first.
  if ! ensure_package_scheme; then
    echo "run-tests.sh: FAILED — could not resolve the Swift package (needed to build a scoped subset)."
    exit 1
  fi
  SCOPED_SCHEME="_PlozzScoped_$$"
  make_scoped_scheme "$SCOPED_SCHEME" "${SCHEMES[@]}"
  echo "=== ${#SCHEMES[@]} suite(s) via scoped scheme (build only their subtrees): ${SCHEMES[*]} ==="
  xcodebuild_test "$MAIN_LOG" -scheme "$SCOPED_SCHEME" || STATUS=$?
else
  # At least one requested name isn't a known test target — fall back to the
  # safe build-once path (which tolerates/filters via -only-testing).
  if ! ensure_package_scheme; then
    echo "run-tests.sh: FAILED — 'Plozz-Package' scheme is unavailable and could not be resolved (needed for a build-once run)."
    exit 1
  fi
  XCB=(-scheme "Plozz-Package")
  echo "=== ${#SCHEMES[@]} suite(s) via Plozz-Package (build once): ${SCHEMES[*]} ==="
  for S in "${SCHEMES[@]}"; do XCB+=(-only-testing:"$S"); done
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
    # Retry the single failing suite in isolation. Prefer a scoped scheme (build
    # only that suite's subtree); fall back to Plozz-Package if it isn't a known
    # test target (e.g. an unexpected bundle name in the log).
    if all_are_test_targets "$S"; then
      RETRY_SCHEME="_PlozzRetry_${$}_${S}"
      make_scoped_scheme "$RETRY_SCHEME" "$S"
      RETRY_ARGS=(-scheme "$RETRY_SCHEME")
    else
      RETRY_ARGS=(-scheme "Plozz-Package" -only-testing:"$S")
    fi
    if xcodebuild_test "$RETRY_LOG" "${RETRY_ARGS[@]}"; then
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
