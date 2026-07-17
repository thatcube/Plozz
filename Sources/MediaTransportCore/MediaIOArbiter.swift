import Foundation

public protocol MediaIOScannerResource: AnyObject, Sendable {
    /// A thread-safe snapshot. Once `cancel()` has returned, this value must
    /// remain true after all scanner-owned I/O has drained.
    var isDrained: Bool { get }
    func cancel() async
    func forceClose() async throws
}

public protocol MediaIODrainDeadline: Sendable {
    func waitForDrain(
        of resource: any MediaIOScannerResource,
        timeout: Duration
    ) async -> Bool
}

public struct MediaIOOneSecondDeadline: MediaIODrainDeadline {
    public init() {}

    public func waitForDrain(
        of resource: any MediaIOScannerResource,
        timeout: Duration
    ) async -> Bool {
        guard timeout > .zero else { return false }
        guard !resource.isDrained else { return true }

        let clock = ContinuousClock()
        let end = clock.now.advanced(by: timeout)
        let pollInterval = Duration.milliseconds(10)
        while clock.now < end {
            let remaining = clock.now.duration(to: end)
            do {
                try await clock.sleep(for: remaining < pollInterval ? remaining : pollInterval)
            } catch {
                return resource.isDrained
            }
            if resource.isDrained { return true }
        }
        return resource.isDrained
    }
}

/// A one-shot race latch. The first `resolve` wins; every later `resolve` is a
/// no-op. Used to bound an unresponsive scanner operation against a deadline
/// without a structured task group whose scope could still wait forever for a
/// cancellation-insensitive child. The latch owns no arbiter state, so a timed-out
/// operation task that resolves it late can never mutate the arbiter.
final class MediaIORaceLatch<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var settled = false
    private var value: Value?
    private var continuation: CheckedContinuation<Value, Never>?

    func wait() async -> Value {
        await withCheckedContinuation { continuation in
            let resolved: Value? = lock.withLock {
                if settled { return value }
                self.continuation = continuation
                return nil
            }
            if let resolved { continuation.resume(returning: resolved) }
        }
    }

    func resolve(_ newValue: Value) {
        let waiter: CheckedContinuation<Value, Never>? = lock.withLock {
            guard !settled else { return nil }
            settled = true
            value = newValue
            let waiter = continuation
            continuation = nil
            return waiter
        }
        waiter?.resume(returning: newValue)
    }
}

/// Staged escalation windows carved out of a single absolute transition deadline.
/// A single `ContinuousClock.Instant` at transition start anchors three absolute
/// cutoffs. Each stage's wait is recomputed as `max(.zero, cutoff - clock.now)` at
/// invocation, so actor-scheduling/transition overhead between stages can never
/// push the end-to-end bound past `finalDeadline`: a stage that starts after its
/// cutoff has already slipped receives no time, and no earlier stage can borrow
/// from a later reserve. The graceful-cancel slice therefore can never consume the
/// force-close reserve even if `cancel()` is cancellation-insensitive.
struct MediaIOTransitionSchedule {
    let cancelCutoff: ContinuousClock.Instant
    let drainCutoff: ContinuousClock.Instant
    let finalDeadline: ContinuousClock.Instant

    init(start: ContinuousClock.Instant, total: Duration) {
        let clamped = total > .zero ? total : .zero
        // ~50% graceful cancel, ~20% drain verification, remainder (~30%) reserved
        // for force-close. Cutoffs are absolute offsets from one start instant, so
        // the three windows sum to exactly one deadline with no inter-stage drift.
        let cancel = clamped / 2
        let verify = clamped / 5
        self.cancelCutoff = start.advanced(by: cancel)
        self.drainCutoff = start.advanced(by: cancel + verify)
        self.finalDeadline = start.advanced(by: clamped)
    }

    /// The time still available before `cutoff`, or `.zero` if it has already
    /// slipped. Computed against the caller-supplied `now` at each stage boundary.
    func remaining(until cutoff: ContinuousClock.Instant, now: ContinuousClock.Instant) -> Duration {
        let interval = now.duration(to: cutoff)
        return interval > .zero ? interval : .zero
    }
}

public final class MediaIOScannerLease: @unchecked Sendable {
    public let generation: UInt64

    private let arbiter: MediaIOArbiter
    private let lock = NSLock()
    private var finishTask: Task<Void, Never>?

    fileprivate init(generation: UInt64, arbiter: MediaIOArbiter) {
        self.generation = generation
        self.arbiter = arbiter
    }

    deinit {
        finish()
    }

    public func finish() {
        _ = taskForFinish()
    }

    public func finishAndWait() async {
        await taskForFinish().value
    }

    private func taskForFinish() -> Task<Void, Never> {
        lock.withLock {
            if let finishTask {
                return finishTask
            }
            let arbiter = self.arbiter
            let generation = self.generation
            let task = Task { [arbiter, generation] in
                await arbiter.finishScanner(generation: generation)
            }
            finishTask = task
            return task
        }
    }
}

public final class MediaIOPlaybackLease: @unchecked Sendable {
    private let id: UUID
    private let arbiter: MediaIOArbiter
    private let lock = NSLock()
    private var releaseTask: Task<Void, Never>?

    fileprivate init(id: UUID, arbiter: MediaIOArbiter) {
        self.id = id
        self.arbiter = arbiter
    }

    deinit {
        release()
    }

    public func release() {
        _ = taskForRelease()
    }

    public func releaseAndWait() async {
        await taskForRelease().value
    }

    private func taskForRelease() -> Task<Void, Never> {
        lock.withLock {
            if let releaseTask {
                return releaseTask
            }
            let arbiter = self.arbiter
            let id = self.id
            let task = Task { [arbiter, id] in
                await arbiter.releasePlayback(id: id)
            }
            releaseTask = task
            return task
        }
    }
}

/// Per-account scanner/playback admission controller.
public actor MediaIOArbiter {
    private struct ScannerAdmission {
        let generation: UInt64
        let resource: any MediaIOScannerResource
    }

    private enum BoundedStage: Sendable, Equatable {
        case completed
        case failed
        case timedOut
    }

    public let accountID: String
    private let deadline: any MediaIODrainDeadline
    private let drainTimeout: Duration
    private var nextGeneration: UInt64 = 0
    private var activeScanner: ScannerAdmission?
    private var playbackIDs: Set<UUID> = []
    /// Playback requests that have entered admission and reserved priority but have
    /// not yet been granted a lease. A reservation preempts any in-progress or
    /// at-boundary scanner replacement so playback wins deterministically.
    private var playbackReservations = 0
    /// True while exactly one caller is draining the active scanner. Other callers
    /// wait on `transitionWaiters` and re-evaluate when it clears rather than
    /// racing a second concurrent drain of the same resource.
    private var transitionInProgress = false
    private var transitionWaiters: [CheckedContinuation<Void, Never>] = []
    /// Once shut down, no new scanner or playback lease is admitted. Set by
    /// `shutdownAndDrain()` during account invalidation so a retired arbiter can be
    /// removed from the coordinator once its already-issued leases drain.
    private var isShutDown = false
    private var shutdownDrainWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        accountID: String,
        deadline: any MediaIODrainDeadline = MediaIOOneSecondDeadline(),
        drainTimeout: Duration = .seconds(1)
    ) {
        self.accountID = accountID
        self.deadline = deadline
        self.drainTimeout = drainTimeout
    }

    public func acquireScanner(
        resource: any MediaIOScannerResource
    ) async throws -> MediaIOScannerLease {
        // A retired arbiter admits no new work; the coordinator installs a fresh
        // arbiter generation after invalidation completes.
        guard !isShutDown else { throw MediaTransportError.resourceBusy }
        // A scanner yields to any playback that is active or merely reserved, and
        // it never queues behind another in-progress transition (fast-fail avoids a
        // scan storm and preserves single-transition serialization).
        guard playbackIDs.isEmpty, playbackReservations == 0, !transitionInProgress else {
            throw MediaTransportError.resourceBusy
        }
        nextGeneration &+= 1
        let generation = nextGeneration
        if let replaced = activeScanner {
            let drained = await runDrainTransition(replaced)
            if !drained {
                throw MediaTransportError.resourceBusy
            }
        }
        try Task.checkCancellation()
        // A playback reservation may have appeared while we drained the previous
        // scanner; yield the freshly cleared slot to it.
        guard playbackIDs.isEmpty, playbackReservations == 0,
              activeScanner == nil, !transitionInProgress else {
            throw MediaTransportError.resourceBusy
        }
        activeScanner = ScannerAdmission(
            generation: generation,
            resource: resource
        )
        return MediaIOScannerLease(generation: generation, arbiter: self)
    }

    public func acquirePlayback() async throws -> MediaIOPlaybackLease {
        // A retired arbiter admits no new playback; the coordinator installs a fresh
        // arbiter generation after invalidation completes.
        guard !isShutDown else { throw MediaTransportError.resourceBusy }
        // Reserve priority before any suspension so a concurrent or at-boundary
        // scanner replacement observes the reservation and yields to us.
        playbackReservations += 1
        defer { playbackReservations -= 1 }

        while true {
            try Task.checkCancellation()
            if transitionInProgress {
                // Another caller is draining the active scanner (a replacement that
                // will yield to this reservation, or another playback that will
                // clear the scanner). Wait for it, then re-evaluate.
                await awaitTransitionClear()
                continue
            }
            guard let scanner = activeScanner else {
                let id = UUID()
                playbackIDs.insert(id)
                return MediaIOPlaybackLease(id: id, arbiter: self)
            }
            let drained = await runDrainTransition(scanner)
            if !drained {
                throw MediaTransportError.resourceBusy
            }
            // The scanner is cleared; loop admits playback on the next iteration.
        }
    }

    /// Whether passive metadata work may use this account right now. The scheduler
    /// polls this between short slices, so playback/scanning never needs to retain a
    /// callback into a higher-level module.
    public func permitsBackgroundWork() -> Bool {
        !isShutDown
            && playbackIDs.isEmpty
            && playbackReservations == 0
            && activeScanner == nil
            && !transitionInProgress
    }

    /// Retire this arbiter: reject all new scanner/playback admission, drain any active
    /// scanner under the bounded transition deadline, then wait for already-issued
    /// playback leases to drain *naturally* (playback finishes on its own timeline; we
    /// never cancel a live lease). Returns only once no lease remains, so the
    /// coordinator can drop the account without leaking arbiters (finding A7).
    ///
    /// Bounded where it must be: scanner cancel/force-close uses the same single
    /// absolute deadline as `stopAndDrain`, so this never waits forever on an
    /// unresponsive scanner. It intentionally *does* wait for genuine playback leases —
    /// that wait is bounded by playback's own lifetime, and new admission is already
    /// rejected. Idempotent: a second call after drain returns immediately.
    public func shutdownAndDrain() async {
        isShutDown = true
        // Let any in-progress drain (a replacement transition) finish before we drain.
        while transitionInProgress {
            await awaitTransitionClear()
        }
        if let scanner = activeScanner {
            _ = await runDrainTransition(scanner)
        }
        // Existing playback leases finish naturally; wait for the last one to release.
        while !playbackIDs.isEmpty {
            await awaitShutdownDrain()
        }
    }

    private func awaitShutdownDrain() async {
        await withCheckedContinuation { continuation in
            shutdownDrainWaiters.append(continuation)
        }
    }

    private func resumeShutdownDrainIfComplete() {
        guard isShutDown, playbackIDs.isEmpty, !shutdownDrainWaiters.isEmpty else { return }
        let waiters = shutdownDrainWaiters
        shutdownDrainWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// Drains `scanner` under a single absolute deadline, clearing it on success.
    /// Returns whether closure was positively established; a bounded failure leaves
    /// the scanner installed so a retry re-drains it. Only one drain runs at a time.
    private func runDrainTransition(_ scanner: ScannerAdmission) async -> Bool {
        transitionInProgress = true
        let closed = await stopAndDrain(scanner)
        if closed, activeScanner?.generation == scanner.generation {
            activeScanner = nil
        }
        endTransition()
        return closed
    }

    private func awaitTransitionClear() async {
        await withCheckedContinuation { continuation in
            transitionWaiters.append(continuation)
        }
    }

    private func endTransition() {
        transitionInProgress = false
        let waiters = transitionWaiters
        transitionWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// One absolute deadline, staged: bounded graceful cancel, then a bounded
    /// drain-verification, then bounded force-close. A single clock instant at the
    /// start anchors all three cutoffs; each stage's timeout is recomputed as the
    /// time remaining until its cutoff, so scheduling overhead between stages cannot
    /// push the end-to-end bound past `finalDeadline`. Force-close is granted exactly
    /// the time remaining until `finalDeadline` — there is no hidden minimum, so the
    /// promised absolute bound is never exceeded. A literal zero/fully-elapsed
    /// deadline therefore yields no bounded force-close stage and reports failure (no
    /// lease) rather than silently borrowing extra time. Returns true only when
    /// closure is positively established (drained after cancel, or a non-throwing
    /// force-close). A timed-out or throwing force-close returns false — a timed-out
    /// unclosed scanner is never reported as cleanly drained. Late completion from a
    /// timed-out cancel/force-close resolves an abandoned latch that owns no arbiter
    /// state, so it can never mutate admission after its window closes.
    private func stopAndDrain(_ scanner: ScannerAdmission) async -> Bool {
        let resource = scanner.resource
        let clock = ContinuousClock()
        let schedule = MediaIOTransitionSchedule(start: clock.now, total: drainTimeout)

        let cancelReturned = await runBounded(
            timeout: schedule.remaining(until: schedule.cancelCutoff, now: clock.now),
            timedOutValue: false
        ) {
            await resource.cancel()
            return true
        }

        // Only spend the drain-verification reserve when cancel actually returned;
        // a blocked cancel escalates straight to force-close so its reserved window
        // (all time up to the absolute final deadline) is preserved.
        if cancelReturned {
            let drained = await deadline.waitForDrain(
                of: resource,
                timeout: schedule.remaining(until: schedule.drainCutoff, now: clock.now)
            )
            if drained { return true }
        }

        let closed = await runBounded(
            timeout: schedule.remaining(until: schedule.finalDeadline, now: clock.now),
            timedOutValue: BoundedStage.timedOut
        ) {
            do {
                try await resource.forceClose()
                return BoundedStage.completed
            } catch {
                return BoundedStage.failed
            }
        }
        return closed == .completed
    }

    /// Runs `operation` in an unstructured detached task and races it against
    /// `timeout`. Returns the operation's value if it finishes first, otherwise
    /// `timedOutValue`. The operation task captures only the injected resource and
    /// the latch — never the arbiter — so an operation that never returns cannot
    /// retain or mutate the arbiter, and the arbiter drops its handle here.
    private func runBounded<R: Sendable>(
        timeout: Duration,
        timedOutValue: R,
        operation: @escaping @Sendable () async -> R
    ) async -> R {
        guard timeout > .zero else { return timedOutValue }
        let latch = MediaIORaceLatch<R>()
        let operationTask = Task.detached { latch.resolve(await operation()) }
        let timerTask = Task.detached {
            do {
                try await ContinuousClock().sleep(for: timeout)
                latch.resolve(timedOutValue)
            } catch {
                latch.resolve(timedOutValue)
            }
        }
        let result = await latch.wait()
        timerTask.cancel()
        operationTask.cancel()
        return result
    }

    fileprivate func finishScanner(generation: UInt64) {
        guard activeScanner?.generation == generation else { return }
        activeScanner = nil
    }

    fileprivate func releasePlayback(id: UUID) {
        playbackIDs.remove(id)
        resumeShutdownDrainIfComplete()
    }

    /// Test-only introspection: the number of playback requests currently holding a
    /// priority reservation but not yet granted a lease.
    func pendingPlaybackReservations() -> Int {
        playbackReservations
    }
}
