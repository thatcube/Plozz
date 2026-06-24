# FeatureSearch

The federated search view: one search box that queries every active
provider (Jellyfin and Plex) in parallel, deduplicates results, and
ranks them with a shared policy.

## Responsibility

- `SearchView` + `SearchViewModel` — focusable tvOS search UI with
  debounced input, per-section results, and `LoadState`-driven
  loading/empty/failure rendering.
- `SearchSection` — section model (movies / shows / episodes / people /
  music / collections) so results are grouped consistently across
  backends.
- `SearchDeduplicator` — collapses items that appear on multiple servers
  / accounts (same title + year + content type → one card with merged
  ids) so the federated view never shows obvious duplicates.
- `SearchPolicy` — the shared sorting/ranking rules (exact-match first,
  watched bias, recency, etc.). Pulled out so it's unit-testable
  independent of the view-model.

## Invariants

- **Provider-agnostic.** Search calls go through `MediaProvider`; nothing
  here imports a specific provider.
- **Federated across active accounts.** Fans out over the active
  `[ResolvedAccount]` set from `AppState`, the same way `FeatureHome`
  does.
- **`LoadState` everywhere.** Loading/empty/failure rendering uses
  `CoreUI.ContentStateView`.
- **Compiles without UI.** `SearchPolicy` and `SearchDeduplicator` are
  plain Swift, Linux-portable, and unit-tested in
  `Tests/FeatureSearchTests`.

## Where to look first

- `SearchViewModel.swift` — the debounced fan-out / merge loop.
- `SearchDeduplicator.swift` + `SearchPolicy.swift` — the pure logic
  pieces (test these without a simulator).
