#!/usr/bin/env bash
# test-fast.sh — change-scoped inner-loop test runner for Plozz.
#
# WHY: the full suite (`tools/run-tests.sh` with no args) takes ~10 minutes,
# almost all of it tvOS-simulator orchestration + compile, NOT test execution
# (all 1088 tests run in <1s of CPU). Running the whole sweep on every change is
# ~100x slower than running only the suite(s) that cover what you touched. This
# script maps the files you changed (git diff) to the matching test target(s)
# and runs ONLY those, via tools/run-tests.sh. Reserve the full sweep for
# pre-merge (`tools/run-tests.sh`).
#
# Usage:
#   tools/test-fast.sh                  # auto: diff vs origin/main, run covering suites
#   tools/test-fast.sh --staged         # auto: only staged changes
#   tools/test-fast.sh CoreModels FeatureAuth   # explicit module or suite names
#   tools/test-fast.sh --base HEAD~3    # diff against a different base
#   PLOZZ_SIM_ID=<udid> tools/test-fast.sh
#
# Notes:
#   * No "move Plozz.xcodeproj aside / regenerate" dance is needed — run-tests.sh
#     runs a per-module scheme on the simulator with the project in place.
#   * Pure-logic suites (CoreModels, providers, networking, metadata) run in
#     ~5-20s each. FeatureHomeTests is QUARANTINED from auto-selection because it
#     currently hangs ~600s on a simulator watchdog (leaked Task.detached work)
#     and has failing assertions on main — run it explicitly once that's fixed.
set -euo pipefail
cd "$(dirname "$0")/.."

# Suites currently too slow/broken for the inner loop. Auto-selection skips them
# (with a warning); pass the name explicitly to force-run.
QUARANTINE=(FeatureHomeTests)

# Foundational modules: a change here can affect many suites. We run a broad set
# of FAST suites (everything except quarantined) rather than the whole sweep.
is_foundational() { case "$1" in CoreModels|CoreUI|CoreNetworking) return 0;; *) return 1;; esac; }

ALL_FAST_SUITES=(
  CoreModelsTests CoreNetworkingTests CoreUITests MetadataKitTests
  FeatureDiscoveryTests ProviderJellyfinTests ProviderPlexTests
  ProviderTrailersTests RatingsServiceTests TraktServiceTests
  FeatureAuthTests FeatureSearchTests FeatureProfilesTests
  FeatureMusicTests FeaturePlaybackTests
)

# Map a Sources/<Module> name to its test target. Modules with no test target
# (FeatureSettings, AppShell, TopShelfKit) map to nothing.
module_to_suite() {
  case "$1" in
    CoreModels)        echo CoreModelsTests;;
    CoreNetworking)    echo CoreNetworkingTests;;
    CoreUI)            echo CoreUITests;;
    MetadataKit)       echo MetadataKitTests;;
    FeatureDiscovery)  echo FeatureDiscoveryTests;;
    ProviderJellyfin)  echo ProviderJellyfinTests;;
    ProviderPlex)      echo ProviderPlexTests;;
    ProviderTrailers)  echo ProviderTrailersTests;;
    RatingsService)    echo RatingsServiceTests;;
    TraktService)      echo TraktServiceTests;;
    FeatureAuth)       echo FeatureAuthTests;;
    FeatureHome)       echo FeatureHomeTests;;
    FeatureSearch)     echo FeatureSearchTests;;
    FeatureProfiles)   echo FeatureProfilesTests;;
    FeatureMusic)      echo FeatureMusicTests;;
    FeaturePlayback)   echo FeaturePlaybackTests;;
    *)                 echo "";;   # FeatureSettings/AppShell/TopShelfKit: no suite
  esac
}

BASE="origin/main"
MODE="diff"
EXPLICIT=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --staged) MODE="staged"; shift;;
    --base) BASE="$2"; shift 2;;
    --base=*) BASE="${1#*=}"; shift;;
    -h|--help) sed -n '2,30p' "$0"; exit 0;;
    *) EXPLICIT+=("$1"); shift;;
  esac
done

suites=()
add_suite() { local s="$1"; [[ -z "$s" ]] && return; for e in "${suites[@]:-}"; do [[ "$e" == "$s" ]] && return; done; suites+=("$s"); }

if [[ ${#EXPLICIT[@]} -gt 0 ]]; then
  # Accept either a module name (CoreModels) or a suite name (CoreModelsTests).
  for a in "${EXPLICIT[@]}"; do
    if [[ "$a" == *Tests ]]; then add_suite "$a"; else add_suite "$(module_to_suite "$a")"; fi
  done
else
  if [[ "$MODE" == "staged" ]]; then
    changed=$(git diff --cached --name-only)
  else
    mergebase=$(git merge-base "$BASE" HEAD 2>/dev/null || echo "$BASE")
    changed=$( { git diff --name-only "$mergebase"...HEAD; git diff --name-only; git diff --cached --name-only; } | sort -u )
  fi
  foundational=0
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if [[ "$f" == Tests/*/* ]]; then
      add_suite "$(echo "$f" | cut -d/ -f2)"
    elif [[ "$f" == Sources/*/* ]]; then
      mod=$(echo "$f" | cut -d/ -f2)
      is_foundational "$mod" && foundational=1
      add_suite "$(module_to_suite "$mod")"
    fi
  done <<< "$changed"
  if [[ $foundational -eq 1 ]]; then
    echo "Foundational module changed -> expanding to all fast suites."
    suites=("${ALL_FAST_SUITES[@]}")
  fi
fi

# Drop quarantined suites unless the user named them explicitly.
if [[ ${#EXPLICIT[@]} -eq 0 ]]; then
  filtered=()
  for s in "${suites[@]:-}"; do
    skip=0; for q in "${QUARANTINE[@]}"; do [[ "$s" == "$q" ]] && skip=1; done
    if [[ $skip -eq 1 ]]; then echo "Skipping quarantined suite: $s (run it explicitly once fixed)"; else filtered+=("$s"); fi
  done
  suites=("${filtered[@]:-}")
fi

if [[ ${#suites[@]} -eq 0 || -z "${suites[0]:-}" ]]; then
  echo "No covering test suite for the changes (docs/config/UI-only module without tests). Nothing to run."
  exit 0
fi

echo "Scoped suites: ${suites[*]}"
exec tools/run-tests.sh "${suites[@]}"
