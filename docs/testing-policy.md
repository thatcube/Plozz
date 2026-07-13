# Plozz testing: data-driven selection & build-once policy

Purpose: run the *right* tests fast during the agentic inner loop, and the full
sweep only when it matters — speed without sacrificing quality. All target/suite
knowledge is **derived at runtime** from `swift package dump-package`; nothing in
the test tooling hardcodes the target list, so new targets (e.g. the WebDAV work's
`MediaTransportWebDAVTests`) are picked up automatically.

## The two speed wins

### 1. Build once, run many (`tools/run-tests.sh`)
The old runner looped `xcodebuild test` **once per test target** — 23 separate
build + simulator-install + launch cycles. Since all tests *execute* in <1s of
CPU, ~all the wall-clock was 23× compile + simulator orchestration. The runner now
does **one** `xcodebuild test` against the always-present `Plozz-Package` scheme:
- **Full sweep:** `xcodebuild test -scheme Plozz-Package` (no `-only-testing`).
- **Subset:** `-scheme Plozz-Package -only-testing:<Suite>` for each selected suite.
- **Single suite with a materialised native `<Suite>` scheme:** used directly (rare
  locally — SPM publishes per-*module* schemes like `CoreModels`, not
  `CoreModelsTests`, and module schemes are not test-configured — so single-suite
  runs normally also go through `Plozz-Package -only-testing`).

`Plozz-Package` is the only test-capable scheme, so build-once relies on the
existing self-heal: a stray generated `Plozz.xcodeproj` shadows the Swift package
and blocks `Plozz-Package`; the runner moves it aside when needed and restores it
on exit.

`-only-testing` filters which suites **run**, not what is **built** — a subset run
still compiles the full test graph once. The win is collapsing 23 build +
orchestration cycles into **one**, not compiling less.

**Flake guard:** if the single run reports specific failed suite bundles, each is
retried **once** in isolation; a suite only fails if it fails twice. A build/compile
failure (no per-suite result) is not retried. This covers the occasional
`ProviderPlexTests` StubHTTPClient timing race.

`PLOZZ_PARALLEL=YES` opts into `-parallel-testing-enabled YES`. It is **off by
default**: tests execute in <1s, so parallelism can't speed execution, and cloning
the tvOS simulator adds boot overhead and can expose the Plex race.

### 2. Change-scoped selection (`tools/test-fast.sh` + `tools/test-impact.py`)
`tools/test-impact.py` builds the package's internal target dependency graph from
`swift package dump-package`, computes for each **test** target the transitive set
of source targets it reaches, and inverts that into `sourceModule → covering test
targets`. `tools/test-fast.sh` maps your `git diff` to a selection and runs only
those suites via `run-tests.sh` (build-once).

Because `CoreModels`, `CoreNetworking`, `MediaTransportCore` etc. are depended on
by many targets, a change to one of them naturally selects everything that depends
on it — **"foundational escalation" falls out of the data with no hardcoded list**.

**Guardrails (never silently skip):** `test-impact.py` forces the **full matrix**
whenever a change could invalidate the map itself or is otherwise unmappable —
`Package.swift`/`Package.resolved`, anything under `tools/` or `.github/`,
`project.yml`/`Config/**`, `*.xctestplan`, or any changed code path it can't map to
a test target. Pure docs/asset changes select nothing. Every run prints the chosen
suites and the reason each was selected.

## SOURCE → TEST map (illustrative — computed live, do not hand-maintain)

Each `Sources/<Module>` is covered by `Tests/<Module>Tests` when that test target
exists. Modules with **no** test target (e.g. `FeatureSettings`, `TopShelfKit`,
`CrashReporting`, the metadata `*Service` shims) map to nothing directly but are
still covered transitively by `AppShellTests` and any feature that depends on them.
Run `tools/test-impact.py --list-tests` for the authoritative current list, or
`tools/test-fast.sh --dry-run <Module>` to see what a change would select.

At time of writing there are 23 test targets: `AppShellTests`, `CoreModelsTests`,
`CoreNetworkingTests`, `CoreUITests`, `EnginePlozzigenTests`, `FeatureAuthTests`,
`FeatureDiscoveryTests`, `FeatureHomeTests`, `FeatureMusicTests`,
`FeaturePlaybackTests`, `FeatureProfilesTests`, `FeatureSearchTests`,
`MediaTransportCoreTests`, `MediaTransportHTTPTests`, `MediaTransportSMBTests`,
`MetadataKitTests`, `ProviderJellyfinTests`, `ProviderPlexTests`,
`ProviderShareTests`, `ProviderTrailersTests`, `RatingsServiceTests`,
`SeerServiceTests`, `TraktServiceTests`.

## Tiered policy — which command when

1. **Inner loop (every change):** `tools/test-fast.sh` — auto-detects changed
   modules and runs only the covering suite(s). Or name them explicitly:
   `tools/test-fast.sh CoreModels FeatureAuth`. Preview with `--dry-run`.
2. **Pre-integration (handing a branch off):** `tools/test-fast.sh` already expands
   foundational changes to the affected set.
3. **Pre-merge / CI gate (before merging to main):** full sweep
   `tools/run-tests.sh` (no args) — build-once, all suites.

### `tools/test-fast.sh` usage
```
tools/test-fast.sh                 # diff vs merge-base with origin/main
tools/test-fast.sh --staged        # only staged changes
tools/test-fast.sh --base HEAD~3   # diff against a specific ref
tools/test-fast.sh CoreModels …    # explicit module or suite names
tools/test-fast.sh --dry-run …     # print the selection, don't run
```

## Notes / gotchas

- **`swift test` does not work on this Mac** — AetherEngine's FFmpeg binary
  xcframeworks are tvOS-only (no macOS slice), so SwiftPM resolution fails. It
  only runs in the Linux CI container. Locally, always use `tools/run-tests.sh` /
  `tools/test-fast.sh` (tvOS Simulator).
- **`export GIT_CONFIG_PARAMETERS="'safe.bareRepository=all'"`** before any
  `swift`/`xcodebuild` invocation (the scripts set it themselves).
- **Data-driven, so it survives target churn.** When the WebDAV branch adds
  `MediaTransportWebDAV(+Tests)`, `run-tests.sh`, `test-fast.sh` and
  `test-impact.py` pick it up with no edits; a change to `MediaTransportCore` then
  automatically includes `MediaTransportWebDAVTests` in its impacted set.

## Known issues to fix (do NOT mask by weakening tests)

- **`FeatureHomeTests`** was previously quarantined (a data race in the shared
  `FakeMediaProvider` test double crashed the xctest host and hung the run). Fixed
  by locking the fake's counters; it now runs by default. No assertions weakened.
- The old "flaky Plex network-probe" tests are deterministic (injected `HTTPClient`
  doubles, fake hosts); only the occasional host-launch timing race remains, which
  the runner's retry-once absorbs.
