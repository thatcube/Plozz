# Disk reclaim safety

`tools/reclaim-disk.sh` removes rebuildable Apple build caches across Plozz,
Mozz, and Twozz. `tools/prune-deriveddata.sh` is its DerivedData-only worker.
Neither script deletes source, worktrees, commits, uncommitted edits, archives,
simulator runtimes, or the shared SwiftPM repository cache at
`~/Library/Caches/org.swift.swiftpm`.

## Apply-run guards

Destructive runs use one shared lock at
`~/Library/Caches/com.thatcube.reclaim-disk.lock`. The lock prevents app
workflow, optional launchd, and manual runs from overlapping. macOS `lockf`
holds a kernel lock on an inherited file descriptor, so crashes release it
automatically and a leftover lock file carries no stale ownership. Live locks
fail closed. The orchestrator passes its locked descriptor to the DerivedData
worker rather than acquiring a second lock.

Before the first deletion, the scripts require a continuous interval with no
Apple build activity. Defaults:

- `APPLE_BUILD_QUIET_SECONDS=120`
- `APPLE_BUILD_MAX_WAIT_SECONDS=900`
- `APPLE_BUILD_POLL_SECONDS=1`

The quiet interval must be at least one second. Setting the maximum wait to zero
is fail-immediate: the run cannot satisfy a new quiet interval and performs no
destructive work.

Detection covers `xcodebuild`, `SWBBuildService`, `XCBBuildService`, `swiftc`,
`swift-frontend`, and Xcode/CommandLineTools `clang`, `actool`, and `ibtool`
processes. Xcode keeps idle build services resident, so a service alone only
counts when attached to `xcodebuild` or orphaned to PID 1. Compilers are matched
independently, so a blocked or orphaned compiler still blocks cleanup.

Process activity is checked again before every destructive phase and immediately
before every cache deletion. Individual cache roots also receive a best-effort
`lsof` open-path snapshot when macOS exposes those handles. A new build
process, reported open file, unavailable safety tool, or explicit open-path
inspection error aborts the remaining destructive work. Directory mtime remains
a secondary skip signal; it is not evidence that a build is idle.

`--dry-run` does not wait, lock, or delete. It only reports candidates.

## Regression test

Run `tools/tests/test-disk-reclaim.sh`. It uses temporary HOME/cache roots and
fake sleeping Apple build executables to cover required process names, active
build refusal in both scripts, lock overlap, stale lock-file recovery, open-path
abort, unsafe-root refusal, and successful cleanup after a quiet interval.

## Scheduling

Use one scheduler: either the app workflow **Daily disk-cache reclaim + report**
or the optional `tools/install-reclaim-agent.sh` LaunchAgent. Both execute the
same guarded `tools/reclaim-disk.sh`; enabling both adds no safety and creates
duplicate reports/work.

## Remaining boundary

No process-sampling guard can make the final check and `rm` one atomic operation.
A build started in the narrow gap after the last process/open-path check can
still race deletion. Eliminating that gap requires every Apple build entry point
to acquire the same maintenance lock before starting.
