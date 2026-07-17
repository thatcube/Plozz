#!/usr/bin/env bash
# test-fast.sh — change-scoped inner-loop test runner for Plozz.
#
# WHY: the full suite (`tools/run-tests.sh` with no args) is bounded by compile +
# tvOS-simulator orchestration, NOT test execution (all tests run in <1s of CPU).
# Running the whole matrix on every change is pointless when you only touched one
# module. This maps the files you changed (git diff) to the covering test
# target(s) and runs ONLY those (via tools/run-tests.sh, which builds once).
#
# DATA-DRIVEN: the change→suite mapping is computed at runtime by
# tools/test-impact.py from `swift package dump-package` — nothing is hardcoded,
# so new targets (e.g. the WebDAV work's MediaTransportWebDAVTests) are picked up
# automatically. Selection escalates to the FULL matrix on foundational/graph
# changes and never silently skips (see tools/test-impact.py).
#
# Usage:
#   tools/test-fast.sh                  # auto: diff vs origin/main, run covering suites
#   tools/test-fast.sh --staged         # auto: only staged changes
#   tools/test-fast.sh --base HEAD~3    # diff against a different base
#   tools/test-fast.sh CoreModels FeatureAuth   # explicit module or suite names
#   PLOZZ_SIM_ID=<udid> tools/test-fast.sh
#
# Modes at a glance:
#   * Impacted (this script)      — while developing: fast, only what you touched.
#   * Full matrix                 — before merging to main / CI gate:
#                                   `tools/run-tests.sh` (no args).
set -euo pipefail
cd "$(dirname "$0")/.."

export GIT_CONFIG_PARAMETERS="${GIT_CONFIG_PARAMETERS-'safe.bareRepository=all'}"

# Architecture layering guard — always gate the inner loop (even on docs-only /
# --dry-run selections), then tell the delegated run-tests.sh to skip its own
# copy so the guard runs exactly once per invocation. See tools/arch-guard.py.
if [[ "${PLOZZ_SKIP_ARCH_GUARD:-0}" != "1" ]]; then
  python3 "$(dirname "$0")/arch-guard.py" || {
    echo "test-fast: architecture layering guard FAILED — fix the module graph first."
    exit 1
  }
  export PLOZZ_SKIP_ARCH_GUARD=1
fi

IMPACT="tools/test-impact.py"

# --- Parse args ---------------------------------------------------------------
# Split into: explicit module/suite names, flags forwarded to test-impact.py
# (--staged / --base REF), and a local --dry-run (print selection, don't run).
EXPLICIT=()
IMPACT_ARGS=()
DRYRUN=0
if [[ $# -gt 0 ]]; then
  skip_next=0
  for a in "$@"; do
    if [[ $skip_next -eq 1 ]]; then skip_next=0; IMPACT_ARGS+=("$a"); continue; fi
    case "$a" in
      --dry-run|-n) DRYRUN=1;;
      --base) skip_next=1; IMPACT_ARGS+=("$a");;   # flag + its value
      --base=*|--staged) IMPACT_ARGS+=("$a");;
      -h|--help) sed -n '2,40p' "$0"; exit 0;;
      -*) IMPACT_ARGS+=("$a");;
      *) EXPLICIT+=("$a");;
    esac
  done
fi

run_or_print() {  # run_or_print <suite>...
  echo "Scoped suites: $*"
  if [[ $DRYRUN -eq 1 ]]; then
    echo "(--dry-run: not executing)"
    exit 0
  fi
  exec tools/run-tests.sh "$@"
}

# --- Explicit module/suite names: resolve (data-driven) and run --------------
if [[ ${#EXPLICIT[@]} -gt 0 ]]; then
  suites=()
  while IFS= read -r s; do
    [[ -n "$s" ]] && suites+=("$s")
  done < <(python3 "$IMPACT" --resolve "${EXPLICIT[@]}" || true)
  if [[ ${#suites[@]} -eq 0 ]]; then
    echo "test-fast: none of (${EXPLICIT[*]}) map to a test target — nothing to run."
    exit 0
  fi
  run_or_print "${suites[@]}"
fi

# --- Auto: compute the selection from the diff -------------------------------
# test-impact.py prints its reasoning to stderr (shown to the user) and a machine
# directive to stdout: ALL | (SELECT + suite list) | NONE.
if [[ ${#IMPACT_ARGS[@]} -gt 0 ]]; then
  OUT="$(python3 "$IMPACT" "${IMPACT_ARGS[@]}")"
else
  OUT="$(python3 "$IMPACT")"
fi
DIRECTIVE="$(printf '%s\n' "$OUT" | head -1)"

case "$DIRECTIVE" in
  ALL)
    echo "Impacted set is broad/foundational — running the FULL matrix."
    if [[ $DRYRUN -eq 1 ]]; then echo "(--dry-run: not executing)"; exit 0; fi
    exec tools/run-tests.sh
    ;;
  NONE)
    echo "No covering test suite for the changes (docs/assets-only). Nothing to run."
    exit 0
    ;;
  SELECT)
    suites=()
    while IFS= read -r s; do
      [[ -n "$s" ]] && suites+=("$s")
    done < <(printf '%s\n' "$OUT" | tail -n +2)
    if [[ ${#suites[@]} -eq 0 ]]; then
      echo "No covering test suite for the changes. Nothing to run."
      exit 0
    fi
    run_or_print "${suites[@]}"
    ;;
  *)
    echo "test-fast: unexpected selector output — falling back to the full matrix."
    if [[ $DRYRUN -eq 1 ]]; then echo "(--dry-run: not executing)"; exit 0; fi
    exec tools/run-tests.sh
    ;;
esac
