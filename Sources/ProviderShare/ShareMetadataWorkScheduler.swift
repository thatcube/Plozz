import Foundation

struct ShareEnrichmentSliceResult: Sendable, Equatable {
    var attempted: Int
    var hasMore: Bool
    var retryAfter: Duration? = nil
}

/// App-wide admission control for share metadata work.
///
/// Opened items jump ahead of the passive backlog. Backlog work runs one slice at a
/// time across every share, waits between slices, and is interrupted by browsing,
/// scanning, or playback without losing its durable SQLite position.
actor ShareMetadataWorkScheduler {
    struct Configuration: Sendable {
        var maxItemsPerSlice: Int
        var maxSliceDuration: Duration
        var delayBetweenSlices: Duration
        var interactiveIdleDelay: Duration
        var blockedPollDelay: Duration

        init(
            maxItemsPerSlice: Int = 10,
            maxSliceDuration: Duration = .seconds(2),
            delayBetweenSlices: Duration = .milliseconds(500),
            interactiveIdleDelay: Duration = .seconds(1),
            blockedPollDelay: Duration = .milliseconds(200)
        ) {
            self.maxItemsPerSlice = max(1, maxItemsPerSlice)
            self.maxSliceDuration = maxSliceDuration
            self.delayBetweenSlices = delayBetweenSlices
            self.interactiveIdleDelay = interactiveIdleDelay
            self.blockedPollDelay = blockedPollDelay
        }
    }

    struct Snapshot: Sendable, Equatable {
        var queuedBacklogs: Int
        var queuedItems: Int
        var runningAccountKey: String?
    }

    typealias MayRun = @Sendable () async -> Bool
    typealias RunSlice = @Sendable (Int, Duration) async -> ShareEnrichmentSliceResult
    typealias RunItem = @Sendable (String) async -> Void
    typealias PassAction = @Sendable () async -> Void

    private struct Job {
        var mayRun: MayRun
        var runSlice: RunSlice
        var runItem: RunItem
        var pausePass: PassAction
        var finishPass: PassAction
        var notBefore: ContinuousClock.Instant?
    }

    private struct UrgentWork: Equatable {
        var accountKey: String
        var itemID: String
    }

    private enum Work: Equatable {
        case item(UrgentWork)
        case backlog(accountKey: String)

        var accountKey: String {
            switch self {
            case .item(let urgent): urgent.accountKey
            case .backlog(let accountKey): accountKey
            }
        }

        var isBacklog: Bool {
            if case .backlog = self { return true }
            return false
        }
    }

    private enum Outcome {
        case item
        case backlog(ShareEnrichmentSliceResult)
    }

    private struct Running {
        var id: UUID
        var work: Work
        var registrationGeneration: UInt64
        var task: Task<Outcome, Never>
    }

    private let configuration: Configuration
    private let clock = ContinuousClock()
    private var jobs: [String: Job] = [:]
    private var backlogQueue: [String] = []
    private var queuedBacklogs: Set<String> = []
    private var urgentQueue: [UrgentWork] = []
    private var queuedUrgentKeys: Set<String> = []
    private var admissionGenerations: [String: UInt64] = [:]
    private var registrationGenerations: [String: UInt64] = [:]
    private var suspensionCounts: [String: Int] = [:]
    private var preferredAccountKeys: Set<String> = []
    private var worker: Task<Void, Never>?
    private var running: Running?

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    func register(
        accountKey: String,
        mayRun: @escaping MayRun,
        runSlice: @escaping RunSlice,
        runItem: @escaping RunItem,
        pausePass: @escaping PassAction = {},
        finishPass: @escaping PassAction = {}
    ) {
        let notBefore = jobs[accountKey]?.notBefore
        admissionGenerations[accountKey, default: 0] &+= 1
        registrationGenerations[accountKey, default: 0] &+= 1
        jobs[accountKey] = Job(
            mayRun: mayRun,
            runSlice: runSlice,
            runItem: runItem,
            pausePass: pausePass,
            finishPass: finishPass,
            notBefore: notBefore
        )
        ensureWorker()
    }

    func enqueueBacklog(accountKey: String) {
        guard jobs[accountKey] != nil else { return }
        requeueBacklog(accountKey)
        ensureWorker()
    }

    func enqueueItem(accountKey: String, itemID: String) {
        guard jobs[accountKey] != nil else { return }
        let urgent = UrgentWork(accountKey: accountKey, itemID: itemID)
        let currentRegistration = registrationGenerations[accountKey, default: 0]
        if running?.work == .item(urgent),
           running?.registrationGeneration == currentRegistration {
            return
        }
        let key = urgentKey(urgent)
        guard queuedUrgentKeys.insert(key).inserted else { return }
        urgentQueue.append(urgent)
        ensureWorker()
    }

    /// Prioritizes the active profile's shares ahead of passive work retained for
    /// other profiles. Urgent opened-item work remains globally first.
    func setPreferredAccountKeys(_ accountKeys: Set<String>) {
        preferredAccountKeys = accountKeys
        if let running,
           running.work.isBacklog,
           !accountKeys.contains(running.work.accountKey),
           backlogQueue.contains(where: { accountKeys.contains($0) }) {
            running.task.cancel()
        }
        ensureWorker()
    }

    func noteInteractiveActivity(accountKey: String) async {
        guard var job = jobs[accountKey] else { return }
        admissionGenerations[accountKey, default: 0] &+= 1
        job.notBefore = clock.now.advanced(by: configuration.interactiveIdleDelay)
        jobs[accountKey] = job
        if running?.work == .backlog(accountKey: accountKey) {
            running?.task.cancel()
        }
        await job.pausePass()
        ensureWorker()
    }

    /// Interrupts the account's current operation. Its queued work remains durable
    /// and automatically resumes when `mayRun` becomes true again.
    func interrupt(accountKey: String) async {
        admissionGenerations[accountKey, default: 0] &+= 1
        if running?.work.accountKey == accountKey {
            running?.task.cancel()
        }
        if let job = jobs[accountKey] {
            await job.pausePass()
        }
        ensureWorker()
    }

    /// Holds an account closed across an external admission transition (scanner or
    /// playback). Counted so nested transitions cannot resume each other early.
    func suspend(accountKey: String) async {
        guard jobs[accountKey] != nil else { return }
        suspensionCounts[accountKey, default: 0] += 1
        admissionGenerations[accountKey, default: 0] &+= 1
        if running?.work.accountKey == accountKey {
            running?.task.cancel()
        }
        if let job = jobs[accountKey] {
            await job.pausePass()
        }
    }

    func resume(accountKey: String) {
        guard let count = suspensionCounts[accountKey] else { return }
        if count <= 1 {
            suspensionCounts[accountKey] = nil
        } else {
            suspensionCounts[accountKey] = count - 1
        }
        ensureWorker()
    }

    func remove(accountKey: String) async {
        let job = jobs.removeValue(forKey: accountKey)
        admissionGenerations[accountKey, default: 0] &+= 1
        registrationGenerations[accountKey, default: 0] &+= 1
        suspensionCounts[accountKey] = nil
        backlogQueue.removeAll { $0 == accountKey }
        queuedBacklogs.remove(accountKey)
        let removed = urgentQueue.filter { $0.accountKey == accountKey }
        urgentQueue.removeAll { $0.accountKey == accountKey }
        for urgent in removed {
            queuedUrgentKeys.remove(urgentKey(urgent))
        }
        let runningTask = running?.work.accountKey == accountKey ? running?.task : nil
        runningTask?.cancel()
        if let job {
            await job.finishPass()
        }
        if let runningTask {
            await runningTask.value
        }
    }

    func snapshot() -> Snapshot {
        Snapshot(
            queuedBacklogs: backlogQueue.count,
            queuedItems: urgentQueue.count,
            runningAccountKey: running?.work.accountKey
        )
    }

    private func ensureWorker() {
        guard worker == nil, hasQueuedWork else { return }
        worker = Task(priority: .utility) { [weak self] in
            await self?.runLoop()
        }
    }

    private func runLoop() async {
        defer {
            worker = nil
            ensureWorker()
        }

        while !Task.isCancelled, hasQueuedWork {
            guard let (work, job) = await dequeueRunnableWork() else {
                await sleep(configuration.blockedPollDelay)
                continue
            }

            let task = Task(priority: .utility) {
                switch work {
                case .item(let urgent):
                    await job.runItem(urgent.itemID)
                    return Outcome.item
                case .backlog:
                    return .backlog(await job.runSlice(
                        configuration.maxItemsPerSlice,
                        configuration.maxSliceDuration
                    ))
                }
            }
            let runningID = UUID()
            let registrationGeneration = registrationGenerations[
                work.accountKey,
                default: 0
            ]
            running = Running(
                id: runningID,
                work: work,
                registrationGeneration: registrationGeneration,
                task: task
            )
            let outcome = await task.value
            let wasCancelled = task.isCancelled
            if running?.id == runningID {
                running = nil
            }
            guard registrationGenerations[work.accountKey, default: 0]
                    == registrationGeneration else {
                continue
            }

            switch outcome {
            case .item:
                if wasCancelled { requeue(work) }
            case .backlog(let result):
                if wasCancelled || result.hasMore {
                    if var updated = jobs[work.accountKey] {
                        let nextDelay = result.retryAfter ?? configuration.delayBetweenSlices
                        let sliceDelay = clock.now.advanced(
                            by: nextDelay
                        )
                        if updated.notBefore == nil || updated.notBefore! < sliceDelay {
                            updated.notBefore = sliceDelay
                        }
                        jobs[work.accountKey] = updated
                    }
                    requeue(work)
                }
            }
        }
    }

    private var hasQueuedWork: Bool {
        !urgentQueue.isEmpty || !backlogQueue.isEmpty
    }

    /// Tries every currently queued item once so one playback-blocked share cannot
    /// starve runnable work from other accounts.
    private func dequeueRunnableWork() async -> (Work, Job)? {
        let candidates =
            urgentQueue.map(Work.item)
            + backlogQueue
                .filter { preferredAccountKeys.contains($0) }
                .map { Work.backlog(accountKey: $0) }
            + backlogQueue
                .filter { !preferredAccountKeys.contains($0) }
                .map { Work.backlog(accountKey: $0) }
        for work in candidates {
            guard takeQueued(work), let job = jobs[work.accountKey] else { continue }
            if suspensionCounts[work.accountKey, default: 0] > 0 {
                requeue(work)
                continue
            }
            if work.isBacklog,
               let notBefore = job.notBefore,
               clock.now < notBefore {
                requeue(work)
                continue
            }
            let admissionGeneration = admissionGenerations[work.accountKey, default: 0]
            if await job.mayRun(),
               jobs[work.accountKey] != nil,
               admissionGenerations[work.accountKey, default: 0] == admissionGeneration,
               suspensionCounts[work.accountKey, default: 0] == 0 {
                // An enqueue may have landed while `mayRun` yielded the actor.
                // Consume that duplicate before returning the admitted work.
                _ = takeQueued(work)
                return (work, job)
            }
            requeue(work)
        }
        return nil
    }

    private func takeQueued(_ work: Work) -> Bool {
        switch work {
        case .item(let urgent):
            guard let index = urgentQueue.firstIndex(of: urgent) else {
                return false
            }
            urgentQueue.remove(at: index)
            queuedUrgentKeys.remove(urgentKey(urgent))
            return true
        case .backlog(let accountKey):
            guard let index = backlogQueue.firstIndex(of: accountKey) else {
                return false
            }
            backlogQueue.remove(at: index)
            queuedBacklogs.remove(accountKey)
            return true
        }
    }

    private func requeue(_ work: Work) {
        guard jobs[work.accountKey] != nil else { return }
        switch work {
        case .item(let urgent):
            let key = urgentKey(urgent)
            if queuedUrgentKeys.insert(key).inserted {
                urgentQueue.append(urgent)
            }
        case .backlog(let accountKey):
            requeueBacklog(accountKey)
        }
    }

    private func requeueBacklog(_ accountKey: String) {
        guard queuedBacklogs.insert(accountKey).inserted else { return }
        backlogQueue.append(accountKey)
    }

    private func urgentKey(_ work: UrgentWork) -> String {
        "\(work.accountKey)\u{0}\(work.itemID)"
    }

    private func sleep(_ duration: Duration) async {
        do {
            try await clock.sleep(for: duration)
        } catch {
            // A cancelled worker exits at the loop condition.
        }
    }
}
