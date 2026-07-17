import CoreModels
import Foundation

/// Seam back to the owner (``PlayerViewModel``) for the pieces of transport
/// intent that live outside the seek pipeline itself. The coordinator holds a
/// *weak* reference so it never retains the view model (which SwiftUI owns).
///
/// - `seekEngine` is a **getter** on purpose: the engine can be swapped
///   mid-session (native ⇆ Plozzigen handoff, image-subtitle swap, retry), and
///   the drain loop must always act on the *current* engine, exactly as the
///   inline pipeline did when it read `self.engine` each iteration.
/// - `seekIntendsPlayback` / `seekDidStop` are the two intent/teardown signals
///   the pipeline gates on. They are read-only from the coordinator's side.
/// - `seekApplyPaused` funnels the "give up and stay paused" outcome back
///   through the view model's single play/pause funnel so intent, reporting and
///   the watchdog stay consistent.
@MainActor
protocol SeekScrubCoordinatorHost: AnyObject {
    var seekEngine: any VideoEngine { get }
    var seekIntendsPlayback: Bool { get }
    var seekDidStop: Bool { get }
    func seekApplyPaused(_ paused: Bool)
}

/// Owns the committed-seek / scrub-commit pipeline extracted from
/// ``PlayerViewModel``: request coalescing, the deferred commit debounce, the
/// single in-flight drain loop, and the post-seek resume confirmation.
///
/// The fragile semantics this type is responsible for preserving exactly:
/// - **`isSeeking` clears only when the drain returns** (the forever-spinner
///   failure mode if it's cleared early or never).
/// - **The `intendsPause` phantom-`.playing` gate**: when we do *not* intend
///   playback across a committed seek, the landed engine is re-paused and
///   `controls.intendsPause` is asserted so the overlay can't read a transient
///   post-seek "playing" and sit frozen.
/// - **The resume-confirm two-consecutive-advance gate** that re-primes an
///   engine which settles at rate 0 on a buffering edge post-seek.
@MainActor
final class SeekScrubCoordinator {
    private weak var host: SeekScrubCoordinatorHost?
    /// Shared, stably-referenced controls model (never reassigned on the VM).
    private let controls: PlayerControlsModel

    /// Most-recently-requested committed seek time; the drain loop jumps
    /// directly to this (skipping intermediate values) so a burst of presses
    /// collapses to one re-buffer.
    private var latestSeekTarget: TimeInterval?
    /// The single in-flight drain loop that processes `latestSeekTarget`.
    private var seekTask: Task<Void, Never>?
    /// Deferred engine-commit timer; every fresh press resets it.
    private var seekCommitTask: Task<Void, Never>?
    /// Post-seek resume verification loop.
    private var resumeConfirmTask: Task<Void, Never>?
    private let seekCommitDebounce: UInt64

    /// How far shy of the very end a committed seek is allowed to land. Scrubbing
    /// to the far right of the bar otherwise sends the engine a seek *at* (or a
    /// hair past) the final sample. On a network-file source (SMB/WebDAV via
    /// Plozzigen) that faults the demuxer at EOF, which surfaces as a playback
    /// error and — worse — the failure fallback then re-resolves *resumed at that
    /// same EOF position*, faulting again with a second, more confusing error,
    /// exactly while an up-next hand-off may already be in flight. Landing a beat
    /// before the end instead lets the stream play out its final moment and fire a
    /// clean natural `onEnded`, which is the path that cleanly auto-advances to the
    /// next episode — which is what a scrub-to-the-end was asking for anyway.
    private let endGuard: TimeInterval = 1.0

    init(
        host: SeekScrubCoordinatorHost,
        controls: PlayerControlsModel,
        commitDebounce: UInt64 = 200_000_000 // 200ms
    ) {
        self.host = host
        self.controls = controls
        self.seekCommitDebounce = commitDebounce
    }

    private var engine: (any VideoEngine)? { host?.seekEngine }

    /// Clamps a requested seek into `[0, duration - endGuard]` so a scrub to the
    /// very end can't drop the engine exactly on (or past) EOF. Only applies the
    /// upper bound when the engine reports a finite, usefully-long duration; while
    /// duration is still unknown (`0`/non-finite, early bring-up) the target is
    /// only floored at 0, preserving prior behaviour.
    func clampedSeekTarget(_ seconds: TimeInterval) -> TimeInterval {
        let floored = max(0, seconds)
        guard let engine else { return floored }
        let duration = engine.duration
        guard duration.isFinite, duration > endGuard else { return floored }
        return min(floored, duration - endGuard)
    }

    /// Waits (bounded) for the engine to publish a usable duration before a
    /// committed seek is forwarded, so AetherEngine's `min(target, duration)` VOD
    /// clamp can't collapse the target to 0 during the brief post-`.ready`,
    /// pre-duration window (the DV·SMB "seek during load snaps to the start" bug).
    /// A no-op once a finite, positive duration is known; bails immediately on a
    /// stop/teardown so a torn-down engine is never awaited.
    private func awaitSeekableDuration() async {
        func durationKnown() -> Bool {
            guard let engine else { return true } // torn down — don't block the drain
            return engine.duration.isFinite && engine.duration > 0
        }
        if durationKnown() { return }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if Task.isCancelled || (host?.seekDidStop ?? true) { return }
            if durationKnown() { return }
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }
    }

    /// Requests a committed seek. Coalesces rapid presses: while one seek is
    /// in flight, additional calls just update the *latest target*; the
    /// scheduler loop then jumps directly to that latest target (skipping the
    /// intermediate values entirely) using `.fast` for any intermediate hop
    /// and `.exact` for the final settle. The `pendingSeekTarget` flag pins
    /// the on-screen position so the refresh loop can't snap the bar backward
    /// to a stale `engine.currentTime` while the seek resolves.
    func requestSeek(to seconds: TimeInterval) {
        let target = clampedSeekTarget(seconds)
        let intendsPlayback = host?.seekIntendsPlayback ?? true
        if let engine {
            PlaybackTrace.note("requestSeek to=\(String(format: "%.2f", target)) from=\(String(format: "%.2f", controls.currentSeconds)) dir=\(target < controls.currentSeconds ? "BACK" : "fwd") engineState curr=\(String(format: "%.2f", engine.currentTime)) dur=\(String(format: "%.2f", engine.duration))")
        }
        controls.currentSeconds = target
        controls.pendingSeekTarget = target
        controls.isSeeking = true
        latestSeekTarget = target
        // Classify where this seek lands relative to any skippable segment so the
        // overlay can respect a deliberate seek: deep landings suppress the Skip
        // affordance, grace-window landings offer a manual button only (Option B).
        updateSeekLanding(for: target)
        // A fresh seek supersedes any in-flight resume confirmation; the new
        // seek will start its own once it lands. Keep the mirror suppressed for
        // the new in-flight seek when we still intend to play, so a transient
        // engine pause between back-to-back committed seeks can't surface.
        cancelResumeConfirm()
        if intendsPlayback { controls.isResumeConfirming = true }
        // Coalesce rapid presses: defer the actual engine seek by a short window
        // so a burst of skips collapses into ONE seek (one re-buffer) to the final
        // target. The on-screen position + skip hint already moved above, so the
        // delay is invisible. A loop already draining picks up the new target on
        // its own, so `scheduleSeekCommit` only starts one when idle.
        scheduleSeekCommit()
    }

    /// Classifies a committed seek's landing relative to the skippable segments so
    /// the overlay can honor a deliberate seek (Option B). A landing *inside* a
    /// skippable segment records a ``SkipSeekLanding``: within the opening grace
    /// window → a manual Skip button is still offered; deeper → the affordance is
    /// suppressed (the seek is respected). A landing outside every segment clears
    /// it. The container clears a stale landing once the live position leaves the
    /// segment, so a later natural re-entry behaves normally.
    private func updateSeekLanding(for target: TimeInterval) {
        controls.seekLanding = SeekLandingClassifier.landing(
            forTarget: target, in: controls.skippableSegments)
    }

    /// Schedules the deferred engine commit for `requestSeek`. Resets on each call
    /// so consecutive presses keep pushing the commit out until they stop, then a
    /// single seek fires to the accumulated `latestSeekTarget`. If a seek loop is
    /// already draining we don't start another — it will pick up the new target
    /// itself — so this is a no-op mid-drain.
    private func scheduleSeekCommit() {
        seekCommitTask?.cancel()
        guard seekTask == nil else { return }
        seekCommitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: self?.seekCommitDebounce ?? 200_000_000)
            guard let self, !Task.isCancelled else { return }
            self.seekCommitTask = nil
            if self.seekTask == nil, self.latestSeekTarget != nil {
                self.startSeekLoop()
            }
        }
    }

    private func cancelSeekCommit() {
        seekCommitTask?.cancel()
        seekCommitTask = nil
    }

    private func startSeekLoop() {
        seekTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // If we intend to keep playing across this committed seek, suppress
            // the engine→model pause mirror for the WHOLE window up front — the
            // engine can settle to a transient paused state mid-seek, and letting
            // that reach the model is what flashed the pause icon and (worse) made
            // the resume gate below mis-read intent. Cleared on every exit path.
            if self.host?.seekIntendsPlayback ?? true { self.controls.isResumeConfirming = true }
            // Hold the committed seek until the engine has published a usable
            // duration. AetherEngine clamps a VOD seek to `min(target, duration)`;
            // in the sliver between it reporting `.ready` (scrubber revealed) and
            // publishing a real duration, `duration` is still 0, so that clamp
            // collapses EVERY target to 0 and slams playback back to the start.
            // That is the "seek right after / while a DV·SMB title is loading snaps
            // to the beginning" report. The optimistic on-screen pin
            // (`pendingSeekTarget`) keeps the requested position visible during the
            // brief wait; it's bounded so a source that never reports a duration
            // still seeks best-effort rather than hanging.
            await self.awaitSeekableDuration()
            // Drain: process the latest pending target until none remains.
            while let next = self.takeLatestSeekTarget() {
                // If a newer target arrives while this one is in flight, we
                // can be cheap here — only the LAST one needs to be precise.
                let isFinal = (self.latestSeekTarget == nil)
                let kind: VideoSeekKind = isFinal ? .exact : .fast
                await self.engine?.seek(to: next, kind: kind)
                // A teardown (stop) or supersede can land while we were suspended
                // in the seek above — bail before touching a torn-down engine.
                // NOTE: only stop() currently cancels seekTask, so clearing the
                // suppression flag here is safe. If superseding seeks ever cancel
                // and restart seekTask, this clear could clobber a newer seek's
                // flag — re-evaluate then.
                if Task.isCancelled || (self.host?.seekDidStop ?? true) {
                    self.controls.isResumeConfirming = false
                    self.seekTask = nil
                    return
                }
            }
            self.seekTask = nil
            self.controls.isSeeking = false
            // The seek has landed. AVPlayer / AEEngine can settle at rate 0 once a
            // seek resolves on a buffering edge — the data is ready but playback
            // never resumes on its own (a manual pause→play would start it
            // instantly). Re-assert play AND confirm it actually took, so a
            // committed seek always resumes without the viewer nudging it.
            // Gate on `intendsPlayback` (NOT `controls.isPaused`, which the engine
            // mirror can have flipped to a transient paused during the drain): so
            // scrubbing while paused — or a user pause mid-seek — stays paused.
            if !Task.isCancelled, !(self.host?.seekDidStop ?? true), self.host?.seekIntendsPlayback ?? false {
                self.confirmResumeAfterSeek()
            } else {
                self.controls.isResumeConfirming = false
                // We do NOT intend playback (pause-to-seek mode, or a user pause
                // mid-seek). A committed seek can leave the engine auto-resumed,
                // or settled at rate-0-while-still-reporting-"playing" — either
                // way the overlay would wrongly read "playing" and the picture
                // would sit frozen. Re-assert the pause so playback genuinely
                // stops AND the overlay reads paused; we stay paused on the
                // landed frame until the user explicitly resumes.
                if !(self.host?.seekDidStop ?? true) {
                    self.engine?.pause()
                    self.controls.isPaused = true
                    // This branch is reached only when we do NOT intend playback
                    // (pause-to-seek, or a user pause mid-seek), so the pause here
                    // is genuine intent — keep the glyph's intent gate honest.
                    self.controls.intendsPause = true
                }
            }
            // `pendingSeekTarget` is cleared by the refresh poll once the
            // engine's `currentTime` arrives within tolerance of the target —
            // that's the moment it's safe to resume mirroring engine time.
        }
    }

    /// Re-issues `play()` after a committed seek and verifies the engine clock
    /// actually advances, retrying for a short window. Fixes the intermittent
    /// "landed but frozen" state where playback settles at rate 0 post-seek and a
    /// single `play()` is swallowed. Self-cancels the moment the clock advances,
    /// the user pauses, or a new seek supersedes it.
    private func confirmResumeAfterSeek() {
        resumeConfirmTask?.cancel()
        // We intend to play from here on; mark it so the container stops
        // mirroring the engine's transient post-seek paused state into the model
        // (which would flash the pause icon and make this loop think the user
        // paused).
        controls.isResumeConfirming = true
        resumeConfirmTask = Task { @MainActor [weak self] in
            guard let self, let engine = self.engine else { return }
            ScrubDiagnostics.note("resume-confirm: start t=\(String(format: "%.2f", engine.currentTime)) enginePaused=\(engine.isPaused)")
            // After a committed seek the engine should already be playing (the
            // commit path re-issued play()). But AEEngine/AVPlayer can land at
            // rate 0 on a buffering edge while still reporting "playing", so a
            // plain play() is a no-op and the picture sits frozen. Verify the
            // clock actually advances; if it doesn't, escalate to a pause→play
            // "kick" — the same transition a manual pause/play does, which is the
            // only thing that reliably re-primes a stalled AEEngine.
            //
            // We deliberately do NOT consult `controls.isPaused` inside this loop.
            // The container mirrors `engine.isPaused` into `controls.isPaused`
            // every refresh tick, and the engine's transient post-seek pause is
            // exactly the freeze we're here to fix — treating it as "the user
            // paused" is what made the previous version bail before it ever
            // kicked. A genuine user pause goes through setPaused(true), which
            // cancels this task; Task cancellation (user pause / superseding seek /
            // teardown) is our only stop signal.
            var lastTime = engine.currentTime
            var kicks = 0
            // Require the clock to advance on TWO consecutive checks before
            // declaring success — a single tick can be a post-seek keyframe snap
            // or a one-frame buffer dribble that then re-freezes, which would
            // otherwise leave us stuck (the very bug we're fixing). We only kick
            // when actually stalled, so an engine that's genuinely recovering is
            // observed, not disrupted.
            var advancingStreak = 0
            // ~4s of coverage: 12 attempts × ~300ms (plus 60ms per kick).
            for attempt in 0..<12 {
                if Task.isCancelled { return }
                let stalled = (advancingStreak == 0)
                if attempt == 0 {
                    // Cheap, blip-free first try — handles the common healthy
                    // landing where play() just needs re-asserting.
                    engine.play()
                } else if stalled {
                    // Still no forward motion → kick it (pause→play), the same
                    // transition a manual pause/play does.
                    engine.pause()
                    try? await Task.sleep(nanoseconds: 60_000_000)
                    if Task.isCancelled { return }
                    engine.play()
                    kicks += 1
                }
                // else: clock is moving — just observe again, don't disrupt it.
                try? await Task.sleep(nanoseconds: 300_000_000)
                if Task.isCancelled { return }
                let now = engine.currentTime
                if now > lastTime + 0.05 {
                    advancingStreak += 1
                    lastTime = now
                    // Two clean advances in a row → genuinely playing.
                    if advancingStreak >= 2 {
                        ScrubDiagnostics.note("resume-confirm: resumed after \(kicks) kick(s)")
                        self.controls.isResumeConfirming = false
                        self.resumeConfirmTask = nil
                        return
                    }
                } else {
                    advancingStreak = 0
                    lastTime = now
                }
            }
            ScrubDiagnostics.note("resume-confirm: gave up still-stalled after \(kicks) kick(s)")
            // We exhausted the kicks and the engine is genuinely sitting at
            // rate 0 (a real stall, not the transient settle we can recover).
            // Reconcile intent with reality instead of leaving `intendsPlayback`
            // stuck "playing": mark it paused so the pause indicator is honest and
            // the viewer's next Play press cleanly retries playback (rather than
            // being read as a pause). `setPaused(true)` also clears
            // `isResumeConfirming`, nils this task, and reports the pause.
            // (Two-consecutive-advance success gating means a false give-up here
            // would require the engine to be effectively frozen anyway, so pausing
            // it is safe.)
            self.host?.seekApplyPaused(true)
        }
    }

    /// Cancels any in-flight post-seek resume confirmation and clears the
    /// suppression flag. Called from every site that supersedes or ends a resume
    /// (a fresh seek, a user pause, teardown). The cancelled task itself does NOT
    /// touch `isResumeConfirming` on its cancellation path, so a brand-new
    /// confirmation started right after a cancel can't be clobbered by the old
    /// task waking up.
    func cancelResumeConfirm() {
        resumeConfirmTask?.cancel()
        resumeConfirmTask = nil
        controls.isResumeConfirming = false
    }

    /// Teardown: cancels the commit timer, the drain loop and the resume
    /// confirmation. Called from ``PlayerViewModel/stop(preserveDisplayMode:)``.
    func cancelAll() {
        cancelSeekCommit()
        seekTask?.cancel()
        seekTask = nil
        cancelResumeConfirm()
    }

    private func takeLatestSeekTarget() -> TimeInterval? {
        guard let target = latestSeekTarget else { return nil }
        latestSeekTarget = nil
        return target
    }

    /// Legacy direct-seek path retained for callers (e.g. resume on load) that
    /// want a one-shot await. New transport input goes through `requestSeek`.
    func seek(to seconds: TimeInterval) async {
        controls.isSeeking = true
        controls.currentSeconds = max(0, seconds)
        controls.pendingSeekTarget = max(0, seconds)
        await engine?.seek(to: seconds, kind: .exact)
        controls.isSeeking = false
    }
}
