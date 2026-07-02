# ProviderJellyfin

Jellyfin implementation of `CoreModels.MediaProvider`. One of Plozz's two
first-class backends; co-equal with `ProviderPlex`.

## Responsibility

- `JellyfinClient` (the `MediaProvider` conformer) — libraries, items,
  continue-watching, latest, seasons/episodes, search, watched state,
  playback URL/streaming info, progress reporting, Quick Connect support.
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
- **Co-equal with `ProviderPlex`.** Any new `MediaProvider` capability must
  be implemented here whenever it's implemented for Plex (and vice versa).

## Where to look first

- `JellyfinClient.swift` — the `MediaProvider` impl.
- `JellyfinDeviceProfile.swift` + `JellyfinCapabilityProfile.swift` — what
  the server is told this device can direct-play.
- `JellyfinDTOs.swift` — server JSON shapes mapped to `CoreModels`.
