#!/usr/bin/env bash
#
# l10n-guard.sh — compile-and-run wrapper for tools/l10n-guard.swift.
#
# The guard is written in Swift rather than Python because it needs a real Swift
# parser: the regressions worth catching (copy typed as `String`, eager
# localization, concatenated copy) are structural, and a regex sees none of them.
#
# SwiftSyntax ships INSIDE the toolchain (usr/lib/swift/host), so this needs no
# package dependency — which matters here, because `swift test` is unusable in
# this repo and a new dependency would have to be carried by every target.
#
# The toolchain path is resolved via `xcrun`, never hardcoded: this machine runs
# Xcode-beta while CI pins Xcode_26.2, and a hardcoded path would work in exactly
# one of those.
#
# The compiled binary is cached in .build/ and rebuilt only when the source or
# the toolchain changes, so repeat runs cost ~0.2s instead of ~10s.
#
# Usage:
#   tools/l10n-guard.sh                    # scan Sources/, exit 1 on any finding
#   tools/l10n-guard.sh --force            # rebuild the guard binary first
#
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

SOURCE="tools/l10n-guard.swift"
CACHE_DIR=".build/l10n-guard"
BINARY="$CACHE_DIR/l10n-guard"
STAMP="$CACHE_DIR/.stamp"

# --force is consumed here (it controls compilation); everything else is passed
# through to the guard binary.
FORCE=0
GUARD_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    *) GUARD_ARGS+=("$arg") ;;
  esac
done

HOST_LIBS="$(dirname "$(xcrun --find swift)")/../lib/swift/host"
if [[ ! -d "$HOST_LIBS" ]]; then
  echo "✗ SwiftSyntax host libraries not found at: $HOST_LIBS" >&2
  echo "  Check your Xcode selection (xcode-select -p)." >&2
  exit 2
fi

# Rebuild when the source changes OR the toolchain moves — a binary linked
# against another Xcode's SwiftSyntax will fail to load at runtime.
FINGERPRINT="$(shasum "$SOURCE" | awk '{print $1}')-$(cd "$HOST_LIBS" && pwd -P)"
if [[ "$FORCE" == "1" || ! -x "$BINARY" || "$(cat "$STAMP" 2>/dev/null || true)" != "$FINGERPRINT" ]]; then
  mkdir -p "$CACHE_DIR"
  echo "▸ Building l10n-guard…"
  swiftc -O -swift-version 5 \
    -I "$HOST_LIBS" -L "$HOST_LIBS" \
    -lSwiftSyntax -lSwiftParser \
    -Xlinker -rpath -Xlinker "$HOST_LIBS" \
    "$SOURCE" -o "$BINARY"
  printf '%s' "$FINGERPRINT" > "$STAMP"
fi

exec "$BINARY" --repo-root "$ROOT" ${GUARD_ARGS[@]+"${GUARD_ARGS[@]}"}
