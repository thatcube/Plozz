# CoreModels

The Foundation-only, **zero-dependency** core of Plozz. Defines the domain
language every other module speaks.

## Responsibility

- Domain value types: `MediaItem`, `MediaLibrary`, `MediaServer`,
  `UserSession`, `Account`, `Profile`, `MusicTrack`, `Person`, etc.
- The dual-provider abstraction: `MediaProvider` protocol, `ProviderKind`,
  `ProviderRegistry` / `ProviderResolving`, `ResolvedAccount`.
- Cross-cutting UI state: `LoadState`, `AppError`.
- Shared decode/encode helpers: `JSONDecoder.plozz`, `JSONEncoder.plozz`.
- Subtitle behaviour + appearance model: `SubtitleBehavior`, `SubtitleStyle`,
  plus the neutral `SubtitleColor` / `SubtitleEdgeStyle` / `SubtitleMode` primitives.
- Profiles persistence contract: `ProfilePersisting`, `ProfileStore`,
  `ProfilesModel`, plus the Plex Home-user mapping (`PlexHomeUser`).

## Invariants

- **No SwiftUI / AVKit / UIKit imports.** This module compiles on Linux so
  pure-logic tests can run there. UI lives in `CoreUI` and feature modules.
- **Never hold secrets.** Tokens are owned by `FeatureAuth` (Keychain). Types
  here (e.g. `Account`, `Profile`) carry only non-secret metadata.
- **Provider-agnostic.** No type here may assume Jellyfin- or Plex-specific
  behavior; the only provider seam is `MediaProvider`.

## Public surface, at a glance

| Concept | Entry point |
| --- | --- |
| Provider abstraction | `MediaProvider`, `ProviderKind`, `ProviderRegistry` |
| Domain models | `MediaItem`, `MediaLibrary`, `MediaServer`, `UserSession` |
| Multi-account | `Account`, `ResolvedAccount`, `AggregatedLibrary` |
| Profiles | `Profile`, `ProfileStore`, `ProfilesModel`, `PlexHomeUser` |
| UI state | `LoadState`, `AppError` |
| Subtitles | `SubtitleBehavior`, `SubtitleStyle` (rendered by `FeaturePlayback`) |

## Where to look first

- `MediaProvider.swift` — the protocol that defines every backend.
- `ProviderRegistry.swift` — how features resolve a provider from a session.
- `AppError.swift` — the single error currency used everywhere.
