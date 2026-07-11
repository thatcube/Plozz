#!/usr/bin/env bash
#
# One-command build / deploy loop for the paired Apple TV.
#
# This is the rapid-iteration entry point for on-device work: it runs the build
# pre-flight (the git-config workaround), does an *incremental* device build, then
# installs and launches on the Apple TV.
#
# Usage:
#   tools/deploy-tv.sh                 # build → install → launch on the Apple TV
#   tools/deploy-tv.sh --build-only    # build ONLY (compile check, no install)
#   tools/deploy-tv.sh --regen         # run `xcodegen generate` first (only when
#                                      #   files were ADDED / REMOVED / RENAMED)
#   tools/deploy-tv.sh --sim-build     # compile for a tvOS Simulator (fast sanity,
#                                      #   no HDR — see AGENTS.local.md)
#   tools/deploy-tv.sh --clean         # wipe THIS worktree's DerivedData first
#   PLOZZ_SHOW_FIRST_RUN_RESET=1 tools/deploy-tv.sh
#                                      # show the Debug first-run reset row
#
# Notes:
#   * Editing an EXISTING file does NOT need --regen; SPM globs the module dirs.
#   * Never `rm -rf` the shared SwiftPM cache — only --clean (per-worktree
#     DerivedData) is safe. See the BUILD PRE-FLIGHT block in AGENTS.local.md.
#   * The Apple TV is a shared, single-install lock across agents. Only the agent
#     whose turn it is should install; everyone else can --build-only freely.
#
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

DEVICE_ID="${PLOZZ_TV_ID:-DE913871-CC2D-5F75-B4F2-0D6F44AA30DE}"
PROJECT="Plozz.xcodeproj"
SCHEME="Plozz"
CONFIG="Debug"

BUILD_ONLY=0
REGEN=0
SIM_BUILD=0
CLEAN=0
for arg in "$@"; do
  case "$arg" in
    --build-only) BUILD_ONLY=1 ;;
    --regen)      REGEN=1 ;;
    --sim-build)  SIM_BUILD=1 ;;
    --clean)      CLEAN=1 ;;
    -h|--help)    grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown flag: $arg (try --help)"; exit 2 ;;
  esac
done

# --- BUILD PRE-FLIGHT (mandatory, see AGENTS.local.md) -----------------------
# The host injects `safe.bareRepository=explicit`; without this export SwiftPM's
# git resolve fails with "cannot use bare repository". This is EXPECTED.
export GIT_CONFIG_PARAMETERS="${GIT_CONFIG_PARAMETERS-'safe.bareRepository=all'}"

if [[ "$CLEAN" == "1" ]]; then
  echo "▸ Cleaning this worktree's DerivedData…"
  DD="$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -showBuildSettings 2>/dev/null \
        | awk -F' = ' '/ BUILD_DIR /{print $2; exit}')"
  [[ -n "${DD:-}" ]] && rm -rf "$(dirname "$(dirname "$DD")")"
fi

if [[ "$REGEN" == "1" ]]; then
  echo "▸ Regenerating Xcode project (files added/removed)…"
  if [[ -x tools/generate-project.sh ]]; then tools/generate-project.sh; else xcodegen generate; fi
fi

# --- Destination -------------------------------------------------------------
if [[ "$SIM_BUILD" == "1" ]]; then
  # Pick a tvOS simulator: explicit env override, else a booted one, else any
  # available one (the device isn't named "Apple TV" on every machine).
  SIM_ID="${PLOZZ_SIM_ID:-}"
  if [[ -z "$SIM_ID" ]]; then
    SIM_ID=$(xcrun simctl list devices tvOS available 2>/dev/null \
      | grep -E "\(Booted\)" | grep -oE "[0-9A-F-]{36}" | head -1)
  fi
  if [[ -z "$SIM_ID" ]]; then
    SIM_ID=$(xcrun simctl list devices tvOS available 2>/dev/null \
      | grep -oE "[0-9A-F-]{36}" | head -1)
  fi
  if [[ -n "$SIM_ID" ]]; then
    DESTINATION="platform=tvOS Simulator,id=$SIM_ID"
  else
    DESTINATION="generic/platform=tvOS Simulator"
  fi
  echo "▸ Building for tvOS Simulator (compile sanity only — no HDR)…"
else
  DESTINATION="platform=tvOS,id=$DEVICE_ID"
  echo "▸ Building for Apple TV ($DEVICE_ID)…"
fi

# --- Build -------------------------------------------------------------------
set -o pipefail
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -destination "$DESTINATION" \
  build \
  | { command -v xcbeautify >/dev/null 2>&1 && xcbeautify || cat; }

echo "✓ Build succeeded."

if [[ "$BUILD_ONLY" == "1" || "$SIM_BUILD" == "1" ]]; then
  echo "▸ --build-only / --sim-build: stopping before install."
  exit 0
fi

# --- Resolve the freshly-built .app (after the build, so the path is current) -
APP_PATH="$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
            -destination "$DESTINATION" -showBuildSettings 2>/dev/null \
            | awk -F' = ' '/ CODESIGNING_FOLDER_PATH /{print $2; exit}')"

if [[ -z "${APP_PATH:-}" || ! -d "$APP_PATH" ]]; then
  echo "✗ Could not locate built .app (CODESIGNING_FOLDER_PATH)." >&2
  exit 1
fi
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Info.plist")"

# --- Work around the Xcode swift-testing overlay duplicate-id install bug -----
# Xcode can embed the swift-testing overlay frameworks in Debug, and two of them
# ship with the SAME CFBundleIdentifier (`_Testing_CoreTransferable` wrongly
# claims CoreGraphics'), so installd rejects the bundle with DuplicateIdentifier.
# If they're present we patch the one bad id and re-seal the app rather than
# delete anything (deleting Testing.framework breaks dependent load chains).
# No-op if absent — the normal case now that nothing force-embeds them.
CT="$APP_PATH/Frameworks/_Testing_CoreTransferable.framework"
if [[ -d "$CT" ]]; then
  CT_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$CT/Info.plist" 2>/dev/null || true)"
  if [[ "$CT_ID" != "com.apple.dt.swift-testing.overlay.CoreTransferable" ]]; then
    echo "▸ Patching swift-testing overlay duplicate bundle id…"
    SIGN_ID="${PLOZZ_SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null \
              | awk '/Apple Development/{print $2; exit}')}"
    if [[ -z "${SIGN_ID:-}" ]]; then
      echo "✗ No codesigning identity found (set PLOZZ_SIGN_ID)." >&2; exit 1
    fi
    /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.apple.dt.swift-testing.overlay.CoreTransferable' "$CT/Info.plist"
    codesign --force --sign "$SIGN_ID" --timestamp=none "$CT" >/dev/null
    # Re-seal the app (its seal covers Frameworks/). Use the build's .xcent —
    # NEVER --deep, which strips entitlements.
    XCENT="$(dirname "$(dirname "$APP_PATH")")/../Intermediates.noindex/${SCHEME}.build/${CONFIG}-appletvos/${SCHEME}.build/${SCHEME}.app.xcent"
    if [[ ! -f "$XCENT" ]]; then
      echo "✗ Entitlements (.xcent) not found at $XCENT — cannot safely re-seal." >&2
      echo "  Re-signing without it would strip entitlements; aborting." >&2
      exit 1
    fi
    codesign --force --sign "$SIGN_ID" --entitlements "$XCENT" \
             --timestamp=none --generate-entitlement-der "$APP_PATH" >/dev/null
  fi
fi

echo "▸ Installing $BUNDLE_ID → Apple TV…"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH"

echo "▸ Launching…"
if [[ "${PLOZZ_SHOW_FIRST_RUN_RESET:-0}" == "1" ]]; then
  export DEVICECTL_CHILD_PLOZZ_SHOW_FIRST_RUN_RESET=1
fi
xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID"

echo "✓ Deployed & launched: $BUNDLE_ID"
