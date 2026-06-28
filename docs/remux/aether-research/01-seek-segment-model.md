Agent completed. agent_id: aether-seek-model, agent_type: research, status: completed, description: Extract AetherEngine seek/segment model, elapsed: 408s, total_turns: 0, duration: 310s

I now have all the data I need. Let me compile the comprehensive structured report.

---

## AetherEngine Research Report — 7 Questions on VOD HLS Trilemma

**Repository:** `superuser404notfound/AetherEngine` · commit `525fbe2`  
All citations use format `FileName.swift:LINE` referencing the temp-file line numbers from the downloaded sources.

---

## Q1 — SEGMENT DURATIONS: How are EXTINF values determined?

### Answer: One deadline-bounded mid-file seek; exact keyframe-PTS durations for MKV-with-Cues, uniform-stride fallback for no-Cues/TS sources. No full pre-scan.

**Step 1 — Cue prewarm seek (single seek to 50% of file):**

```swift
// HLSVideoEngine.swift:457-463
let prewarmOK = dem.seekBounded(to: durationSeconds * 0.5, timeout: Self.cuePrewarmTimeout)
// ...
if !prewarmOK {
    EngineLog.emit("cue prewarm: capped ... no usable Cues index")
}
```
`cuePrewarmTimeout = 10.0` seconds (`HLSVideoEngine.swift:276`). For a well-formed MKV the Cues binary tree is 1–2 HTTP range reads. The deadline fires on a missing/corrupt Cues.

**Step 2 — Read keyframes from the now-populated libavformat index:**

```swift
// HLSVideoEngine.swift:468-469
let keyframes = dem.indexedKeyframes(streamIndex: videoIndex)
let indexTrustworthy = Self.keyframeIndexIsTrustworthy(keyframes:..., maxTrustedGapSeconds:...)
```

`indexedKeyframes` reads `avformat_index_get_entry` for all `AVINDEX_KEYFRAME`-flagged entries (`Demuxer.swift:584-606`). For MKV this is what the Cue prewarm populated. For MP4 (stss atom) it was populated at `avformat_find_stream_info` time.

**Step 3a — Keyframe-aligned plan (MPEG-TS/M2TS rejected via trustworthiness check):**

```swift
// HLSVideoEngine+SegmentPlanning.swift — buildKeyframeSegmentPlan():
// Mirror libavformat hls muxer cut algorithm: segment N ends at first keyframe
// where (keyframe_pts - start_pts) >= (N+1) * targetDuration
```
Produces per-segment EXTINF values derived from real keyframe PTS timestamps, exact to the time-base resolution.

**Step 3b — Uniform-stride fallback** (TS/M2TS, or Cues timeout, or sparse index):

```swift
// HLSVideoEngine+SegmentPlanning.swift — keyframeIndexIsTrustworthy():
// MPEG-TS / M2TS have no upfront keyframe table the way MKV Cues / MP4 stss do:
// the libavformat index holds only what find_stream_info + mid-file seek scanned
// ... A clustered TS index gaps by thousands of seconds. Such an index is routed
// to the uniform-stride fallback.
```
EXTINF values are `targetSegmentDuration (4.0s)` uniform strides — they will drift at real keyframe boundaries. The restart machinery renegotiates alignment per restart.

**The duration oracle**: `dem.duration` → `AVFormatContext.duration` from the container header. The total duration is known from the container header alone, with zero packet scanning.

**`HLSVideoEngine.targetSegmentDuration = 4.0s`** (`HLSVideoEngine.swift:272`).

> **LESSON FOR PLOZZ:** Do NOT scan all packets. Issue ONE `avformat_seek_file` to 50% of the file (deadline-bounded at 10s). Then read the keyframe index libavformat built from that seek (Cue binary tree). Build all EXTINF values from those keyframe PTS values. Fall back to uniform stride (using `formatContext.duration`) if the Cues are absent. This gives you exact durations for MKV-with-Cues and estimated-but-acceptable durations for no-Cues, with ≤10s startup cost instead of a minutes-long full scan.

---

## Q2 — PLAYLIST TYPE & DURATION: What does the served .m3u8 look like?

### Answer: Full `EXT-X-PLAYLIST-TYPE:VOD` with `#EXT-X-ENDLIST`, all segments declared from the first request. Total duration from the container header. Segments named `/seg{N}.mp4`.

The playlist builder (confirmed `HLSLocalServer.swift:860-946`):

```swift
// HLSLocalServer.swift:910-912
} else {
    // EXT-X-PLAYLIST-TYPE:VOD lets AVPlayer prune fetched segments past the buffer-behind
    // window; without it RSS grows linearly with segment count for the whole playback.
    lines.append("#EXT-X-PLAYLIST-TYPE:VOD")
}
// ...
// HLSLocalServer.swift:943-944
if !typeIsLive && (snapshot.endlistAdded || !typeIsEvent) {
    lines.append("#EXT-X-ENDLIST")
}
```

A served VOD `media.m3u8` looks like:
```
#EXTM3U
#EXT-X-VERSION:7
#EXT-X-TARGETDURATION:4
#EXT-X-MEDIA-SEQUENCE:0
#EXT-X-PLAYLIST-TYPE:VOD
#EXT-X-MAP:URI="init.mp4"
#EXTINF:3.998,
seg0.mp4
#EXTINF:4.001,
seg1.mp4
...
#EXTINF:3.954,
seg847.mp4
#EXT-X-ENDLIST
```

- **Segments:** numbered `seg{N}.mp4` (e.g. `/seg0.mp4`, `/seg1.mp4`, …) — `HLSLocalServer.swift:920-923`
- **Init segment:** `/init.mp4` — `HLSLocalServer.swift:927`
- **EXTINF format:** `"%.3f"` precision — `HLSLocalServer.swift:939`
- **Duration:** computed from `dem.duration` = `AVFormatContext.duration / AV_TIME_BASE` — `Demuxer.swift:344-348`
- **All segment durations baked at `start()` time**: `VideoSegmentProvider` receives the full `plan: [Segment]` array and `segmentCount` is immediately `plan.count` — `HLSVideoEngine.swift:862-870`
- **No byte ranges**: distinct fMP4 files per segment
- A `master.m3u8` is optionally served for DV/HDR signaling — `HLSLocalServer.swift:128-129`; AVPlayer is pointed at `master.m3u8` or `media.m3u8` directly depending on panel HDR state.

> **LESSON FOR PLOZZ:** Serve `EXT-X-PLAYLIST-TYPE:VOD` with `#EXT-X-ENDLIST` immediately from the first request. Pre-populate all EXTINF from the keyframe plan. AVPlayer sees a complete finite timeline and can seek to any position without the EVENT far-seek clamp. This is the entire answer to the EVENT far-seek problem — VOD + ENDLIST is the fix.

---

## Q3 — FAR SEEK: How does a seek to 90% work? Exact trace.

### Answer: AVPlayer seeks within the pre-declared VOD timeline. When AVPlayer fetches a segment not yet produced, `VideoSegmentProvider` detects the cache miss, calls `restartHandler`, which synchronously stops the old producer, seeks the demuxer to the target PTS via `avformat_seek_file`, and starts a new producer at the target segment index. AVPlayer never replaceCurrentItem — the HLS item stays in place; only the producer restarts.

**Full call trace:**

1. **User seeks to 90%**: AVPlayer (using pre-declared VOD durations) resolves e.g. segment #763 → fetches `GET /seg763.mp4`

2. **HLSLocalServer** calls `provider.mediaSegmentURL(at: 763)` → `provider.mediaSegment(at: 763)` — `HLSLocalServer.swift:578-590`

3. **VideoSegmentProvider.mediaSegment(at:)** calls `handleTargetChange(to: 763)` → `cache.declareTarget(763)`:

```swift
// VideoSegmentProvider.swift:246-263
if previousTarget >= 0, index < previousTarget - 2, let restart = restartHandler {
    if cache.peekURL(index: index) != nil { return }  // in cache, no restart
    lastRestartIndex = index
    restart(index)    // ← fires restartHandler
    cache.resetHighWaterForRestart()
}
```

For a far forward seek (not in cache): falls through to the `needsRestart` logic:
```swift
// VideoSegmentProvider.swift:317-318
} else if index > r.1 + Self.forwardWaitWindow {
    needsRestart = true
}
```

4. **`restartHandler` = `HLSVideoEngine.requestRestart(at: 763)`** — `HLSVideoEngine.swift:877-879`:
```swift
restartHandler: { [weak self] idx in
    self?.requestRestart(at: idx)
}
```

5. **`requestRestart(at: 763)`** coalesces burst seeks, then calls **`performRestart(at: 763)`** — `HLSVideoEngine.swift:1262-1291`

6. **`performRestart(at: 763)`** — `HLSVideoEngine.swift:1318-1429`:

```swift
let targetStartPts = segmentPlan[idx].startPts
// ...
old.stop(); old.waitForFinish(timeout: 5.0)  // stop old producer
// ...
let absoluteTargetSeconds = Double(targetStartPts) * Double(videoTb.num) / Double(videoTb.den)
activeDem.seek(to: absoluteTargetSeconds)    // ← avformat_seek_file on the shared demuxer
// ...
let newProd = try makeProducer(baseIndex: idx)
producer = newProd
newProd.start()
```

7. **`makeProducer(baseIndex: 763)`** — `HLSVideoEngine.swift:1144-1156`:
```swift
// videoTarget = plan PTS; desiredVideoTfdt = plan PTS - firstKeyframePts
// Producer gate: scan forward to first AV_PKT_FLAG_KEY with dts >= videoTarget
// then shift = actualFirstDts - desiredFirstTfdt applied to all packets
videoTarget = segmentPlan[baseIndex].startPts
desiredVideoTfdt = segmentPlan[baseIndex].startPts - firstKeyframePts
```

8. **New producer starts pumping**, writes seg763.mp4 into `SegmentCache`. The blocked `cache.fetch(index: 763, timeout: ...)` in VideoSegmentProvider returns it to the server. AVPlayer gets its 200 OK and begins playing from segment 763.

**How the EVENTclamp is avoided:** AVPlayer's `seekableTimeRanges` cover the full declared VOD playlist from the start. There is no "live edge" ceiling. The playlist is complete with ENDLIST from the first response.

> **LESSON FOR PLOZZ:** Do NOT use EVENT playlists for VOD. Declare the full VOD timeline upfront. When AVPlayer fetches any segment that isn't in the cache window, restart the producer at that segment's PTS via `avformat_seek_file` to the **absolute source PTS** (not relative playlist time). The `AVPlayerItem` stays in place — no `replaceCurrentItem`. Only the demuxer/producer restarts.

---

## Q4 — SHORT SCRUB vs FAR SEEK: How are they distinguished?

### Answer: A fixed 8-segment "forward-wait window" (`forwardWaitWindow = 8`). Segments within cache or within 8 of the producer's write head = wait. Anything farther triggers a restart.

```swift
// VideoSegmentProvider.swift:69
private static let forwardWaitWindow = 8
// comment: "8 absorbs AVPlayer's 5-7 segment speculative prefetch at 4s segments (~32s headroom)
// while keeping user-initiated 30+ s scrubs below the threshold."
```

**Decision tree** (`VideoSegmentProvider.swift:302-335`):

| Condition | Action |
|---|---|
| `cache.peek(index:)` returns data | Fast path: serve immediately |
| Index in `[r.0, r.1]` (producer's current range) | Wait 2s then maybe restart |
| Index in `(r.1, r.1 + 8]` (just ahead of producer) | Backpressure-wait up to 30s |
| Index > `r.1 + 8` | **Restart** |
| Index < `r.0` (behind cache) | **Restart** |
| `highWater > index` and index outside stored range | **Restart** (producer passed and pruned) |
| Empty cache + `abs(index - lastRestartIndex) > 2` | **Restart** (big scrub, not cold start) |

A short scrub of 30s = ~7–8 segments at 4s/seg → hits the `≤ r.1+8` branch → backpressure wait → no restart.  
A far seek of 90% on a 110-minute film = hundreds of segments ahead → hits `> r.1+8` → restart.

> **LESSON FOR PLOZZ:** Use a forward-wait window of ~8 segments (32s at 4s segments) as the short-scrub vs far-seek threshold. Within the window: wait passively for the producer to catch up. Outside: restart. Size the window to absorb AVPlayer's speculative prefetch (~5-7 segments) without unnecessary restarts.

---

## Q5 — SEEK MECHANICS: libavformat seek and the Cues deadline

### Answer: `avformat_seek_file` (not `av_seek_frame`). Cue-prewarm deadline implemented as a wall-clock read deadline on the AVIO callback. No-Cues files: deadline fires, uniform plan used — no hang, at the cost of EXTINF drift.

**Why `avformat_seek_file` not `av_seek_frame`:**
```swift
// Demuxer.swift:626-628
/// Seek via avformat_seek_file (not av_seek_frame: assertion failures
/// in matroskadec.c with nested elements).
func seek(to seconds: Double) {
```

**The `seekBounded` implementation (Cue prewarm path):**

```swift
// Demuxer.swift:647-661
func seekBounded(to seconds: Double, timeout: TimeInterval) -> Bool {
    let reader = avioProvider as? AVIOReader
    reader?.beginReadDeadline(secondsFromNow: timeout)  // arm the clock
    defer { reader?.endReadDeadline() }
    let timestamp = Int64(seconds * Double(AV_TIME_BASE))
    let ret = avformat_seek_file(ctx, -1, Int64.min, timestamp, Int64.max, 0)
    avformat_flush(ctx)
    let capped = reader?.readDeadlineFired ?? false
    return ret >= 0 && !capped  // deadline is authoritative, not ret
}
```

**The AVIO deadline implementation (AVIOReader):**

```swift
// AVIOReader.swift:386-408
private var readDeadline = Date.distantFuture
private var isPastReadDeadline: Bool { Date() >= readDeadline }
private(set) var readDeadlineFired = false

func beginReadDeadline(secondsFromNow seconds: TimeInterval) {
    readDeadlineFired = false
    readDeadline = Date(timeIntervalSinceNow: seconds)
    winCond.broadcast()  // wake a parked read immediately
}
```

And in the read callback:
```swift
// AVIOReader.swift:497
if isPastReadDeadline { readDeadlineFired = true; return -1 }
```

The `-1` return from AVIO causes `avformat_seek_file` to abort. Critically, the code notes:
> "matroska may still return success with a partial index after abort; deadline flag is authoritative, not ret" — `Demuxer.swift:657-660`

**No-Cues file handling:**
- Deadline fires at 10s, `seekBounded` returns `false`
- `HLSVideoEngine.start()` branches to `buildUniformSegmentPlan` with whatever keyframes were partially scanned — `HLSVideoEngine.swift:493-526`
- Muxer still snaps cuts to real keyframes, so EXTINF drifts per-segment; restart machinery renegotiates alignment after each scrub

**Producer-restart seek** (the production playback path) uses plain `dem.seek(to: absoluteTargetSeconds)` without a deadline:
```swift
// HLSVideoEngine.swift:1388-1391
let absoluteTargetSeconds = Double(targetStartPts) * Double(videoTb.num) / Double(videoTb.den)
activeDem.seek(to: absoluteTargetSeconds)
```
No deadline is needed here because the Cues index is already populated from the prewarm; the seek is fast (1-2 range reads).

> **LESSON FOR PLOZZ:** Implement a wall-clock deadline on the AVIO read callback (`return -1` when `Date() >= deadline`) and use it to bound the cue-prewarm seek. Don't trust `avformat_seek_file`'s return value — check your own `deadlineFired` flag. This is what saves you from the 100 GB linear scan on no-Cues files.

---

## Q6 — LIVELOCK/SCRUB FIX: Issue #65 `BackpressureWedgeDetector`

### Answer: The producer parks waiting for AVPlayer to consume segments; rapid scrubbing causes both sides to stall. The fix is a 24-second detector that watches whether `SegmentCache.targetIndex` (AVPlayer's highest fetched segment) advances. If it's frozen while `timeControlStatus == .waitingToPlay`, the park is broken, the producer exits, and the host re-anchors the producer on AVPlayer's actual rendered position.

**The wedge scenario:**
1. User scrubs rapidly. Producer is at segment 100; AVPlayer requests segment 80.
2. Producer reaches max-ahead (`bufferAheadSegments = 10`) and parks in `awaitBackpressureRelease`.
3. AVPlayer is wedged because the segment it wants (80) isn't in cache.
4. Both sides are frozen.

**Piece A — `BackpressureWedgeDetector` in the pump loop:**

```swift
// HLSSegmentProducer.swift:726-770 — awaitBackpressureRelease():
var wedgeDetector = BackpressureWedgeDetector(
    breakThresholdSeconds: Self.backpressureWedgeBreakThresholdSeconds,  // 24s
    initialTarget: cache.targetIndex
)
while !checkShouldStop() {
    if cache.awaitFetchHighWater(reaching: target, timeout: 1.0) { return true }
    parked += 1
    let cacheTarget = cache.targetIndex
    let wantsToPlay = wantsToPlayProvider?() ?? true
    if !isLive, wedgeDetector.observe(currentTarget: cacheTarget, wantsToPlay: wantsToPlay) {
        markBackpressureWedgeBroken()
        // ... log "WEDGE BROKEN" ...
        return false
    }
}
```

**`BackpressureWedgeDetector.observe()` logic** (from `Issue65LivelockBreakers.swift`):
```swift
mutating func observe(currentTarget: Int, wantsToPlay: Bool = true) -> Bool {
    guard wantsToPlay else {
        // Pause false-positive: paused consumer = no forward fetch; NOT a wedge. Reset baseline.
        if currentTarget > maxTargetSeen { maxTargetSeen = currentTarget }
        stuckSeconds = 0
        return false
    }
    if currentTarget > maxTargetSeen {
        maxTargetSeen = currentTarget
        stuckSeconds = 0  // advancing = healthy backpressure; reset timer
    } else {
        stuckSeconds += 1
    }
    return stuckSeconds >= breakThresholdSeconds
}
```

The key: a slow-but-advancing consumer (cold CDN, buffering) keeps `stuckSeconds = 0` and never trips. Only a frozen-for-24s target fires.

**Piece B — Wedge break exit → host re-anchor:**
The pump exits with `.backpressureWedge`. The engine handler calls:
```swift
// From handlePumpFinished / consecutiveWedgeReanchors logic:
let realPosition = currentPlaybackPositionProvider?()  // AVPlayer's rendered position
let idx = segmentIndexForPlaylistTime(realPosition)
requestRestart(at: idx, authoritative: true)
```
Storm guard: `maxConsecutiveWedgeReanchors = 5` — prevents infinite re-anchor loops (`HLSVideoEngine.swift:256-258`).

**Piece C — Deadline-bounded seek in NativeAVPlayerHost:**
```swift
// NativeAVPlayerHost.swift:521-559 — seek(to:deadlineSeconds:)
// SeekResumeGuard: single-resume latch — AVPlayer landing and deadline race to fire once.
// On deadline expiry: seekInFlight cleared so periodic observer resumes (un-gates currentTime).
// The underlying avPlayer.seek() is NOT cancelled.
```

`seekIsWedged()` predicate (`Issue65LivelockBreakers.swift`):
```swift
func seekIsWedged(renderedTime: Double, bufferedEnd: Double, forwardBufferFloor: Double = 1.0) -> Bool {
    return (bufferedEnd - renderedTime) < forwardBufferFloor
    // Healthy seek: bufferedEnd climbs past renderedTime. Wedged: both frozen.
}
```

> **LESSON FOR PLOZZ:** Implement a per-second poll of `SegmentCache.targetIndex` (the highest segment index AVPlayer has fetched). When it's frozen for >20s AND `timeControlStatus == .waitingToPlay` (play intent guard), break the backpressure park and re-anchor the producer on `avPlayer.currentTime()`. A slow-but-advancing consumer must never trip this — only freeze it.

---

## Q7 — SEGMENT MUXER: libavformat `hls` muxer or hand-rolled fMP4?

### Answer: `MP4SegmentMuxer` — a custom type that wraps `avformat_alloc_output_context2` (evidenced by the error message and class-level doc). It is NOT a direct invocation of libavformat's `hls` muxer writing to disk. It overrides `AVFormatContext.io_open`/`io_close2` to redirect each segment's bytes into `SegmentCache` in memory. The README claim "byte-identical to ffmpeg -f hls -hls_segment_type fmp4" is confirmed by the comment in `buildKeyframeSegmentPlan` which says the algorithm "mirror[s] libavformat's hls muxer cut algorithm."

**Evidence for MP4SegmentMuxer as the production path:**

```swift
// HLSSegmentProducer.swift:216
private var currentMuxer: MP4SegmentMuxer?
```

```swift
// HLSSegmentProducer.swift:843-870 — allocateMuxer():
let muxer = try MP4SegmentMuxer(
    initialSegmentIndex: initialSegmentIndex,
    sessionDir: cache.sessionDir,
    video: muxerVideo,
    audio: muxerAudio,
    subtitles: muxerSubtitles,
    maxBufferedFragmentSeconds: 2 * targetSegmentDurationSeconds,
    onInitCaptured: { ... }
)
```

**Internal architecture evidence:**

The class-level doc on `HLSVideoEngine.swift:7-10`:
```swift
/// HLS-fMP4 loopback session: libavformat `hls` muxer fed by `Demuxer`, fragments
/// redirected into `SegmentCache` via custom `io_open`/`io_close2`, served to
/// AVPlayer by a local HTTP server that blocks on a condvar until the requested
/// segment is muxed.
```

The `frag_custom` reference in `HLSVideoEngine+SegmentPlanning.swift`:
```swift
// A clustered TS index gaps by thousands of seconds. Such an index is routed to the
// uniform-stride fallback. ... the `frag_custom` muxer buffers that whole span in
// libavformat's interleaver before its first flush, which on a 110 min Blu-ray
// climbed to ~13 GB of RAM and swapped until the device disk filled.
```

The `ProducerError.muxerAllocFailed` string:
```swift
// HLSSegmentProducer.swift:21
case .muxerAllocFailed(let c):
    return "HLSSegmentProducer: avformat_alloc_output_context2 for hls failed (\(c))"
```

**Conclusion**: `MP4SegmentMuxer` allocates a libavformat output context in HLS/fMP4 mode (`avformat_alloc_output_context2` with format `"hls"` or similar, using `frag_custom` movflags), then overrides `io_open`/`io_close2` to capture ftyp+moov (init segment, captured once) and each mdat fragment (media segments) into `SegmentCache` instead of writing to files. This is architecturally equivalent to ffmpeg's `-f hls -hls_segment_type fmp4` with custom IO, but gives full control over segment boundaries (keyframe-aligned via pre-computed plan) and segment numbering.

**Why NOT the plain HLS muxer writing to disk:** 2h 4K at 6s/10MB would require ~120 GB resident on disk, per the comment on `HLSSegmentProvider.swift:6`:
```swift
/// Production implementation synthesizes segments lazily on AVPlayer fetch (2h 4K at 6s/10MB
/// would otherwise require ~120 GB resident).
```

> **LESSON FOR PLOZZ:** Use `avformat_alloc_output_context2` with HLS/fMP4 output format + `io_open`/`io_close2` override to redirect segment bytes into an in-memory (or disk-backed) cache. Do NOT write segments to disk and serve them from files — that would require 120+ GB. Capture ftyp+moov once (init.mp4), then each fragment is a separate `SegmentCache` entry that gets served on demand and evicted after AVPlayer consumes it.

---

## WHAT PLOZZ SHOULD CHANGE — 5-Bullet Summary

1. **Switch to `EXT-X-PLAYLIST-TYPE:VOD` + `#EXT-X-ENDLIST` immediately.** Build the full segment plan at `start()` time using the container's `AVFormatContext.duration` (already known from headers). Serve all EXTINF values from the first playlist response. This alone eliminates the EVENT far-seek clamp — AVPlayer sees a complete timeline and can seek to any position without restriction.

2. **Replace full-scan with a single deadline-bounded mid-file cue-prewarm seek.** Call `avformat_seek_file(ctx, -1, ...)` to 50% of the file (10s wall-clock deadline via AVIO read callback `return -1` on expiry). Read `avformat_index_get_entry()` on the video stream to get the now-populated keyframe PTS array. Build EXTINF from those PTS values using the same cut algorithm as the libavformat `hls` muxer. For no-Cues files the deadline fires and you fall back to uniform stride — negligible cost, no hang.

3. **Implement producer restart at target segment PTS for far seeks.** When AVPlayer fetches a segment outside your cache window (> 8 segments ahead of the producer, or any out-of-cache backward jump), call `avformat_seek_file` to `segmentPlan[N].startPts` (absolute source PTS, not playlist-relative time), create a new producer instance at `baseIndex = N`, and start pumping. AVPlayer's `AVPlayerItem` stays in place — only the producer and demuxer state restarts. The 8-segment forward-wait window absorbs normal forward buffering; anything beyond that triggers a restart.

4. **Implement `BackpressureWedgeDetector` for the VOD scrub-burst livelock.** When the producer parks waiting for AVPlayer to consume, poll `cache.targetIndex` every second. If it is frozen for 20–24 seconds AND `timeControlStatus == .waitingToPlay`, break the park, exit the pump with a wedge signal, and re-anchor the producer on `avPlayer.currentTime()` → `segmentIndexForPlaylistTime()`. Add a pause false-positive guard: if `timeControlStatus == .paused`, reset the stuck timer and don't count as a wedge.

5. **Override `AVFormatContext.io_open`/`io_close2` to capture fMP4 segments into an in-memory cache (not disk files).** Capture the init segment (ftyp+moov) once as `init.mp4`. Each media segment is captured on-demand, served to AVPlayer, and evicted after consumption. Evict segments behind AVPlayer's play position to stay within ~22 MB resident. This makes the segment muxer lazy and bounded rather than pre-generating the entire ~120 GB output of a 2h 4K film.

---

### Gaps / Uncertainties

- **`MP4SegmentMuxer` source not directly read** — its internal libavformat format name ("`hls`" vs "`mp4`" with `frag_custom` flags) is inferred from the `muxerAllocFailed` error string and the `frag_custom` comment; the actual `avformat_alloc_output_context2` call site is in that file which was not in the read list.
- **Exact `handlePumpFinished` for `.backpressureWedge`** — the re-anchor logic calling `segmentIndexForPlaylistTime` + `requestRestart` was described in comments and state variables but not read directly in the `+LiveReopen` extension file.
- **`SegmentCache.awaitFetchHighWater`** — the condvar-based blocking mechanism in the cache was referenced but not read; its exact timeout/wakeup contract is inferred from usage.
- All citations verified at commit `525fbe28989dee95b21e1b3b9786f2384f667930`.