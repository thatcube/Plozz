#!/usr/bin/env bash
#
# Analyze what changed since the last TestFlight release, so an agent (or human)
# can draft the TestFlight "What to Test" notes for the build about to ship.
#
# It answers: "last build vs. current — what's new?" by
#   1. asking App Store Connect for the newest TestFlight build + its upload date
#      (using the same .p8 creds fastlane uses), then
#   2. finding the commit on the release branch that was current at that time
#      (build numbers don't map to commits, so the upload DATE is the bridge), and
#   3. printing the NET changed files + diffstat between that baseline and target,
#      with commit history available only as secondary context.
#
# The `fastlane beta` lane needs a WHAT_TO_TEST.txt (or PLOZZ_WHATS_NEW). The
# normal flow is: run this, inspect the net diff, write a short tester-facing summary
# to WHAT_TO_TEST.txt, then `fastlane beta --env fastlane`. See the "How to deploy
# to TestFlight" section in AGENTS.local.md.
#
# Usage:
#   tools/release-changeset.sh                 # baseline = last TestFlight build
#   tools/release-changeset.sh --base <ref>    # baseline = an explicit git ref
#   tools/release-changeset.sh --target <ref>  # target (default: origin/main)
#   tools/release-changeset.sh --full          # also print historical commit context
#
# Reads .env.fastlane (ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH) if present.
# Falls back to the latest git tag, else the target's last 40 commits, when App
# Store Connect can't be reached or no creds are available.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

TARGET="origin/main"
BASE_OVERRIDE=""
SHOW_FULL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --base)   BASE_OVERRIDE="${2:?--base needs a ref}"; shift 2 ;;
    --target) TARGET="${2:?--target needs a ref}"; shift 2 ;;
    --full)   SHOW_FULL=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Best-effort refresh of the target so "current" is accurate.
git fetch -q origin main 2>/dev/null || true

# Resolve target to a concrete sha.
if ! TARGET_SHA="$(git rev-parse --verify --quiet "$TARGET^{commit}")"; then
  TARGET="HEAD"; TARGET_SHA="$(git rev-parse HEAD)"
fi

BUILD_INFO=""   # human-readable "build N — version — date" if we learned it
BASE_SHA=""

resolve_from_appstore() {
  # Load fastlane creds if present.
  if [ -f "$REPO_ROOT/.env.fastlane" ]; then
    set -a; # shellcheck disable=SC1091
    . "$REPO_ROOT/.env.fastlane"; set +a
  fi
  [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ] && [ -n "${ASC_KEY_PATH:-}" ] || return 1
  command -v python3 >/dev/null 2>&1 || return 1

  # Prints two lines on success:  <iso8601-uploadedDate>\n<human build info>
  python3 - "$ASC_KEY_ID" "$ASC_ISSUER_ID" "$ASC_KEY_PATH" <<'PY' 2>/dev/null || return 1
import sys, time, json, urllib.request, urllib.error
try:
    import jwt
except Exception:
    sys.exit(1)
KEY_ID, ISSUER, KEY_PATH = sys.argv[1], sys.argv[2], sys.argv[3]
BUNDLE = "com.thatcube.Plozz"
try:
    priv = open(KEY_PATH).read()
except Exception:
    sys.exit(1)
now = int(time.time())
tok = jwt.encode({"iss": ISSUER, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"},
                 priv, algorithm="ES256", headers={"kid": KEY_ID, "typ": "JWT"})
H = {"Authorization": f"Bearer {tok}"}
def get(u):
    return json.load(urllib.request.urlopen(urllib.request.Request(u, headers=H)))
try:
    apps = get("https://api.appstoreconnect.apple.com/v1/apps?filter[bundleId]=" + BUNDLE)
    if not apps.get("data"):
        sys.exit(1)
    appid = apps["data"][0]["id"]
    q = (f"https://api.appstoreconnect.apple.com/v1/builds?filter[app]={appid}"
         "&sort=-uploadedDate&limit=1&include=preReleaseVersion"
         "&fields[builds]=version,uploadedDate&fields[preReleaseVersions]=version")
    b = get(q)
    if not b.get("data"):
        sys.exit(1)
    d = b["data"][0]["attributes"]
    inc = {i["id"]: i for i in b.get("included", [])}
    pr = b["data"][0].get("relationships", {}).get("preReleaseVersion", {}).get("data")
    mv = inc.get(pr["id"], {}).get("attributes", {}).get("version") if pr else "?"
    print(d["uploadedDate"])
    print(f"build {d.get('version','?')} (v{mv}), uploaded {d['uploadedDate']}")
except Exception:
    sys.exit(1)
PY
}

if [ -n "$BASE_OVERRIDE" ]; then
  BASE_SHA="$(git rev-parse --verify "$BASE_OVERRIDE^{commit}")"
  BUILD_INFO="explicit --base $BASE_OVERRIDE"
else
  if ASC_OUT="$(resolve_from_appstore)"; then
    UPLOADED="$(printf '%s\n' "$ASC_OUT" | sed -n '1p')"
    BUILD_INFO="$(printf '%s\n' "$ASC_OUT" | sed -n '2p')"
    # Last commit on the target at/before the build's upload time is the shipped one.
    BASE_SHA="$(git log "$TARGET_SHA" --before="$UPLOADED" -1 --pretty='%H' 2>/dev/null || true)"
  fi
  # Fallbacks when App Store Connect is unavailable.
  if [ -z "$BASE_SHA" ]; then
    if TAG="$(git describe --tags --abbrev=0 "$TARGET_SHA" 2>/dev/null)"; then
      BASE_SHA="$(git rev-parse "$TAG^{commit}")"; BUILD_INFO="latest git tag $TAG (App Store Connect unavailable)"
    else
      BASE_SHA="$(git rev-parse "$TARGET_SHA~40" 2>/dev/null || git rev-list --max-parents=0 "$TARGET_SHA" | head -1)"
      BUILD_INFO="last 40 commits (no App Store Connect creds and no tags)"
    fi
  fi
fi

RANGE="$BASE_SHA..$TARGET_SHA"
COMMITS="$(git rev-list --count --no-merges "$RANGE")"

hr() { printf '%s\n' "────────────────────────────────────────────────────────"; }

hr
echo "Plozz — changes since the last TestFlight release"
hr
echo "Baseline : $(git rev-parse --short "$BASE_SHA")  ($BUILD_INFO)"
echo "Target   : $(git rev-parse --short "$TARGET_SHA")  ($TARGET)"
echo "Commits  : $COMMITS non-merge commit(s)"
echo "Files    : $(git diff --shortstat "$RANGE" | sed 's/^ *//')"
echo

if [ "$COMMITS" -eq 0 ]; then
  echo "No new commits since the last release — nothing to test."
  exit 0
fi

# Commit subjects are historical context only. A range can contain experiments,
# reversions, and work later replaced wholesale, so subjects must never be copied
# directly into release notes or treated as proof that behavior ships.
INTERNAL_RE='^(test|tests|ci|chore|docs|build|refactor|style)(\(|:)|flaky|quarantin|run-tests|test-fast|deriveddata|gitignore|README|CONTRIBUTING|issue template|code review|address .*review|pre-merge review|-agent review|AGENTS'

echo "NET USER-FACING FILES CHANGED (source of truth for what ships):"
git diff --name-status "$RANGE" -- 'Sources/*' 'App/*' \
  | grep -vE $'\t(.*Tests/|.*README\\.md$)' \
  | sed 's/^/  /' || echo "  (none)"
echo

echo "TOP CHANGED AREAS (Sources/ modules + App, by churn):"
git diff --numstat "$RANGE" -- 'Sources/*' 'App/*' \
  | awk '{a=$1+$2; split($3,p,"/"); mod=p[1]"/"p[2]; sum[mod]+=a}
         END{for(m in sum) printf "%8d  %s\n", sum[m], m}' \
  | sort -rn | head -12 | sed 's/^/  /'
echo

if [ "$SHOW_FULL" -eq 1 ]; then
  echo "HISTORICAL COMMIT CONTEXT (never use as release-note source):"
  echo "The entries below may describe reverted or superseded behavior."
  git log "$RANGE" --no-merges --pretty='%s' \
    | grep -viE "$INTERNAL_RE" \
    | sed 's/^/  • /' || echo "  (none — everything was internal)"
  echo
  echo "FULL HISTORICAL LOG (all $COMMITS commits, newest first):"
  git log "$RANGE" --no-merges --date=short --pretty='  %ad %s'
  echo
fi

hr
echo "Next: draft a short, plain-text, tester-facing 'What to Test' from the"
echo "NET DIFF above — never from commit subjects alone, because history may include"
echo "reverted or superseded work. Verify every claimed behavior exists in the target"
echo "tree. Group by feature, use no markdown bullets, and omit internal churn. Write"
echo "it to WHAT_TO_TEST.txt at the repo root, then run:"
echo "    fastlane beta --env fastlane"
hr
