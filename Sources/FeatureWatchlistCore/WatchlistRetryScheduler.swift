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
    private var wakeTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    public init(
        profileID: String,
        nextAttempt: @escaping NextAttempt,
        drain: @escaping Drain,
        now: @escaping @Sendable () -> Date = { Date() },
        minimumContentionDelay: TimeInterval = 0.05,
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
        let delay = max(
            minimumDelay,
            max(0, date.timeIntervalSince(now()))
        )
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
