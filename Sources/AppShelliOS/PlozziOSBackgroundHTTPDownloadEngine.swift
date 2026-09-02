#if os(iOS)
@preconcurrency import AVFoundation
import Foundation
import MediaDownloads

public enum PlozziOSBackgroundSessionBridge {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var completionHandlers: [String: () -> Void] = [:]

    public static func handleEvents(
        identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        lock.lock()
        completionHandlers[identifier] = completionHandler
        lock.unlock()
        activate()
    }

    public static func activate() {
        BackgroundDownloadSession.shared.activate()
        BackgroundHLSDownloadSession.shared.activate()
    }

    static func finishEvents(identifier: String) {
        lock.lock()
        let completionHandler = completionHandlers.removeValue(forKey: identifier)
        lock.unlock()
        DispatchQueue.main.async {
            completionHandler?()
        }
    }
}

private enum BackgroundDownloadSession {
    static let shared = BackgroundDownloadCoordinator(
        identifier: "com.thatcube.Plozz.downloads.managed"
    )
}

private enum BackgroundHLSDownloadSession {
    static let shared = BackgroundHLSDownloadCoordinator(
        identifier: "com.thatcube.Plozz.downloads.renditions"
    )
}

struct PlozziOSBackgroundHTTPDownloadEngine:
    MediaDownloadEngine,
    DownloadPolicyApplying,
    DownloadPersistentWorkCancelling
{
    struct Resolution: Sendable {
        let url: URL
        let expectedDuration: TimeInterval?
    }

    typealias URLResolver =
        @Sendable (ManagedHTTPDownloadSource) async throws -> Resolution

    private let profileID: String
    private let registry: DownloadedMediaRegistry
    private let resolveURL: URLResolver

    init(
        profileID: String,
        registry: DownloadedMediaRegistry,
        resolveURL: @escaping URLResolver
    ) {
        self.profileID = profileID
        self.registry = registry
        self.resolveURL = resolveURL
        BackgroundDownloadSession.shared.activate()
    }

    func applyDownloadPolicy(_ policy: DownloadNetworkPolicy) {
        BackgroundDownloadSession.shared.apply(
            profileID: profileID,
            policy: policy
        )
        BackgroundHLSDownloadSession.shared.apply(
            profileID: profileID,
            policy: policy
        )
        Task {
            await ForegroundManagedDownloadCoordinator.shared.apply(
                profileID: profileID,
                policy: policy
            )
        }
    }

    func discardPersistentWork(identityKey: String) async {
        await BackgroundDownloadSession.shared.discard(
            profileID: profileID,
            identityKey: identityKey
        )
        await BackgroundHLSDownloadSession.shared.discard(
            profileID: profileID,
            identityKey: identityKey
        )
    }

    func download(
        record: DownloadedMediaRecord,
        to destination: URL,
        onProgress: @escaping @Sendable (Int64, Int64) async -> Void
    ) async throws -> Int64 {
        guard let source = record.managedHTTPSource else {
            throw BackgroundDownloadError.missingSource
        }
        let resolution = try await resolveURL(source)
        let url = resolution.url
        if let expectedDuration = resolution.expectedDuration,
           expectedDuration > 0 {
            try? await registry.setRuntime(
                identityKey: record.identityKey,
                runtime: expectedDuration
            )
        }
        let usesProgressiveRendition =
            source.provider == .plex && source.quality != .original
        if case .constrained(let constraint) = source.quality,
           !usesProgressiveRendition {
            return try await BackgroundHLSDownloadSession.shared.download(
                profileID: profileID,
                identityKey: record.identityKey,
                localFileName: record.localFileName,
                title: record.snapshot.title,
                from: url,
                to: destination,
                constraint: constraint,
                includesAllAudioTracks: source.includesAllAudioTracks,
                includesTextSubtitleTracks: source.includesTextSubtitleTracks,
                onProgress: onProgress
            )
        }
        if usesProgressiveRendition {
            // Builds before progressive Plex renditions used AVAssetDownloadTask.
            // Cancel any persisted HLS task before reusing the same identity.
            await BackgroundHLSDownloadSession.shared.discard(
                profileID: profileID,
                identityKey: record.identityKey
            )
            if record.localFileName.lowercased().hasSuffix(".movpkg"),
               (
                   try? destination.resourceValues(
                       forKeys: [.isDirectoryKey]
                   ).isDirectory
               ) == true {
                try? FileManager.default.removeItem(at: destination)
            }
        }
        let transferredBytes: Int64
        if BackgroundDownloadSession.shared.usesForegroundRateLimit(
            profileID: profileID
        ) {
            let policy = BackgroundDownloadSession.shared.policy(
                profileID: profileID
            )
            transferredBytes = try await ForegroundManagedDownloadCoordinator.shared
                .download(
                    profileID: profileID,
                    policy: policy,
                    from: url,
                    to: destination,
                    onProgress: onProgress
                )
        } else {
            if FileManager.default.fileExists(
                atPath: destination.appendingPathExtension("source").path
            ) {
                try? FileManager.default.removeItem(at: destination)
                try? FileManager.default.removeItem(
                    at: destination.appendingPathExtension("source")
                )
            }
            transferredBytes = try await BackgroundDownloadSession.shared.download(
                profileID: profileID,
                identityKey: record.identityKey,
                localFileName: record.localFileName,
                from: url,
                to: destination,
                onProgress: onProgress
            )
        }
        if usesProgressiveRendition {
            do {
                try await PlexRenditionValidator.validate(
                    fileURL: destination,
                    expectedDuration:
                        resolution.expectedDuration ?? record.snapshot.runtime
                )
            } catch {
                try? FileManager.default.removeItem(at: destination)
                try? FileManager.default.removeItem(
                    at: destination.appendingPathExtension("source")
                )
                try? FileManager.default.removeItem(
                    at: destination.appendingPathExtension("resume")
                )
                await onProgress(0, record.totalBytes ?? 0)
                throw error
            }
        }
        return transferredBytes
    }
}

private enum PlexRenditionValidator {
    enum ValidationError: LocalizedError {
        case unreadable
        case incomplete

        var errorDescription: String? {
            switch self {
            case .unreadable:
                "Plex returned a rendition that could not be opened."
            case .incomplete:
                "Plex returned an incomplete rendition. Please retry the download."
            }
        }
    }

    static func validate(
        fileURL: URL,
        expectedDuration: TimeInterval?
    ) async throws {
        let asset = AVURLAsset(url: fileURL)
        let duration: CMTime
        do {
            duration = try await asset.load(.duration)
        } catch {
            throw ValidationError.unreadable
        }
        let actual = duration.seconds
        guard actual.isFinite, actual > 0 else {
            throw ValidationError.unreadable
        }
        guard let expectedDuration, expectedDuration > 0 else { return }
        let tolerance = max(2, min(10, expectedDuration * 0.005))
        let minimumAcceptable = max(1, expectedDuration - tolerance)
        guard actual >= minimumAcceptable else {
            throw ValidationError.incomplete
        }

        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .video)
        } catch {
            throw ValidationError.unreadable
        }
        guard let track = tracks.first else {
            throw ValidationError.unreadable
        }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw ValidationError.unreadable
        }
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: nil
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw ValidationError.unreadable
        }
        reader.add(output)
        let verificationStart = max(0, minimumAcceptable - 5)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: verificationStart, preferredTimescale: 600),
            duration: CMTime(
                seconds: max(1, actual - verificationStart),
                preferredTimescale: 600
            )
        )
        guard reader.startReading() else {
            throw ValidationError.unreadable
        }

        var latestSampleEnd = 0.0
        while let sample = output.copyNextSampleBuffer() {
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(
                sample
            )
            let sampleDuration = CMSampleBufferGetDuration(sample)
            let sampleEnd = sampleDuration.isValid
                ? CMTimeAdd(presentationTime, sampleDuration)
                : presentationTime
            let seconds = sampleEnd.seconds
            if seconds.isFinite {
                latestSampleEnd = max(latestSampleEnd, seconds)
            }
        }
        guard latestSampleEnd >= minimumAcceptable else {
            throw ValidationError.incomplete
        }
    }
}

private final class BackgroundHLSDownloadCoordinator:
            NSObject,
            AVAssetDownloadDelegate,
            URLSessionTaskDelegate,
            @unchecked Sendable
        {
            private struct Transfer {
                let destination: URL
                let estimatedBytes: Int64
                let onProgress: @Sendable (Int64, Int64) async -> Void
                var continuation: CheckedContinuation<Int64, Error>?
                var finalResult: Result<Int64, Error>?
                var stagedLocation: URL?
                var progressTask: Task<Void, Never>?
            }

            private struct SessionPolicy: Hashable {
                let allowsExpensiveNetwork: Bool
                let allowsConstrainedNetwork: Bool

                static let all: [Self] = [
                    .init(
                        allowsExpensiveNetwork: false,
                        allowsConstrainedNetwork: false
                    ),
                    .init(
                        allowsExpensiveNetwork: false,
                        allowsConstrainedNetwork: true
                    ),
                    .init(
                        allowsExpensiveNetwork: true,
                        allowsConstrainedNetwork: false
                    ),
                    .init(
                        allowsExpensiveNetwork: true,
                        allowsConstrainedNetwork: true
                    )
                ]

                var identifierSuffix: String {
                    "\(allowsExpensiveNetwork ? "expensive" : "wifi")."
                        + "\(allowsConstrainedNetwork ? "standard" : "low-data-paused")"
                }
            }

            private let identifier: String
            private let stagedLocationsKey = "PlozzBackgroundHLSStagedLocations"
            private let lock = NSLock()
            private var transfers: [String: Transfer] = [:]
            private var completedResults: [String: Result<Int64, Error>] = [:]
            private var discardedKeys: Set<String> = []
            private var policies: [String: DownloadNetworkPolicy] = [:]
            private var sessions: [SessionPolicy: AVAssetDownloadURLSession] = [:]

            init(identifier: String) {
                self.identifier = identifier
                super.init()
            }

            func activate() {
                for policy in SessionPolicy.all {
                    session(for: policy).getAllTasks { _ in }
                }
            }

            func apply(
                profileID: String,
                policy: DownloadNetworkPolicy
            ) {
                lock.withLock {
                    policies[profileID] = policy
                }
            }

            func download(
                profileID: String,
                identityKey: String,
                localFileName: String,
                title: String,
                from url: URL,
                to destination: URL,
                constraint: DownloadRenditionConstraint,
                includesAllAudioTracks: Bool,
                includesTextSubtitleTracks: Bool,
                onProgress: @escaping @Sendable (Int64, Int64) async -> Void
            ) async throws -> Int64 {
                let descriptor = BackgroundTaskDescriptor(
                    profileID: profileID,
                    identityKey: identityKey,
                    localFileName: localFileName
                )
                let key = try descriptor.encoded()
                if FileManager.default.fileExists(atPath: destination.path) {
                    return max(1, Self.allocatedSize(of: destination))
                }
                let asset = AVURLAsset(url: url)
                let duration = try await asset.load(.duration)
                let mediaSelections = try await Self.mediaSelections(
                    for: asset,
                    includesAllAudioTracks: includesAllAudioTracks,
                    includesTextSubtitleTracks: includesTextSubtitleTracks
                )
                let seconds = duration.seconds.isFinite ? max(1, duration.seconds) : 1
                let estimatedBytes = max(
                    1,
                    Int64(seconds * Double(constraint.maximumVideoBitrateBps) / 8 * 1.15)
                )

                return try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        lock.lock()
                        if let result = completedResults.removeValue(forKey: key) {
                            lock.unlock()
                            continuation.resume(with: result)
                            return
                        }
                        var transfer = transfers[key] ?? Transfer(
                            destination: destination,
                            estimatedBytes: estimatedBytes,
                            onProgress: onProgress,
                            progressTask: nil
                        )
                        if let result = transfer.finalResult {
                            let progressTask = transfer.progressTask
                            transfers.removeValue(forKey: key)
                            lock.unlock()
                            Task {
                                await progressTask?.value
                                continuation.resume(with: result)
                            }
                            return
                        }
                        transfer.continuation = continuation
                        transfers[key] = transfer
                        discardedKeys.remove(key)
                        lock.unlock()

                        let selectedSession = self.sessionForCurrentPolicy(
                            profileID: profileID
                        )
                        self.allTasks { [weak self] tasks in
                            guard let self else { return }
                            if let existing = tasks.first(where: {
                                $0.taskDescription == key
                            }) {
                                if self.hasTransfer(key) {
                                    existing.resume()
                                }
                                return
                            }
                            guard self.hasTransfer(key) else { return }
                            let task: URLSessionTask?
                            if mediaSelections.count > 1 {
                                task = selectedSession.aggregateAssetDownloadTask(
                                    with: asset,
                                    mediaSelections: mediaSelections,
                                    assetTitle: title,
                                    assetArtworkData: nil,
                                    options: nil
                                )
                            } else {
                                task = selectedSession.makeAssetDownloadTask(
                                    asset: asset,
                                    assetTitle: title,
                                    assetArtworkData: nil,
                                    options: nil
                                )
                            }
                            guard let task else {
                                self.finish(
                                    key: key,
                                    result: .failure(
                                        BackgroundDownloadError.unavailableRendition
                                    )
                                )
                                return
                            }
                            task.taskDescription = key
                            if self.hasTransfer(key) {
                                task.resume()
                            } else {
                                task.cancel()
                            }
                        }
                    }
                } onCancel: {
                    self.allTasks { tasks in
                        tasks.first { $0.taskDescription == key }?.suspend()
                        self.finish(key: key, result: .failure(CancellationError()))
                    }
                }
            }

            func discard(profileID: String, identityKey: String) async {
                let tasks = await withCheckedContinuation { continuation in
                    allTasks { continuation.resume(returning: $0) }
                }
                for task in tasks {
                    guard let value = task.taskDescription,
                          let descriptor = try? BackgroundTaskDescriptor.decode(value),
                          descriptor.profileID == profileID,
                          descriptor.identityKey == identityKey else {
                        continue
                    }
                    _ = lock.withLock {
                        discardedKeys.insert(value)
                    }
                    task.cancel()
                    removeStagedLocation(for: value)
                }
            }

            func urlSession(
                _ session: URLSession,
                assetDownloadTask: AVAssetDownloadTask,
                didLoad timeRange: CMTimeRange,
                totalTimeRangesLoaded loadedTimeRanges: [NSValue],
                timeRangeExpectedToLoad: CMTimeRange
            ) {
                guard let key = assetDownloadTask.taskDescription else { return }
                reportProgress(
                    key: key,
                    loadedTimeRanges: loadedTimeRanges,
                    timeRangeExpectedToLoad: timeRangeExpectedToLoad
                )
            }

            func urlSession(
                _ session: URLSession,
                aggregateAssetDownloadTask: AVAggregateAssetDownloadTask,
                didLoad timeRange: CMTimeRange,
                totalTimeRangesLoaded loadedTimeRanges: [NSValue],
                timeRangeExpectedToLoad: CMTimeRange,
                for mediaSelection: AVMediaSelection
            ) {
                guard let key = aggregateAssetDownloadTask.taskDescription else { return }
                reportProgress(
                    key: key,
                    loadedTimeRanges: loadedTimeRanges,
                    timeRangeExpectedToLoad: timeRangeExpectedToLoad
                )
            }

            private func reportProgress(
                key: String,
                loadedTimeRanges: [NSValue],
                timeRangeExpectedToLoad: CMTimeRange
            ) {
                let expected = timeRangeExpectedToLoad.duration.seconds
                guard expected.isFinite, expected > 0 else { return }
                let loaded = loadedTimeRanges.reduce(0.0) {
                    $0 + $1.timeRangeValue.duration.seconds
                }
                lock.lock()
                guard var transfer = transfers[key] else {
                    lock.unlock()
                    return
                }
                let fraction = min(1, max(0, loaded / expected))
                let bytes = Int64(Double(transfer.estimatedBytes) * fraction)
                let previous = transfer.progressTask
                let callback = transfer.onProgress
                transfer.progressTask = Task {
                    await previous?.value
                    await callback(bytes, transfer.estimatedBytes)
                }
                transfers[key] = transfer
                lock.unlock()
            }

            func urlSession(
                _ session: URLSession,
                aggregateAssetDownloadTask: AVAggregateAssetDownloadTask,
                willDownloadTo location: URL
            ) {
                guard let key = aggregateAssetDownloadTask.taskDescription else { return }
                lock.lock()
                if var transfer = transfers[key] {
                    transfer.stagedLocation = location
                    transfers[key] = transfer
                }
                lock.unlock()
                var locations = UserDefaults.standard.dictionary(
                    forKey: stagedLocationsKey
                ) as? [String: String] ?? [:]
                locations[key] = location.path
                UserDefaults.standard.set(locations, forKey: stagedLocationsKey)
            }

            func urlSession(
                _ session: URLSession,
                assetDownloadTask: AVAssetDownloadTask,
                didFinishDownloadingTo location: URL
            ) {
                guard let key = assetDownloadTask.taskDescription else { return }
                finalizeDownload(key: key, location: location)
    }

    private func finalizeDownload(key: String, location: URL) {
                guard !lock.withLock({
                    discardedKeys.contains(key)
                }) else {
                    removeStagedLocation(for: key)
                    return
                }
                lock.lock()
                let transfer = transfers[key]
                lock.unlock()
                let destination: URL
                if let transfer {
                    destination = transfer.destination
                } else {
                    guard let descriptor = try? BackgroundTaskDescriptor.decode(key),
                          let resolved = try? descriptor.destinationURL() else {
                        return
                    }
                    destination = resolved
                }
                do {
                    try FileManager.default.createDirectory(
                        at: destination.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(
                        at: location,
                        to: destination
                    )
                    let bytes = Self.allocatedSize(of: destination)
                    removeStagedLocation(for: key)
                    finish(key: key, result: .success(max(1, bytes)))
                } catch {
                    removeStagedLocation(for: key)
                    finish(key: key, result: .failure(error))
                }
            }

            func urlSession(
                _ session: URLSession,
                task: URLSessionTask,
                didCompleteWithError error: (any Error)?
            ) {
                guard let key = task.taskDescription else { return }
                if lock.withLock({ discardedKeys.remove(key) != nil }) {
                    removeStagedLocation(for: key)
                    finish(key: key, result: .failure(CancellationError()))
                    return
                }
                if let error {
                    finish(key: key, result: .failure(error))
                    return
                }
                lock.lock()
                let stagedLocation = transfers[key]?.stagedLocation
                    ?? persistedStagedLocation(for: key)
                lock.unlock()
                if let stagedLocation {
                    finalizeDownload(key: key, location: stagedLocation)
                }
            }

            func urlSessionDidFinishEvents(
                forBackgroundURLSession session: URLSession
            ) {
                guard let identifier = session.configuration.identifier else { return }
                PlozziOSBackgroundSessionBridge.finishEvents(identifier: identifier)
            }

            private func finish(key: String, result: Result<Int64, Error>) {
                lock.lock()
                guard var transfer = transfers[key] else {
                    completedResults[key] = result
                    lock.unlock()
                    return
                }
                if let continuation = transfer.continuation {
                    let progressTask = transfer.progressTask
                    transfers.removeValue(forKey: key)
                    lock.unlock()
                    Task {
                        await progressTask?.value
                        continuation.resume(with: result)
                    }
                } else {
                    transfer.finalResult = result
                    transfers[key] = transfer
                    lock.unlock()
                }
            }

            private func hasTransfer(_ key: String) -> Bool {
                lock.withLock { transfers[key] != nil }
            }

            private func sessionForCurrentPolicy(
                profileID: String
            ) -> AVAssetDownloadURLSession {
                let activePolicy = lock.withLock {
                    let policy = policies[profileID] ?? .default
                    return SessionPolicy(
                        allowsExpensiveNetwork: policy.allowsExpensiveNetwork,
                        allowsConstrainedNetwork: !policy.pausesOnConstrainedNetwork
                    )
                }
                return session(for: activePolicy)
            }

            private func session(
                for policy: SessionPolicy
            ) -> AVAssetDownloadURLSession {
                lock.lock()
                defer { lock.unlock() }
                if let existing = sessions[policy] {
                    return existing
                }
                let configuration = URLSessionConfiguration.background(
                    withIdentifier: "\(identifier).\(policy.identifierSuffix)"
                )
                configuration.sessionSendsLaunchEvents = true
                configuration.isDiscretionary = false
                configuration.allowsCellularAccess =
                    policy.allowsExpensiveNetwork
                configuration.allowsExpensiveNetworkAccess =
                    policy.allowsExpensiveNetwork
                configuration.allowsConstrainedNetworkAccess =
                    policy.allowsConstrainedNetwork
                let created = AVAssetDownloadURLSession(
                    configuration: configuration,
                    assetDownloadDelegate: self,
                    delegateQueue: nil
                )
                sessions[policy] = created
                return created
            }

            private func allTasks(
                completion: @escaping @Sendable ([URLSessionTask]) -> Void
            ) {
                let activeSessions = SessionPolicy.all.map(session(for:))
                let group = DispatchGroup()
                let resultLock = NSLock()
                var tasks: [URLSessionTask] = []
                for session in activeSessions {
                    group.enter()
                    session.getAllTasks { sessionTasks in
                        resultLock.withLock {
                            tasks.append(contentsOf: sessionTasks)
                        }
                        group.leave()
                    }
                }
                group.notify(queue: .global()) {
                    completion(resultLock.withLock { tasks })
                }
            }

            private func persistedStagedLocation(for key: String) -> URL? {
                guard let locations = UserDefaults.standard.dictionary(
                    forKey: stagedLocationsKey
                ) as? [String: String],
                      let path = locations[key] else {
                    return nil
                }
                return URL(fileURLWithPath: path)
            }

            private func removeStagedLocation(for key: String) {
                var locations = UserDefaults.standard.dictionary(
                    forKey: stagedLocationsKey
                ) as? [String: String] ?? [:]
                locations.removeValue(forKey: key)
                UserDefaults.standard.set(locations, forKey: stagedLocationsKey)
            }

            private static func allocatedSize(of url: URL) -> Int64 {
                let keys: Set<URLResourceKey> = [
                    .isRegularFileKey,
                    .fileAllocatedSizeKey,
                    .totalFileAllocatedSizeKey
                ]
                guard let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: Array(keys),
                    options: [.skipsHiddenFiles]
                ) else {
                    return 0
                }
                var total: Int64 = 0
                for case let fileURL as URL in enumerator {
                    let values = try? fileURL.resourceValues(forKeys: keys)
                    guard values?.isRegularFile == true else { continue }
                    total += Int64(
                        values?.totalFileAllocatedSize
                            ?? values?.fileAllocatedSize
                            ?? 0
                    )
                }
                return total
            }

            private static func mediaSelections(
                for asset: AVURLAsset,
                includesAllAudioTracks: Bool,
                includesTextSubtitleTracks: Bool
            ) async throws -> [AVMediaSelection] {
                let preferred = try await asset.load(.preferredMediaSelection)
                guard includesAllAudioTracks || includesTextSubtitleTracks else {
                    return [preferred]
                }
                let all = try await asset.load(.allMediaSelections)
                let audioGroup = try await asset.loadMediaSelectionGroup(
                    for: .audible
                )
                let subtitleGroup = try await asset.loadMediaSelectionGroup(
                    for: .legible
                )
                let preferredAudio = audioGroup.flatMap {
                    preferred.selectedMediaOption(in: $0)
                }
                let filtered = all.filter { selection in
                    if !includesAllAudioTracks,
                       let audioGroup,
                       selection.selectedMediaOption(in: audioGroup) != preferredAudio {
                        return false
                    }
                    if !includesTextSubtitleTracks,
                       let subtitleGroup,
                       selection.selectedMediaOption(in: subtitleGroup) != nil {
                        return false
                    }
                    return true
                }
                return filtered.isEmpty ? [preferred] : filtered
            }
        }
private struct BackgroundTaskDescriptor: Codable {
    let profileID: String
    let identityKey: String
    let localFileName: String

    func encoded() throws -> String {
        try JSONEncoder().encode(self).base64EncodedString()
    }

    static func decode(_ value: String) throws -> BackgroundTaskDescriptor {
        guard let data = Data(base64Encoded: value) else {
            throw BackgroundDownloadError.missingTaskIdentity
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    func destinationURL() throws -> URL {
        try PlatformDownloadStorageLocator(
            subdirectory: "PlozzDownloads/\(profileID)"
        )
        .pinnedFolderURL(forKey: identityKey)
        .appendingPathComponent(localFileName, isDirectory: false)
    }
}

private enum BackgroundDownloadError: LocalizedError {
    case missingSource
    case missingTaskIdentity
    case missingTemporaryFile
    case unexpectedHTTPStatus(Int)
    case incompleteTransfer(expected: Int64, actual: Int64)
    case unavailableRendition

    var errorDescription: String? {
        switch self {
        case .missingSource: "The managed download source is unavailable."
        case .missingTaskIdentity: "The background download lost its identity."
        case .missingTemporaryFile: "The downloaded file could not be finalized."
        case let .unexpectedHTTPStatus(status):
            "The media server returned HTTP \(status) instead of a media file."
        case let .incompleteTransfer(expected, actual):
            "The download ended after \(actual) of \(expected) bytes."
        case .unavailableRendition:
            "The media server could not create an offline rendition."
        }
    }
}

private final class BackgroundDownloadCoordinator:
    NSObject,
    URLSessionDownloadDelegate,
    URLSessionTaskDelegate,
    @unchecked Sendable
{
    private struct Transfer {
        let destination: URL
        let onProgress: @Sendable (Int64, Int64) async -> Void
        var continuation: CheckedContinuation<Int64, Error>?
        var finalResult: Result<Int64, Error>?
        var progressTask: Task<Void, Never>?
    }

    private let identifier: String
    private let lock = NSLock()
    private var transfers: [String: Transfer] = [:]
    private var cancelledTaskIDs: Set<String> = []
    private var policies: [String: DownloadNetworkPolicy] = [:]

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(
            withIdentifier: identifier
        )
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.allowsCellularAccess = true
        return URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: nil
        )
    }()

    init(identifier: String) {
        self.identifier = identifier
        super.init()
    }

    func activate() {
        _ = session
    }

    func apply(profileID: String, policy: DownloadNetworkPolicy) {
        lock.lock()
        policies[profileID] = policy
        lock.unlock()
    }

    func usesForegroundRateLimit(profileID: String) -> Bool {
        lock.withLock {
            policies[profileID]?.maximumBytesPerSecond != nil
        }
    }

    func policy(profileID: String) -> DownloadNetworkPolicy {
        lock.withLock { policies[profileID] ?? .default }
    }

    func download(
        profileID: String,
        identityKey: String,
        localFileName: String,
        from url: URL,
        to destination: URL,
        onProgress: @escaping @Sendable (Int64, Int64) async -> Void
    ) async throws -> Int64 {
        let taskID = try BackgroundTaskDescriptor(
            profileID: profileID,
            identityKey: identityKey,
            localFileName: localFileName
        ).encoded()
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                transfers[taskID] = Transfer(
                    destination: destination,
                    onProgress: onProgress,
                    continuation: continuation,
                    progressTask: nil
                )
                cancelledTaskIDs.remove(taskID)
                lock.unlock()

                Task {
                    let tasks = await allTasks()
                    if let existing = tasks.first(where: {
                        $0.taskDescription == taskID
                    }) as? URLSessionDownloadTask {
                        if hasTransfer(taskID) {
                            existing.resume()
                        }
                        return
                    }

                    guard hasTransfer(taskID) else { return }
                    if FileManager.default.fileExists(atPath: destination.path) {
                        let values = try? destination.resourceValues(
                            forKeys: [.fileSizeKey]
                        )
                        finish(
                            taskID: taskID,
                            result: .success(Int64(values?.fileSize ?? 0))
                        )
                        return
                    }

                    // Older builds persisted URLSession resume blobs containing
                    // token-bearing request URLs. Remove any legacy blob and
                    // always restart managed authenticated downloads with the
                    // freshly resolved URL.
                    try? FileManager.default.removeItem(
                        at: destination.appendingPathExtension("resume")
                    )
                    let policy = lock.withLock {
                        self.policies[profileID] ?? .default
                    }
                    var request = URLRequest(url: url)
                    request.allowsExpensiveNetworkAccess =
                        policy.allowsExpensiveNetwork
                    request.allowsConstrainedNetworkAccess =
                        !policy.pausesOnConstrainedNetwork
                    let task = session.downloadTask(with: request)
                    task.taskDescription = taskID
                    if hasTransfer(taskID) {
                        task.resume()
                    } else {
                        task.cancel()
                    }
                }
            }
        } onCancel: {
            Task { await self.cancel(taskID: taskID) }
        }
    }

    private func allTasks() async -> [URLSessionTask] {
        await withCheckedContinuation { continuation in
            session.getAllTasks { continuation.resume(returning: $0) }
        }
    }

    private func cancel(taskID: String) async {
        let tasks = await allTasks()
        guard let task = tasks.first(where: {
            $0.taskDescription == taskID
        }) as? URLSessionDownloadTask else {
            finish(taskID: taskID, result: .failure(CancellationError()))
            return
        }
        task.suspend()
        finish(taskID: taskID, result: .failure(CancellationError()))
    }

    func discard(profileID: String, identityKey: String) async {
        let tasks = await allTasks()
        for task in tasks {
            guard let value = task.taskDescription,
                  let descriptor = try? BackgroundTaskDescriptor.decode(value),
                  descriptor.profileID == profileID,
                  descriptor.identityKey == identityKey else {
                continue
            }
            _ = lock.withLock {
                cancelledTaskIDs.insert(value)
            }
            task.cancel()
        }
    }

    private func hasTransfer(_ taskID: String) -> Bool {
        lock.withLock { transfers[taskID] != nil }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let taskID = downloadTask.taskDescription else { return }
        lock.lock()
        guard var transfer = transfers[taskID] else {
            lock.unlock()
            return
        }
        let previous = transfer.progressTask
        let callback = transfer.onProgress
        let expected = totalBytesExpectedToWrite > 0
            ? totalBytesExpectedToWrite
            : 0
        transfer.progressTask = Task {
            await previous?.value
            await callback(totalBytesWritten, expected)
        }
        transfers[taskID] = transfer
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let taskID = downloadTask.taskDescription else { return }
        guard !lock.withLock({
            cancelledTaskIDs.contains(taskID)
        }) else {
            return
        }
        do {
            guard let response = downloadTask.response as? HTTPURLResponse else {
                throw BackgroundDownloadError.missingTemporaryFile
            }
            guard (200...299).contains(response.statusCode) else {
                throw BackgroundDownloadError.unexpectedHTTPStatus(
                    response.statusCode
                )
            }
            let destination = try BackgroundTaskDescriptor
                .decode(taskID)
                .destinationURL()
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: location, to: destination)
            let values = try destination.resourceValues(forKeys: [.fileSizeKey])
            let bytes = Int64(values.fileSize ?? 0)
            lock.lock()
            if var transfer = transfers[taskID] {
                transfer.finalResult = .success(bytes)
                transfers[taskID] = transfer
            }
            lock.unlock()
        } catch {
            lock.lock()
            if var transfer = transfers[taskID] {
                transfer.finalResult = .failure(error)
                transfers[taskID] = transfer
            }
            lock.unlock()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let taskID = task.taskDescription else { return }
        if lock.withLock({ cancelledTaskIDs.remove(taskID) != nil }) {
            finish(taskID: taskID, result: .failure(CancellationError()))
            return
        }
        if let error {
            let result: Result<Int64, Error> = (error as NSError).code == NSURLErrorCancelled
                ? .failure(CancellationError())
                : .failure(error)
            finish(taskID: taskID, result: result)
            return
        }

        lock.lock()
        let result = transfers[taskID]?.finalResult
        lock.unlock()
        finish(
            taskID: taskID,
            result: result ?? .failure(BackgroundDownloadError.missingTemporaryFile)
        )
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        PlozziOSBackgroundSessionBridge.finishEvents(identifier: identifier)
    }

    private func finish(taskID: String, result: Result<Int64, Error>) {
        lock.lock()
        guard var transfer = transfers.removeValue(forKey: taskID) else {
            lock.unlock()
            return
        }
        let continuation = transfer.continuation
        let progressTask = transfer.progressTask
        transfer.continuation = nil
        cancelledTaskIDs.remove(taskID)
        lock.unlock()
        Task {
            await progressTask?.value
            continuation?.resume(with: result)
        }
    }

}

private actor ForegroundManagedDownloadCoordinator {
    static let shared = ForegroundManagedDownloadCoordinator()

    private struct Validator: Codable {
        var eTag: String?
        var lastModified: String?

        var ifRangeValue: String? { eTag ?? lastModified }
    }

    private var limiters: [String: ManagedDownloadRateLimiter] = [:]
    private var policies: [String: DownloadNetworkPolicy] = [:]

    func apply(profileID: String, policy: DownloadNetworkPolicy) async {
        policies[profileID] = policy
        let limiter = limiter(for: profileID)
        await limiter.update(
            maximumBytesPerSecond: policy.maximumBytesPerSecond
        )
    }

    func download(
        profileID: String,
        policy: DownloadNetworkPolicy,
        from url: URL,
        to destination: URL,
        onProgress: @escaping @Sendable (Int64, Int64) async -> Void
    ) async throws -> Int64 {
        policies[profileID] = policy
        let limiter = limiter(for: profileID)
        await limiter.update(
            maximumBytesPerSecond: policy.maximumBytesPerSecond
        )
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let metadataURL = destination.appendingPathExtension("source")
        let existingSize = ((try? destination.resourceValues(
            forKeys: [.fileSizeKey]
        ).fileSize).map(Int64.init)) ?? 0
        let existingValidator: Validator?
        if let data = try? Data(contentsOf: metadataURL) {
            existingValidator = try? JSONDecoder().decode(
                Validator.self,
                from: data
            )
        } else {
            existingValidator = nil
        }
        if existingSize > 0, existingValidator == nil {
            return existingSize
        }

        var request = URLRequest(url: url)
        request.allowsExpensiveNetworkAccess = policy.allowsExpensiveNetwork
        request.allowsConstrainedNetworkAccess =
            !policy.pausesOnConstrainedNetwork
        if existingSize > 0 {
            request.setValue(
                "bytes=\(existingSize)-",
                forHTTPHeaderField: "Range"
            )
            if let ifRange = existingValidator?.ifRangeValue {
                request.setValue(ifRange, forHTTPHeaderField: "If-Range")
            }
        }

        let (stream, response) = try await URLSession.shared.bytes(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw BackgroundDownloadError.missingTemporaryFile
        }
        guard (200...299).contains(response.statusCode) else {
            throw BackgroundDownloadError.unexpectedHTTPStatus(
                response.statusCode
            )
        }

        let isResume = existingSize > 0 && response.statusCode == 206
        let offset = isResume ? existingSize : 0
        if !isResume, fileManager.fileExists(atPath: destination.path) {
            try Data().write(to: destination, options: .atomic)
        } else if !fileManager.fileExists(atPath: destination.path) {
            _ = fileManager.createFile(atPath: destination.path, contents: nil)
        }

        let validator = Validator(
            eTag: response.value(forHTTPHeaderField: "ETag"),
            lastModified: response.value(
                forHTTPHeaderField: "Last-Modified"
            )
        )
        try JSONEncoder().encode(validator).write(
            to: metadataURL,
            options: .atomic
        )

        let expectedTotal = Self.expectedTotal(
            response: response,
            offset: offset
        )
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try handle.seekToEnd()

        var written = offset
        var buffer = Data()
        buffer.reserveCapacity(64 * 1_024)
        for try await byte in stream {
            try Task.checkCancellation()
            buffer.append(byte)
            if buffer.count >= 64 * 1_024 {
                try await limiter.waitToTransfer(byteCount: buffer.count)
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                await onProgress(written, expectedTotal ?? 0)
            }
        }
        if !buffer.isEmpty {
            try await limiter.waitToTransfer(byteCount: buffer.count)
            try handle.write(contentsOf: buffer)
            written += Int64(buffer.count)
            await onProgress(written, expectedTotal ?? written)
        }
        try handle.synchronize()
        if let expectedTotal, written != expectedTotal {
            throw BackgroundDownloadError.incompleteTransfer(
                expected: expectedTotal,
                actual: written
            )
        }
        try? fileManager.removeItem(at: metadataURL)
        return written
    }

    private func limiter(for profileID: String) -> ManagedDownloadRateLimiter {
        if let existing = limiters[profileID] {
            return existing
        }
        let created = ManagedDownloadRateLimiter()
        limiters[profileID] = created
        return created
    }

    private static func expectedTotal(
        response: HTTPURLResponse,
        offset: Int64
    ) -> Int64? {
        if let contentRange = response.value(
            forHTTPHeaderField: "Content-Range"
        ),
           let totalText = contentRange.split(separator: "/").last,
           let total = Int64(totalText) {
            return total
        }
        let length = response.expectedContentLength
        return length > 0 ? offset + length : nil
    }
}

private actor ManagedDownloadRateLimiter {
    private let clock = ContinuousClock()
    private var maximumBytesPerSecond: Int64?
    private var nextTransfer: ContinuousClock.Instant?

    func update(maximumBytesPerSecond: Int64?) {
        self.maximumBytesPerSecond = maximumBytesPerSecond
        nextTransfer = nil
    }

    func waitToTransfer(byteCount: Int) async throws {
        guard let maximumBytesPerSecond,
              maximumBytesPerSecond > 0,
              byteCount > 0 else {
            return
        }
        let now = clock.now
        let start = nextTransfer.map { max($0, now) } ?? now
        let nanoseconds = Int64(
            Double(byteCount) / Double(maximumBytesPerSecond)
                * 1_000_000_000
        )
        nextTransfer = start.advanced(
            by: .nanoseconds(max(1, nanoseconds))
        )
        if start > now {
            try await clock.sleep(until: start)
        }
    }
}
#endif
