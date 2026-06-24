# ProviderTrailers

A **synthetic** `MediaProvider` that plays online (YouTube) trailers without
backing them with a server library item. Used by `FeatureHome` as a fallback
when the user's server has no attached trailer for a title.

## Responsibility

- `YouTubeTrailerProvider` — conforms to `MediaProvider` but only
  meaningfully implements `playbackInfo(for:)`. The `itemID` is treated as
  a YouTube video id; YouTubeKit resolves a *progressive* (single
  video+audio) stream URL which is returned as a regular `PlaybackRequest`
  so the existing player plays it with no YouTube chrome or ads.
- `TrailerStreamSelection` — the stream-quality / format selection policy
  applied to YouTubeKit's candidate set (codec, container, resolution
  caps), kept isolated so it's unit-testable.

## Invariants

- **No UI imports.** Pure logic.
- **Inert for non-playback APIs.** Everything except `playbackInfo` returns
  empty / no-op results — a trailer is a single leaf, not a library.
- **No keys, no quotas.** Stream extraction is keyless via YouTubeKit; if
  it fails the optional `AlternativeResolving` closure may supply fallback
  video ids (typically from a keyless YouTube search by title) so a stale
  TMDb-sourced video id can self-heal.
- **No persistence.** Trailer streams are short-lived URLs; nothing is
  cached here.

## Where to look first

- `YouTubeTrailerProvider.swift` — the `MediaProvider` conformer.
- `TrailerStreamSelection.swift` — codec/container/quality picking.
