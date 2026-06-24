# EngineMPV

libmpv-backed implementation of the engine-agnostic `VideoEngine` protocol
from `FeaturePlayback`. The on-device decoder for everything AVPlayer can't
handle: MKV, DTS / DTS-HD / TrueHD audio, certain HEVC/10-bit, AV1 quirks,
image-based PGS/VOBSUB subtitles, etc. Renders through Metal with
libplacebo HDR tone-mapping.

> ⚠️ Builds against gitignored `Libmpv.xcframework` + FFmpeg xcframeworks
> staged by `tools/setup-mpv.sh`. See the **`_pl_log_create_NNN` linker
> trap** in `AGENTS.local.md` before "fixing" any libmpv link error — the
> libmpv build and the pinned `Libplacebo` must match libplacebo's
> versioned `pl_log_create_<API_VER>` symbol.

## Responsibility

- `MPVClient` — narrow Swift wrapper around `libmpv`'s C API (option /
  property / command setting; observe-property bridge).
- `MPVRenderView` / `MPVRenderView`'s `CAMetalLayer` — the bare video
  output surface vended to `CustomPlayerContainer`. No transport chrome
  here — the shared overlay hosts and drives playback purely through the
  `VideoEngine` protocol.
- `MPVVideoEngine` — the `VideoEngine` conformer. Implements lifecycle
  (`load` / `play` / `pause` / `seek` / `stop`), observable position /
  duration / state, audio + subtitle track selection, progress / failure
  callbacks.
- `MPVHDR` — Dolby Vision / HDR10 metadata extraction + display-criteria
  handoff so AVKit-style display matching still happens for the libmpv
  surface.

## Invariants

- **Linked at the composition root only.** `FeaturePlayback` does not
  import `EngineMPV`; `AppShell` injects an `EngineFactory` closure that
  constructs an `MPVVideoEngine`. The view-model stays engine-agnostic.
- **No UI imports beyond UIKit/Metal.** SwiftUI hosting happens in
  `FeaturePlayback`.
- **Guarded by `#if canImport(Libmpv) && canImport(UIKit)`** — the module
  still compiles on platforms / configurations where the binary
  xcframeworks are unavailable.
- **No secrets in player options.** Stream URLs may contain access tokens
  — never log raw options or property strings via `PlozzLog`.

## Where to look first

- `MPVVideoEngine.swift` — the `VideoEngine` conformance & event mapping.
- `MPVClient.swift` — the C bridge.
- `MPVRenderView.swift` — the Metal-backed render surface.
- `AGENTS.local.md` (private) — the libplacebo `_pl_log_create_NNN` trap.
