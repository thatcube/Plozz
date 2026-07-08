# Plozz testing: SOURCE → TEST map & tiered policy

Purpose: run the *right* tests fast during the agentic inner loop, and the full
sweep only when it matters — speed without sacrificing quality.

## Why this exists (measured)

On an Apple TV 4K simulator (tvOS 27.0), warm DerivedData:

| Action | Time | Note |
|---|---|---|
| `tools/generate-project.sh` | ~0.08s | negligible — regenerating is not a cost |
| `swift test` (macOS host) | fails ~10s | AetherEngine's FFmpeg xcframeworks are tvOS-only |
| Full `Plozz-Package` suite (cold) | 653s | full-graph compile |
| Full `Plozz-Package` suite (warm) | 627s | ~11s CPU; rest is sim orchestration |
| `CoreModelsTests` (483 tests) | 5.5s | exec 0.36s |
| `ProviderJellyfinTests` (107) | 5.5s | exec 0.14s |
| `FeatureHomeTests` (234) | ~9s | exec ~2.8s (was 606s / 23 failing before the data-race fix) |
| `run-tests.sh CoreNetworkingTests` | 19.5s | no "xcodeproj aside" dance needed |

All 1068 tests *execute* in under 1 second of CPU. Nearly all wall-clock cost is
compile + tvOS-simulator orchestration. So: run only the suite(s) you need.

## SOURCE → TEST map

Each `Sources/<Module>` is covered by `Tests/<Module>Tests`. Modules with **no**
test target: `FeatureSettings`, `AppShell`, `TopShelfKit`.

| Source module | Test target | Tests | Speed |
|---|---|---|---|
| CoreModels | CoreModelsTests | 483 | ⚡ ~5s |
| CoreNetworking | CoreNetworkingTests | 14 | ⚡ |
| CoreUI | CoreUITests | 18 | ⚡ |
| MetadataKit | MetadataKitTests | 45 | ⚡ |
| FeatureDiscovery | FeatureDiscoveryTests | 19 | ⚡ |
| ProviderJellyfin | ProviderJellyfinTests | 107 | ⚡ ~5s |
| ProviderPlex | ProviderPlexTests | 102 | ⚡ (injected probe doubles; no real network) |
| ProviderTrailers | ProviderTrailersTests | 13 | ⚡ |
| RatingsService | RatingsServiceTests | 11 | ⚡ |
| TraktService | TraktServiceTests | 16 | ⚡ |
| FeatureAuth | FeatureAuthTests | 35 | ⚡ |
| FeatureHome | FeatureHomeTests | 234 | ⚡ ~9s |
| FeatureSearch | FeatureSearchTests | 23 | ⚡ |
| FeatureProfiles | FeatureProfilesTests | 4 | ⚡ |
| FeatureMusic | FeatureMusicTests | 7 | ⚡ |
| FeaturePlayback | FeaturePlaybackTests | 51 | ⚡ |

**Foundational modules** (`CoreModels`, `CoreUI`, `CoreNetworking`) are depended
on by almost everything; a change there warrants running the broad set of fast
suites (handled automatically by `tools/test-fast.sh`).

## Tiered policy

1. **Inner loop (every change):** compile (the sim/device build you do to
   deploy) + the covering suite(s):
   `tools/test-fast.sh`  (auto-detects changed modules)  — or name them:
   `tools/run-tests.sh CoreModelsTests FeatureAuthTests`. ~5–20s.
2. **Pre-integration (handing a branch off):** run the fast suites for every
   module you touched plus their foundational deps. `tools/test-fast.sh` already
   expands foundational changes.
3. **Pre-merge (before merging to main):** full sweep `tools/run-tests.sh`. All
   suites (FeatureHomeTests included) now run promptly, so the sweep is bounded by
   compile + simulator orchestration rather than a watchdog hang.

## Notes / gotchas

- **`swift test` does not work on this Mac** — AetherEngine's FFmpeg binary
  xcframeworks are tvOS-only (no macOS slice), so SwiftPM resolution fails. It
  only runs in the Linux CI container (`swift:6.0`), where the Apple xcframeworks
  are ignored and the UI modules compile out behind `#if canImport(...)`.
  Locally, use `tools/run-tests.sh <Suite>` / `tools/test-fast.sh` (simulator).
- **No shadow dance for targeted suites.** `tools/run-tests.sh <Suite>` runs a
  per-module scheme on the simulator with `Plozz.xcodeproj` in place. Moving the
  project aside is only needed for the aggregate `Plozz-Package` scheme.

## Known issues to fix (do NOT mask by weakening tests)

- **CoreModelsTests:** 21 assertions fail on clean `main`, all in the
  **media-identity / cross-server merging** area — **not** subtitles/captions,
  playback transport, or settings. Agents keep re-discovering these and burning a
  ~10-min recompile each time; they are pre-existing and unrelated to most work.
  The failing cases (as of this writing):
  - `IdentityIndexTests` (6): `testEnrichmentFetchFailureIsInconclusiveNotDropped`,
    `testEnrichmentFillsGuidlessPlexSeries`, `testEnrichmentGenuinelyUnmatchableIsConclusive`,
    `testEnrichmentNeverLoosensSeriesToTitle`, `testEnrichmentProcessesMixedPageConcurrently`,
    `testSymmetricFanOutToFormerlyGuidlessPlexSeries`.
  - `MediaItemIdentityTests` (`CrossServerIdentityTests`, 4):
    `testExternalIDSuppressesTitleKey`, `testMultipleExternalIDsEmittedInPriorityOrder`,
    `testTitleIdentityIsMoviesOnly`, `testTitleIdentityRequiresYear`.
  - `MediaItemMergerTests` (1): `testMergesMovieByTitleAndYearWithoutExternalIDs`.
  - `SameAccountVersionGroupingTests` (1): `testTwoSameTitleSameYearMoviesGroupViaTitleIdentityWhenNoIDs`.
  - `PlaybackDiagnosticsEnrichedTests` (1): `testStreamTransportSummaryFlagsLocalAndStripsTokens`.
  Common thread: `MediaIdentity` now emits a `sameItemID(...)` identity and no
  longer emits bare `title(...)`/some `external(...)` in the cases these tests
  assert, and the diagnostics transport summary dropped the `· HLS` suffix. Fix =
  reconcile these tests with the current identity/merging + diagnostics behaviour
  (or fix the behaviour if it regressed) — do **not** weaken assertions to hide
  them. **If you are working on subtitles/playback/settings and see exactly these
  21, they are not your regression — carry on.**
- **FeatureHomeTests:** ✅ **Fixed & un-quarantined** (issue #4). The suite used to
  crash the xctest host and then hang ~600s (CoreSimulator watchdog), with ~23
  "downstream" assertion failures. Real root cause was **not** leaked
  `Task.detached` in the view models (those are already tracked + cancelled on
  `deinit`): it was a **data race in the shared test double**. `FakeMediaProvider`
  was `@unchecked Sendable` but mutated its call-counter dictionaries
  (`itemCallCounts`, …) without synchronization, and the view model legitimately
  calls the provider **concurrently** — the main-actor `load()`/`reload()` path and
  the background alternate-source fan-out (`.utility` task group) both hit the same
  fake (tests share one instance via `alternateProviderResolver: { _ in provider }`).
  Concurrent `Dictionary` mutation corrupted the buffer → an
  `-[__NSTaggedDate count]` unrecognized-selector crash, which forced xctest to
  relaunch and hang, and the crashed/congested run starved the async `waitUntil`
  spins (hence the "23 failing"). Fix = guard the fake's counters with a lock (a
  correct test-double fix; real providers are thread-safe, and production resolves
  a distinct provider per account so the race is test-only). No assertions were
  weakened — all 234 tests pass in ~2.8s exec, verified deterministic across
  repeated runs.
- The old "flaky Plex network-probe" tests are **already deterministic**
  (injected `HTTPClient` doubles, fake hosts). No action needed beyond dropping
  the "flaky" label.
