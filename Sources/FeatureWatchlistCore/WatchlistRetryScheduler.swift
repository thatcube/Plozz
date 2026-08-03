import Foundation

public enum WatchlistRetryDrainOutcome: Sendable, Equatable {
    case completed
    case busy
}

/// Owns one cancellation-safe wake task for one profile. Only
/// `.retryScheduled` mutations contribute a wake date; authentication and
/// unsupported-identity work remain dormant until explicit evidence/reconnect.
public actor WatchlistRetryScheduler {
    public typealias NextAttempt =
        @Sendable (_ profileID: String) async -> Date?
    public typealias Drain =
        @Sendable (
            _ profileID: String,
            _ now: Date
        ) async -> WatchlistRetryDrainOutcome
    public typealias Sleeper =
        @Sendable (_ delay: TimeInterval) async throws -> Void

    private let profileID: String
    private let nextAttempt: NextAttempt
    private let drain: Drain
    private let now: @Sendable () -> Date
    private let sleeper: Sleeper
    private let minimumContentionDelay: TimeInterval
    /// Floor between drain waves while a backlog is still working itself off.
    ///
    /// `earliestNextAttempt` reports `.distantPast` whenever anything is queued,
    /// which is "there is work now" rather than a time to wait for. Taking it
    /// literally produced a zero-delay wake → drain → reschedule → wake cycle
    /// that pegged a core for as long as the backlog lasted; on an iPhone that
    /// was measured at ~106% CPU sustained with the device in the Serious
    /// thermal state. A drain wave writes several records and is bounded by the
    /// network anyway, so pacing it costs nothing a person can perceive.
    private let minimumDrainInterval: TimeInterval
    private var wakeTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    public init(
        profileID: String,
        nextAttempt: @escaping NextAttempt,
        drain: @escaping Drain,
        now: @escaping @Sendable () -> Date = { Date() },
        minimumContentionDelay: TimeInterval = 0.05,
        minimumDrainInterval: TimeInterval = 0.25,
        sleeper: @escaping Sleeper = { delay in
            guard delay > 0 else { return }
            try await Task.sleep(
                nanoseconds: UInt64(delay * 1_000_000_000)
            )
        }
    ) {
        self.profileID = profileID
        self.nextAttempt = nextAttempt
        self.drain = drain
        self.now = now
        self.minimumContentionDelay = max(0, minimumContentionDelay)
        self.minimumDrainInterval = max(0, minimumDrainInterval)
        self.sleeper = sleeper
    }

    deinit {
        wakeTask?.cancel()
    }

    public func reschedule() async {
        await reschedule(minimumDelay: 0)
    }

    private func reschedule(minimumDelay: TimeInterval) async {
        generation &+= 1
        let expectedGeneration = generation
        wakeTask?.cancel()
        wakeTask = nil
        guard let date = await nextAttempt(profileID) else { return }
        let scheduled = max(0, date.timeIntervalSince(now()))
        // A due-now date means "work is waiting", not "spin". Anything already
        // due is paced; a genuine future retry keeps its own longer delay.
        let paced = scheduled <= 0 ? minimumDrainInterval : scheduled
        let delay = max(minimumDelay, paced)
        let sleeper = self.sleeper
        wakeTask = Task { [weak self] in
            do {
                try await sleeper(delay)
                try Task.checkCancellation()
            } catch {
                return
            }
            await self?.wake(expectedGeneration: expectedGeneration)
        }
    }

    public func cancel() {
        generation &+= 1
        wakeTask?.cancel()
        wakeTask = nil
    }

    private func wake(expectedGeneration: UInt64) async {
        guard expectedGeneration == generation,
              !Task.isCancelled else { return }
        wakeTask = nil
        let outcome = await drain(profileID, now())
        guard expectedGeneration == generation else { return }
        await reschedule(
            minimumDelay: outcome == .busy ? minimumContentionDelay : 0
        )
    }
}
