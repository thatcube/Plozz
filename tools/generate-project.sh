#!/bin/sh
# generate-project.sh — regenerate Plozz.xcodeproj via XcodeGen AND bake an
# auto-incrementing build number into it, so CFBundleVersion lands natively in
# every target's Info.plist at build time. The app and the Top Shelf extension
# share the baked value (lockstep), and because it's a real build setting there's
# no fragile post-build plist editing to race with embedding/codesigning.
#
# ALWAYS generate the project with this script (not a bare `xcodegen generate`)
# so the build number is never missed. The build/deploy flow and fastlane both
# call it.
#
# Build number precedence:
#   1. $PLOZZ_BUILD_NUMBER  — explicit override. The fastlane `build` lane sets
#      this to (latest TestFlight build + 1) so App Store / TestFlight uploads
#      stay strictly increasing per upload even without a new commit.
#   2. git commit count (`git rev-list --count HEAD`) — auto-increments on every
#      commit, so each local/device/simulator build shows a fresh build number in
#      the Settings "About" panel.
# If neither is available, the project.yml default (1) is left in place so the
# build still succeeds.
set -eu

cd "$(dirname "$0")/.."

xcodegen generate

proj="Plozz.xcodeproj/project.pbxproj"

# If PLOZZ_SENTRY_DSN wasn't provided in the environment, read it from the local,
# gitignored .env.fastlane so one file feeds both local device builds and
# `fastlane` (which also exports it). An explicit env override always wins.
if [ -z "${PLOZZ_SENTRY_DSN:-}" ] && [ -f ".env.fastlane" ]; then
  dsn_line=$(grep -E '^[[:space:]]*PLOZZ_SENTRY_DSN=' ".env.fastlane" | tail -n1 || true)
  if [ -n "$dsn_line" ]; then
    PLOZZ_SENTRY_DSN=$(printf '%s' "$dsn_line" \
      | sed -E "s/^[[:space:]]*PLOZZ_SENTRY_DSN=//; s/^\"//; s/\"$//; s/^'//; s/'$//")
    export PLOZZ_SENTRY_DSN
  fi
fi

# --- Opt-in crash-reporting DSN bake -----------------------------------------
# If PLOZZ_SENTRY_DSN is set in the environment, bake it into the generated
# project so CrashReporting can read it from Info.plist at runtime. When unset
# the project.yml default ("") is left in place and the app never sends anything.
# The DSN is a secret-ish URL (contains '/', ':', '@') so we use '|' as the sed
# delimiter and escape the few characters sed treats specially in a replacement.
if [ -n "${PLOZZ_SENTRY_DSN:-}" ]; then
  if [ -f "$proj" ]; then
    esc_dsn=$(printf '%s' "${PLOZZ_SENTRY_DSN}" | sed -e 's/[\\&|]/\\&/g')
    /usr/bin/sed -i '' -E "s|PLOZZ_SENTRY_DSN = [^;]*;|PLOZZ_SENTRY_DSN = \"${esc_dsn}\";|g" "$proj"
    echo "Baked PLOZZ_SENTRY_DSN into ${proj} (crash reporting endpoint configured)"
  else
    echo "warning: $proj not found after xcodegen generate; skipping DSN bake"
  fi
fi

if [ -n "${PLOZZ_BUILD_NUMBER:-}" ]; then
  build="${PLOZZ_BUILD_NUMBER}"
  src="PLOZZ_BUILD_NUMBER override"
elif build="$(git rev-list --count HEAD 2>/dev/null)" && [ -n "$build" ]; then
  src="git commit count"
else
  echo "warning: could not determine a build number (no PLOZZ_BUILD_NUMBER and git unavailable); leaving CFBundleVersion at the project.yml default"
  exit 0
fi

proj="Plozz.xcodeproj/project.pbxproj"
if [ ! -f "$proj" ]; then
  echo "warning: $proj not found after xcodegen generate; skipping build-number bake"
  exit 0
fi

/usr/bin/sed -i '' -E "s/CURRENT_PROJECT_VERSION = [^;]*;/CURRENT_PROJECT_VERSION = ${build};/g" "$proj"
echo "Baked CFBundleVersion (CURRENT_PROJECT_VERSION) = ${build} (from ${src}) into ${proj}"
