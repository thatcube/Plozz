#!/usr/bin/env bash
# Regenerate the screenshots embedded in README.md.
#
# The masters come from the capture pipeline in docs/screenshots.md:
#
#   ./tools/capture-shots.sh                 # -> build/shots/
#   cd ../plozz-website && npm run images    # -> screenshots-src/ masters
#
# This script takes a handful of those 4K masters and writes web-sized JPEGs
# into docs/assets/screenshots/, because a 5 MB PNG per shot is not something a
# README should ask a visitor to download.
#
#   tools/readme-shots.sh                    # use the website's masters
#   tools/readme-shots.sh build/shots        # use a fresh local capture
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$REPO_ROOT/docs/assets/screenshots"

# The website checkout is a sibling of the main clone, which is *not* the parent
# of a worktree — so look in a few plausible places before giving up.
find_masters() {
  local candidates=(
    "$REPO_ROOT/../plozz-website/screenshots-src"
    "$REPO_ROOT/../../plozz-website/screenshots-src"
    "$REPO_ROOT/../../../plozz-website/screenshots-src"
    "$HOME/Development/plozz-website/screenshots-src"
    "$REPO_ROOT/build/shots"
  )
  for dir in "${candidates[@]}"; do
    [[ -d "$dir" ]] && printf '%s\n' "$dir" && return 0
  done
  return 1
}

SRC="${1:-$(find_masters || true)}"

# Screens shown in the README. Add or reorder here, then update README.md.
SHOTS=(home show player settings)

WIDTH=1600
QUALITY=78

if [[ -z "$SRC" || ! -d "$SRC" ]]; then
  echo "error: no screenshot masters found (looked next to the repo, in ~/Development/plozz-website, and in build/shots)" >&2
  echo "       pass one explicitly, e.g. tools/readme-shots.sh build/shots" >&2
  exit 1
fi

mkdir -p "$OUT"

for name in "${SHOTS[@]}"; do
  master=""
  for candidate in "$SRC/plozz-tv-$name.png" "$SRC/$name.png" "$SRC/tv-$name.png"; do
    [[ -f "$candidate" ]] && master="$candidate" && break
  done

  if [[ -z "$master" ]]; then
    echo "error: no master found for '$name' in $SRC" >&2
    exit 1
  fi

  sips -Z "$WIDTH" "$master" \
    --out "$OUT/tv-$name.jpg" \
    -s format jpeg \
    -s formatOptions "$QUALITY" >/dev/null

  printf '%-10s %s\n' "$name" "$(du -h "$OUT/tv-$name.jpg" | cut -f1)"
done

echo
echo "Wrote ${#SHOTS[@]} screenshot(s) to docs/assets/screenshots/"
