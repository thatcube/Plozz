#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d -t plozz-reclaim-tests)"
TEST_HOME="$TMP/home"
DD="$TEST_HOME/Library/Developer/Xcode/DerivedData"
LOCK="$TEST_HOME/Library/Caches/reclaim-test.lock"
LOG="$TMP/reclaim.log"
ACTIVE_PID=""
MAINTENANCE_PID=""
QUIET_TOOLS="$TMP/quiet-tools"

cleanup() {
  if [ -n "$ACTIVE_PID" ] && kill -0 "$ACTIVE_PID" 2>/dev/null; then
    kill "$ACTIVE_PID"
    wait "$ACTIVE_PID" 2>/dev/null || true
  fi
  if [ -n "$MAINTENANCE_PID" ] && kill -0 "$MAINTENANCE_PID" 2>/dev/null; then
    kill "$MAINTENANCE_PID"
    wait "$MAINTENANCE_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_exists() {
  [ -e "$1" ] || fail "expected path to exist: $1"
}

assert_missing() {
  [ ! -e "$1" ] || fail "expected path to be removed: $1"
}

assert_contains() {
  grep -F "$2" "$1" >/dev/null || fail "expected '$2' in $1"
}

run_guarded() {
  env \
    HOME="$TEST_HOME" \
    DERIVED_DATA_DIR="${RUN_DD:-$DD}" \
    RECLAIM_LOCK_FILE="$LOCK" \
    APPLE_BUILD_QUIET_SECONDS="${QUIET_SECONDS:-1}" \
    APPLE_BUILD_MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-3}" \
    APPLE_BUILD_POLL_SECONDS=1 \
    APPLE_BUILD_OPEN_PATH_CHECK="${OPEN_PATH_CHECK:-0}" \
    PATH="${TEST_PATH:-$PATH}" \
    ACTIVE_MIN=0 \
    RECLAIM_BUILD_ROOTS="${RECLAIM_BUILD_ROOTS:-}" \
    RECLAIM_MAIN_REPOS="${RECLAIM_MAIN_REPOS:-}" \
    MCP_WORKSPACES_DIR="${MCP_WORKSPACES_DIR:-}" \
    RECLAIM_LOG="${RECLAIM_LOG:-}" \
    OPEN_TARGET="${OPEN_TARGET:-}" \
    "$@"
}

start_fake_tool() {
  local name="$1" path
  if [ "$name" = "clang" ] || [ "$name" = "actool" ] || [ "$name" = "ibtool" ]; then
    path="$TMP/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/$name"
  else
    path="$TMP/bin/$name"
  fi
  mkdir -p "$(dirname "$path")"
  ln -sf /bin/sleep "$path"
  if [ "$name" = "SWBBuildService" ] || [ "$name" = "XCBBuildService" ]; then
    ACTIVE_PID="$(/bin/sh -c '"$1" 30 >/dev/null 2>&1 & echo $!' _ "$path")"
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      [ "$(ps -o ppid= -p "$ACTIVE_PID" 2>/dev/null | tr -d ' ')" = "1" ] && break
      sleep 0.1
    done
  else
    "$path" 30 &
    ACTIVE_PID=$!
  fi
  sleep 0.1
}

stop_fake_tool() {
  kill "$ACTIVE_PID"
  wait "$ACTIVE_PID" 2>/dev/null || true
  ACTIVE_PID=""
}

mkdir -p "$DD"
mkdir -p "$QUIET_TOOLS"
printf '%s\n' \
  '#!/bin/sh' \
  'if [ "$*" = "-ww -axo pid=,ppid=,args=" ]; then exit 0; fi' \
  'exec /bin/ps "$@"' > "$QUIET_TOOLS/ps"
chmod +x "$QUIET_TOOLS/ps"
QUIET_PATH="$QUIET_TOOLS:$PATH"

for tool in xcodebuild SWBBuildService XCBBuildService swiftc swift-frontend clang actool ibtool; do
  start_fake_tool "$tool"
  activity="$(
    HOME="$TEST_HOME" RECLAIM_LOCK_FILE="$LOCK" \
      bash -c 'source "$1"; apple_build_activity' _ "$ROOT/tools/lib/apple-build-guard.sh"
  )"
  printf '%s\n' "$activity" | grep -F "pid=$ACTIVE_PID " >/dev/null ||
    fail "detector missed fake $tool process"
  stop_fake_tool
done

idle_service="$TMP/bin/SWBBuildService"
"$idle_service" 30 &
ACTIVE_PID=$!
sleep 0.1
activity="$(
  HOME="$TEST_HOME" RECLAIM_LOCK_FILE="$LOCK" \
    bash -c 'source "$1"; apple_build_activity' _ "$ROOT/tools/lib/apple-build-guard.sh"
)"
if printf '%s\n' "$activity" | grep -F "pid=$ACTIVE_PID " >/dev/null; then
  fail "detector treated a non-orphaned idle build service as active"
fi
stop_fake_tool

inspection_failure="$(
  PATH=/nonexistent /bin/bash -c 'source "$1"; apple_build_activity' _ "$ROOT/tools/lib/apple-build-guard.sh"
)"
printf '%s\n' "$inspection_failure" | grep -F "process inspection failed" >/dev/null ||
  fail "process inspection failure did not fail closed"

mkdir -p "$DD/PruneCandidate"
touch -t 202001010000 "$DD/PruneCandidate"
start_fake_tool xcodebuild
set +e
MAX_WAIT_SECONDS=0 run_guarded "$ROOT/tools/prune-deriveddata.sh" --all >"$TMP/prune-active.log" 2>&1
prune_status=$?
set -e
[ "$prune_status" -eq 75 ] || fail "prune active-build status was $prune_status, expected 75"
assert_exists "$DD/PruneCandidate"
assert_contains "$TMP/prune-active.log" "Apple build activity detected"

BUILD_ROOT="$TMP/worktrees"
mkdir -p "$BUILD_ROOT/idle/.build"
touch -t 202001010000 "$BUILD_ROOT/idle/.build"
set +e
RECLAIM_BUILD_ROOTS="$BUILD_ROOT" \
RECLAIM_MAIN_REPOS="$TMP/no-main" \
MCP_WORKSPACES_DIR="$TMP/no-mcp" \
RECLAIM_LOG="$LOG" \
MAX_WAIT_SECONDS=0 \
  run_guarded "$ROOT/tools/reclaim-disk.sh" --days 0 --no-extras >"$TMP/reclaim-active.log" 2>&1
reclaim_status=$?
set -e
[ "$reclaim_status" -eq 75 ] || fail "reclaim active-build status was $reclaim_status, expected 75"
assert_exists "$BUILD_ROOT/idle/.build"
assert_contains "$TMP/reclaim-active.log" "Apple build activity detected"
stop_fake_tool

LOCK_DD="$TMP/lock-dd"
mkdir -p "$LOCK_DD"
QUIET_SECONDS=2 MAX_WAIT_SECONDS=3 RUN_DD="$LOCK_DD" TEST_PATH="$QUIET_PATH" \
  run_guarded "$ROOT/tools/prune-deriveddata.sh" --all >"$TMP/lock-first.log" 2>&1 &
first_pid=$!
MAINTENANCE_PID="$first_pid"
lock_held=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  if [ -f "$LOCK" ] && ! /usr/bin/lockf -s -t 0 "$LOCK" /usr/bin/true; then
    lock_held=1
    break
  fi
  sleep 0.1
done
[ "$lock_held" -eq 1 ] || fail "first maintenance process did not acquire lock"
set +e
RUN_DD="$LOCK_DD" TEST_PATH="$QUIET_PATH" \
  run_guarded "$ROOT/tools/prune-deriveddata.sh" --all >"$TMP/lock-second.log" 2>&1
overlap_status=$?
set -e
[ "$overlap_status" -eq 75 ] || fail "overlap status was $overlap_status, expected 75"
assert_contains "$TMP/lock-second.log" "refusing overlap"
wait "$first_pid"
MAINTENANCE_PID=""

printf 'stale owner metadata\n' > "$LOCK"
mkdir -p "$DD/StaleLockCandidate"
touch -t 202001010000 "$DD/StaleLockCandidate"
TEST_PATH="$QUIET_PATH" run_guarded "$ROOT/tools/prune-deriveddata.sh" --all >"$TMP/stale-lock.log" 2>&1
assert_missing "$DD/StaleLockCandidate"

mkdir -p "$DD/OpenPathCandidate"
FAKE_LSOF="$TMP/fake-lsof"
mkdir -p "$FAKE_LSOF"
printf '%s\n' '#!/bin/sh' 'printf "p12345\nn%s/held\n" "$OPEN_TARGET"' > "$FAKE_LSOF/lsof"
chmod +x "$FAKE_LSOF/lsof"
OPEN_TARGET_PHYSICAL="$(cd "$DD/OpenPathCandidate" && pwd -P)"
set +e
OPEN_PATH_CHECK=1 TEST_PATH="$FAKE_LSOF:$QUIET_PATH" OPEN_TARGET="$OPEN_TARGET_PHYSICAL" \
  run_guarded "$ROOT/tools/prune-deriveddata.sh" --all >"$TMP/open-path.log" 2>&1
open_path_status=$?
set -e
[ "$open_path_status" -eq 75 ] || {
  sed -n '1,80p' "$TMP/open-path.log" >&2
  fail "open-path status was $open_path_status, expected 75"
}
assert_exists "$DD/OpenPathCandidate"
assert_contains "$TMP/open-path.log" "Open files detected"
TEST_PATH="$QUIET_PATH" run_guarded "$ROOT/tools/prune-deriveddata.sh" --all >"$TMP/open-path-clear.log" 2>&1
assert_missing "$DD/OpenPathCandidate"

RECLAIM_BUILD_ROOTS="$BUILD_ROOT" \
RECLAIM_MAIN_REPOS="$TMP/no-main" \
MCP_WORKSPACES_DIR="$TMP/no-mcp" \
RECLAIM_LOG="$LOG" \
TEST_PATH="$QUIET_PATH" \
  run_guarded "$ROOT/tools/reclaim-disk.sh" --days 0 --no-extras >"$TMP/reclaim-clear.log" 2>&1
assert_missing "$BUILD_ROOT/idle/.build"

mkdir -p "$TEST_HOME/Library/Caches/org.swift.swiftpm/repository"
set +e
HOME="$TEST_HOME" APPLE_BUILD_OPEN_PATH_CHECK=0 \
  bash -c 'source "$1"; guard_cache_path_for_delete "$HOME/Library/Caches/org.swift.swiftpm/repository"' \
  _ "$ROOT/tools/lib/apple-build-guard.sh" >"$TMP/swiftpm.log" 2>&1
swiftpm_status=$?
set -e
[ "$swiftpm_status" -ne 0 ] || fail "shared SwiftPM cache guard unexpectedly allowed deletion"
assert_contains "$TMP/swiftpm.log" "Refusing unsafe cache deletion target"

for unsafe in / "$TEST_HOME" relative-cache; do
  set +e
  HOME="$TEST_HOME" APPLE_BUILD_OPEN_PATH_CHECK=0 \
    bash -c 'source "$1"; guard_cache_path_for_delete "$2"' \
    _ "$ROOT/tools/lib/apple-build-guard.sh" "$unsafe" >"$TMP/unsafe.log" 2>&1
  unsafe_status=$?
  set -e
  [ "$unsafe_status" -ne 0 ] || fail "unsafe target was allowed: $unsafe"
done

set +e
HOME="$TEST_HOME" bash -c 'source "$1"; validate_cache_container /' \
  _ "$ROOT/tools/lib/apple-build-guard.sh" >"$TMP/unsafe-container.log" 2>&1
container_status=$?
set -e
[ "$container_status" -ne 0 ] || fail "unsafe cache container was allowed"

echo "disk reclaim guard tests passed"
