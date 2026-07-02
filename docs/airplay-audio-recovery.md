# AirPlay 2 / HomePod Audio-Drop Recovery

How Plozz keeps audio alive on an AirPlay 2 speaker (HomePod, HomePod-as-TV-
speakers) across **seeks, track skips, and transient network failures** — and the
mechanisms that actually worked after a long, evidence-driven hunt.

This was written for the **music** engine (`AudioPlaybackController`), but the
root cause is an `AVPlayer` + AirPlay 2 interaction, so the same techniques apply
to the **video** engines that use `AVPlayer` (Native and Plozzigen). See
[Applying this to video](#applying-this-to-video).

---

## Symptom

Intermittently, when playing to a HomePod over AirPlay 2:

- **Seeking** (scrubbing) or **skipping** a track would silently kill audio. The
  speaker went quiet while `AVPlayer` kept reporting `timeControlStatus == .playing`
  (rate 1.0). Nothing looked wrong in code — the player thought it was playing.
- Recovery only happened after physically reconnecting the speaker, or after
  several minutes / a track or two.
- **Spotify on the same HomePod never had this problem** — proving it was
  Plozz-specific, not the speaker or the network.
- On skips especially, the drop fired **zero** events: no interruption, no route
  change, no stall/error. Any purely *reactive* recovery was therefore impossible;
  the drop had to be **prevented**, and any residual failures **self-healed**.

## Root cause

Plozz music streams are **progressive-download HTTP `AVPlayerItem`s** (Jellyfin/
Plex FLAC/MP3/AAC), **not HLS**. Two things make the HomePod drop:

1. **`advanceToNextItem()` on a progressive item forces the HomePod to
   re-negotiate its AirPlay 2 stream** (~200–800 ms). A plain `play()` issued into
   that renegotiation window hands the still-renegotiating sink a "play now" it
   can't honor → the sink silently drops. The app never learns, because the player
   already believes it's `.playing`.
2. **Seeking flushes the render buffer** with the same net effect on the AirPlay
   stream.

Spotify avoids this by feeding the AirPlay sink one **continuous output stream**
(engine/HLS-style) that never tears down on a track change.

## The winning mechanism ⭐

> A full **audio-session deactivate → reactivate cycle** forces tvOS to
> re-establish the HomePod stream from scratch. This is the core cure.

```swift
let session = AVAudioSession.sharedInstance()
try? session.setActive(false, options: .notifyOthersOnDeactivation)
try? session.setActive(true)
```

Two hard-won details:

- **`setActive(true)` *alone* is a no-op** on an already-active session. Early
  attempts that just re-asserted `setActive(true)` (or `play()`/`playImmediately`)
  did nothing — that's why they failed. You must toggle it **off, then on**.
- This cycle both **prevents** the drop (do it as part of the transition) **and
  recovers** an already-dropped stream (a seek doing this fixed a dead HomePod
  live on-device).

Because deactivating stops output for a beat, apply it only where a tiny gap is
acceptable — see the gapless rule below.

## The full shipped design

Ordered roughly from "prevents the drop" to "heals it if it happens anyway".

### 1. Reactivate on seek
`seek(to:)` does `pause()` → `setActive(false, .notifyOthersOnDeactivation)` →
`setActive(true)` → preroll-gated restart. Seeks became 100% reliable and can even
rescue an already-broken stream.

### 2. Reactivate on manual skip — but keep natural ends gapless
The clean signal is **who initiated the transition**:

| Transition | `reactivateRoute` | Behavior |
|---|---|---|
| Manual skip / previous / tap-to-play / arbitrary jump | `true` | `pause()` → `advanceToNextItem()` → **deactivate→reactivate** → preroll-gated play. A tiny gap is fine (the user pressed a button). |
| Natural gapless album end / repeat-one / fresh play | `false` | Plain `advanceToNextItem()` + `play()`. **No** session toggle → seamless, no gap between album tracks. |

`reactivateRoute` is threaded from the `debounced` flag in `scheduleStart(debounced:)`
(`debounced == true` ⟺ user-initiated skip). Natural ends never dropped in any
log, so preserving their seamless hand-off is safe.

### 3. Debounce rapid skips into ONE transition
`scheduleStart(debounced:)` waits 350 ms and bumps a `trackTransitionGeneration`
counter so a burst of Next/Previous presses collapses into a single player
transition. Firing a transition per press interrupts each item's route
negotiation mid-flight — the classic way to drop the speaker. Every `await` in
`startCurrent` is followed by a `generation == trackTransitionGeneration` guard so
a superseded start bails instead of stomping the one the user actually landed on.

### 4. Treadmill (pre-enqueue) + preroll-before-play
The next track is pre-enqueued behind the current one (`prepareNextInQueue`,
`preparedNext`) and prerolled while the current one plays, so the common case is a
seamless fast-path hand-off. On the reactivate path we `preroll(atRate:)` to arm
**all** render pipelines (including the AirPlay output) and only start output once
it reports ready (`playImmediately`), instead of forcing `play()` into a sink
that's mid-renegotiation.

### 5. Retry a `.failed` item with a fresh re-resolve
A rapid-skip burst (or any network blip) can make a freshly-inserted item come
back `.failed` — on-device we captured `itemStatus=.failed itemError=The network
connection was lost.` **Advancing onto a `.failed` item strands the player at
`AVPlayerWaitingWithNoItemToPlayReason` forever** (seeks can't revive an item with
no data). So the HARD-PATH now loops up to 3×: on `.failed` it removes the corpse,
backs off 400 ms, **re-resolves a fresh URL** (the old stream/session may be
dead), rebuilds the item, and only advances once one is actually ready.

### 6. Self-heal watchdog for a stranded player
A 4×/sec time-observer watchdog (`detectAndRecoverStuckPlayback`) reloads the
current track when the player is stranded — `.waitingToPlayAtSpecifiedRate` with
`reasonForWaitingToPlay == .noItemToPlay`, **or** a `.failed` current item — for
≥ 2.5 s while we still intend to play (`isPlaying && !startPending`). This also
catches a *currently-playing* item whose connection drops mid-stream. Single-flight
via `stuckRecoveryTask`.

### 7. Delayed retry when a jump exhausts its attempts
If a HARD-PATH jump fails all its load attempts (persistent network failure —
resolve keeps succeeding but the stream can't establish), we don't bare-return.
`scheduleStalledRetry` backs off ~2.5 s and re-attempts the **same** target
(generation/`isPlaying`-guarded), chaining politely until the network returns, so
a failed jump or a failed natural-end hand-off self-heals. Its handle
(`stalledRetryTask`) is kept separate from `stuckRecoveryTask` so the two recovery
paths never clobber each other; the watchdog stands down while either is in flight.

### Lifecycle hygiene
`stop()` bumps `trackTransitionGeneration` and cancels **both** recovery tasks
(and clears `stuckSince`) so an in-flight recovery/resolve can't resume past the
generation guard and resurrect playback into an empty queue with a spurious
`.start` report.

## What did NOT work (don't retry these)

| Attempt | Why it failed |
|---|---|
| `setActive(true)` **alone** as a "nudge" | No-op on an already-active session — the session was never *deactivated*, so tvOS never re-negotiated the stream. |
| `play()` / `playImmediately()` after the drop | The player already believed it was `.playing`; re-issuing play doesn't rebuild the torn AirPlay sink. |
| Recovering on interruption `.began` | `interrupt .began reason=default` is a **lagging** indicator — it fired ~3.5 min *after* a skip in one session, and skips often fired no interruption at all. Useless as a trigger. |
| Reacting to `routeConfigurationChange` | Self-inflicted churn; reacting to it caused more drops than it fixed. |
| Treating item status `2` as "ready" | `AVPlayerItem.Status.failed == 2` (not ready). Advancing on it strands the player. Gate on `.readyToPlay` + `isPlaybackLikelyToKeepUp`/`isPlaybackBufferFull`, and handle `.failed` explicitly. |

## Diagnostics pipeline

The controller writes a pullable on-device log. **It must live in `Library/Caches`**
— `.documentDirectory` fails at runtime on tvOS.

```bash
# Pull the log
xcrun devicectl device copy from \
  --device DE913871-CC2D-5F75-B4F2-0D6F44AA30DE --user mobile \
  --domain-type appDataContainer --domain-identifier com.thatcube.Plozz \
  --source Library/Caches/audio-diagnostics.log --destination /tmp/audio-diagnostics.log

# Isolate the latest launch/session
awk '/════════ launch/{buf=""} {buf=buf $0 "\n"} END{print buf}' /tmp/audio-diagnostics.log
```

Every route line also records the negotiated `@<sampleRate>Hz/<channels>ch`, and
timeControl **transitions** are logged (not the 4×/sec noise) — a
`playing→waiting→paused` slide with no user pause is the fingerprint of a route
drop. Useful markers to grep: `reactivated`, `seek recovery`, `HARD-PATH item
FAILED`, `re-resolving`, `stuck …s — reloading`, `stalled-retry firing`.

## Applying this to video

The same root cause applies wherever we drive audio through **`AVPlayer`**:

- **Native engine** (`AVPlayer` directly) and **Plozzigen** (FFmpeg → localhost
  HLS-fMP4 → `AVPlayer`) both output audio via `AVAudioSession` and are subject to
  the same HomePod renegotiation on **seek** and on any player-item swap.

### Known gap in the video path (as of this writing)

`NativeVideoEngine.observeAudioRouteChanges` currently recovers with
`setActive(true)` **alone** — the exact no-op that failed for music:

```swift
// Sources/FeaturePlayback/NativeVideoEngine.swift (route-change observer)
try? AVAudioSession.sharedInstance().setActive(true)   // ← no-op on an active session
```

If video exhibits the HomePod drop on **seek** (the most likely trigger for a
single long video), port the proven techniques:

1. **On seek**, wrap the seek in the deactivate→reactivate cycle (§1): `pause()` →
   `setActive(false, .notifyOthersOnDeactivation)` → `setActive(true)` → resume
   (preroll-gated if using a queued item). A brief scrub gap is expected and fine.
2. **Replace the route-change nudge** with the full deactivate→reactivate cycle so
   it actually re-negotiates the stream.
3. **Handle `.failed` items + a stranded player** the same way (§5–§7): don't sit
   on `AVPlayerWaitingWithNoItemToPlayReason`; re-resolve/reload with backoff.
4. Video is mostly a **single long item**, so the track-skip/treadmill machinery
   (§2–§4) is less relevant — **seek** and **mid-stream network drop** are the
   cases to cover.

### Reference code (music)

All in `Sources/FeatureMusic/AudioPlaybackController.swift`:

| Concern | Symbol |
|---|---|
| Deactivate→reactivate on seek | `seek(to:)` |
| Deactivate→reactivate on skip/jump | `reactivateAndStart(generation:path:)` |
| Gapless vs reactivate gating | `startCurrent(reactivateRoute:)`, `scheduleStart(debounced:)` |
| Debounce + supersede | `scheduleStart(debounced:)`, `trackTransitionGeneration` |
| Preroll-before-play | `prerollCurrentItem(timeout:)`, `PrerollContinuationBox` |
| `.failed` retry + re-resolve | HARD-PATH loop in `startCurrent` |
| Stranded-player watchdog | `detectAndRecoverStuckPlayback`, `reloadCurrentTrackAfterStall` |
| Delayed retry after exhausted attempts | `scheduleStalledRetry(forGeneration:)` |
| Teardown hygiene | `stop()` |
| Diagnostics | `AudioDiagnostics` (`Sources/FeatureMusic/AudioDiagnostics.swift`) |
