# Fresh-session kickoff — Plozz local-remux, take 2

> Paste this into a new Plozz session to resume the local-remux effort from everything
> learned, without the branch sprawl. Full detail: **`docs/remux/REMUX-FINDINGS.md`** (on main).

---

You are picking up the Plozz tvOS **local-remux playback** effort after a deliberate reset.
A previous multi-session swarm (B1–B7 + Track A/B/C) made real progress but sprawled into ~80
branches without solving the core stability problem. All that work is **preserved as
`preserve/remux-*` git tags** and **documented in `docs/remux/REMUX-FINDINGS.md` on `main`** —
read that doc first; it is the source of truth. Do NOT recreate the swarm. Work as ONE session.

## The goal
Native AVPlayer playback on Apple TV of 4K HEVC + Dolby Vision (P5/P8.1) + E-AC3 (Dolby Digital
Plus / Atmos JOC) MKVs, preserving true DoVi, Atmos passthrough, full-timeline seek, and
sub-second start. Pipeline: libavformat demux over HTTP-range → on-device `-c copy` remux →
localhost HLS → AVPlayer. Only how we feed/index the muxer changes.

## What's already proven (don't re-litigate, don't regress)
- DoVi + E-AC3 passthrough through AVPlayer is GREEN on-device (make-or-break done).
- The routing seam (already on `main`) improves non-DoVi/non-Atmos playback — keep it.
- Approximate-EXTINF A/V sync HOLDS (AVPlayer follows real media PTS/tfdt; EXTINF is advisory).
- VOD+ENDLIST gives instant full-timeline seek.
- AVSampleBuffer self-demux is a dead end (no Atmos passthrough outside AVPlayer).

## The pivot
~90–95% of real movie MKVs already ship a `Cues` index readable in ~2 HTTP range requests
(<1s) via `SeekHead → Cues`. There is ONE engine with two front-ends: a Cues fast-path
(primary) and a lazy-producer fixed-cadence fallback for the no-Cues minority. Declare the
full VOD up front; produce segment bytes lazily; restart the producer on far seek
(AetherEngine model — see `docs/remux/aether-research/`).

## The open problem (your real work)
The full-vod engine still **crashes (jetsam) on a cold RESUME** of large 4K titles. Tonight
proved the per-segment **span-cap is a dead-end lever** (60s → resume crash; 15s → off-keyframe
stutter). **The crash is a MEMORY/concurrency problem, not a segment-span problem.** Fix it at
the producer/cache layer: bounded lazy segment cache (Aether L5) + backpressure to cap
concurrent in-flight segment muxing (Aether L6). Bound RSS, not span. Segments cut on real
keyframes only (Cues or a per-seek probe), never on a time cap.

## Recommended order
1. Land the **Cues fast-path** (B5 `readCues` or B6 `read_cues_table` → `KeyframeTable` →
   B7 `set_full_vod_mode`, short-circuiting cadence estimation when Cues exist). Real-keyframe
   boundaries make the far-seek balloon impossible on Cues titles. Prove on-device first.
2. Run the **gating experiment** (one capture): B5 tag `preserve/remux-b5-cues-2f73cf8` with
   `-com.plozz.playback.remuxCuesProbe YES -com.plozz.playback.remuxHevcAny YES`, grep `cues:`
   for `hasCues=YES count=N` on **Family Guy 43681** + **Jupiter 1438** (B5's probe is pure
   measurement; B6's `83e2120` `remuxCuesFastPath` also applies). Settles whether those "no
   usable index" titles truly lack Cues or ffmpeg just never fetched at-EOF Cues. Likely shrinks
   the no-Cues class to near-zero.
3. Fix the resume crash with bounded cache + backpressure (L5/L6).
4. Apply Aether L7/L9 (DV panel signaling + synchronous `preferredDisplayCriteria`) to harden DoVi.
5. Keep Track B (resource-loader fMP4) as a parked structural hedge only.

`KeyframeTable { duration: Double; times: [Double]; byteOffsets: [Int64]? }` — byteOffsets
present for live Cues (resolve is a no-op), nil for persisted (backward-seek to re-derive;
persist PTS-only, guard with size+duration+ETag).

## Preserved tags (resurrect with `git switch -c <branch> <tag>`)
- `preserve/remux-b5-cues-2f73cf8` — Swift Cues reader + `remuxCuesProbe` (MatroskaKeyframeSampler, 214 tests)
- `preserve/remux-b6-cues-d485635` — C direct-EBML Cues (byte-offset emit) + 4K probe-window + resync guard
- `preserve/remux-b7-fullvod-3aaace3` — full-vod engine + span-cap + **Cue-consume wired in** — **THE MERGE BASELINE** (clean FF of main)
- `preserve/remux-trackA-cues-vod-73d03e3` — provider lane + `KeyframeTable` canonical in `CoreModels` root
- `preserve/remux-trackB-fmp4-bb497a5` — resource-loader fMP4+sidx + estimator crash fix
- `preserve/remux-trackC-nocues-b572cbf` — no-Cues cache + background populator

## Hard rules
- Apple TV device id `DE913871-CC2D-5F75-B4F2-0D6F44AA30DE`. Only one app installs at a time;
  coordinate deploys with Brandon.
- Author commits as `Brandon Moore <16313090+thatcube@users.noreply.github.com>`, **no Copilot
  co-author trailer**. No PRs. Merge to `main` only with Brandon's confirmation.
- `export GIT_CONFIG_PARAMETERS="'safe.bareRepository=all'"`; `./tools/generate-project.sh`
  (XcodeGen) before building; **never `swift test`** (use `./tools/run-tests.sh LocalRemuxTests`).
- `setup-mpv.sh` never `--refresh`. Never commit the `M App/Plozz/PlozzApp.swift` register-
  defaults test block.
- Report raw on-device evidence, not optimism. Nothing is "working" on n=1 — validate across
  multiple 4K titles, both DoVi profiles, DD+/Atmos variants, with cold-resume + near-EOF tail
  tests each.
