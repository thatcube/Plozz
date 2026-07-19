#if canImport(UIKit)
import UIKit
import ImageIO
import CoreModels

/// Process-wide, in-memory cache of *decoded* artwork images, keyed by source URL
/// and target variant.
///
/// `URLCache.shared` keeps recently-fetched image *bytes* warm, but reading and
/// decoding those bytes is still asynchronous, so a card scrolled into view would
/// render a gray placeholder for a frame or two before its image appears — most
/// visible while holding RIGHT to blast through an episode rail. This cache lets a
/// card read its already-decoded image *synchronously* on first render (no async
/// hop, no gray frame), and lets a rail prefetch/decode upcoming cards ahead of
/// scroll so their art is ready the instant they appear.
///
/// Images are force-decoded off the main thread (`preparingForDisplay`) before
/// being stored, so handing one to SwiftUI never triggers a main-thread decode.
public final class ArtworkImageCache: NSObject, @unchecked Sendable {
    public static let shared = ArtworkImageCache()

    private enum Source: Hashable {
        case url(URL)
        case network(NetworkArtworkReference)
    }

    private struct CacheKey: Hashable {
        let source: Source
        let variant: ArtworkImageVariant

        init(url: URL, variant: ArtworkImageVariant) {
            self.source = .url(url)
            self.variant = variant
        }

        init(reference: NetworkArtworkReference, variant: ArtworkImageVariant) {
            self.source = .network(reference)
            self.variant = variant
        }

        var cacheKey: NSString {
            switch source {
            case let .url(url):
                return variant.cacheKey(for: url) as NSString
            case let .network(reference):
                // This decoded-memory key contains no transport path. Source
                // revision changes naturally invalidate the image.
                return "\(variant.rawValue)|network|\(reference.accountID)|\(reference.credentialRevision.rawValue.uuidString)|\(reference.sourceRevision)" as NSString
            }
        }

    }

    private struct NetworkRevisionScope: Hashable {
        let accountID: String
        let credentialRevision: CredentialRevision
    }

    private struct NetworkInvalidationToken: Equatable {
        let accountGeneration: UInt64
        let revisionGeneration: UInt64
    }

    private final class CachedImageEntry: NSObject {
        let image: UIImage
        let key: CacheKey
        let cost: Int

        init(image: UIImage, key: CacheKey, cost: Int) {
            self.image = image
            self.key = key
            self.cost = cost
        }
    }

    private let cache = NSCache<NSString, CachedImageEntry>()
    private let lock = NSLock()
    private let decodedIndexLock = NSLock()

    /// Live decoded-cache accounting (diagnostic). Tracks resident image count and
    /// approximate decoded byte cost so the browse memory sampler can separate
    /// "the decoded-image cache is growing" from "render surfaces / view backing
    /// stores are growing" — the two have completely different fixes. Updated on
    /// store (+) and on NSCache eviction (via `NSCacheDelegate`, -). Gated by
    /// `BrowseDiagnostics.isEnabled` (the `PLZXMEM` dev flag) so the accounting is
    /// entirely free — no lock, no counters — in a normal/shipped run; it only
    /// tracks while the on-device memory sampler is active during development.
    nonisolated(unsafe) private static var liveCount = 0
    nonisolated(unsafe) private static var liveCostBytes = 0
    private static let statsLock = NSLock()
    private static let statsEnabled = BrowseDiagnostics.isEnabled
    public struct CacheStats: Sendable { public let count: Int; public let costMB: Double }
    public static func cacheStats() -> CacheStats {
        statsLock.lock(); defer { statsLock.unlock() }
        return CacheStats(count: liveCount, costMB: Double(liveCostBytes) / (1024 * 1024))
    }
    /// Instance convenience for callers holding `.shared`.
    public func currentStats() -> CacheStats { Self.cacheStats() }
    private static func noteStored(cost: Int) {
        guard statsEnabled else { return }
        statsLock.lock(); liveCount += 1; liveCostBytes += cost; statsLock.unlock()
    }
    private static func noteEvicted(cost: Int) {
        guard statsEnabled else { return }
        statsLock.lock(); liveCount = max(0, liveCount - 1); liveCostBytes = max(0, liveCostBytes - cost); statsLock.unlock()
    }
    /// Reset accounting to empty — used by the memory-warning flush, which calls
    /// `removeAllObjects()` (NSCache does not fire `willEvictObject:` for that).
    private static func noteFlushedAll() {
        guard statsEnabled else { return }
        statsLock.lock(); liveCount = 0; liveCostBytes = 0; statsLock.unlock()
    }
    /// Dedicated, bounded queue for the *synchronous* image decode
    /// (`CGImageSourceCreateThumbnailAtIndex` / `preparingForDisplay`). This work
    /// is CPU-bound, and running it inside `Task.detached` executes it directly on
    /// Swift's small cooperative thread pool (only ~2-3 threads on tvOS). A scroll
    /// burst through a library — especially thumbnail-less cells that try several
    /// candidate URLs — would then fire many concurrent decodes that occupy every
    /// cooperative thread, starving unrelated `async` continuations (a foreground
    /// `provider.item`/cross-server `search`, even `Task.sleep` timeouts) for
    /// seconds. Moving decode onto its own bounded `OperationQueue` keeps that CPU
    /// off the cooperative pool entirely, so artwork can never freeze the app.
    /// Foreground decode lane for artwork the user is actually looking at (a
    /// visible card or the detail hero awaiting `image(for:)`). Runs at
    /// `.userInitiated` so it is scheduled ahead of background warming.
    private static let decodeQueueFG: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
        return queue
    }()
    /// Background decode lane for prefetch/warm work (rail prewarm, season
    /// still prefetch). Kept fully separate from the foreground lane so a
    /// prewarm storm can never make a visible card's decode wait behind it.
    private static let decodeQueueBG: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .utility
        return queue
    }()
    private enum ImageLoadState {
        case pending
        case finished(UIImage?)
    }

    /// One coalesced load of a single URL+variant. Every caller gets its own
    /// continuation so cancelling one waiter returns immediately without cancelling
    /// a transfer another visible/background consumer still needs. When the final
    /// waiter leaves, the shared download/decode is cancelled as before.
    private final class ImageLoad: @unchecked Sendable {
        var task: Task<Void, Never>!
        var state: ImageLoadState = .pending
        var waiterIsForeground: [UUID: Bool] = [:]
        var continuations: [UUID: CheckedContinuation<UIImage?, Never>] = [:]
        var foregroundWaiterCount = 0
        var decodeJob: DecodeJob?
        let networkInvalidationToken: NetworkInvalidationToken?

        init(networkInvalidationToken: NetworkInvalidationToken?) {
            self.networkInvalidationToken = networkInvalidationToken
        }
    }

    private struct ImageWaiter: @unchecked Sendable {
        let id: UUID
        let key: CacheKey
        let load: ImageLoad
    }

    /// Cancellation-aware bridge around ImageIO's synchronous thumbnail decode.
    /// Cancelling before this operation starts removes it from the queue entirely;
    /// cancelling after it starts resumes the async caller immediately and discards
    /// the unavoidable synchronous result when ImageIO returns.
    private final class DecodeJob: @unchecked Sendable {
        private let lock = NSLock()
        private let decode: () -> UIImage?
        private var continuation: CheckedContinuation<UIImage?, Never>?
        private var operation: BlockOperation?
        private var finished = false
        private var promotionRequested = false
        private var decodeStarted = false
        private var operationIsForeground = false

        init(foregroundRequested: Bool, decode: @escaping () -> UIImage?) {
            self.promotionRequested = foregroundRequested
            self.decode = decode
        }

        func install(continuation: CheckedContinuation<UIImage?, Never>) -> Bool {
            lock.lock()
            guard !finished else {
                lock.unlock()
                continuation.resume(returning: nil)
                return false
            }
            self.continuation = continuation
            lock.unlock()
            return true
        }

        func start(
            backgroundQueue: OperationQueue,
            foregroundQueue: OperationQueue
        ) {
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            let useForeground = promotionRequested
            let operation = makeOperation(foreground: useForeground)
            self.operation = operation
            operationIsForeground = useForeground
            lock.unlock()
            (useForeground ? foregroundQueue : backgroundQueue).addOperation(operation)
        }

        private func makeOperation(foreground: Bool) -> BlockOperation {
            let operation = BlockOperation()
            operation.qualityOfService = foreground ? .userInitiated : .utility
            operation.queuePriority = foreground ? .veryHigh : .normal
            operation.addExecutionBlock { [weak self, weak operation] in
                guard let self, let operation, self.claim(operation) else { return }
                let image = autoreleasepool { self.decode() }
                self.finish(with: image)
            }
            return operation
        }

        /// Only the operation currently owned by this job may enter ImageIO. A
        /// foreground promotion replaces a queued background operation; this claim
        /// closes the race where the canceled operation begins while its replacement
        /// is being enqueued, so the bitmap is still decoded exactly once.
        private func claim(_ operation: BlockOperation) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !finished,
                  !decodeStarted,
                  self.operation === operation,
                  !operation.isCancelled
            else { return false }
            decodeStarted = true
            return true
        }

        private func finish(with image: UIImage?) {
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            finished = true
            let continuation = self.continuation
            self.continuation = nil
            operation = nil
            lock.unlock()
            continuation?.resume(returning: image)
        }

        func cancel() {
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            finished = true
            let continuation = self.continuation
            let operation = self.operation
            self.continuation = nil
            self.operation = nil
            lock.unlock()
            operation?.cancel()
            continuation?.resume(returning: nil)
        }

        func promote(to foregroundQueue: OperationQueue) {
            lock.lock()
            promotionRequested = true
            guard !finished,
                  !decodeStarted,
                  !operationIsForeground,
                  let oldOperation = operation
            else {
                lock.unlock()
                return
            }
            // `claim` checks operation identity under this same lock. Replacing the
            // identity before unlocking guarantees the old block can no longer enter
            // ImageIO, even if OperationQueue marks it executing concurrently.
            oldOperation.cancel()
            let replacement = makeOperation(foreground: true)
            operation = replacement
            operationIsForeground = true
            lock.unlock()
            foregroundQueue.addOperation(replacement)
        }

        func demote(to backgroundQueue: OperationQueue) {
            lock.lock()
            promotionRequested = false
            guard !finished,
                  !decodeStarted,
                  operationIsForeground,
                  let oldOperation = operation
            else {
                lock.unlock()
                return
            }
            oldOperation.cancel()
            let replacement = makeOperation(foreground: false)
            operation = replacement
            operationIsForeground = false
            lock.unlock()
            backgroundQueue.addOperation(replacement)
        }
    }
    /// In-flight image loads keyed by URL+variant so a card's own load and the
    /// rail's prefetch never decode the same target twice.
    private var inFlight: [CacheKey: ImageLoad] = [:]
    private var decodedNetworkKeys = Set<CacheKey>()
    private var accountInvalidationGenerations: [String: UInt64] = [:]
    private var revisionInvalidationGenerations: [NetworkRevisionScope: UInt64] = [:]
    private var purgingAccountCounts: [String: Int] = [:]
    private var purgingRevisionCounts: [NetworkRevisionScope: Int] = [:]
    private var networkFileService: ArtworkNetworkFileService?
    private let derivedCache = LocalArtworkDerivedCache()
    private static let networkForegroundLimiter = ConcurrencyLimiter(limit: 2)
    private static let networkBackgroundLimiter = ConcurrencyLimiter(limit: 2)

    private override init() {
        super.init()
        cache.delegate = self
        // Decoded landscape/poster thumbnails are small; cap retained pixels so the
        // cache stays bounded on long seasons (NSCache evicts under memory pressure
        // regardless).
        cache.totalCostLimit = 96 * 1024 * 1024
        // Belt-and-suspenders: NSCache already evicts under pressure, but a decoded
        // poster/hero wall can spike the footprint faster than that fires. Purge the
        // decoded cache on a real memory warning so we shed the biggest reclaimable
        // allocation immediately instead of risking a jettison (tvOS limits are
        // tight; a browse session that opens several 4K-source heroes can climb
        // hundreds of MB before the OS reclaims). Bytes stay warm in `URLCache`, so
        // re-decode is cheap.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.lock.withLock {
                self.cache.removeAllObjects()
                self.decodedIndexLock.withLock {
                    self.decodedNetworkKeys.removeAll()
                }
            }
            // NSCache does NOT call `willEvictObject:` for `removeAllObjects()`
            // (only for automatic cost/pressure eviction), so reset the diagnostic
            // accounting directly here — otherwise the PLZXMEM sampler would stay
            // over-counted after a memory warning.
            Self.noteFlushedAll()
            Task { [weak self] in
                guard let self else { return }
                self.cancelBackgroundPrefetches()
                await self.derivedCache.trimForMemoryWarning()
            }
        }
    }

    /// Configured once at the app composition boundary. `CoreUI` never imports the
    /// transport implementation or has access to media-share credentials.
    public func configure(networkFileService: ArtworkNetworkFileService?) {
        lock.withLock { self.networkFileService = networkFileService }
    }

    public func setPreferredNetworkArtworkAccounts(_ accounts: Set<String>, revision: UInt64) async {
        await derivedCache.setPreferredAccounts(accounts, revision: revision)
    }

    public func purgeNetworkArtwork(accountID: String) async {
        let tasks = beginNetworkArtworkInvalidation(
            accountID: accountID,
            credentialRevision: nil
        )
        for task in tasks { await task.value }
        await derivedCache.purge(accountID: accountID)
        await HeroLogoPipeline.shared.purgeNetworkArtwork(
            accountID: accountID,
            credentialRevision: nil
        )
        endNetworkArtworkInvalidation(accountID: accountID, credentialRevision: nil)
    }

    public func purgeNetworkArtwork(accountID: String, credentialRevision: CredentialRevision) async {
        let tasks = beginNetworkArtworkInvalidation(
            accountID: accountID,
            credentialRevision: credentialRevision
        )
        for task in tasks { await task.value }
        await derivedCache.purge(accountID: accountID, credentialRevision: credentialRevision.rawValue.uuidString)
        await HeroLogoPipeline.shared.purgeNetworkArtwork(
            accountID: accountID,
            credentialRevision: credentialRevision
        )
        endNetworkArtworkInvalidation(
            accountID: accountID,
            credentialRevision: credentialRevision
        )
    }

    /// The decoded image for `url`+`variant` if one is already resident, read
    /// synchronously.
    public func cachedImage(for url: URL, variant: ArtworkImageVariant = .original) -> UIImage? {
        cache.object(forKey: CacheKey(url: url, variant: variant).cacheKey)?.image
    }

    /// Synchronous decoded-cache lookup for a direct-share reference.
    public func cachedImage(
        for reference: ArtworkReference,
        variant: ArtworkImageVariant = .original
    ) -> UIImage? {
        guard case let .networkFile(network) = reference else {
            if case let .remote(url) = reference { return cachedImage(for: url, variant: variant) }
            return nil
        }
        return cache.object(forKey: CacheKey(reference: network, variant: variant).cacheKey)?.image
    }

    /// Returns the decoded image for `url`+`variant`, serving a cached copy
    /// immediately when present and otherwise downloading + decoding it once
    /// (coalescing concurrent callers). Result is stored for synchronous reuse via
    /// `cachedImage(for:variant:)`.
    @discardableResult
    public func image(for url: URL, variant: ArtworkImageVariant = .original, background: Bool = false) async -> UIImage? {
        if let cached = cachedImage(for: url, variant: variant) { return cached }
        let key = CacheKey(url: url, variant: variant)
        guard let waiter = registerWaiter(for: key, background: background) else { return nil }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                install(continuation, for: waiter)
            }
        } onCancel: {
            unregisterWaiter(waiter)
        }
    }

    /// Loads one ordered reference. Remote URLs intentionally keep their existing
    /// ArtworkSession path; direct-share references use the injected narrow model
    /// abstraction and report terminal failures for their exact fingerprint.
    @discardableResult
    public func image(
        for reference: ArtworkReference,
        variant: ArtworkImageVariant = .original,
        background: Bool = false
    ) async -> UIImage? {
        switch reference {
        case let .remote(url):
            return await image(for: url, variant: variant, background: background)
        case let .networkFile(network):
            guard networkArtworkIsAdmitted(network) else { return nil }
            if let cached = cache.object(forKey: CacheKey(reference: network, variant: variant).cacheKey)?.image {
                return cached
            }
            let key = CacheKey(reference: network, variant: variant)
            guard let waiter = registerWaiter(for: key, background: background) else { return nil }
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in install(continuation, for: waiter) }
            } onCancel: {
                unregisterWaiter(waiter)
            }
        }
    }

    /// Warms the cache for `url`+`variant` without awaiting the result —
    /// fire-and-forget prefetch used by rails to decode upcoming cards ahead of
    /// scroll. Bounded by the shared background-warm limiter so a prewarm/scroll
    /// burst can't flood the artwork connection pool and starve foreground art.
    public func prefetch(_ url: URL, variant: ArtworkImageVariant = .original) {
        guard cachedImage(for: url, variant: variant) == nil else { return }
        Task.detached(priority: .utility) {
            await ArtworkSession.warmLimiter.run {
                _ = await ArtworkImageCache.shared.image(for: url, variant: variant, background: true)
            }
        }
    }

    public func prefetch(_ reference: ArtworkReference, variant: ArtworkImageVariant = .original) {
        guard cachedImage(for: reference, variant: variant) == nil else { return }
        Task.detached(priority: .utility) {
            await ArtworkSession.warmLimiter.run {
                _ = await ArtworkImageCache.shared.image(for: reference, variant: variant, background: true)
            }
        }
    }

    private func cancelBackgroundPrefetches() {
        lock.withLock {
            for load in inFlight.values where load.foregroundWaiterCount == 0 {
                load.task.cancel()
                load.decodeJob?.cancel()
            }
            inFlight = inFlight.filter { $0.value.foregroundWaiterCount > 0 }
        }
    }

    private func beginNetworkArtworkInvalidation(
        accountID: String,
        credentialRevision: CredentialRevision?
    ) -> [Task<Void, Never>] {
        var decodedKeys: [CacheKey] = []
        var cancelledLoads: [(CacheKey, ImageLoad)] = []
        lock.lock()
        if let credentialRevision {
            let scope = NetworkRevisionScope(
                accountID: accountID,
                credentialRevision: credentialRevision
            )
            purgingRevisionCounts[scope, default: 0] += 1
            revisionInvalidationGenerations[scope, default: 0] &+= 1
        } else {
            purgingAccountCounts[accountID, default: 0] += 1
            accountInvalidationGenerations[accountID, default: 0] &+= 1
        }
        decodedKeys = decodedIndexLock.withLock {
            let matches = decodedNetworkKeys.filter {
                networkKey($0, matches: accountID, credentialRevision: credentialRevision)
            }
            decodedNetworkKeys.subtract(matches)
            return Array(matches)
        }
        cancelledLoads = inFlight.compactMap { key, load in
            networkKey(key, matches: accountID, credentialRevision: credentialRevision)
                ? (key, load)
                : nil
        }
        for (key, _) in cancelledLoads {
            inFlight[key] = nil
        }
        lock.unlock()

        for key in decodedKeys {
            cache.removeObject(forKey: key.cacheKey)
        }
        for (key, load) in cancelledLoads {
            load.task.cancel()
            load.decodeJob?.cancel()
            finishLoad(load, for: key, with: nil)
        }
        return cancelledLoads.map { $0.1.task }
    }

    private func endNetworkArtworkInvalidation(
        accountID: String,
        credentialRevision: CredentialRevision?
    ) {
        lock.withLock {
            if let credentialRevision {
                let scope = NetworkRevisionScope(
                    accountID: accountID,
                    credentialRevision: credentialRevision
                )
                let next = max(0, purgingRevisionCounts[scope, default: 1] - 1)
                purgingRevisionCounts[scope] = next == 0 ? nil : next
            } else {
                let next = max(0, purgingAccountCounts[accountID, default: 1] - 1)
                purgingAccountCounts[accountID] = next == 0 ? nil : next
            }
        }
    }

    private func networkKey(
        _ key: CacheKey,
        matches accountID: String,
        credentialRevision: CredentialRevision?
    ) -> Bool {
        guard case let .network(reference) = key.source,
              reference.accountID == accountID else { return false }
        return credentialRevision == nil || reference.credentialRevision == credentialRevision
    }

    /// Must be called while `lock` is held.
    private func networkInvalidationToken(for key: CacheKey) -> NetworkInvalidationToken? {
        guard case let .network(reference) = key.source else { return nil }
        let scope = NetworkRevisionScope(
            accountID: reference.accountID,
            credentialRevision: reference.credentialRevision
        )
        return NetworkInvalidationToken(
            accountGeneration: accountInvalidationGenerations[reference.accountID, default: 0],
            revisionGeneration: revisionInvalidationGenerations[scope, default: 0]
        )
    }

    private func networkLoadIsCurrent(_ load: ImageLoad, for key: CacheKey) -> Bool {
        lock.withLock {
            load.networkInvalidationToken == networkInvalidationToken(for: key)
                && networkArtworkIsAdmittedLocked(for: key)
        }
    }

    private func networkArtworkIsAdmitted(_ reference: NetworkArtworkReference) -> Bool {
        lock.withLock {
            networkArtworkIsAdmittedLocked(reference)
        }
    }

    /// Must be called while `lock` is held.
    private func networkArtworkIsAdmittedLocked(_ reference: NetworkArtworkReference) -> Bool {
        let scope = NetworkRevisionScope(
            accountID: reference.accountID,
            credentialRevision: reference.credentialRevision
        )
        return purgingAccountCounts[reference.accountID, default: 0] == 0
            && purgingRevisionCounts[scope, default: 0] == 0
    }

    /// Must be called while `lock` is held.
    private func networkArtworkIsAdmittedLocked(for key: CacheKey) -> Bool {
        guard case let .network(reference) = key.source else { return true }
        return networkArtworkIsAdmittedLocked(reference)
    }

    private func registerWaiter(for key: CacheKey, background: Bool) -> ImageWaiter? {
        lock.lock()
        defer { lock.unlock() }
        guard networkArtworkIsAdmittedLocked(for: key) else { return nil }
        let waiterID = UUID()
        if let existing = inFlight[key] {
            if !background {
                existing.foregroundWaiterCount += 1
                existing.decodeJob?.promote(to: Self.decodeQueueFG)
            }
            existing.waiterIsForeground[waiterID] = !background
            return ImageWaiter(id: waiterID, key: key, load: existing)
        }
        let load = ImageLoad(networkInvalidationToken: networkInvalidationToken(for: key))
        load.waiterIsForeground[waiterID] = !background
        load.foregroundWaiterCount = background ? 0 : 1
        // Detached so the download + decode never inherit (and block) the MainActor
        // when kicked off from a card's `onAppear`/prefetch. The download is a
        // cancellable URLSession call and the decode runs off the cooperative pool,
        // so cancelling this task (last waiter gone) both stops the in-flight
        // transfer — freeing its connection — and skips the decode.
        let priority: TaskPriority = background ? .utility : .userInitiated
        load.task = Task<Void, Never>.detached(priority: priority) { [weak self, weak load] in
            guard let self, let load else { return }
            let image = await self.performLoad(for: key, load: load)
            self.finishLoad(load, for: key, with: image)
        }
        inFlight[key] = load
        return ImageWaiter(id: waiterID, key: key, load: load)
    }

    private func install(
        _ continuation: CheckedContinuation<UIImage?, Never>,
        for waiter: ImageWaiter
    ) {
        var immediateResult: (ready: Bool, image: UIImage?) = (false, nil)
        lock.lock()
        switch waiter.load.state {
        case .finished(let image):
            immediateResult = (true, image)
        case .pending:
            if waiter.load.waiterIsForeground[waiter.id] != nil {
                waiter.load.continuations[waiter.id] = continuation
            } else {
                // Cancellation won before the continuation was installed.
                immediateResult = (true, nil)
            }
        }
        lock.unlock()
        if immediateResult.ready {
            continuation.resume(returning: immediateResult.image)
        }
    }

    private func unregisterWaiter(_ waiter: ImageWaiter) {
        var continuation: CheckedContinuation<UIImage?, Never>?
        var taskToCancel: Task<Void, Never>?
        lock.lock()
        if let wasForeground = waiter.load.waiterIsForeground.removeValue(forKey: waiter.id) {
            if wasForeground {
                waiter.load.foregroundWaiterCount = max(0, waiter.load.foregroundWaiterCount - 1)
                if waiter.load.foregroundWaiterCount == 0,
                   !waiter.load.waiterIsForeground.isEmpty {
                    waiter.load.decodeJob?.demote(to: Self.decodeQueueBG)
                }
            }
            continuation = waiter.load.continuations.removeValue(forKey: waiter.id)
            if waiter.load.waiterIsForeground.isEmpty,
               case .pending = waiter.load.state {
                taskToCancel = waiter.load.task
                if inFlight[waiter.key] === waiter.load {
                    inFlight[waiter.key] = nil
                }
            }
        }
        lock.unlock()
        continuation?.resume(returning: nil)
        taskToCancel?.cancel()
    }

    private func performLoad(for key: CacheKey, load: ImageLoad) async -> UIImage? {
        if Task.isCancelled { return nil }
        let data: Data?
        switch key.source {
        case let .url(url):
            data = await Self.downloadData(key.variant.requestURL(for: url))
        case let .network(reference):
            data = await networkData(for: reference, variant: key.variant, background: load.foregroundWaiterCount == 0)
        }
        guard let data, !Task.isCancelled else { return nil }
        let image = await decodeImageOffPool(
            from: data,
            variant: key.variant,
            load: load
        )
        guard !Task.isCancelled else { return nil }
        guard let image else {
            if case let .network(reference) = key.source {
                guard networkLoadIsCurrent(load, for: key) else { return nil }
                let service = lock.withLock { networkFileService }
                await service?.failureReporter?.reportArtworkFailure(.malformed, for: reference)
            }
            return nil
        }
        guard store(image, for: key, load: load) else { return nil }
        if case let .network(reference) = key.source, key.variant.maxPixelSize != nil {
            await derivedCache.store(
                image,
                key: key.cacheKey as String,
                accountID: reference.accountID,
                credentialRevision: reference.credentialRevision.rawValue.uuidString,
                sourceFingerprint: reference.sourceRevision,
                variant: key.variant
            )
            guard networkLoadIsCurrent(load, for: key) else {
                await derivedCache.purge(
                    accountID: reference.accountID,
                    credentialRevision: reference.credentialRevision.rawValue.uuidString
                )
                return nil
            }
        }
        return image
    }

    private func networkData(
        for reference: NetworkArtworkReference,
        variant: ArtworkImageVariant,
        background: Bool
    ) async -> Data? {
        guard !Task.isCancelled else { return nil }
        let cacheKey = CacheKey(reference: reference, variant: variant)
        let service = lock.withLock { networkFileService }
        guard let service else { return nil }
        let key = cacheKey.cacheKey as String
        if let cached = await derivedCache.data(
            for: key,
            accountID: reference.accountID,
            credentialRevision: reference.credentialRevision.rawValue.uuidString,
            sourceFingerprint: reference.sourceRevision,
            markUsed: !background
        ) {
            return cached
        }
        let limiter = background ? Self.networkBackgroundLimiter : Self.networkForegroundLimiter
        do {
            let data = try await limiter.run {
                try await service.loader.loadArtwork(reference, maximumBytes: 32 * 1024 * 1024)
            }
            guard !data.isEmpty else {
                await service.failureReporter?.reportArtworkFailure(.empty, for: reference)
                return nil
            }
            if let failure = Self.stillImageFailure(data) {
                await service.failureReporter?.reportArtworkFailure(failure, for: reference)
                return nil
            }
            return data
        } catch is CancellationError {
            await service.failureReporter?.reportArtworkFailure(.cancelled, for: reference)
            return nil
        } catch let error as ArtworkNetworkFileLoadError {
            await service.failureReporter?.reportArtworkFailure(error.failure, for: reference)
            return nil
        } catch {
            await service.failureReporter?.reportArtworkFailure(.unavailable, for: reference)
            return nil
        }
    }

    private func finishLoad(_ load: ImageLoad, for key: CacheKey, with image: UIImage?) {
        var continuations: [CheckedContinuation<UIImage?, Never>] = []
        lock.lock()
        if case .pending = load.state {
            load.state = .finished(image)
            continuations = Array(load.continuations.values)
            load.continuations.removeAll()
            load.waiterIsForeground.removeAll()
            load.foregroundWaiterCount = 0
            if inFlight[key] === load {
                inFlight[key] = nil
            }
        }
        lock.unlock()
        for continuation in continuations {
            continuation.resume(returning: image)
        }
    }

    @discardableResult
    private func store(_ image: UIImage, for key: CacheKey, load: ImageLoad) -> Bool {
        let scale = image.scale
        let cost = max(Int(image.size.width * scale * image.size.height * scale * 4), 1)
        lock.lock()
        if case .network = key.source,
           (load.networkInvalidationToken != networkInvalidationToken(for: key)
                || !networkArtworkIsAdmittedLocked(for: key)) {
            lock.unlock()
            return false
        }
        if case .network = key.source {
            decodedIndexLock.withLock {
                decodedNetworkKeys.insert(key)
            }
        }
        cache.setObject(
            CachedImageEntry(image: image, key: key, cost: cost),
            forKey: key.cacheKey,
            cost: cost
        )
        lock.unlock()
        Self.noteStored(cost: cost)
        return true
    }

    private static func downloadData(_ url: URL) async -> Data? {
        guard let (data, response) = try? await ArtworkSession.shared.data(from: url) else {
            return nil
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { return nil }
        return data
    }

    /// Runs the synchronous decode on a dedicated bounded queue instead of the
    /// Swift cooperative pool, bridging back via a continuation. Foreground
    /// decodes (visible card / detail hero) use the higher-priority lane so they
    /// never wait behind a background prewarm storm. Keeps artwork CPU off the
    /// cooperative pool so it can't starve unrelated `async` continuations.
    private func decodeImageOffPool(
        from data: Data,
        variant: ArtworkImageVariant,
        load: ImageLoad
    ) async -> UIImage? {
        let job = lock.withLock {
            let job = DecodeJob(
                foregroundRequested: load.foregroundWaiterCount > 0
            ) {
                Self.decodeImage(from: data, variant: variant)
            }
            load.decodeJob = job
            return job
        }

        defer {
            lock.withLock {
                if load.decodeJob === job {
                    load.decodeJob = nil
                }
            }
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if job.install(continuation: continuation) {
                    job.start(
                        backgroundQueue: Self.decodeQueueBG,
                        foregroundQueue: Self.decodeQueueFG
                    )
                }
            }
        } onCancel: {
            job.cancel()
        }
    }

    private static func decodeImage(from data: Data, variant: ArtworkImageVariant) -> UIImage? {
        guard validateStillImage(data) else { return nil }
        if let maxPixelSize = variant.maxPixelSize {
            // `kCGImageSourceShouldCacheImmediately` already materializes the
            // thumbnail's pixels. Calling `preparingForDisplay()` again here creates
            // a redundant second prepared image and repeats work on the hot path.
            return downsampledImage(from: data, maxPixelSize: maxPixelSize)
        }

        let image = UIImage(data: data)
        guard let image else { return nil }
        // Force-decode now (off the main thread) so the cached image is render-ready.
        return image.preparingForDisplay() ?? image
    }

    private static func validateStillImage(_ data: Data) -> Bool {
        stillImageFailure(data) == nil
    }

    private static func stillImageFailure(_ data: Data) -> ArtworkNetworkFileFailure? {
        guard !data.isEmpty else { return .empty }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source) as String?
        else { return .malformed }
        guard ["public.jpeg", "public.png", "org.webmproject.webp"].contains(type) else {
            return .unsupported
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { return .malformed }
        guard width <= 16_384, height <= 16_384, width <= 64_000_000 / height else {
            return .unsafeDimensions
        }
        return nil
    }

    private static func downsampledImage(from data: Data, maxPixelSize: Int) -> UIImage? {
        let sourceOptions: [CFString: Any] = [
            // Do not let ImageIO inflate/cache the full source before producing the
            // thumbnail; only the bounded destination bitmap should be materialized.
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            sourceOptions as CFDictionary
        ) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maxPixelSize, 1),
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// Shared ImageIO downsample for callers that decode outside the cache but
    /// still must not inflate a full-size bitmap (e.g. the hero logo pipeline,
    /// which needs the pixels for its own halo/contrast analysis). Decodes only a
    /// thumbnail whose longest edge is `maxPixelSize`, preserving alpha. Never
    /// upscales. Returns `nil` if the data isn't a decodable image.
    public static func downsample(_ data: Data, maxPixelSize: Int) -> UIImage? {
        downsampledImage(from: data, maxPixelSize: maxPixelSize)
    }
}

extension ArtworkImageCache: NSCacheDelegate {
    /// NSCache is about to drop `obj` (cost-limit or memory-pressure eviction).
    /// Decrement the live accounting by the same cost formula `store` used, so the
    /// diagnostic count/cost track the real resident set. NOTE: this does NOT fire
    /// for `removeAllObjects()` — the memory-warning flush resets the counters
    /// itself via `noteFlushedAll()`.
    public func cache(_ cache: NSCache<AnyObject, AnyObject>, willEvictObject obj: Any) {
        guard let entry = obj as? CachedImageEntry else { return }
        if case .network = entry.key.source {
            decodedIndexLock.withLock {
                decodedNetworkKeys.remove(entry.key)
            }
        }
        Self.noteEvicted(cost: entry.cost)
    }
}
#endif
