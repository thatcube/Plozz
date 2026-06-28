# Plozz Local-Remux — Findings & Next Strategy (2026-06-28 reset)

This document consolidates everything learned across the multi-session "local remux"
swarm (sessions B1–B7 + Track A/B/C + research agents) so the work survives the
deletion of all those feature branches. **Every experimental engine is preserved as a
permanent git tag** (see [Preserved code](#preserved-code)); the branches can be deleted
without losing anything.

---

## 1. The goal (unchanged)

Native **AVPlayer** playback on Apple TV of MKV titles that carry
**4K HEVC + Dolby Vision + E-AC3 (Dolby Digital Plus, sometimes JOC/Atmos)**, while
preserving:

- true Dolby Vision (profile 5 / 8.1),
- E-AC3 / Atmos passthrough to the AVR,
- full-timeline seek (scrub anywhere, immediately),
- fast start (sub-second TTFF).

The approach: libavformat demux of the source over HTTP-range → on-device `-c copy`
remux (no re-encode) → fMP4 segments served over a localhost HLS origin → AVPlayer.
**Only how we feed and index the muxer changes** — the demux→copy→AVPlayer spine is proven.

---

## 2. What is PROVEN (do not re-litigate, do not regress)

1. **DoVi + E-AC3 passthrough through AVPlayer is GREEN on-device.** The make-or-break is
   done. `init.mp4` boxes `[ftyp,moov,mvex,trak,dvh1,hvcC,dvvC,ec-3,dec3] DoVi-cfg=YES dec3=YES`.
   Remaining work is *only* start + seek + memory stability — never whether DoVi/Atmos survive.
2. **The routing seam works and improves non-DoVi/non-Atmos playback.** `.localRemux`
   selection + register-defaults flags + `mpvSafeAudio` + HDR10→AVPlayer routing. **Keep it.**
   (`Sources/CoreModels/LocalRemuxModels.swift`, `Sources/FeaturePlayback/LocalRemuxStreaming.swift`
   are already on `main`.)
3. **Approximate-EXTINF sync HOLDS.** Captured live (`fg-clean.log`, build d02dce4): on a
   no-index title using fixed-cadence segments, declared EXTINF diverges from the real
   segment span by up to ~46s, yet audio/video skew stays bounded ±0.4s and **self-corrects
   every segment (non-cumulative)**. tvOS AVPlayer schedules off **real media PTS/tfdt**, not
   off EXTINF — EXTINF is advisory. **Consequence:** exact Cue durations are a *seek-precision
   refinement*, not an A/V-sync correctness requirement. No three-way VOD A/B is needed.
4. **mpv multichannel (5.1/6ch) SIGSEGV** is root-caused and contained by routing — never
   route a multichannel title back to mpv.
5. **Full-timeline native seek works** with a VOD + `ENDLIST` playlist declared up front
   (every EXTINF present at open → scrub bar immediately seekable, no 3-minute EVENT clamp).

---

## 3. The PIVOT that reframes the whole effort

The original "trilemma" (scan the whole file vs. estimate cadence vs. clamp seeking) rested
on a **false premise**: that we must discover the keyframe timeline ourselves.

**~90–95% of real movie MKVs already ship a `Cues` keyframe index**, readable in
**~2 HTTP range requests (<1s)** via `SeekHead → Cues`. No timeline scan, no cadence
estimate. The entire B5/B6/B7 fight was optimizing the rare *no-Cues* minority case.

So there is **ONE engine with two front-ends**, not three competing tracks:

- **Cheap path (primary, ~90–95% of titles):** read `Cues` → exact `(pts, byte-offset)`
  table → emit a complete static VOD + `ENDLIST` with exact EXTINF. Segments are
  real-keyframe-bounded by construction → no desync, no far-seek balloon.
- **Fallback path (no-Cues minority):** declare a full VOD with **fixed/estimated cadence**
  over the known container duration, and **produce segment bytes lazily** on AVPlayer fetch;
  a far seek **restarts the remux producer** at the target source PTS (it does NOT grow an
  EVENT playlist and does NOT clamp).

This is exactly the AetherEngine model (see §6) — playlist **declaration** is decoupled from
segment **production**.

### The AVSampleBuffer dead-end (settled)

Self-demuxing into `AVSampleBufferDisplayLayer` to bypass the HLS/remux machinery is a
**dead end** — there is no E-AC3/JOC Atmos passthrough outside AVPlayer on tvOS. Atmos alone
forces AVPlayer. Do not revisit.

---

## 4. What BLOCKED us — the on-device crash (the real open problem)

Two distinct failure shapes were seen on-device, and only one is solved:

| | Symptom | Root cause | Status |
|---|---|---|---|
| **A** | Far-seek (e.g. resume @22min) on a 4K title builds a **single ~198s segment** in one buffer → `signal 9` (jetsam) | `mux_segment_full` read loop only stopped on `pts >= end_limit && KEY`, **no upper bound** → a far jump into a sparse-keyframe region ran ~198s of 4K into one `dyn_buf` | **Fixed for the first 4K title** by the span-cap (b382cad → ccad89b → 879a5a3). seg=44/103/105 now bounded & in-sync, no crash. |
| **B** | **Cold RESUME** of a *different* 2.48h DoVi-P8 / DD+ title still **crashes (jetsam)** even with the span cap | Memory pressure on cold resume — believed to be **concurrent prefetch of several far segments**, each muxing up to the cap, spiking RSS past the tvOS jetsam limit | **OPEN.** Span-cap cannot fix it. |

**The span-cap is a proven dead-end as a stability lever.** Tonight's sweep on title B:

- `PLOZZ_SEGMENT_SPAN_CAP=60` → bounds the 198s balloon but **still crashes on cold resume**.
- `PLOZZ_SEGMENT_SPAN_CAP=15` → **stutters**: GOPs on the title run ~24–33s, so a 15s cap
  forces every segment to cut **mid-GOP, off-keyframe** (`SPAN-CAPPED ~15.0s off-keyframe`) →
  constant re-seek/overlap → visible stutter.
- There is **no cap value** that both prevents the balloon/crash AND keeps segments
  keyframe-aligned. Segments must be bounded by **real keyframes** (Cues or a per-seek probe),
  never by an arbitrary time cap.

**Therefore the crash is a MEMORY/concurrency problem, not a segment-span problem.** The fix
belongs at the producer/cache layer (bounded in-flight muxing + backpressure + a bounded
segment cache), which is precisely the AetherEngine machinery we have NOT yet built (§6, L5/L6).

---

## 5. Ownership map at reset (who built what)

Massive primitive duplication accreted across sessions (everyone re-derived B5's full stack).
At reset the concerns were consolidated one-owner-each:

| Concern | Owner | Lang | Notes |
|---|---|---|---|
| Full-vod **engine** (declare VOD+ENDLIST, forward-snap on-demand mux, serving) | **B7** | C/Swift | The deploy spine. `set_full_vod_mode`. Tag `preserve/remux-b7-fullvod-879a5a3`. |
| **Cues fast-path** (open-time exact index) | **B5** | Swift | `readCues()/hasCues()` on one `MatroskaKeyframeSampler` (shares `parseInit` with the no-Cues walk). Tag `preserve/remux-b5-cues-777fde4`. |
| **Cues fast-path (alt)** + live per-seek **resolve** + cluster **resync** | **B6** | C | `plozz_remux_read_cues_table` (in-muxer apply) + `kf_probe_at` + 6a86a8b resync (hot mux path). Tag `preserve/remux-b6-cues-83e2120`. |
| Provider protocol / source selection / Swift→C marshal | **Track A** | Swift | `MatroskaCueParser` + provider plumbing. Tag `preserve/remux-trackA-cues-vod-fb0e34c`. |
| Structural-cure: segment-less seekable fMP4 via `AVAssetResourceLoaderDelegate` + sidx | **Track B** | Swift | Independent of the Cues/KeyframeTable spine. Also fixed a real `FragmentSizeEstimator` overflow crash. Tag `preserve/remux-trackB-fmp4-bb497a5`. |
| no-Cues **cache + background populator** | **Track C** | Swift | Background full-walk → persist times-only index, ETag/size guard. Tag `preserve/remux-trackC-nocues-b572cbf`. |

**Duplication that recurred (watch for it next time):** three separate Cues parsers
(B5 Swift, B6 C, Track A) and two VOD engines (B7 + B5's `ProvisionalVODPlan`). The container
parser legitimately exists twice **only** because open-time/background discovery (Swift) and
live per-seek resolve in the mux hot path (C) are genuinely different runtime contexts — that
is the *only* justified duplication.

### The `KeyframeTable` contract (the seam all sources marshal into)

```
struct KeyframeTable { var duration: Double; var times: [Double]; var byteOffsets: [Int64]? }
```

- `byteOffsets` **present** for fresh live Cues → forward-snap resolve is a **no-op** (the Cue
  offset *is* the keyframe cluster).
- `byteOffsets` **nil** for a persisted cache/walk → the muxer **backward-seeks** to re-derive
  (dodges the stale-offset-after-reencode trap). Persist **PTS seconds only**, guard with
  size + duration + ETag/Last-Modified HEAD.

> **Known blocker for the next session:** there are currently **two** `KeyframeTable`
> definitions — B5's nested `MatroskaKeyframeSampler.KeyframeTable` and Track A's canonical
> `CoreModels.KeyframeTable` (identical fields). The first integration task is to canonicalize
> **one** (Track A's in `CoreModels`) and have B5's sampler return that type so the modules can
> exchange tables. Track A's provider lane (`KeyframeTableSource` protocol, priority selection
> `liveCues < noCuesWalk < persistedCache < serverEndpoint`, `FullVODKeyframeSink` Swift→C seam,
> default-OFF `FullVODKeyframeCoordinator`) is built and green at tag
> `preserve/remux-trackA-cues-vod-fb0e34c` — pick it up rather than rebuild.

---

## 6. AetherEngine lessons (the reference implementation of our exact pipeline)

`superuser404notfound/AetherEngine` ships this exact pipeline on tvOS. Brandon's directive:
**learn from it, build it ourselves — do NOT link/fork.** Full raw research in
[`aether-research/`](./aether-research/); the load-bearing lessons:

- **L3 — Producer-restart far seek.** A far seek restarts the remux *producer* at the target
  source PTS. NOT a new `AVPlayerItem`, NOT a growing EVENT playlist. This is the correct
  far-seek model and extends our proven VOD+ENDLIST win.
- **L4 — 8-segment scrub/seek threshold.** Distinguish scrub from seek to avoid thrashing the producer.
- **L5 — Lazy custom-IO segment cache.** Segments produced on demand into a **bounded** cache.
  *(We never built this — likely central to the §4-B resume crash.)*
- **L6 — `BackpressureWedgeDetector`.** Bounds concurrent production / detects wedge.
  *(Also unbuilt — the other half of the resume-crash fix.)*
- **L7 — Panel-aware DV HLS signaling matrix** + **L9 — synchronous `preferredDisplayCriteria`
  before item assignment.** Load-bearing for reliable DV on tvOS 26.5+; likely behind any
  DoVi flakiness. `/db1p` SUPPLEMENTAL + non-DV-panel `dvvC` strip.
- **L8 — P7→8.1 libdovi NAL surgery.**
- **L10 — `+delay_moov`** for EAC3+JOC Atmos `dec3`.

**The insight that dissolves the trilemma:** the swarm conflated playlist **declaration** with
segment **production**. Declare the full VOD up front (durations from the container header —
free); produce bytes lazily; restart the producer on far seek. EVENT playlists (far-seek clamp)
and full pre-scans are both wrong.

---

## 7. RECOMMENDED NEW STRATEGY (for the fresh session)

Stop iterating the span-cap. Build the AetherEngine producer model properly, smallest-first:

1. **Land the Cues fast-path as the primary front-end.** Wire B5's `readCues()` (or B6's
   `read_cues_table`) → `KeyframeTable` → B7's `set_full_vod_mode`, short-circuiting cadence
   estimation when Cues exist. Exact EXTINF + real-keyframe segment boundaries = the §4-A
   balloon **cannot** happen on the ~90–95% of titles with Cues. **This likely makes most
   titles stable on its own** and should be proven on-device first.
2. **Run the gating experiment** (one capture): B6's `83e2120` with
   `-com.plozz.playback.remuxCuesFastPath YES` logs `cues: found N CuePoints` on the two
   original "no usable index" bug titles (**Family Guy 43681**, **Jupiter 1438**). This settles
   whether those titles *truly* lack Cues, or whether ffmpeg's `avformat_index` just never
   fetched the at-EOF Cues (because our localhost VOD range reader never served the
   avio-seek-to-EOF after `SeekHead→Cues`). If it's the latter, the direct-EBML reader fixes
   them in one stroke and the no-Cues class shrinks to near-zero.
3. **Fix the resume crash at the right layer (memory, not span):** implement L5 (bounded
   lazy segment cache) + L6 (backpressure / cap concurrent in-flight segment muxing). Bound
   **RSS**, not segment span. Segments cut on real keyframes only.
4. **Keep Track B (resource-loader fMP4) as the structural-cure hedge** for the genuine no-Cues
   case — but the mature reference (AetherEngine) uses localhost-HLS + lazy producer, not a
   resource loader, so it's the lower-priority bet. Park unless the Cues path proves insufficient.
5. **Apply L7/L9** (DV panel signaling + synchronous display criteria) to harden DoVi.

**Evidence bar:** nothing is "working" on n=1. Validate across multiple 4K titles, both DoVi
profiles (P5/P8.1), DD+/Atmos variants, **and a cold-resume + a near-EOF tail test on each**.

---

## 8. Preserved code

All experimental engines are reachable forever via these annotated tags (branches may be deleted):

| Tag | What |
|---|---|
| `preserve/remux-b5-cues-777fde4` | B5 Cues fast-path — Swift `readCues` on `MatroskaKeyframeSampler`, 152 tests |
| `preserve/remux-b6-cues-83e2120` | B6 direct-EBML Cues fast-path — C `read_cues_table`, in-muxer apply, 153 tests |
| `preserve/remux-b7-fullvod-879a5a3` | B7 full-vod engine + span-cap + `PLOZZ_SEGMENT_SPAN_CAP` (build 759) |
| `preserve/remux-trackA-cues-vod-fb0e34c` | Track A provider/marshal + `MatroskaCueParser` |
| `preserve/remux-trackB-fmp4-bb497a5` | Track B `AVAssetResourceLoaderDelegate` fMP4+sidx + `FragmentSizeEstimator` crash fix |
| `preserve/remux-trackC-nocues-b572cbf` | Track C no-Cues cache + background populator |

Inspect any with `git show <tag>` or `git checkout <tag>`. To resurrect work:
`git switch -c <new-branch> <tag>`.

---

## 9. Build / device notes (carried forward)

- `export GIT_CONFIG_PARAMETERS="'safe.bareRepository=all'"` before git ops in worktrees.
- `./tools/generate-project.sh` (XcodeGen) bakes `CFBundleVersion` from git commit count.
- **Never `swift test`** — mpv xcframeworks are tvOS-only (no macOS slice). Use
  `./tools/run-tests.sh LocalRemuxTests` (tvOS Simulator).
- Device build: `xcodebuild -project Plozz.xcodeproj -scheme Plozz -destination
  "platform=tvOS,id=DE913871-CC2D-5F75-B4F2-0D6F44AA30DE" build`.
- Capture: `xcrun devicectl device process launch --console --terminate-existing
  -e '{"REMUX_STDOUT":"1",...}' com.thatcube.Plozz -- -com.plozz.playback.remuxFullVod YES ...`
  (put `--` before the `-com.plozz...` app args). `log collect` is unreliable on this device
  ("Device not configured (6)") — stdout-via-`--console` is the reliable path.
- The uncommitted `M App/Plozz/PlozzApp.swift` register-defaults test block must **never** be committed.
