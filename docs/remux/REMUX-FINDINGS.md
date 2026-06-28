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
| **A** | Far-seek (e.g. resume @22min) on a 4K title builds a **single ~198s segment** in one buffer → `signal 9` (jetsam) | `mux_segment_full` read loop only stopped on `pts >= end_limit && KEY`, **no upper bound** → a far jump into a sparse-keyframe region ran ~198s of 4K into one `dyn_buf` | **Fixed for the first 4K title** by the span-cap. seg=44/103/105 now bounded & in-sync, no crash. |
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

### 4.1 Raw on-device proof of the balloon mechanism (B7, seg83)

The clearest single artifact of the effort. On a no-Cues title, far-seek window `END=1260` →
`resolve` declared end `1253.750 + 19.916 = 1273.666`, but the mux END forward-walk ran all the
way to **1511.917 (258s vspan)** because **no `AV_PKT_FLAG_KEY` exists anywhere between 1273.666
and 1511.917** — a mis-flagged-keyframe region typical of no-Cues sources. This proves the span
cap **bounds** the balloon (crash-safe) but does **not fix** it: the segment is still cut off a
real keyframe, so a cap tight enough to prevent the balloon lands mid-GOP → stutter, while a cap
loose enough to stay keyframe-aligned can still balloon past the jetsam limit. The actual cure is
a **real parsed keyframe boundary** (Cues fast-path, or B6's parsed-END pre-resolve that drops
the unreliable `KEY`-flag stop) — i.e. the whole reason the Cues pivot is primary.

---

## 5. Ownership map at reset (who built what)

Massive primitive duplication accreted across sessions (everyone re-derived B5's full stack).
At reset the concerns were consolidated one-owner-each:

| Concern | Owner | Lang | Notes |
|---|---|---|---|
| Full-vod **engine** (declare VOD+ENDLIST, forward-snap on-demand mux, serving) | **B7** | C/Swift | The deploy spine. `set_full_vod_mode` + **Cue-consume wired in**. Tag `preserve/remux-b7-fullvod-3aaace3`. |
| **Cues fast-path** (open-time exact index) | **B5** | Swift | `readCues()/hasCues()/keyframeTableFromCues()` on one `MatroskaKeyframeSampler` (shares `parseInit` with the no-Cues walk) + `remuxCuesProbe` diagnostic. Tag `preserve/remux-b5-cues-2f73cf8`, 214 tests. |
| **Cues fast-path (alt)** + live per-seek **resolve** + cluster **resync** | **B6** | C | `plozz_remux_read_cues_table` (in-muxer apply) + `kf_probe_at` + 6a86a8b resync (hot mux path). Tag `preserve/remux-b6-cues-d485635` (real tip; supersedes 83e2120). |
| Provider protocol / source selection / Swift→C marshal | **Track A** | Swift | `MatroskaCueParser` + provider plumbing + canonical `CoreModels.KeyframeTable` + `zeroBasedTimes`. Tag `preserve/remux-trackA-cues-vod-73d03e3` (real tip; supersedes fb0e34c). |
| Structural-cure: segment-less seekable fMP4 via `AVAssetResourceLoaderDelegate` + sidx | **Track B** | Swift | Independent of the Cues/KeyframeTable spine. Also fixed a real `FragmentSizeEstimator` overflow crash. Tag `preserve/remux-trackB-fmp4-bb497a5`. |
| no-Cues **cache + background populator** | **Track C** | Swift | Background full-walk → persist times-only index, ETag/size guard. Tag `preserve/remux-trackC-nocues-0094702` (real tip of `thatcube-ideal-train`; the earlier `b572cbf` tag is an **orphaned amend off the real branch** — do NOT harvest it). |

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

> **Known blocker for the next session (mostly resolved):** B5 and Track A have **converged** on
> a single `KeyframeTable` shape — Track A's canonical `CoreModels.KeyframeTable` and B5's
> `keyframeTableFromCues()` emit the identical 3 fields. The one remaining **mechanical** step is
> to have B5's sampler target *import* `CoreModels` and return that exact type (instead of its
> still-nested struct of identical fields), so the modules literally exchange the same type. Track A's provider lane (`KeyframeTableSource` protocol, priority selection
> `liveCues < noCuesWalk < persistedCache < serverEndpoint`, `FullVODKeyframeSink` Swift→C seam,
> default-OFF `FullVODKeyframeCoordinator`) is built and green at tag
> `preserve/remux-trackA-cues-vod-92a440f` (supersedes fb0e34c) — pick it up rather than rebuild.
> (Track A's true tip is `73d03e3`/`preserve/remux-trackA-cues-vod-73d03e3`, which already
> **relocated `KeyframeTable` to the `CoreModels` root** — the canonical survivor.)
>
> **⚠️ THREE-MIRROR ATOMIC-COLLAPSE HAZARD (Track A flagged, honor at integration):** at full
> integration there will be THREE `KeyframeTable` definitions — the canonical `CoreModels.KeyframeTable`
> (survivor), B5's nested `MatroskaKeyframeSampler.KeyframeTable` (standalone-compile shim), and Track
> C's top-level `LocalRemux.KeyframeTable` (standalone shim). The collapse must be **ONE atomic commit**
> that deletes BOTH `LocalRemux` mirrors together, adds `import CoreModels` at every referencing site,
> and routes construct-sites through `normalized()`. If a merge step deletes only one mirror, unqualified
> `KeyframeTable` inside the `LocalRemux` module becomes ambiguous (CoreModels vs the surviving mirror) →
> build break in the intermediate tree. So: never sequence a merge order that leaves one mirror live
> while the other is gone. (Does NOT affect the engine-only merge on `main` — B7's `3aaace3` ships none
> of these structs; this is purely a fresh-session provider-lane integration constraint.)
>
> **Two more settled handoff decisions (recorded; confirm against real merged code):**
> - **⚠️ Canonical C sink — SHIPPED REALITY differs from my earlier recommendation. Verified against
>   the MERGED engine (`3aaace3`) source:** the merged tree exposes
>   **`plozz_remux_set_cue_table(session, double duration, const double* times, int count,
>   const int64_t* byte_offsets /*nullable*/)`** + `plozz_remux_has_cue_table(session)`
>   (`remux_core.h:313`/`:318`). Call order: `set_cue_table(...)` FIRST (stores the table only),
>   THEN the UNCHANGED 2-arg `plozz_remux_set_full_vod_mode(session, 1)` (`remux_core.h:333`); the
>   consume runs inside full-vod engage at `remux_core.c:1181` (`if (s->has_cue_table && cue_count>=2)`),
>   gated on the existing `used_fixed_cadence==1` engage gate. **`apply_keyframe_boundaries_ex` is NOT
>   present in the merged tree** — my earlier "reuse the existing `apply_keyframe_boundaries_ex`"
>   recommendation was SUPERSEDED by what B7 actually shipped (`set_cue_table`). Track A's
>   `FullVODKeyframeSink` is a one-signature swap either way (both consume the same
>   `KeyframeTable{duration, zeroBasedTimes, byteOffsets?}`). Fresh session: wire against
>   `set_cue_table` (it's what's on `main` after the merge); reconcile only if it later prefers the
>   apply_keyframe_boundaries_ex shape. **Gating: only set a cue table when `used_fixed_cadence==1`
>   (libav-blind-but-Cues-exist); native-index titles NO-OP full-vod — don't set there.**
> - **0-based boundaries:** `plan_segments_core` clamps a non-zero first boundary → segment-0
>   becomes over-long → desync. The marshal MUST feed 0-based times — Track A added
>   `KeyframeTable.zeroBasedTimes`; B7 also normalizes to 0-based inside the consume at `3aaace3`
>   ("normalize cue-table boundaries to 0-based domain in full-vod consume").
>
> **B5 final-report integration gotchas (bank these — non-obvious, costly to rediscover):**
> - **Cache call-site merge break (B5 ↔ Track C):** B5's branch still has the PRE-donation
>   `KeyframeIndexCache` + 3 `RemuxSegmenter` call-sites (~lines 533/534/722) behind default-OFF
>   `remuxKeyframeCache` using the OLD API (`store(boundaries:)`, `boundaries(fromDurations:)`).
>   Track C (`a5fd88e9`) owns the EVOLVED cache (renamed `times:`, v2, deleted the baked-cadence
>   helper). At cache-merge: **Track C's file wins**; re-point B5's 3 sites to `store(times:)` with
>   RAW keyframe times (sampler path `self.lazyKf`; C-table path `seg.start_seconds` — NEVER
>   re-derive from durations). Self-consistent on each branch now; breaks only at merge.
> - **`add_tail` & serve gate:** exact-Cues tables use `add_tail=0` (`add_tail=1` → tail-404 drift);
>   serve gate is `plozz_remux_used_fixed_cadence(s)==1`, NOT a count comparison (under hypothesis-B
>   libav's index is empty).
> - **Sparse mis-index probe edge:** the `remuxCuesProbe` is instrumented to catch `fixedCadence=no`
>   + `hasCues=YES` with B5's count ≠ libav's index count = a SPARSE (non-empty) mis-index that the
>   `used_fixed_cadence` gate would MISS. Unlikely, but the gating capture will reveal it.

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
2. **Run the gating experiment** (one capture): the cleanest probe is **B5's pure-measurement**
   `remuxCuesProbe` (parses + logs + discards, zero serving effect) — `preserve/remux-b5-cues-2f73cf8`
   with `-com.plozz.playback.remuxCuesProbe YES -com.plozz.playback.remuxHevcAny YES`, grep
   `cues:` → `cues: hasCues=YES count=N span=[..]`. (B6's `83e2120` `remuxCuesFastPath` is the
   apply-path sibling that *also* installs the boundaries.) Run on the two original "no usable
   index" bug titles (**Family Guy 43681**, **Jupiter 1438**). This settles
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
6. **No-Cues 4K per-seek hardening candidates (B6's frozen lane, NOT yet built):** make the
   keyframe probe-window knobs `PLOZZ_KF_HEADER_WINDOW` / `PLOZZ_KF_RESYNC_BACK` env-tunable
   (getenv, default-identical) so the 4K parse window can be sized **on-device without a rebuild**.
   Addresses the known caveat: a giant 4K cluster whose video SimpleBlock sits past the fixed 16KB
   header window currently fail-closes to the seek-landing keyframe (bounded but coarse). Also add
   robustness tests for the truncated-window fail-closed + cluster-sync resync at varied cursor
   offsets. The per-seek primitive itself (`kf_probe_at/_next/_range`, cluster-sync resync,
   video_track re-arm) is preserved at `preserve/remux-b6-cues-d485635`.

**Evidence bar:** nothing is "working" on n=1. Validate across multiple 4K titles, both DoVi
profiles (P5/P8.1), DD+/Atmos variants, **and a cold-resume + a near-EOF tail test on each**.

---

## 8. Preserved code

All experimental engines are reachable forever via these annotated tags (branches may be deleted):

| Tag | What |
|---|---|
| `preserve/remux-b5-cues-2f73cf8` | B5 Cues fast-path — Swift `readCues`/`keyframeTableFromCues` on `MatroskaKeyframeSampler` + `remuxCuesProbe` diagnostic, 214 tests |
| `preserve/remux-b6-cues-d485635` | B6 direct-EBML Cues — C `read_cues_table` (now emits byte offsets) + 4K-widened probe window + backward-align resync guard + warm session-cache (supersedes 83e2120) |
| `preserve/remux-b7-fullvod-3aaace3` | **THE MERGE BASELINE** — B7 full-vod engine + span-cap + `PLOZZ_SEGMENT_SPAN_CAP` knob **+ Cue fast-path CONSUME wired into the engine** (exact-boundary VOD table + pre-seeded resolves). Clean FF of main. (supersedes 879a5a3) |
| `preserve/remux-trackA-cues-vod-73d03e3` | Track A provider lane + **`KeyframeTable` relocated to `CoreModels` root (canonical)** + byteOffsets all-or-nothing (supersedes 92a440f) |
| `preserve/remux-trackB-fmp4-bb497a5` | Track B `AVAssetResourceLoaderDelegate` fMP4+sidx + `FragmentSizeEstimator` crash fix |
| `preserve/remux-trackC-nocues-0094702` | Track C no-Cues cache + background populator (KeyframeIndexCache v2 + KeyframeIndexService + FullTimelineVODStreamer, all behind `remuxPersistIndex` default-OFF; 154 tests). **Real tip of `thatcube-ideal-train`.** ⚠️ The earlier `preserve/remux-trackC-nocues-b572cbf` tag is an ORPHANED amend off the real branch — do NOT harvest it. |

Inspect any with `git show <tag>` or `git checkout <tag>`. To resurrect work:
`git switch -c <new-branch> <tag>`.

**Merge-base lineage note (B7 engine):** the merge baseline is **`3aaace3`** (= `879a5a3`
+ the Cue-consume). `879a5a3` = `b382cad` (cap = `max(2×cadence, 8)`, = 60 at cadence 30,
**no ceiling** — correct) **+ the `PLOZZ_SEGMENT_SPAN_CAP` knob**. The intermediate `ccad89b`
added a 30s ceiling that **clipped legit ~33–36s segments — a regression**, and `879a5a3`
already reverts it. `3aaace3` then adds the **Cue fast-path consume** (`4c7e92c` exact-boundary
VOD table + pre-seeded resolves, `cc66a0f` tiles producer boundaries verbatim, `3aaace3` 0-based
normalize). All of `b382cad → … → 3aaace3` is a **clean fast-forward of main**. **Merge
`3aaace3`; never `ccad89b` standalone.**

### 8.1 Confirmed final tips (git ground truth, 2026-06-28 ~01:55 — self-reports were stale)

| Session | Branch | Confirmed tip | Worktree |
|---|---|---|---|
| B7 (engine) | `thatcube-b7-lazy-windowed-index` | **`3aaace3`** | clean (only never-commit `PlozzApp.swift` flag block + build artifacts) |
| B5 (Cues) | `thatcube-remux-desync-stutter-fix` | `2f73cf8` | clean (only `PlozzApp.swift`) |
| B6 (Cues) | `thatcube-thatcube-b6-remux-desync-independent` | `d485635` | clean |
| Track A (provider) | `thatcube-track-a-cues-vod` | `73d03e3` | clean |
| Track B (fMP4) | `thatcube-track-b-fmp4-loader` | `bb497a5` | clean |

> NOTE: post-report commits (B7 `879a5a3→3aaace3`, B6 `83e2120→d485635`, Track A `92a440f→73d03e3`)
> were authored after each session's last green-build claim, so their **build/test status is
> coordinator-unverified** — the fresh session should run `./tools/run-tests.sh LocalRemuxTests`
> + a device build at `3aaace3` before relying on it.

### 8.2 Two integration rulings locked for the fresh session (record only)

1. **Cues source = serve B5's Swift `keyframeTableFromCues()`** (byteOffsets populated → B7's
   forward-snap is a no-op; marshalled once at open, not the per-seek hot path). **B6's C
   `read_cues_table` = differential oracle** (must agree on PTS+offset per Cues title;
   disagreement = parser bug caught pre-ship) **+ owner of the no-Cues walk.** Not two competing
   serve-parsers — different layers. B7's `3aaace3` already consumes a *passed* Cue boundary
   table, so the producer is the marshalled B5 table.
2. **Canonical C sink** = B7's `plozz_remux_set_cue_table(s, duration, times, count,
   byte_offsets?)` setter → consume inside `set_full_vod_mode` (just before the fixed-cadence
   build), **gated on `used_fixed_cadence==1`** so a good-libav-index DoVi title no-ops the
   full-vod path → **byte-identical, HARD-REQ-5 protected**. `byteOffsets` present = Phase-2
   direct byte-seek; nil = backward-seek-by-time (the boundary *is* a real keyframe). This
   build+pre-seed is the **one shared `apply_keyframes` ingest** B5 Cues / B6 no-Cues / Track C
   cache all reuse.

### 8.3 Other branches NOT individually tagged

~80 other worktree branches exist (earlier B1–B4 remux experiments, SSOT, watch-state, UI, etc.).
Only the 6 canonical remux tags above are preserved. **If any of those other branches hold work
worth keeping, tag them before deleting** — otherwise branch deletion loses them. The remux
*lessons* from the earlier experiments are already captured in this document.

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
