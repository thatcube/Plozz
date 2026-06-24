# FeaturePlayback

`AVPlayer` view-model/view, engine-agnostic playback surface, resume
reporting back to the server, caption style rules, trickplay scrubbing,
and the diagnostics overlay.

## Responsibility

- **Engine abstraction** — `VideoEngine` protocol + the two seam files:
  - `NativeVideoEngine` — the always-shipped AVPlayer-backed engine.
  - `EngineFactory` — closure-based factory that the composition root
    (`AppShell`) wires up. The non-AVPlayer engine (libmpv) lives in
    `EngineMPV` and is injected here as a closure, so `FeaturePlayback`
    never imports `EngineMPV` directly. This keeps the dependency on the
    libmpv xcframeworks out of the rest of the app.
- **View model / view** —
  - `PlayerViewModel` orchestrates engine lifecycle, audio/subtitle
    selection, scrub state, resume, and progress reporting.
  - `PlayerView` + `CustomPlayerContainer` host the engine's vended
    bare video surface and overlay the shared transport chrome.
- **Caption rendering** — `CaptionStyleRules` translates
  `CoreModels.CaptionSettings` (font, size, color, opacity, background,
  edge style) into `AVPlayer` text style rules.
- **Subtitles** — `SubtitleHLSComposer`, `SubtitleInjectingResourceLoader`,
  `WebVTTNormalizer`: inject external sidecar subtitles into the
  AVPlayer pipeline as a synthesized HLS variant and normalize timing /
  encoding to WebVTT, AVPlayer's only timed-text format.
- **Trickplay scrubbing** — `ScrubGeometry`, `ScrubThumbnailProviding`,
  `TrickplayThumbnailLoader`, `PlexBIFThumbnailLoader`: focus-driven
  scrub bar with per-provider thumbnail loaders (Jellyfin "trickplay"
  PNG/JPG tiles + Plex BIF).
- **Diagnostics** — `PlaybackDiagnosticsSampler` +
  `PlaybackDiagnosticsOverlay`: opt-in HUD with engine, codec, bitrate,
  dropped frames, etc.
- **Display matching** — `DolbyVisionDisplayCriteria` /
  `IdleSleepGuard`: AVKit display-criteria match + keep-awake while
  playing.

## Invariants

- **Engine-agnostic.** All transport chrome drives engines through the
  `VideoEngine` protocol — never down-casts. A second engine
  (libmpv/VLCKit) must work with the same chrome and `PlayerViewModel`.
- **Resume is the contract.** Progress reports back to the provider on
  pause/seek/end so `Continue Watching` is always accurate.
- **Captions through the rules pipeline.** No view directly twiddles
  AVPlayer text style — it all flows through `CaptionStyleRules`.
- **No secrets in URLs logged.** Stream URLs frequently embed tokens —
  `PlayerViewModel` redacts before logging.

## Where to look first

- `VideoEngine.swift` — the protocol every engine implements.
- `PlayerViewModel.swift` — the orchestration & resume contract.
- `EngineFactory.swift` — how the libmpv engine is plugged in without
  this module depending on it.
- `CaptionStyleRules.swift` — caption settings → AVPlayer text rules.
