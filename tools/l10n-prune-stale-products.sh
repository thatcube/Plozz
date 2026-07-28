#!/usr/bin/env bash
#
# Remove localization folders left behind by an older incremental build.
#
# Xcode copies newly-added .lproj folders but does not prune a language removed
# from a String Catalog. The old folder stays inside Plozz.app, so the OS and App
# Store still see and select that language even though source validation says it
# is gone. Run this immediately BEFORE `xcodebuild build`; the normal signing
# phase then signs the corrected bundle.
#
# Usage:
#   tools/l10n-prune-stale-products.sh /path/to/Plozz.app
#
set -euo pipefail

cd "$(dirname "$0")/.."
APP_PATH="${1:-}"
[[ -n "$APP_PATH" ]] || { echo "usage: $0 /path/to/Plozz.app" >&2; exit 2; }
[[ -d "$APP_PATH" ]] || exit 0

LANGUAGES="$(
  python3 - <<'PY'
import json

catalog = json.load(open("App/Resources/Localizable.xcstrings", encoding="utf-8"))
languages = {"en"}
for entry in catalog.get("strings", {}).values():
    languages.update(entry.get("localizations", {}))
languages.discard("Base")
print("\n".join(sorted(languages)))
PY
)"

removed=0
for directory in "$APP_PATH"/*.lproj; do
  [[ -d "$directory" ]] || continue
  tag="$(basename "$directory" .lproj)"
  if ! printf '%s\n' "$LANGUAGES" | grep -Fxq "$tag"; then
    rm -r -- "$directory"
    echo "▸ Removed stale built localization: $tag"
    removed=$((removed + 1))
  fi
done

if [[ "$removed" -gt 0 ]]; then
  echo "✓ Pruned $removed stale localization folder(s) before signing."
fi
