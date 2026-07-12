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

    public let accountID: String
    private let deadline: any MediaIODrainDeadline
    private let drainTimeout: Duration
    private var nextGeneration: UInt64 = 0
    private var activeScanner: ScannerAdmission?
    private var playbackIDs: Set<UUID> = []
    private var playbackPending = false
    private var scannerTransitionPending = false

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
        guard playbackIDs.isEmpty, !playbackPending, !scannerTransitionPending else {
            throw MediaTransportError.resourceBusy
        }
        nextGeneration &+= 1
        let generation = nextGeneration
        scannerTransitionPending = true
        defer { scannerTransitionPending = false }
        if let replaced = activeScanner {
            do {
                try await stopAndDrain(replaced)
            } catch {
                throw MediaTransportError.resourceBusy
            }
            if activeScanner?.generation == replaced.generation {
                activeScanner = nil
            }
        }
        try Task.checkCancellation()
        guard playbackIDs.isEmpty, !playbackPending, activeScanner == nil else {
            throw MediaTransportError.resourceBusy
        }
        activeScanner = ScannerAdmission(
            generation: generation,
            resource: resource
        )
        return MediaIOScannerLease(generation: generation, arbiter: self)
    }

    public func acquirePlayback() async throws -> MediaIOPlaybackLease {
        guard !playbackPending, !scannerTransitionPending else {
            throw MediaTransportError.resourceBusy
        }
        if activeScanner == nil {
            let id = UUID()
            playbackIDs.insert(id)
            return MediaIOPlaybackLease(id: id, arbiter: self)
        }
        playbackPending = true
        defer { playbackPending = false }
        if let scanner = activeScanner {
            do {
                try await stopAndDrain(scanner)
            } catch {
                throw MediaTransportError.resourceBusy
            }
            if activeScanner?.generation == scanner.generation {
                activeScanner = nil
            }
        }
        try Task.checkCancellation()
        guard activeScanner == nil, !scannerTransitionPending else {
            throw MediaTransportError.resourceBusy
        }
        let id = UUID()
        playbackIDs.insert(id)
        return MediaIOPlaybackLease(id: id, arbiter: self)
    }

    private func stopAndDrain(_ scanner: ScannerAdmission) async throws {
        await scanner.resource.cancel()
        let drained = await deadline.waitForDrain(
            of: scanner.resource,
            timeout: drainTimeout
        )
        if !drained {
            try await scanner.resource.forceClose()
        }
    }

    fileprivate func finishScanner(generation: UInt64) {
        guard activeScanner?.generation == generation else { return }
        activeScanner = nil
    }

    fileprivate func releasePlayback(id: UUID) {
        playbackIDs.remove(id)
    }
}
