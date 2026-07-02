# Plozz testing: SOURCE → TEST map & tiered policy

Purpose: run the *right* tests fast during the agentic inner loop, and the full
sweep only when it matters — speed without sacrificing quality.

## Why this exists (measured)

On an Apple TV 4K simulator (tvOS 27.0), warm DerivedData:

| Action | Time | Note |
|---|---|---|
| `tools/setup-mpv.sh` | 0.27s | idempotent |
| `tools/generate-project.sh` | ~0.08s | negligible — regenerating is not a cost |
| `swift test` (macOS host) | fails ~10s | mpv xcframeworks have no macOS slice |
| Full `Plozz-Package` suite (cold) | 653s | full-graph compile |
| Full `Plozz-Package` suite (warm) | 627s | ~11s CPU; rest is sim orchestration |
| `CoreModelsTests` (483 tests) | 5.5s | exec 0.36s |
| `ProviderJellyfinTests` (107) | 5.5s | exec 0.14s |
| `FeatureHomeTests` (120) | 606s | exec 1.14s + ~600s sim watchdog; 23 failing |
| `run-tests.sh CoreNetworkingTests` | 19.5s | no "xcodeproj aside" dance needed |

All 1088 tests *execute* in under 1 second of CPU. Nearly all wall-clock cost is
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
| EngineMPV | EngineMPVTests | 20 | needs mpv + tvOS sim |
| FeatureDiscovery | FeatureDiscoveryTests | 19 | ⚡ |
| ProviderJellyfin | ProviderJellyfinTests | 107 | ⚡ ~5s |
| ProviderPlex | ProviderPlexTests | 102 | ⚡ (injected probe doubles; no real network) |
| ProviderTrailers | ProviderTrailersTests | 13 | ⚡ |
| RatingsService | RatingsServiceTests | 11 | ⚡ |
| TraktService | TraktServiceTests | 16 | ⚡ |
| FeatureAuth | FeatureAuthTests | 35 | ⚡ |
| FeatureHome | FeatureHomeTests | 120 | 🐌 QUARANTINED (see below) |
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
3. **Pre-merge (before merging to main):** full sweep `tools/run-tests.sh` — but
   first fix/quarantine the slow suite so the sweep isn't 10 minutes of watchdog.

## Notes / gotchas

- **`swift test` does not work on this Mac** — the mpv binary xcframeworks have
  no macOS slice, so SwiftPM resolution fails. It only runs in the Linux CI
  container (`swift:6.0`), where the Apple xcframeworks are ignored and the
  UI modules compile out behind `#if canImport(...)`. Locally, use
  `tools/run-tests.sh <Suite>` / `tools/test-fast.sh` (simulator).
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
- **FeatureHomeTests:** 23 assertions fail on clean `main`
  (`ItemDetailViewModelTests` — trailer resolution / alternate-source
  enrichment / "Condition not met before timeout"). The suite also hangs the
  xctest process ~600s: `ItemDetailViewModel`/`HomeViewModel` spawn unstructured
  `Task.detached` background work (snapshot writes, enrichment with 0.4–2.5s
  sleeps) that isn't cancelled at teardown, so the host lives until the ~600s
  CoreSimulator watchdog kills it. Fix = cancel those tasks on teardown/deinit,
  then triage the 23 failures. Quarantined from `test-fast.sh` until fixed.
- The old "flaky Plex network-probe" tests are **already deterministic**
  (injected `HTTPClient` doubles, fake hosts). No action needed beyond dropping
  the "flaky" label.
