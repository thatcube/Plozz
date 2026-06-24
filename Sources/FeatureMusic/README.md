# FeatureMusic

Music browsing (artists / albums / tracks) and an app-scoped audio
player that is **independent** of the full-screen video `PlayerViewModel`,
so audio keeps playing as the user navigates the rest of the app.

## Responsibility

- **Browse UI** — `MusicTabView`, `MusicScreens`, `MusicViewModels`,
  `MusicAggregator`: artist / album / track screens that aggregate
  across the active accounts via `MediaProvider`.
- **Audio engine** — `AudioPlaybackController`:
  - owns an `AVQueuePlayer` + manually-managed queue so it can resolve
    each track's stream URL on demand and support shuffle / repeat /
    next / previous;
  - configures `AVAudioSession` `.playback` + `setActive(true)` so audio
    keeps playing across screens / screensaver;
  - publishes `MPNowPlayingInfoCenter` (title / artist / album / artwork
    / duration) and registers `MPRemoteCommandCenter` handlers so Siri
    Remote play/pause/skip and tvOS Control Center work.
- **Mini-player & Now Playing** — `MiniPlayerView` + `NowPlayingView`
  observe the **same** injected `AudioPlaybackController` instance from
  the environment.
- **Artwork** — `MusicArtworkImage` + `MusicCard` render through
  `CoreUI.FallbackAsyncImage`. Server art is always tried first; if it's
  missing, `MusicArtworkFallback` produces an async closure that asks
  `MetadataKit.ArtworkRouter` for a Deezer / Cover Art Archive image.
  One provider path, one cache.

## Invariants

- **Independent of video playback.** `AudioPlaybackController` and
  `FeaturePlayback.PlayerViewModel` are separate lifecycles. They must
  not share state, AVPlayer instances, or audio session ownership in a
  way that causes one to interrupt the other unexpectedly.
- **Single shared controller.** The mini-player and Now Playing screen
  observe the same `AudioPlaybackController` injected at `AppShell`.
- **Server art first.** `MetadataKit` art is a fallback, not the
  default.
- **Dual-provider.** Browsing works against both Plex and Jellyfin via
  `MediaProvider` / `JellyfinMusicProvider`.

## Where to look first

- `AudioPlaybackController.swift` — the queue / session / remote-command
  / Now-Playing wiring.
- `MusicArtworkFallback.swift` — how `MetadataKit` art is plugged in.
- `MusicViewModels.swift` — screen state coordination.
