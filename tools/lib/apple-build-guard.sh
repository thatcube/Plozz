#!/usr/bin/env bash
#
# Shared fail-closed guard for destructive Apple build-cache maintenance.
# Callers must acquire the maintenance lock and complete the quiet window before
# deleting, then call guard_cache_path_for_delete immediately before each rm.

APPLE_BUILD_QUIET_SECONDS="${APPLE_BUILD_QUIET_SECONDS:-120}"
APPLE_BUILD_MAX_WAIT_SECONDS="${APPLE_BUILD_MAX_WAIT_SECONDS:-900}"
APPLE_BUILD_POLL_SECONDS="${APPLE_BUILD_POLL_SECONDS:-1}"
APPLE_BUILD_OPEN_PATH_CHECK="${APPLE_BUILD_OPEN_PATH_CHECK:-1}"
RECLAIM_LOCK_FILE="${RECLAIM_LOCK_FILE:-$HOME/Library/Caches/com.thatcube.reclaim-disk.lock}"
BUILD_GUARD_HOME="$(cd "$HOME" 2>/dev/null && pwd -P || printf '%s' "$HOME")"

BUILD_GUARD_OWNS_LOCK=0
BUILD_GUARD_INHERITED_LOCK=0

if ! declare -F build_guard_log >/dev/null 2>&1; then
  build_guard_log() {
    printf '%s\n' "$*"
  }
fi

build_guard_valid_nonnegative_integer() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

build_guard_validate_config() {
  local name value
  for name in APPLE_BUILD_QUIET_SECONDS APPLE_BUILD_MAX_WAIT_SECONDS APPLE_BUILD_POLL_SECONDS; do
    eval "value=\${$name}"
    if ! build_guard_valid_nonnegative_integer "$value"; then
      build_guard_log "$name must be a non-negative integer (got '$value')."
      return 1
    fi
  done
  if [ "$APPLE_BUILD_POLL_SECONDS" -eq 0 ]; then
    build_guard_log "APPLE_BUILD_POLL_SECONDS must be at least 1."
    return 1
  fi
  if [ "$APPLE_BUILD_QUIET_SECONDS" -eq 0 ]; then
    build_guard_log "APPLE_BUILD_QUIET_SECONDS must be at least 1 for destructive maintenance."
    return 1
  fi
}

# Prints every active Apple build process. Matching argv[0] catches script-based
# test doubles as well as full Xcode executable paths. Each process is checked
# independently, so orphaned descendants remain visible after their original
# xcodebuild parent exits.
apple_build_activity() {
  local process_list output
  if ! process_list="$(ps -ww -axo pid=,ppid=,args= 2>/dev/null)"; then
    printf '%s\n' "pid=? ppid=? Apple build process inspection failed"
    return 0
  fi
  if ! output="$(printf '%s\n' "$process_list" | awk '
    function basename(path, count, parts) {
      count = split(path, parts, "/")
      return parts[count]
    }
    function build_tool_name(token, name) {
      name = basename(token)
      if (name ~ /^(xcodebuild|SWBBuildService|XCBBuildService|swiftc|swift-frontend)$/) {
        return name
      }
      if (name ~ /^(clang|actool|ibtool)$/ &&
          (index(token, ".app/Contents/Developer/") ||
           index(token, "/Library/Developer/CommandLineTools/") ||
           index(token, "/Library/Developer/Toolchains/") ||
           token == "/usr/bin/" name)) {
        return name
      }
      return ""
    }
    function parent_is_xcodebuild(parent, idx) {
      for (idx = 1; idx <= process_count; idx++) {
        if (pids[idx] == parent && names[idx] == "xcodebuild") {
          return 1
        }
      }
      return 0
    }
    {
      process_count++
      pids[process_count] = $1
      ppids[process_count] = $2
      $1 = ""
      $2 = ""
      sub(/^[[:space:]]+/, "")
      commands[process_count] = $0
      count = split($0, argv, /[[:space:]]+/)
      if (count >= 1) {
        names[process_count] = build_tool_name(argv[1])
      }
    }
    END {
      for (idx = 1; idx <= process_count; idx++) {
        name = names[idx]
        if (name == "") {
          continue
        }
        if (name == "SWBBuildService" || name == "XCBBuildService") {
          # Xcode keeps idle services resident. A service is build activity when
          # attached to xcodebuild or orphaned to launchd/PID 1. Compiler children
          # are detected independently even if the service itself is GUI-owned.
          if (ppids[idx] != 1 && !parent_is_xcodebuild(ppids[idx])) {
            continue
          }
        }
        printf "pid=%s ppid=%s %s\n", pids[idx], ppids[idx], commands[idx]
      }
    }
  ')"; then
    # Process inspection is safety-critical. Treat an inspection failure as
    # activity so a ps/awk portability or runtime failure cannot fail open.
    printf '%s\n' "pid=? ppid=? Apple build process inspection failed"
    return 0
  fi
  printf '%s\n' "$output"
}

apple_builds_active() {
  [ -n "$(apple_build_activity)" ]
}

build_guard_report_activity() {
  local activity="$1" line shown=0
  while IFS= read -r line; do
    if [ -n "$line" ]; then
      if [ "${#line}" -gt 300 ]; then
        line="${line:0:300}..."
      fi
      build_guard_log "  $line"
    fi
    shown=$((shown + 1))
    [ "$shown" -ge 12 ] && break
  done <<< "$activity"
}

acquire_maintenance_lock() {
  local lock_dir owner_start file_inode fd_inode
  lock_dir="$(dirname "$RECLAIM_LOCK_FILE")"
  mkdir -p "$lock_dir" || {
    build_guard_log "Cannot create maintenance lock directory: $lock_dir"
    return 1
  }

  if [ -n "${RECLAIM_LOCK_OWNER_PID:-}" ] &&
     kill -0 "$RECLAIM_LOCK_OWNER_PID" 2>/dev/null &&
     [ -e /dev/fd/9 ]; then
    owner_start="$(ps -o lstart= -p "$RECLAIM_LOCK_OWNER_PID" 2>/dev/null)"
    file_inode="$(stat -f '%i' "$RECLAIM_LOCK_FILE" 2>/dev/null)"
    fd_inode="$(stat -f '%i' /dev/fd/9 2>/dev/null)"
    if [ -n "${RECLAIM_LOCK_OWNER_START:-}" ] &&
       [ "$owner_start" = "$RECLAIM_LOCK_OWNER_START" ] &&
       [ -n "${RECLAIM_LOCK_INODE:-}" ] &&
       [ "$file_inode" = "$RECLAIM_LOCK_INODE" ] &&
       [ "$fd_inode" = "$RECLAIM_LOCK_INODE" ]; then
      BUILD_GUARD_INHERITED_LOCK=1
      return 0
    fi
  fi

  if ! command -v lockf >/dev/null 2>&1; then
    build_guard_log "Cannot acquire maintenance lock: /usr/bin/lockf is unavailable."
    return 1
  fi
  if ! exec 9>>"$RECLAIM_LOCK_FILE"; then
    build_guard_log "Cannot open maintenance lock: $RECLAIM_LOCK_FILE"
    return 1
  fi
  if ! lockf -s -t 0 9; then
    exec 9>&-
    build_guard_log "Destructive maintenance already running; refusing overlap."
    return 1
  fi

  BUILD_GUARD_OWNS_LOCK=1
  RECLAIM_LOCK_OWNER_PID="$$"
  RECLAIM_LOCK_OWNER_START="$(ps -o lstart= -p $$ 2>/dev/null)"
  RECLAIM_LOCK_INODE="$(stat -f '%i' "$RECLAIM_LOCK_FILE" 2>/dev/null)"
  if [ -z "$RECLAIM_LOCK_OWNER_START" ] || [ -z "$RECLAIM_LOCK_INODE" ]; then
    build_guard_log "Cannot verify maintenance lock ownership; refusing destructive work."
    release_maintenance_lock
    return 1
  fi
  export RECLAIM_LOCK_OWNER_PID RECLAIM_LOCK_OWNER_START RECLAIM_LOCK_INODE RECLAIM_LOCK_FILE
}

release_maintenance_lock() {
  [ "$BUILD_GUARD_OWNS_LOCK" -eq 1 ] || return 0
  exec 9>&-
  BUILD_GUARD_OWNS_LOCK=0
}

wait_for_apple_build_quiet() {
  local started now quiet_started="" activity announced=0
  started="$(date +%s)"

  while :; do
    now="$(date +%s)"
    activity="$(apple_build_activity)"
    if [ -n "$activity" ]; then
      quiet_started=""
      if [ "$APPLE_BUILD_MAX_WAIT_SECONDS" -eq 0 ] ||
         [ $((now - started)) -ge "$APPLE_BUILD_MAX_WAIT_SECONDS" ]; then
        build_guard_log "Apple build activity detected; destructive maintenance aborted."
        build_guard_report_activity "$activity"
        return 1
      fi
      if [ "$announced" -eq 0 ]; then
        build_guard_log "Apple build activity detected; waiting up to ${APPLE_BUILD_MAX_WAIT_SECONDS}s for a ${APPLE_BUILD_QUIET_SECONDS}s quiet window."
        build_guard_report_activity "$activity"
        announced=1
      fi
    else
      [ -n "$quiet_started" ] || quiet_started="$now"
      if [ $((now - quiet_started)) -ge "$APPLE_BUILD_QUIET_SECONDS" ]; then
        build_guard_log "Apple build quiet window satisfied (${APPLE_BUILD_QUIET_SECONDS}s)."
        return 0
      fi
    fi

    if [ $((now - started)) -ge "$APPLE_BUILD_MAX_WAIT_SECONDS" ]; then
      build_guard_log "No ${APPLE_BUILD_QUIET_SECONDS}s Apple build quiet window within ${APPLE_BUILD_MAX_WAIT_SECONDS}s; destructive maintenance aborted."
      return 1
    fi
    sleep "$APPLE_BUILD_POLL_SECONDS"
  done
}

begin_destructive_maintenance() {
  build_guard_validate_config || return 1
  acquire_maintenance_lock || return 1

  if [ "$BUILD_GUARD_INHERITED_LOCK" -eq 1 ] &&
     [ "${APPLE_BUILD_QUIET_OWNER_PID:-}" = "${RECLAIM_LOCK_OWNER_PID:-}" ]; then
    guard_no_apple_build_activity "before nested maintenance" || return 1
    return 0
  fi

  wait_for_apple_build_quiet || return 1
  APPLE_BUILD_QUIET_OWNER_PID="${RECLAIM_LOCK_OWNER_PID:-$$}"
  export APPLE_BUILD_QUIET_OWNER_PID
}

guard_no_apple_build_activity() {
  local context="$1" activity
  activity="$(apple_build_activity)"
  if [ -n "$activity" ]; then
    build_guard_log "Apple build activity appeared $context; aborting remaining destructive maintenance."
    build_guard_report_activity "$activity"
    return 1
  fi
}

cache_path_has_open_files() {
  local path="$1" output matches status
  [ "$APPLE_BUILD_OPEN_PATH_CHECK" -eq 1 ] || return 1
  command -v lsof >/dev/null 2>&1 || {
    build_guard_log "Cannot verify open files under $path: lsof is unavailable."
    return 2
  }

  if output="$(lsof -n -F n 2>&1)"; then
    status=0
  else
    status=$?
  fi
  if ! matches="$(printf '%s\n' "$output" | awk -v root="$path" '
    substr($0, 1, 1) == "n" {
      name = substr($0, 2)
      if (name == root || index(name, root "/") == 1) print
    }
  ')"; then
    build_guard_log "Could not interpret open-file data for $path; aborting remaining destructive maintenance."
    return 2
  fi
  if [ "$status" -eq 0 ] && [ -n "$matches" ]; then
    build_guard_log "Open files detected under $path; aborting remaining destructive maintenance."
    printf '%s\n' "$matches" | sed -n '1,12p' | while IFS= read -r line; do
      build_guard_log "  $line"
    done
    return 0
  fi
  if [ "$status" -gt 1 ] || { [ "$status" -eq 1 ] && [ -n "$output" ]; }; then
    build_guard_log "Could not verify open files under $path; aborting remaining destructive maintenance."
    [ -n "$output" ] && build_guard_log "  $(printf '%s' "$output" | head -n1)"
    return 2
  fi
  return 1
}

validate_cache_container() {
  local path="$1" resolved
  case "$path" in
    /*) ;;
    *)
      build_guard_log "Refusing non-absolute cache container: $path"
      return 1
      ;;
  esac
  if ! resolved="$(cd "$path" 2>/dev/null && pwd -P)"; then
    build_guard_log "Cannot resolve cache container: $path"
    return 1
  fi
  case "$resolved" in
    "/"|"$BUILD_GUARD_HOME"|"$BUILD_GUARD_HOME/Library"|"$BUILD_GUARD_HOME/Library/Caches"|\
    "$BUILD_GUARD_HOME/Library/Developer"|"$BUILD_GUARD_HOME/Library/Developer/Xcode"|\
    "$BUILD_GUARD_HOME/Library/Developer/XcodeBuildMCP"|"$BUILD_GUARD_HOME/Development"|\
    "$BUILD_GUARD_HOME/Library/Caches/org.swift.swiftpm"|"$BUILD_GUARD_HOME/Library/Caches/org.swift.swiftpm/"*)
      build_guard_log "Refusing unsafe cache container: $path"
      return 1
      ;;
  esac
}

guard_cache_path_for_delete() {
  local path="$1" resolved open_status
  case "$path" in
    /*) ;;
    *)
      build_guard_log "Refusing unsafe cache deletion target: $path"
      return 1
      ;;
  esac
  if ! resolved="$(cd "$path" 2>/dev/null && pwd -P)"; then
    build_guard_log "Cannot resolve cache deletion target: $path"
    return 1
  fi
  case "$resolved" in
    "/"|"$BUILD_GUARD_HOME"|"$BUILD_GUARD_HOME/Library"|"$BUILD_GUARD_HOME/Library/Caches"|\
    "$BUILD_GUARD_HOME/Library/Developer"|"$BUILD_GUARD_HOME/Library/Developer/Xcode"|\
    "$BUILD_GUARD_HOME/Library/Developer/Xcode/DerivedData"|\
    "$BUILD_GUARD_HOME/Library/Developer/XcodeBuildMCP"|\
    "$BUILD_GUARD_HOME/Library/Developer/XcodeBuildMCP/workspaces"|\
    "$BUILD_GUARD_HOME/Development"|\
    "$BUILD_GUARD_HOME/Library/Caches/org.swift.swiftpm"|"$BUILD_GUARD_HOME/Library/Caches/org.swift.swiftpm/"*)
      build_guard_log "Refusing unsafe cache deletion target: $path"
      return 1
      ;;
  esac

  guard_no_apple_build_activity "before deleting $path" || return 1
  cache_path_has_open_files "$resolved"
  open_status=$?
  [ "$open_status" -eq 1 ] || return 1
  guard_no_apple_build_activity "after open-file check for $path" || return 1
}
