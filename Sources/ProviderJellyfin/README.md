# ProviderJellyfin

Shared Jellyfin/Emby implementation of `CoreModels.MediaProvider`. Both use the
MediaBrowser API lineage and intentionally share one implementation so every
supported capability remains at parity.

## Responsibility

- `JellyfinProvider` (the `MediaProvider` conformer) — libraries, items,
  continue-watching, latest, seasons/episodes, search, watched state,
  playback URL/streaming info, progress reporting, and Jellyfin Quick Connect.
- Emby compatibility — password authentication, Emby UDP discovery, chapter
  intro/credit markers, BIF trickplay, combined theme media, and Emby playback
  negotiation while preserving the shared feature surface.
- Delayed E-AC-3 JOC enrichment — when Emby omits Atmos from its API, Plozz
  performs a bounded one-frame decode after first paint, caches the confirmed
  result by source revision, and updates badges without delaying detail or Play.
- `JellyfinDTOs` — server JSON shapes, mapped into `CoreModels` value types
  at the seam (no DTO ever leaks above this module).
- `JellyfinDeviceProfile` + `JellyfinCapabilityProfile` — the
  direct-play / transcode capability matrix sent on `/PlaybackInfo`,
  parameterised by whether the on-device decode engine (Plozzigen) is linked
  so the server allows MKV / DTS / TrueHD / etc. to direct play when we can
  decode them locally.
- `JellyfinMusicProvider` — music-library queries (artists, albums, tracks)
  surfaced through the shared provider abstraction.

## Invariants

- **No UI imports.** Pure logic + DTOs. Compiles on Linux.
- **Never logs tokens.** All `Authorization` / `X-MediaBrowser-Token` headers
  flow through `CoreNetworking` redaction.
- **Maps every error to `AppError`.** Transport / decode / HTTP-status
  failures don't escape this module raw.
- **Jellyfin/Emby parity by construction.** Shared capabilities stay in one
  implementation; provider-specific branches are limited to API differences.
- **Co-equal with `ProviderPlex`.** Any new `MediaProvider` capability must be
  implemented here whenever it's implemented for Plex (and vice versa).

## Where to look first

- `JellyfinClient.swift` — the `MediaProvider` impl.
- `JellyfinDeviceProfile.swift` + `JellyfinCapabilityProfile.swift` — what
  the server is told this device can direct-play.
- `JellyfinDTOs.swift` — server JSON shapes mapped to `CoreModels`.
