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
        /// Consecutive preferred backlog admissions after which one runnable
        /// non-preferred account is surfaced ahead of the preferred bias. Must be
        /// at least 1; larger values bias the active profile more strongly.
        var preferredBacklogBurst: Int
        /// A non-preferred backlog account that has waited this long is promoted
        /// ahead of the preferred bias regardless of the burst counter.
        var nonPreferredAgePromotion: Duration

        init(
            maxItemsPerSlice: Int = 10,
            maxSliceDuration: Duration = .seconds(2),
            delayBetweenSlices: Duration = .milliseconds(500),
            interactiveIdleDelay: Duration = .seconds(1),
            blockedPollDelay: Duration = .milliseconds(200),
            preferredBacklogBurst: Int = 4,
            nonPreferredAgePromotion: Duration = .seconds(30)
        ) {
            self.maxItemsPerSlice = max(1, maxItemsPerSlice)
            self.maxSliceDuration = maxSliceDuration
            self.delayBetweenSlices = delayBetweenSlices
            self.interactiveIdleDelay = interactiveIdleDelay
            self.blockedPollDelay = blockedPollDelay
            self.preferredBacklogBurst = max(1, preferredBacklogBurst)
            self.nonPreferredAgePromotion = nonPreferredAgePromotion
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

    /// A queued unit of work tagged with the account registration generation that
    /// was current when it was enqueued, plus the instant it entered the queue.
    ///
    /// The generation lets the scheduler DISCARD work whose registration was
    /// replaced (`remove` + `register`) while it sat in the queue or was suspended
    /// mid-admission, so stale work can never requeue into — or run under — a
    /// replacement registration (finding A3). `enqueuedAt` drives backlog fairness
    /// aging (finding A6).
    private struct QueuedWork {
        var work: Work
        var registrationGeneration: UInt64
        var enqueuedAt: ContinuousClock.Instant
    }

    private let configuration: Configuration
    private let clock = ContinuousClock()
    private let fairnessPolicy: ShareBacklogFairnessPolicy
    private var jobs: [String: Job] = [:]
    private var backlogQueue: [QueuedWork] = []
    private var queuedBacklogs: Set<String> = []
    private var urgentQueue: [QueuedWork] = []
    private var queuedUrgentKeys: Set<String> = []
    private var admissionGenerations: [String: UInt64] = [:]
    private var registrationGenerations: [String: UInt64] = [:]
    private var suspensionCounts: [String: Int] = [:]
    private var preferredAccountKeys: Set<String> = []
    /// Preferred backlog admissions that ran back-to-back with no intervening
    /// non-preferred admission. Updated only on a REAL admission so a blocked
    /// account cannot consume the burst quota.
    private var consecutivePreferredBacklogAdmissions = 0
    private var worker: Task<Void, Never>?
    private var running: Running?

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.fairnessPolicy = ShareBacklogFairnessPolicy(
            preferredBurst: configuration.preferredBacklogBurst,
            agePromotion: configuration.nonPreferredAgePromotion
        )
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
        urgentQueue.append(QueuedWork(
            work: .item(urgent),
            registrationGeneration: currentRegistration,
            enqueuedAt: clock.now
        ))
        ensureWorker()
    }

    /// Prioritizes the active profile's shares ahead of passive work retained for
    /// other profiles. Urgent opened-item work remains globally first.
    func setPreferredAccountKeys(_ accountKeys: Set<String>) {
        preferredAccountKeys = accountKeys
        if let running,
           running.work.isBacklog,
           !accountKeys.contains(running.work.accountKey),
           backlogQueue.contains(where: { accountKeys.contains($0.work.accountKey) }) {
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
        backlogQueue.removeAll { $0.work.accountKey == accountKey }
        queuedBacklogs.remove(accountKey)
        let removed = urgentQueue.filter { $0.work.accountKey == accountKey }
        urgentQueue.removeAll { $0.work.accountKey == accountKey }
        for queued in removed {
            if case .item(let urgent) = queued.work {
                queuedUrgentKeys.remove(urgentKey(urgent))
            }
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
            guard let (queued, job) = await dequeueRunnableWork() else {
                await sleep(configuration.blockedPollDelay)
                continue
            }
            let work = queued.work

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
            running = Running(
                id: runningID,
                work: work,
                registrationGeneration: queued.registrationGeneration,
                task: task
            )
            let outcome = await task.value
            let wasCancelled = task.isCancelled
            if running?.id == runningID {
                running = nil
            }
            // The registration that owned this work may have been replaced while it
            // ran; if so, discard rather than requeue into the replacement (A3).
            guard registrationGenerations[work.accountKey, default: 0]
                    == queued.registrationGeneration else {
                continue
            }

            switch outcome {
            case .item:
                // A served turn restarts age; requeue is generation-guarded.
                if wasCancelled { requeue(queued, resetAge: true) }
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
                    requeue(queued, resetAge: true)
                }
            }
        }
    }

    private var hasQueuedWork: Bool {
        !urgentQueue.isEmpty || !backlogQueue.isEmpty
    }

    /// Tries every currently queued item once so one playback-blocked share cannot
    /// starve runnable work from other accounts. Urgent opened-item work is globally
    /// first; backlog order comes from the pure fairness policy.
    private func dequeueRunnableWork() async -> (QueuedWork, Job)? {
        let now = clock.now
        let backlogByKey = Dictionary(
            backlogQueue.map { ($0.work.accountKey, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let orderedBacklogKeys = fairnessPolicy.order(
            candidates: backlogQueue.map {
                ShareBacklogFairnessPolicy.Candidate(
                    accountKey: $0.work.accountKey,
                    isPreferred: preferredAccountKeys.contains($0.work.accountKey),
                    enqueuedAt: $0.enqueuedAt
                )
            },
            consecutivePreferredAdmissions: consecutivePreferredBacklogAdmissions,
            now: now
        )
        let candidates: [QueuedWork] =
            urgentQueue + orderedBacklogKeys.compactMap { backlogByKey[$0] }

        for queued in candidates {
            let work = queued.work
            guard takeQueued(work), let job = jobs[work.accountKey] else { continue }
            if suspensionCounts[work.accountKey, default: 0] > 0 {
                requeue(queued, resetAge: false)
                continue
            }
            if work.isBacklog,
               let notBefore = job.notBefore,
               clock.now < notBefore {
                requeue(queued, resetAge: false)
                continue
            }
            let admissionGeneration = admissionGenerations[work.accountKey, default: 0]
            if await job.mayRun(),
               jobs[work.accountKey] != nil,
               admissionGenerations[work.accountKey, default: 0] == admissionGeneration,
               registrationGenerations[work.accountKey, default: 0] == queued.registrationGeneration,
               suspensionCounts[work.accountKey, default: 0] == 0 {
                // An enqueue may have landed while `mayRun` yielded the actor.
                // Consume that duplicate before returning the admitted work.
                _ = takeQueued(work)
                noteAdmission(work)
                return (queued, job)
            }
            // Failed admission (blocked/suspended/replaced): preserve age; a stale
            // registration is discarded by `requeue`'s generation guard.
            requeue(queued, resetAge: false)
        }
        return nil
    }

    /// Records that `work` was actually admitted, updating the preferred-burst
    /// counter. Only a real admission moves the counter, so a blocked account can
    /// never consume the burst quota. Urgent work leaves the counter unchanged.
    private func noteAdmission(_ work: Work) {
        guard case .backlog(let accountKey) = work else { return }
        if preferredAccountKeys.contains(accountKey) {
            consecutivePreferredBacklogAdmissions += 1
        } else {
            consecutivePreferredBacklogAdmissions = 0
        }
    }

    private func takeQueued(_ work: Work) -> Bool {
        switch work {
        case .item(let urgent):
            guard let index = urgentQueue.firstIndex(where: { $0.work == .item(urgent) }) else {
                return false
            }
            urgentQueue.remove(at: index)
            queuedUrgentKeys.remove(urgentKey(urgent))
            return true
        case .backlog(let accountKey):
            guard let index = backlogQueue.firstIndex(where: {
                $0.work == .backlog(accountKey: accountKey)
            }) else {
                return false
            }
            backlogQueue.remove(at: index)
            queuedBacklogs.remove(accountKey)
            return true
        }
    }

    /// Re-enqueues previously admitted/queued work, DISCARDING it if the account was
    /// removed or its registration was replaced since the work was tagged (A3).
    /// `resetAge` restarts the fairness age for a work item that just took a served
    /// turn; a failed admission preserves the age so it keeps aging toward promotion.
    private func requeue(_ queued: QueuedWork, resetAge: Bool) {
        let accountKey = queued.work.accountKey
        guard jobs[accountKey] != nil,
              registrationGenerations[accountKey, default: 0] == queued.registrationGeneration else {
            return
        }
        let enqueuedAt = resetAge ? clock.now : queued.enqueuedAt
        switch queued.work {
        case .item(let urgent):
            guard queuedUrgentKeys.insert(urgentKey(urgent)).inserted else { return }
            urgentQueue.append(QueuedWork(
                work: .item(urgent),
                registrationGeneration: queued.registrationGeneration,
                enqueuedAt: enqueuedAt
            ))
        case .backlog(let accountKey):
            guard queuedBacklogs.insert(accountKey).inserted else { return }
            backlogQueue.append(QueuedWork(
                work: .backlog(accountKey: accountKey),
                registrationGeneration: queued.registrationGeneration,
                enqueuedAt: enqueuedAt
            ))
        }
    }

    private func requeueBacklog(_ accountKey: String) {
        guard queuedBacklogs.insert(accountKey).inserted else { return }
        backlogQueue.append(QueuedWork(
            work: .backlog(accountKey: accountKey),
            registrationGeneration: registrationGenerations[accountKey, default: 0],
            enqueuedAt: clock.now
        ))
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
