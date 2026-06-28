# Playback Engine Architecture

Plozz uses three playback engines, automatically selected per-item based on
container, codecs, and subtitle requirements. The goal is maximum format coverage
with the best possible quality (Dolby Vision, Atmos, full-timeline seek).

## Engine Overview

| Engine | Internal name | Underlying tech | Primary use case |
|--------|--------------|-----------------|------------------|
| **Plozzigen** | `.plozzigen` | AetherEngine (FFmpeg demux → HLS-fMP4 → localhost → AVPlayer) | MKV library content — the workhorse (~95% of local files) |
| **mpv** | `.hybrid` | libmpv (software decode + system audio output) | Edge cases: PGS subs, external audio, exotic codecs |
| **Native** | `.native` | AVPlayer directly | Server-delivered HLS/fMP4 (transcodes, direct-play manifests) |

## Routing Logic

Engine selection happens in `PlayerViewModel` at playback start:

```
1. Is there a localRemuxSource descriptor?
   NO  → Native (server is delivering a ready-to-play stream)
   YES → continue

2. Is plozzigenEligibility == .eligible?
   NO  → mpv (codec/container not supported by Plozzigen)
   YES → continue

3. Does the default subtitle track use PGS (bitmap) format?
   YES → mpv (AVPlayer can't render bitmap subs)
   NO  → continue

4. Is there an external audio URL?
   YES → mpv (only mpv can mux two separate URLs)
   NO  → Plozzigen ✓
```

## Plozzigen Eligibility Gate

Plozzigen accepts content when ALL of these are true:

- **Container:** MKV / Matroska
- **Video codec:** HEVC, H.264, VP9, or AV1
- **Audio codec:** Any (fMP4-legal codecs are stream-copied; incompatible ones
  like TrueHD/DTS are bridged to lossless FLAC internally)
- **Byte-range readable:** HTTP range requests or local file access
- **NOT Dolby Vision Profile 7** (dual-layer BL+EL+RPU — unsupported everywhere)

## When mpv Takes Over

mpv is the fallback for content Plozzigen can't handle optimally:

| Scenario | Why mpv? |
|----------|----------|
| PGS bitmap subtitles active | AVPlayer has no bitmap subtitle renderer |
| External audio URL | Only mpv can combine two separate media URLs |
| Non-MKV containers (rare edge cases) | Plozzigen gate requires Matroska |
| DV Profile 7 dual-layer | Can't be remuxed to single-layer fMP4 |
| Exotic video codecs (MPEG-2, VC-1) | Not in the Plozzigen codec set |

## When Native AVPlayer Is Used

Native handles content the server has already prepared:

- Server-transcoded HLS streams (`.m3u8`)
- Direct-play of natively compatible MP4/MOV files
- YouTube trailers (no `localRemuxSource` — just a URL)

## Quality Capabilities by Engine

| Feature | Plozzigen | mpv | Native |
|---------|-----------|-----|--------|
| Dolby Vision | ✅ (Profile 5/8) | ❌ (tone-mapped) | ✅ (if server delivers DV) |
| Dolby Atmos | ✅ (passthrough) | ❌ (decoded to PCM) | ✅ (if stream has E-AC3 JOC) |
| HDR10 / HLG | ✅ | ✅ (tone-mapped) | ✅ |
| Full-timeline seek | ✅ | ✅ | ✅ (if not live transcode) |
| PGS subtitles | ❌ | ✅ | ❌ |
| DTS bitstream | ❌ (bridged to FLAC) | ❌ (decoded to PCM) | ❌ |
| TrueHD bitstream | ❌ (bridged to FLAC) | ❌ (decoded to PCM) | ❌ |

## Source Code References

- Eligibility gate: `Sources/CoreModels/LocalRemuxModels.swift` → `plozzigenEligibility`
- Engine routing: `Sources/FeaturePlayback/PlayerViewModel.swift` → engine selection block
- Plozzigen adapter: `Sources/EnginePlozzigen/PlozzigenVideoEngine.swift`
- Engine factory: `Sources/FeaturePlayback/EngineFactory.swift`
- AetherEngine dependency: `Package.swift` → `superuser404notfound/AetherEngine`

## History

Plozzigen replaced a custom local-remux engine (CRemuxCore + cue-table approach)
that suffered from audio/video desync, fragile resume behavior, and inability to
handle Plex content correctly. The prior engine's experimental branches are
preserved under `preserve/remux-*` git tags for reference but are not used.

AetherEngine was adopted because it solves the exact same problem (MKV → AVPlayer
with DoVi + Atmos + seeking) with a battle-tested pipeline. Plozz wraps it via
the `PlozzigenVideoEngine` adapter conforming to the `VideoEngine` protocol.
