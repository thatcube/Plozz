Agent completed. agent_id: aether-dovi-atmos, agent_type: research, status: completed, description: Extract AetherEngine DoVi/HDR/Atmos mechanics, elapsed: 574s, total_turns: 0, duration: 288s

I now have all the required files. Here is the full structured research report.

---

# AetherEngine Research Report
**Commit:** `525fbe28989dee95b21e1b3b9786f2384f667930`
**Purpose:** DV/HDR/Atmos correctness and HTTP-range I/O mechanics for application to Plozz

---

## Q1 — DV PLAYLIST SIGNALING: CODECS, VIDEO-RANGE, SUPPLEMENTAL-CODECS, and dvh1/hvc1 sample entries

### Profile 5 (DV-only, IPT-PQ-c2)

```
primaryCodecs: "dvh1.05.<dvLevel>"          // e.g. "dvh1.05.06"
videoRange:    .pq                           // VIDEO-RANGE=PQ in the playlist
supplemental:  nil
codecTagOverride: "dvh1"
stripDolbyVisionMetadata: false
```

**Citation:** `Sources/AetherEngine/Video/CodecRoutePolicy.swift`, `profile5` case:
```swift
return CodecRoute(
    codecTagOverride: "dvh1",
    videoRange: .pq,
    primaryCodecs: "dvh1.05.\(dvLevelStr)",
    supplementalCodecs: nil,
    stripDolbyVisionMetadata: false,
    convertP7ToProfile81: false,
    dvVariant: dvVariant
)
```
**Key gotcha (HEVC-path comment):**
> "P5 needs dvh1 even on non-DV panels because AVPlayer's system DV decoder tonemaps IPT-PQ-c2 internally; without dvh1 IPT chroma reads as YCbCr (green/purple cast, AetherEngine#4 Build 160+163 / DrHurt#19). Routing forces media playlist for P5-on-non-DV."

And separately:
> "Bare dvh1.05 in master playlist fires -11868 on non-DV panels; routing forces media playlist."

So P5 is **always `dvh1` in CODECS** regardless of panel type — but it must be served via a media-only playlist (not the master multivariant) on non-DV panels to dodge `-11868`.

---

### Profile 8.1 (HDR10-compat base) — the most important case for Plozz

**On a DV panel (`effectiveDvMode == true`):**
```
primaryCodecs:       "hvc1.2.4.L<hevcLevel>"          // e.g. "hvc1.2.4.L150"
supplementalCodecs:  "dvh1.08.<dvLevel>/db1p"          // e.g. "dvh1.08.06/db1p"
videoRange:          .pq
codecTagOverride:    "hvc1"
stripDolbyVisionMetadata: false    // dvvC box IS written by the muxer
```
**On a non-DV panel:**
```
primaryCodecs:       "hvc1.2.4.L<hevcLevel>"
supplementalCodecs:  nil
videoRange:          .pq
codecTagOverride:    "hvc1"
stripDolbyVisionMetadata: true     // dvvC stripped — plain HDR10
```

**Citation:** `CodecRoutePolicy.swift`, `.profile81` case:
```swift
// DV panel: hvc1 + dvvC (muxer writes dvvC automatically) + SUPPLEMENTAL dvh1.08.XX/db1p.
//   db1p required; without it AVPlayer treats variant as plain HDR10 and DV never engages.
// Non-DV panel: strip dvvC (hvc1 + dvvC trips -11868 even without SUPPLEMENTAL, 2026-05-26).
```

---

### Profile 8.4 (HLG-compat base)

**DV panel:**
```
primaryCodecs:       "hvc1.2.4.L<hevcLevel>"
supplementalCodecs:  "dvh1.08.<dvLevel>/db4h"   // db4h marks HLG-base for AVKit criteria
videoRange:          .hlg
codecTagOverride:    "hvc1"
```
**Non-DV panel:** strip dvvC, plain HLG.

**Note (code comment):**
> "`dvh1` sample entry is never valid for HLG-base (AVPlayer rejects it, DrHurt#4 Build 160)."

---

### Profile 7 — after conversion to 8.1 (on DV panel)

```
primaryCodecs:       "hvc1.2.4.L<hevcLevel>"
supplementalCodecs:  "dvh1.08.<dvLevel>/db1p"
videoRange:          .pq
codecTagOverride:    "hvc1"
convertP7ToProfile81:    true
rewriteDoviConfigTo81:   true
```

---

### What makes the dvcC/dvvC box work

The `codecTagOverride` field is passed to `MP4SegmentMuxer`, which overrides the FFmpeg container `codec_tag` before `avformat_write_header`. For P8.x on a DV panel, the tag is `hvc1`; the muxer writes the `dvvC` box automatically (it's in the HEVC codec parameters). For P5, `dvh1` is the tag and `dvcC` is preserved. The `SUPPLEMENTAL-CODECS` attribute is what triggers AVKit/AVPlayer to engage the DV compositor; without `db1p` (for P8.1) or `db4h` (for P8.4) in that attribute, AVPlayer treats the stream as plain HDR10/HLG.

**`docs/formats.md` summary:**
> "On a DV-capable display the muxer writes the `dvvC` box and the variant carries `dvh1.08.<dvLevel>/db1p` (8.1) or `/db4h` (8.4) in `SUPPLEMENTAL-CODECS`, which is what makes AVKit engage DV."

---

**⚠️ `P8.6` malformed-compat gotcha (issue #53):**
> "P8.6 malformed compat (#53): rewriteDoviConfigTo81 normalizes container to compat=1; on non-DV panel the strip path handles it without rewrite."

Any source with `dv_bl_signal_compatibility_id != 1` but `profile == 8` is treated as P8.1 on DV panels but the container `dvcC` is rewritten to `compat=1`. Non-DV panel: stripped.

---

### LESSON FOR PLOZZ (Q1)
Plozz must use `hvc1.2.4.L<level>` as the primary CODECS for P8.1 (not `dvh1`), add `SUPPLEMENTAL-CODECS="dvh1.08.XX/db1p"` only when the panel is in DV mode (detected via `currentEDRHeadroom > 1.001` post-`waitForSwitch`), and strip the `dvvC` box on non-DV panels to avoid `-11868`. For P5, `dvh1.05.XX` is mandatory even on SDR panels, but must not appear in a multivariant master; serve it only in a dedicated media playlist.

---

## Q2 — PROFILE 7 → 8.1: Per-Packet NAL Surgery via libdovi

### The converter: `DoviRpuConverter.convertPacketToProfile81`

**Full citation:** `Sources/AetherEngine/Video/DoviRpuConverter.swift`

The algorithm processes **AVCC-layout** (4-byte big-endian length-prefix) HEVC NAL units in each AVPacket:

1. **NAL type 62 (`unspec62`)** = Dolby Vision RPU:
   ```swift
   let nalType = (data[nalStart] >> 1) & 0x3F   // HEVC NAL: bits 1..6 of byte 0
   case nalTypeRPU:  // 62
       guard let rpu = dovi_parse_unspec62_nalu(data + nalStart, len) else { return false }
       let rc = dovi_convert_rpu_with_mode(rpu, 2)   // libdovi mode 2 = P7 → P8.1
       // ... write back via dovi_write_unspec62_nalu
   ```
   Mode 2 is the same as `dovi_tool -m 2` per the docs: it converts P7's dual-layer RPU metadata to a single-layer P8.1 RPU, dropping all references to the now-absent EL. libdovi handles emulation-prevention bytes internally.

2. **NAL type 63 (`unspec63`)** = Enhancement Layer (EL) — simply **dropped**:
   ```swift
   case nalTypeEL:  // 63
       droppedEL = true
       // NOT appended to outputNALs — EL is silently discarded
   ```

3. **All other NAL types** (VCL BL data, VPS, SPS, PPS, AUD, SEI) pass through unchanged.

4. The output NALs are **reassembled** into a new `av_buffer_alloc`'d block with their 4-byte length prefixes re-written, and the packet's `data`/`size` pointers are atomically swapped. `AV_INPUT_BUFFER_PADDING_SIZE` bytes of zero padding follow for decoders that read past the declared size.

5. **Degenerate guard:** If all NALs in a packet were EL (a rare standalone EL packet), the packet is **left untouched** rather than producing a zero-length video packet.

6. **Failure semantics:** `false` only on a libdovi error. Packets with no RPU or EL return `true` without modification — the function is a no-op on non-DV frames and on I/P/B frames that contain only VCL NALs.

**Works for MEL and FEL** (both dual-layer P7 variants): the EL NALs (type 63) are dropped regardless of MEL/FEL distinction; only the RPU (type 62) matters for libdovi.

**Container-level rewrite:** In addition to per-packet surgery, `rewriteDoviConfigTo81 = true` causes the init segment's `dvcC`/`dvvC` box to be rewritten to `profile=8, compat=1` so AVPlayer's sample-entry parser confirms the stream is P8.1 before the first frame. (Citation: `CodecRoutePolicy.swift`, `CodecRoute.rewriteDoviConfigTo81` + the P7 case comment: "rewrite container dvcC to P8.1 in init.mp4".)

**Applicability to other profiles:** The converter is hardcoded to `mode 2` and triggered only when `convertP7ToProfile81 == true`, which is set only for P7. For P8.1 the RPU is already single-layer; for P5 there's no HDR10-compatible BL. Theoretically `mode 2` could be applied to P7-from-non-UHD-BD sources as well — the code doesn't gate on MEL vs FEL — but the engine only enables it for the P7 profile classification.

**`DoviRpuConverter+Probe.swift`** provides a diagnostic CLI tool (`doviConvertProbe`) that opens a source, runs `convertPacketToProfile81` on every HEVC packet, and writes Annex-B output (AVCC → `00 00 00 01` start codes) for external validation with `dovi_tool extract-rpu`. It also handles the case where `hvcC numOfArrays=0` (VPS/SPS/PPS are in-band only, e.g. some WEB-DL DV P5 encodes): it calls `rebuildHEVCExtradataWithInBandParameterSets` to scan up to 16 packets for the parameter set NALs and assembles a proper `hvcC` block before emitting Annex-B.

### LESSON FOR PLOZZ (Q2)
Plozz can implement the exact same P7→8.1 conversion using libdovi. The three-step recipe: (1) for every video AVPacket, walk AVCC NAL units, (2) for type-62 call `dovi_parse_unspec62_nalu` + `dovi_convert_rpu_with_mode(rpu, 2)` + `dovi_write_unspec62_nalu`, (3) silently drop type-63. Also rewrite the `dvcC` box in the init segment to `profile=8, compat=1`. This is purely in-process during remux with no extra decode pass.

---

## Q3 — DISPLAY CRITERIA: Ordering, `-11868` Prevention, and tvOS 26.5

### The mandatory ordering

**`DisplayCriteriaController.apply()` must be called BEFORE `replaceCurrentItem`.**

From the README (`Host setup on tvOS`):
> "tvOS 26.5 now enforces [the criteria ordering] synchronously at HLS variant validation: the validator rejects variants whose `VIDEO-RANGE` the panel can't currently host with `AVFoundationErrorDomain -11868`, before fetching the `EXT-X-MAP` init segment, producing `item.status = .failed` with zero `errorLog().events`."
> "SDR variants are unaffected."

And why AVKit-auto can't do this:
> "AVKit-auto criteria (`appliesPreferredDisplayCriteriaAutomatically = true`) cannot satisfy this for HLS multivariant HDR sources, because AVKit reads criteria from `AVAsset.preferredDisplayCriteria`, which is synthesized from the chosen variant's format description, which only exists after `init.mp4` is parsed, which only happens after the variant passes the validator. Chicken-and-egg."

**Required host setup:** `playerVC.appliesPreferredDisplayCriteriaAutomatically = false` (engine is the sole writer).

---

### `DisplayCriteriaController.apply()` mechanics

**Citation:** `Sources/AetherEngine/Display/DisplayCriteriaController.swift`

```swift
func apply(format: VideoFormat, frameRate: Double?, codecTag: FourCharCode?, omitColorExtensions: Bool) -> Bool {
    // ... guard tvOS 17+ and isDisplayCriteriaMatchingEnabled ...

    // Codec FourCC drives the HDMI mode:
    // 'hvc1' -> HDR10/HLG, 'dvh1' -> Dolby Vision.
    // Using HEVC for a DV source kept Philips panel in HDR10 instead of DV (P8 MKV).
    let dvh1: FourCharCode = 0x64766831
    let codecType: CMVideoCodecType = codecTag ?? (format == .dolbyVision ? dvh1 : kCMVideoCodecType_HEVC)

    // HDR: attach BT.2020 + transfer function + matrix extensions
    let extensions: NSDictionary? = (isHDR && !omitColorExtensions) ? [
        kCMFormatDescriptionExtension_ColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_2020,
        kCMFormatDescriptionExtension_TransferFunction: transferFunction,  // PQ or HLG
        kCMFormatDescriptionExtension_YCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_2020,
    ] : nil

    CMVideoFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        codecType: codecType,
        width: 3840, height: 2160,
        extensions: extensions,
        formatDescriptionOut: &formatDesc
    )
    let criteria = AVDisplayCriteria(refreshRate: effectiveRate, formatDescription: desc)
    displayManager.preferredDisplayCriteria = criteria
    // ...
    return isHDR   // signals caller to call waitForSwitch()
}
```

Key decisions in `apply()`:
- **SDR sources still get a criteria write** (rate-only, no color extensions) so Match Frame Rate fires — a prior version early-returned for SDR and MFR never fired.
- **`dvh1` FourCC (0x64766831) is mandatory for DV**: passing `kCMVideoCodecType_HEVC` for a DV source kept a Philips panel in HDR10 instead of DV mode.
- **Transfer function for HLG** uses `kCVImageBufferTransferFunction_ITU_R_2100_HLG` (not PQ) — collapsing both to PQ caused wrong EOTF.
- **Fixed resolution 3840×2160** is passed to `CMVideoFormatDescriptionCreate` — the actual content resolution is irrelevant for the display mode switch.

---

### `waitForSwitch()` — the two-stage blocking poll

```swift
func waitForSwitch() async {
    // Stage 1: 100 × 10ms = 1000ms budget, wait for isDisplayModeSwitchInProgress
    // (HDMI handshake starts asynchronously; can be false for a beat)
    for _ in 0..<100 {
        if displayManager.isDisplayModeSwitchInProgress { sawSwitchStart = true; break }
        if screen.currentEDRHeadroom > 1.001 { return }   // already in HDR
        try? await Task.sleep(for: .milliseconds(10))
    }
    // Stage 2: 50 × 100ms = 5s settle
    for tick in 0..<50 {
        try? await Task.sleep(for: .milliseconds(100))
        if !displayManager.isDisplayModeSwitchInProgress {
            // Validate: headroom > 1.001 = success; headroom 1.0 on HDR request = failure
            return
        }
    }
    // 5s timeout: proceed anyway
}
```

**Why two stages?** The HDMI handshake initiates asynchronously: `isDisplayModeSwitchInProgress` can be `false` for up to ~100ms after the `preferredDisplayCriteria` write. A single-check guard race on DV8.1 → AVPlayer caused `-11848`. The 1000ms Stage 1 also accommodates the AVKit-sole-writer path which fires even later.

**The `-11868` guard:** `didApply` and `lastCriteriaWasHDR` track whether the engine wrote criteria; `reset()` is gated on `didApply` to prevent nil-writing a criteria managed by AVKit on `suppressDisplayCriteria=true` sessions, which would collapse EDR headroom to 1.0 and cause the validator to fail.

---

### `FrameRateSnap` — rate selection

**Citation:** `Sources/AetherEngine/Display/FrameRateSnap.swift`

```swift
static let standard: [Double] = [23.976, 24, 25, 29.97, 30, 48, 50, 59.94, 60]

// Film-cadence shortcut: 23.5 .. 24.05 → 23.976
// (24.000 probes also sent as 23.976: panels supporting 24 also support 23.976; reverse not guaranteed)
if raw >= 23.5 && raw <= 24.05 { return 23.976 }
```

Real-world sources probe at 23.97–23.98 due to container rounding; snapping to `23.976` is intentional. The ±0.5 fps tolerance covers minor probe rounding for all other rates.

### LESSON FOR PLOZZ (Q3)
In Plozz's `load(url:)` flow: (1) set `appliesPreferredDisplayCriteriaAutomatically = false`, (2) call `DisplayCriteriaController.apply()` with `dvh1` FourCC for DV content or `kCMVideoCodecType_HEVC` for HDR10/HLG, (3) `await waitForSwitch()` using the two-stage poll (1000ms Phase 1, 5s Phase 2), (4) only then call `replaceCurrentItem`. Don't skip the write for SDR — include it for Match Frame Rate. EDR headroom > 1.001 is the only authoritative way to confirm panel mode.

---

## Q4 — ATMOS / AUDIO STREAM-COPY: EAC3+JOC fMP4, `dec3` box, and the 3-tier cascade

### The cascade: stream-copy → bridge → video-only

**Citation:** `Sources/AetherEngine/Video/HLSVideoEngine+AudioRoute.swift`, `buildProducerWithAudioCascade()`

**Tier 1: Stream-copy** (lossless, preserves Atmos JOC):
- Eligible codecs: AAC, AC3, **EAC3** (including JOC), FLAC, ALAC.
- **EAC3+JOC detection:** `stream.pointee.codecpar.pointee.profile == 30` (FFmpeg `FF_PROFILE_EAC3_JOC = 30`).
- **MKV dec3 problem:** Matroska `CodecPrivate` rarely carries the pre-parsed `dec3` box that `avformat_write_header` needs for the EAC3 sample entry. The solution: **`+delay_moov` mux flag** (alongside `+empty_moov+default_base_moof+frag_custom`) defers the `moov` atom until the first fragment flush, by which time libavformat's `handle_eac3` has populated the sample-entry boxes from actual packet bitstream parsing.
- **Pre-flight probe:** Before creating the full producer, `MP4SegmentMuxer.probeWriteHeader()` is called to test whether `avformat_write_header` would succeed. If it fails with `-22 EINVAL` ("Cannot write moov atom before EAC3 packets parsed"), the cascade falls to Tier 2.

```swift
// EAC3 profile=30 is the JOC marker; any stream-copy->FLAC fallback silently loses Atmos.
let sourceIsAtmos: Bool = {
    guard let stream = sourceAudioStream else { return false }
    return stream.pointee.codecpar.pointee.codec_id == AV_CODEC_ID_EAC3
        && stream.pointee.codecpar.pointee.profile == 30
}()
```

On successful stream-copy, the engine emits:
> `"EAC3+JOC Atmos: stream-copy engaged; DD+/JOC bitstream preserved for the downstream renderer (HDMI passthrough / AirPods spatial; plain Bluetooth A2DP / LE downmixes natively)"`

**Tier 2: AudioBridge** — for TrueHD, DTS, DTS-HD MA, MP3, Opus, Vorbis, PCM, MP2, AAC-LATM:
- Mode `.surroundCompat` (default): EAC3 at **128 kbps/channel** (256 kbps stereo, 768 kbps 5.1), max 6 channels. AVPlayer tunnels the bitstream via HDMI.
- Mode `.lossless`: FLAC up to 8 channels. AVPlayer decodes to LPCM. Needs a multichannel-LPCM sink.
- **Atmos lost in both modes**: FFmpeg's EAC3 encoder produces no JOC; FLAC has no object-channel concept. A loud warning is emitted if JOC ever falls through.
- **7.1 cap**: EAC3 mode silently caps at 6 channels (SL/SR dropped from 7.1). `av_channel_layout_default(&encLayout, nChannels)` with `nChannels = min(sourceChannels, maxEncodedChannels)`.

**Tier 3: Video-only** — only if bridge init throws or `avformat_write_header` fails for bridge output too. Illegal if a `sideAudioDemuxer` companion is present.

---

### `dec3` box construction (formats.md)

> "Matroska CodecPrivate doesn't usually carry the pre-parsed `dec3` / `dac3` box content the mov muxer needs at `avformat_write_header` time, so the muxer is configured with `+delay_moov`... The moov atom is deferred until the first fragment-cut flush, by which point packets have flowed through `mov_write_packet` and libavformat's `handle_eac3` / `handle_ac3` have populated the sample-entry boxes from the actual packet bitstream."

**`dec3` box for JOC recognition by AVPlayer (formats.md):**
> "AVPlayer reads the segment, recognises JOC from the `dec3` box (`numDepSub=1`, `depChanLoc=0x0100`)..."

The `dec3` box must have `numDepSub=1` and `depChanLoc=0x0100` for AVPlayer to recognize Atmos. With `+delay_moov`, libavformat builds this automatically from parsed EAC3 bitstream headers — no manual box construction.

---

### `AudioChannelLayout` and 5.1/7.1

`AudioBridge` uses `av_channel_layout_default(&encLayout, nChannels)` for the encoder, which generates the FFmpeg default layout for n channels. The resulting `AVCodecParameters` passed to the muxer carries the correct channel count; the fMP4 sample entry then declares the correct channel count for AVPlayer's `AudioChannelLayout` assignment. The channel-count resolution priority:
1. `srcCodecpar.ch_layout.nb_channels` (container header — most reliable)
2. `dec.ch_layout.nb_channels` (decoder at `avcodec_open2`)
3. Stereo fallback (with a loud log — note: TrueHD/MLP in MKV often skips container channel count)

**HE-AAC stream-copy rule** (from `HLSVideoEngine+SegmentPlanning.swift`):
> "HE-AAC (SBR, profile=4) and HE-AACv2 (PS, profile=28) stream-copy cleanly when an ASC is present (MP4 esds, MKV CodecPrivate). Bridge only when ASC is absent (live ADTS/MPEG-TS)."

### LESSON FOR PLOZZ (Q4)
For EAC3+JOC (Atmos) from MKV: use `+delay_moov` mux flag so libavformat's `handle_eac3` builds the `dec3` box from live packet parsing rather than CodecPrivate. Pre-flight the `avformat_write_header` call before committing to stream-copy; fall back to EAC3 bridge (not FLAC) as the first fallback since it preserves HDMI bitstream routing. The 5.1 cap on the EAC3 encoder bridge is by design — accept it. Always detect JOC by `profile == 30` (not by channel count or stream description), and log loudly if JOC hits the bridge path.

---

## Q5 — HTTP-RANGE I/O: Three Modes, Reconnect, Backward Seek, Probesize

### The three modes

**Citation:** `Sources/AetherEngine/Demuxer/AVIOReader.swift`, `read()` dispatch:

```swift
fileprivate func read(into buf: UnsafeMutablePointer<UInt8>, size: Int32) -> Int32 {
    if usePersistentReader { return readPersistent(into: buf, size: size) }
    if isStreaming         { return readStreaming(into: buf, size: size) }
    return readSeekable(into: buf, size: size)
}
```

#### Mode 1: **Persistent** (playback path — `prefetchEnabled=true` + known size OR live feed)

Single long-lived `Range: bytes=<pos>-` GET into a **sliding window** (`window: Data`, `winStart: Int64`).

- Window high-water mark: **16 MB** (`winHighWater`). Backpressure: delivery task suspended above this, resumed below 32 MB `streamLowWater` (wait, those are for streaming mode).
- Lookback: **2 MB** behind cursor retained for small Matroska backward re-reads (`winLookback`).
- Trim: in **4 MB batches** to avoid O(n²) `memmove` (`winTrimBatch`). Uses `subdata()` not `removeFirst()` — the latter only advances the slice lower bound, causing ~14 MB/s backing-storage leak on 80 Mbps remux (issue #31).
- **Stall timeout:** `connStallTimeout = 20s`. A `winCond.wait(until:)` with this deadline; stall triggers reconnect at the frontier.
- **Reconnect on drop:** `startPersistentConnection(at: frontier)`. Not `seekReconnect` (which resets the unproductive counter); unplanned reconnects increment `unproductiveReconnects`.
- **Reconnect cap:** 12 consecutive unproductive reconnects → give up. Live feeds return `AVERROR_EIO` instead of EOF. `minReconnectProgress = 512 KB` resets the streak.
- **Rate-limit (429/503):** separate `rateLimitStreak` counter (survives `seekReconnect`, so parse-driven seeks can't mask throttled origin — issue #71). Cap: 6. Honour `Retry-After` header.
- **CDN redirect caching:** resolved URL cached in `_resolvedURL`, invalidated on 401/403/404/410.
- **Unplanned reconnect timestamp:** `lastUnplannedReconnectAt` exposed to the producer to detect Jellyfin transcode respawn (re-serves from byte 0 on a re-GET).

**Open-time size resolution** (issue #70): the `Range: bytes=0-` open request itself is the size probe — its 206 `Content-Range` response resolves `fileSize`. If the response doesn't contain a size (some origins return no `Content-Range`), `resolveOptimisticOpen()` atomically abandons the connection and falls back to a dedicated HEAD+Range probe.

#### Mode 2: **Seekable Chunked** (`prefetchEnabled=false`, known size — still/frame extraction)

Discrete `Range: bytes=<pos>-<pos+chunkSize>` GETs. Default chunk size: **4 MB**. For still extraction: 1 MB chunk, 8s request timeout, 1 retry (`DemuxerOpenProfile.stillExtraction`).

Prefetch: triggered when >50% of current chunk is consumed; speculative next-chunk fetch. Disabled for random-access (frame extraction) since the next read position is unpredictable.

**For backward seeks in seekable mode:** the current buffer is simply abandoned and a new `fetchChunk(from: newPosition, size: chunkSize)` is issued. No reconnect concept — each chunk is independent.

#### Mode 3: **Streaming** (`fileSize <= 0` — unknown-length source, sequential GET)

Single sequential GET, no reconnect machinery. **Trim threshold: 1 MB** behind cursor (`streamTrimThreshold`). Backpressure: task suspended above **64 MB** high-water (`streamHighWater`), resumed below 32 MB (`streamLowWater`).

---

### Backward / far-forward seeks in persistent mode

**Citation:** `Sources/AetherEngine/Demuxer/AVIOReader.swift`, `readPersistent()`:

```swift
if curPosition < winStart {
    // Backward random-access read (MP4 parse ping-pong, or large backward scrub).
    // Serve via the pooled detour cache so the anchored streaming connection is NOT torn down.
    if detourEligible {
        switch serveFromDetour(into: ..., at: curPosition, allowFetch: true) {
        case .served(let n): /* hit */ continue
        case .rateLimited:   /* backoff, retry detour */ continue
        case .miss:          seekReconnect(at: curPosition)
        }
    }
    seekReconnect(at: curPosition)
    continue
}
// ...
if curPosition > frontier + Int64(Self.seekKeepForwardLimit) {  // 8 MB
    // Far-forward: try detour cache (no fetch), then reconnect.
    seekReconnect(at: curPosition)
}
```

**Detour block cache** (issue #69): an LRU cache of **4 MB aligned blocks**, max **8 blocks (~32 MB)**. Serves non-sequential reads (MP4 moov parse ping-pong) from the `chunkSession` (pooled keep-alive connection) without tearing down the main streaming connection. The streaming connection stays **anchored**; only genuine forward-scrub seeks miss the cache and issue `seekReconnect`. Once detour reads turn sequential for **8 MB** (`detourReanchorBytes`), the streaming connection is re-anchored there, returning to the cheap window path.

**Forward seeks within `seekKeepForwardLimit = 8 MB`**: wait on `winCond` for the live connection to fill forward. No new connection.

**Backward scrub / `seekReconnect`:** closes the current connection and opens a new `Range: bytes=<newPos>-` GET. **Resets** `unproductiveReconnects = 0` (intentional seek, not a drop).

---

### Probesize and first-frame latency

**Citation:** `Sources/AetherEngine/Demuxer/Demuxer.swift`, `DemuxerOpenProfile`:

```swift
static let playback = DemuxerOpenProfile(
    probesize: 50 * 1024 * 1024,         // 50 MB
    maxAnalyzeDuration: 60 * 1_000_000,  // 60 seconds
    avioPrefetch: true,
    avioChunkSize: 4 * 1024 * 1024,
    avioRequestTimeout: 35,
    avioMaxRetries: 3
)

static let stillExtraction = DemuxerOpenProfile(
    probesize: 2 * 1024 * 1024,         // 2 MB
    maxAnalyzeDuration: 2 * 1_000_000,  // 2 seconds
    ...
    avioChunkSize: 1 * 1024 * 1024,
    avioRequestTimeout: 8,
    avioMaxRetries: 1
)
```

Comment: "Default 5 MB/5s budgets miss sparse PGS/DVB tracks on 10-20 GB Blu-ray rips. 50 MB/60s ensures codec params are populated without noticeably slowing open."

Callers can override per session via `LoadOptions.probesize` / `maxAnalyzeDuration` to cut first-frame latency on remote remuxes (a smaller budget is sufficient if the source is well-formed fMP4 with front-loaded `moov`).

**`avformat_find_stream_info` cover-art optimization** (issue #75): streams flagged `AV_DISPOSITION_ATTACHED_PIC` are reclassified to `AVMEDIA_TYPE_ATTACHMENT` before `find_stream_info`. This makes `has_codec_parameters` return `true` without a decoder, preventing the probe from consuming the full 50 MB budget on unresolvable mjpeg cover art streams.

**`fflags=+genpts`:** applied to every open via `applyDemuxerOptions`. Comment: "what Jellyfin's server-side remux uses. Cuts 4K HDR HEVC RSS growth ~50%."

### LESSON FOR PLOZZ (Q5)
For Plozz's localhost HLS server the AVIOReader pattern isn't directly applicable (it's localhost), but the principles are: (1) for the remote source fetch side, use a persistent forward-streaming connection with a sliding window and detour block cache for backward reads; (2) for the remux side, use 50 MB / 60s probesize defaults but expose a `LoadOptions` override for fast-start on well-formed fMP4 sources; (3) reclassify attached-picture streams before `find_stream_info`; (4) use `fflags=+genpts`.

---

## Q6 — OTHER TVOS DV/ATMOS GOTCHAS

### 1. `hvc1` vs `dvh1` for HLG-base DV

> "`dvh1` sample entry is never valid for HLG-base (AVPlayer rejects it, DrHurt#4 Build 160). `hvc1` + SUPPLEMENTAL `dvh1.08.XX/db4h` is the only valid form for P8.4."

`dvh1` is only valid as the primary sample entry for P5 (DV-only, no base layer) and as the SUPPLEMENTAL value for P8.x. Using `dvh1` as the sample entry for HLG-base content causes AVPlayer rejection.

---

### 2. The `-11868` validator failure matrix (tvOS 26.5)

From `CodecRoutePolicy.swift` comments and README:
- **`dvh1.05.XX` in a multivariant master playlist on a non-DV panel:** `-11868`. Fix: serve P5 only from a dedicated media playlist.
- **`hvc1` + `dvvC` box on a non-DV panel (P8.1 or P8.4):** `-11868`, even without `SUPPLEMENTAL-CODECS`. Fix: strip `dvvC` on non-DV panels (`stripDolbyVisionMetadata = true`).
- **P8.6 (malformed `compat != 1`) on DV panel without `rewriteDoviConfigTo81`:** uncertain, noted as issue #53. Fix: normalize to `compat=1` in the `dvcC` box.

---

### 3. P5 IPT-PQ-c2 color cast (AetherEngine#4, DrHurt#19)

> "Without `dvh1` the IPT chroma reads as YCbCr (green/purple cast)."

P5 encodes color in IPT-PQ-c2 (Dolby's color space, not BT.2020). If the stream is tagged as `hvc1` (HEVC), AVPlayer processes it as BT.2020 YCbCr-PQ, producing a green/purple cast. `dvh1` tag tells the system compositor to invoke the DV decoder/tonemapper which correctly handles IPT-PQ-c2. **This applies even on SDR panels** — which is why P5 always gets `dvh1`.

---

### 4. EAC3 `dec3` box variants

From `docs/formats.md`:
> "AVPlayer reads the segment, recognises JOC from the `dec3` box (`numDepSub=1`, `depChanLoc=0x0100`)."

The `dec3` box encodes EAC3-specific metadata. For Atmos recognition, AVPlayer specifically needs `numDepSub=1` and `depChanLoc=0x0100`. The `+delay_moov` technique gets libavformat to build this from actual packet bitstream rather than from (often absent) Matroska CodecPrivate.

---

### 5. DTS-HD MA FLTP vs S32P mismatch (AudioBridge comment, issue #66)

> "An earlier fix routed DTS through the `dca_core` bitstream filter... but that (a) discarded lossless XLL for streams that decode fine (#66) and (b) on a stripped standalone core the decoder takes the FLOAT path (FLTP), mismatching the S32P input swr is seeded with from the probe → garbled audio."

The fix: decode DTS-HD MA **full stream** (not just the core). The resampler input config is re-derived from each decoded frame (`resampleAndPushIntoFIFO` re-seeds `swrInFmt` from the actual frame), not just from the probe.

---

### 6. ADTS AAC from MPEG-TS: synthesized AudioSpecificConfig

From `HLSVideoEngine+SegmentPlanning.swift`, `prepareAACForFMP4()`:
- ADTS AAC has no `extradata` — the `mp4a`/`esds` sample entry can't be written without an `AudioSpecificConfig`.
- A 2-byte ASC is synthesized from `sample_rate` (via frequency table lookup) and channel count.
- `audioObjectType` = `profile + 1` (AAC-LC = 2), with a safe fallback to 2 for unknown profiles.
- 7-channel AAC has no ASC representation → bridge. 8-channel maps to `chanConfig=7`.
- HE-AAC (profile=4) with a synthesized ASC is wrong: it declares LC at the SBR output rate, causing `-11821` in AudioToolbox. **Bridge only HE-AAC when ASC is absent.**

---

### 7. DV Profile 8.1 `db1p` vs. generic SUPPLEMENTAL

From `CodecRoutePolicy.swift`:
> "`db1p` required; without it AVPlayer treats variant as plain HDR10 and DV never engages."

The SUPPLEMENTAL-CODECS tag `"dvh1.08.XX/db1p"` — the `/db1p` suffix is a mandatory indicator that this is a DV BL+RPU stream with HDR10-compatible base. Its absence causes AVPlayer to treat the `hvc1` track as plain HDR10 even when a `dvvC` box is present. `db4h` is the corresponding suffix for HLG-base (P8.4).

---

### 8. In-band VPS/SPS/PPS for DV P5 WEB-DL encodes (issue #19)

From `HLSVideoEngine+SegmentPlanning.swift`, `rebuildHEVCExtradataWithInBandParameterSets()`:
> "Scan packets for in-band VPS/SPS/PPS when hvcC `numOfArrays=0` (DV P5 MP4 encoders, e.g. Wandering Earth 2 WEB-DL). AVPlayer symptom: `item.tracks count=2`, `fourCC=<no fdesc>`, `CoreMediaErrorDomain -4`."

Some DV P5 MP4 encodes write `hvcC` with `numOfArrays=0` and put VPS/SPS/PPS in-band in the first packets. The fix: detect `numOfArrays=0`, scan up to 16 packets for NAL types 32 (VPS), 33 (SPS), 34 (PPS), then rebuild the `hvcC` extradata block with the parameter sets.

---

## WHAT PLOZZ SHOULD ADOPT — 5-Bullet Summary

1. **DV Playlist Signaling:** Use `hvc1.2.4.L<level>` + `SUPPLEMENTAL-CODECS="dvh1.08.XX/db1p"` only when `currentEDRHeadroom > 1.001` (panel confirmed in DV mode post-`waitForSwitch`). Strip the `dvvC` box on non-DV panels to avoid `-11868`. For P5 always use `dvh1.05.XX` as primary CODECS but never in a multivariant master on non-DV panels. Never use `dvh1` as primary sample entry for HLG-base content. Include `db1p` / `db4h` suffix in SUPPLEMENTAL — AVPlayer ignores DV without it.

2. **P7→8.1 RPU Conversion:** Integrate libdovi and apply `dovi_convert_rpu_with_mode(rpu, 2)` per-packet in the remux loop: parse AVCC NAL units, convert type-62 RPUs, drop type-63 EL NALs, rewrite the `dvcC` box in `init.mp4` to `profile=8, compat=1`. This is zero-cost relative to any existing decode pass and makes P7 UHD-BD remuxes actually display DV on tvOS.

3. **Display Criteria Ordering:** Set `appliesPreferredDisplayCriteriaAutomatically = false`. Before calling `replaceCurrentItem`, write `preferredDisplayCriteria` with `dvh1` FourCC (0x64766831) for DV or `kCMVideoCodecType_HEVC` for HDR10/HLG, plus BT.2020/PQ (or HLG) extensions for HDR. Use the two-stage async poll: 1000ms/10ms ticks to detect handshake start, then 5s/100ms settle wait. Confirm success via `currentEDRHeadroom > 1.001`. Also write criteria for SDR sources (rate-only, no extensions) to engage Match Frame Rate.

4. **EAC3+JOC Atmos Stream-Copy:** Configure the fMP4 muxer with `movflags=+delay_moov+empty_moov+default_base_moof+frag_custom`. Detect JOC by `codec_id == EAC3 && profile == 30`. Pre-flight `avformat_write_header` before committing to stream-copy; on failure fall back to EAC3 bridge (128 kbps/channel, max 6ch). Verify the resulting `dec3` box has `numDepSub=1, depChanLoc=0x0100` for HDMI Atmos passthrough. Never re-encode EAC3+JOC through a bridge — object metadata is irrecoverably lost.

5. **HTTP-Range I/O and Probesize:** For the source (MKV) fetch side: use a single persistent `Range: bytes=<pos>-` forward-streaming connection with a 16 MB sliding window, reconnect-on-drop (20s stall timeout), a 4 MB detour block cache (8-block LRU) for backward parse reads, and `seekReconnect` for explicit backward scrubs. For `find_stream_info`: use 50 MB / 60s defaults; reclassify `AV_DISPOSITION_ATTACHED_PIC` streams to `AVMEDIA_TYPE_ATTACHMENT` before the probe call; expose a `probesize` override for fast-start on well-formed sources. Apply `fflags=+genpts` universally.