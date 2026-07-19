#if os(iOS)
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

struct PlozziOSBackgroundHTTPDownloadEngine:
    MediaDownloadEngine,
    DownloadPolicyApplying
{
    typealias URLResolver = @Sendable (ManagedHTTPDownloadSource) async throws -> URL

    private let profileID: String
    private let resolveURL: URLResolver

    init(profileID: String, resolveURL: @escaping URLResolver) {
        self.profileID = profileID
        self.resolveURL = resolveURL
        BackgroundDownloadSession.shared.activate()
    }

    func applyDownloadPolicy(_ policy: DownloadNetworkPolicy) {
        BackgroundDownloadSession.shared.apply(policy: policy)
    }

    func download(
        record: DownloadedMediaRecord,
        to destination: URL,
        onProgress: @escaping @Sendable (Int64, Int64) async -> Void
    ) async throws -> Int64 {
        guard let source = record.managedHTTPSource else {
            throw BackgroundDownloadError.missingSource
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            let values = try destination.resourceValues(forKeys: [.fileSizeKey])
            return Int64(values.fileSize ?? 0)
        }
        let url = try await resolveURL(source)
        return try await BackgroundDownloadSession.shared.download(
            profileID: profileID,
            identityKey: record.identityKey,
            localFileName: record.localFileName,
            from: url,
            to: destination,
            onProgress: onProgress
        )
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

    var errorDescription: String? {
        switch self {
        case .missingSource: "The managed download source is unavailable."
        case .missingTaskIdentity: "The background download lost its identity."
        case .missingTemporaryFile: "The downloaded file could not be finalized."
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
    private var policy = DownloadNetworkPolicy.default

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

    func apply(policy: DownloadNetworkPolicy) {
        lock.lock()
        self.policy = policy
        lock.unlock()
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

                    let resumeURL = Self.resumeDataURL(for: destination)
                    let policy = lock.withLock { self.policy }
                    var request = URLRequest(url: url)
                    request.allowsExpensiveNetworkAccess =
                        policy.allowsExpensiveNetwork
                    request.allowsConstrainedNetworkAccess =
                        !policy.pausesOnConstrainedNetwork
                    var task: URLSessionDownloadTask
                    if let data = try? Data(contentsOf: resumeURL), !data.isEmpty {
                        task = session.downloadTask(withResumeData: data)
                        if task.originalRequest?.allowsExpensiveNetworkAccess
                            != request.allowsExpensiveNetworkAccess
                            || task.originalRequest?.allowsConstrainedNetworkAccess
                            != request.allowsConstrainedNetworkAccess {
                            task.cancel()
                            try? FileManager.default.removeItem(at: resumeURL)
                            task = session.downloadTask(with: request)
                        }
                    } else {
                        task = session.downloadTask(with: request)
                    }
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
        _ = lock.withLock {
            cancelledTaskIDs.insert(taskID)
        }
        let tasks = await allTasks()
        guard let task = tasks.first(where: {
            $0.taskDescription == taskID
        }) as? URLSessionDownloadTask else {
            finish(taskID: taskID, result: .failure(CancellationError()))
            return
        }
        task.cancel { [weak self] resumeData in
            self?.persistResumeData(resumeData, taskID: taskID)
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
            try? fileManager.removeItem(at: Self.resumeDataURL(for: destination))
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
        if let error {
            let resumeData = (error as NSError).userInfo[
                NSURLSessionDownloadTaskResumeData
            ] as? Data
            persistResumeData(resumeData, taskID: taskID)
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

    private func persistResumeData(_ data: Data?, taskID: String) {
        guard let data, !data.isEmpty else { return }
        lock.lock()
        let inMemoryDestination = transfers[taskID]?.destination
        lock.unlock()
        let destination = inMemoryDestination
            ?? (try? BackgroundTaskDescriptor.decode(taskID).destinationURL())
        guard let destination else { return }
        try? data.write(to: Self.resumeDataURL(for: destination), options: .atomic)
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

    private static func resumeDataURL(for destination: URL) -> URL {
        destination.appendingPathExtension("resume")
    }
}
#endif
