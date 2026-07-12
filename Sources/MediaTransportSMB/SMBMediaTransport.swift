import CoreModels
import Foundation
import MediaTransportCore
@preconcurrency import SMBClient

public enum SMBMediaTransportCredential: Sendable, Equatable {
    case anonymous
    case password(username: String, password: String)

    fileprivate var isGuestIntent: Bool {
        switch self {
        case .anonymous:
            return true
        case .password(let username, _):
            return username.isEmpty
                || username.caseInsensitiveCompare("guest") == .orderedSame
                || username.caseInsensitiveCompare("anonymous") == .orderedSame
        }
    }

    fileprivate var normalizedForSMBLogin: SMBMediaTransportCredential {
        guard case let .password(username, password) = self,
              username.isEmpty else {
            return self
        }
        return .password(username: "guest", password: password)
    }
}

public struct SMBMediaTransportConfiguration: Sendable, Equatable {
    public let credential: SMBMediaTransportCredential
    public let options: SMBTransportOptions

    public init(
        credential: SMBMediaTransportCredential,
        options: SMBTransportOptions = SMBTransportOptions()
    ) {
        self.credential = credential
        self.options = options
    }
}

public typealias SMBMediaTransportConfigurationProvider =
    @Sendable (String, CredentialRevision) throws -> SMBMediaTransportConfiguration

public struct SMBMediaTransportAdapter: MediaTransportAdapter, Sendable {
    public let transportIdentifier = MediaShareTransportKind.smb.rawValue

    private let configurationProvider: SMBMediaTransportConfigurationProvider
    private let backendFactory: @Sendable () -> any SMBTransportBackend

    public init(configurationProvider: @escaping SMBMediaTransportConfigurationProvider) {
        self.init(
            configurationProvider: configurationProvider,
            backendFactory: { SMBClientBackend() }
        )
    }

    init(
        configurationProvider: @escaping SMBMediaTransportConfigurationProvider,
        backendFactory: @escaping @Sendable () -> any SMBTransportBackend
    ) {
        self.configurationProvider = configurationProvider
        self.backendFactory = backendFactory
    }

    public func connect(for key: MediaTransportSessionKey) async throws -> any MediaTransportSession {
        guard key.endpoint.transportIdentifier == transportIdentifier else {
            throw MediaTransportError.unsupportedCapability("transport")
        }

        let target = try SMBConnectionTarget(endpoint: key.endpoint)
        let configuration = try configurationProvider(key.accountID, key.credentialRevision)
        let credential = configuration.credential.normalizedForSMBLogin
        if configuration.options.minimumDialect == .smb3 {
            throw MediaTransportError.unsupportedCapability("minimum SMB 3 dialect")
        }
        if configuration.options.requiresEncryption {
            // The pinned SMB client does not expose negotiated encryption state,
            // so Plozz cannot honestly enforce a required-encryption policy yet.
            throw MediaTransportError.unsupportedCapability("SMB encryption policy")
        }
        if configuration.options.requiresSigning,
           credential.isGuestIntent {
            throw MediaTransportError.unsupportedCapability("signed anonymous SMB")
        }

        let backend = backendFactory()
        do {
            try await backend.connect(
                host: target.host,
                port: target.port,
                share: target.share,
                credential: credential,
                requiresSigning: configuration.options.requiresSigning
            )
        } catch {
            await backend.shutdown()
            throw mapSMBError(error)
        }

        let fileSystem = SMBMediaTransportFileSystem(
            backend: backend,
            sourceFactory: { path, representation in
                let sourceBackend = backendFactory()
                do {
                    try await sourceBackend.connect(
                        host: target.host,
                        port: target.port,
                        share: target.share,
                        credential: credential,
                        requiresSigning: configuration.options.requiresSigning
                    )
                    let source = try await sourceBackend.openSource(
                        path: path,
                        expectedRepresentation: representation
                    )
                    return SMBFileSourceChannel(
                        backend: sourceBackend,
                        source: source
                    )
                } catch {
                    await sourceBackend.shutdown()
                    throw mapSMBError(error)
                }
            },
            rootPath: target.rootPath,
            accountID: key.accountID,
            credentialRevision: key.credentialRevision
        )
        return SMBMediaTransportSession(
            key: key,
            fileSystem: fileSystem,
            backend: backend
        )
    }
}

private struct SMBConnectionTarget: Sendable {
    let host: String
    let port: Int
    let share: String
    let rootPath: String

    init(endpoint: MediaTransportEndpointIdentity) throws {
        guard !endpoint.host.isEmpty,
              endpoint.port.map({ (1...65_535).contains($0) }) ?? true else {
            throw MediaTransportError.invalidInput(reason: "invalid SMB endpoint")
        }

        let components = endpoint.rootPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard let share = components.first, !share.isEmpty else {
            throw MediaTransportError.invalidInput(reason: "missing SMB share")
        }

        host = endpoint.host
        port = endpoint.port ?? 445
        self.share = share
        rootPath = components.dropFirst().joined(separator: "/")
    }
}

private typealias SMBFileSourceFactory = @Sendable (
    _ path: String,
    _ representation: RemoteFileRepresentation
) async throws -> SMBFileSourceChannel

private final class SMBFileSourceChannel: @unchecked Sendable {
    let source: any MediaTransportByteSource

    private let backend: any SMBTransportBackend
    private let lock = NSLock()
    private var isClosed = false

    init(
        backend: any SMBTransportBackend,
        source: any MediaTransportByteSource
    ) {
        self.backend = backend
        self.source = source
    }

    func shutdown() async {
        let shouldClose = lock.withLock {
            guard !isClosed else { return false }
            isClosed = true
            return true
        }
        guard shouldClose else { return }
        await source.shutdown()
        await backend.shutdown()
    }
}

private final class SMBMediaTransportSession: MediaTransportSession, @unchecked Sendable {
    let key: MediaTransportSessionKey
    let fileSystem: any MediaTransportFileSystem

    private let backend: any SMBTransportBackend

    init(
        key: MediaTransportSessionKey,
        fileSystem: any MediaTransportFileSystem,
        backend: any SMBTransportBackend
    ) {
        self.key = key
        self.fileSystem = fileSystem
        self.backend = backend
    }

    func shutdown() async {
        await backend.shutdown()
    }
}

private final class SMBMediaTransportFileSystem: MediaTransportFileSystem, @unchecked Sendable {
    private static let maximumSmallFileSize = 16 * 1_024 * 1_024

    private let backend: any SMBTransportBackend
    private let sourceFactory: SMBFileSourceFactory
    private let rootPath: String
    private let accountID: String
    private let credentialRevision: CredentialRevision

    init(
        backend: any SMBTransportBackend,
        sourceFactory: @escaping SMBFileSourceFactory,
        rootPath: String,
        accountID: String,
        credentialRevision: CredentialRevision
    ) {
        self.backend = backend
        self.sourceFactory = sourceFactory
        self.rootPath = rootPath
        self.accountID = accountID
        self.credentialRevision = credentialRevision
    }

    func validate() async throws {
        do {
            _ = try await backend.list(path: rootPath)
        } catch {
            throw mapSMBError(error)
        }
    }

    func probe() async throws -> MediaTransportProbe {
        MediaTransportProbe(
            capabilities: try MediaTransportCapabilities(
                supportsList: true,
                supportsStat: true,
                supportsBoundedWholeFileRead: true,
                byteRangeBehavior: .randomAccess,
                maximumBoundedWholeFileReadBytes: Self.maximumSmallFileSize,
                consistency: .changeDetecting
            )
        )
    }

    func list(relativePath: String) async throws -> [RemoteFileEntry] {
        let normalizedPath = try normalizedRelativePath(relativePath, allowEmpty: true)
        let path = joinedRootPath(normalizedPath)

        do {
            return try await backend.list(path: path).compactMap { entry in
                guard entry.name != ".", entry.name != "..",
                      !entry.isHidden, !entry.isSystem else {
                    return nil
                }
                let childPath = normalizedPath.isEmpty
                    ? entry.name
                    : "\(normalizedPath)/\(entry.name)"
                return try RemoteFileEntry(
                    relativePath: childPath,
                    kind: entry.kind,
                    size: entry.size,
                    modifiedAt: entry.modifiedAt,
                    createdAt: entry.createdAt
                )
            }
        } catch {
            throw mapSMBError(error)
        }
    }

    func stat(relativePath: String) async throws -> RemoteFileEntry {
        let normalizedPath = try normalizedRelativePath(relativePath)
        do {
            let entry = try await backend.stat(path: joinedRootPath(normalizedPath))
            return try RemoteFileEntry(
                relativePath: normalizedPath,
                kind: entry.kind,
                size: entry.size,
                modifiedAt: entry.modifiedAt,
                createdAt: entry.createdAt
            )
        } catch {
            throw mapSMBError(error)
        }
    }

    func readSmallFile(relativePath: String, maximumBytes: Int) async throws -> Data {
        guard maximumBytes > 0,
              maximumBytes <= Self.maximumSmallFileSize else {
            throw MediaTransportError.invalidInput(reason: "invalid small-file bound")
        }

        let normalizedPath = try normalizedRelativePath(relativePath)
        do {
            return try await backend.readSmallFile(
                path: joinedRootPath(normalizedPath),
                maximumBytes: maximumBytes
            )
        } catch {
            throw mapSMBError(error)
        }
    }

    func openSource(for locator: NetworkFileLocator) async throws -> MediaTransportSourceLease {
        guard locator.accountID == accountID,
              locator.credentialRevision == credentialRevision else {
            throw MediaTransportError.invalidInput(reason: "locator session mismatch")
        }
        let normalizedPath = try normalizedRelativePath(locator.relativePath)
        do {
            let path = joinedRootPath(normalizedPath)
            let current = try await backend.stat(path: path)
            try validateSMBRepresentation(current, against: locator.representation)
            let source = SMBCursorIsolatedFileByteSource(
                byteSize: locator.representation.size,
                path: path,
                expectedRepresentation: locator.representation,
                sourceFactory: sourceFactory
            )
            return MediaTransportSourceLease(source: source)
        } catch {
            throw mapSMBError(error)
        }
    }

    private func joinedRootPath(_ relativePath: String) -> String {
        guard !rootPath.isEmpty else { return relativePath }
        guard !relativePath.isEmpty else { return rootPath }
        return "\(rootPath)/\(relativePath)"
    }
}

struct SMBBackendEntry: Sendable, Equatable {
    let name: String
    let kind: RemoteFileEntryKind
    let size: Int64?
    let modifiedAt: Date?
    let createdAt: Date?
    let isHidden: Bool
    let isSystem: Bool

    init(
        name: String,
        kind: RemoteFileEntryKind,
        size: Int64?,
        modifiedAt: Date?,
        createdAt: Date?,
        isHidden: Bool = false,
        isSystem: Bool = false
    ) {
        self.name = name
        self.kind = kind
        self.size = size
        self.modifiedAt = modifiedAt
        self.createdAt = createdAt
        self.isHidden = isHidden
        self.isSystem = isSystem
    }
}

protocol SMBTransportBackend: Sendable {
    func connect(
        host: String,
        port: Int,
        share: String,
        credential: SMBMediaTransportCredential,
        requiresSigning: Bool
    ) async throws
    func list(path: String) async throws -> [SMBBackendEntry]
    func stat(path: String) async throws -> SMBBackendEntry
    func readSmallFile(path: String, maximumBytes: Int) async throws -> Data
    func openSource(
        path: String,
        expectedRepresentation: RemoteFileRepresentation
    ) async throws -> any MediaTransportByteSource
    func shutdown() async
}

private final class SMBClientBackend: SMBTransportBackend, @unchecked Sendable {
    private let state = State()

    func connect(
        host: String,
        port: Int,
        share: String,
        credential: SMBMediaTransportCredential,
        requiresSigning: Bool
    ) async throws {
        try await state.connect(
            host: host,
            port: port,
            share: share,
            credential: credential,
            requiresSigning: requiresSigning
        )
    }

    func list(path: String) async throws -> [SMBBackendEntry] {
        try await state.list(path: path)
    }

    func stat(path: String) async throws -> SMBBackendEntry {
        try await state.stat(path: path)
    }

    func readSmallFile(path: String, maximumBytes: Int) async throws -> Data {
        try await state.readSmallFile(path: path, maximumBytes: maximumBytes)
    }

    func openSource(
        path: String,
        expectedRepresentation: RemoteFileRepresentation
    ) async throws -> any MediaTransportByteSource {
        try await state.openSource(path: path, expectedRepresentation: expectedRepresentation)
    }

    func shutdown() async {
        await state.shutdown()
    }

    fileprivate actor State {
        private var client: SMBClient?
        private var operationTail = Task<Void, Never> {}
        private var isClosed = false

        func connect(
            host: String,
            port: Int,
            share: String,
            credential: SMBMediaTransportCredential,
            requiresSigning: Bool
        ) async throws {
            guard client == nil, !isClosed else {
                throw MediaTransportError.invalidInput(reason: "SMB backend already connected")
            }

            let client = SMBClient(host: host, port: port)
            self.client = client

            do {
                switch credential {
                case .anonymous:
                    do {
                        _ = try await enqueue(timeout: .seconds(12)) { client in
                            try await client.login(
                                username: "guest",
                                password: nil,
                                requireSigning: requiresSigning
                            )
                        }
                    } catch {
                        switch mapSMBError(error) {
                        case .transport, .timeout, .cancelled:
                            throw error
                        default:
                            _ = try await enqueue(timeout: .seconds(12)) { client in
                                try await client.login(
                                    username: nil,
                                    password: nil,
                                    requireSigning: requiresSigning
                                )
                            }
                        }
                    }
                case let .password(username, password):
                    guard !username.isEmpty else {
                        throw MediaTransportError.invalidInput(reason: "missing SMB username")
                    }
                    try await enqueue(timeout: .seconds(12)) { client in
                        try await client.login(
                            username: username,
                            password: password,
                            requireSigning: requiresSigning
                        )
                        guard credential.isGuestIntent || !client.session.isGuestSession else {
                            throw MediaTransportError.authentication(reason: "guest fallback")
                        }
                    }
                }

                _ = try await enqueue(timeout: .seconds(12)) { client in
                    try await client.connectShare(share)
                }
            } catch {
                client.session.disconnect()
                isClosed = true
                throw error
            }
        }

        func list(path: String) async throws -> [SMBBackendEntry] {
            try await enqueue(timeout: .seconds(20)) { client in
                try await client.listDirectory(path: path).map {
                    SMBBackendEntry(
                        name: $0.name,
                        kind: $0.isDirectory ? .directory : .file,
                        size: $0.isDirectory ? nil : Int64(clamping: $0.size),
                        modifiedAt: $0.lastWriteTime,
                        createdAt: $0.creationTime,
                        isHidden: $0.isHidden,
                        isSystem: $0.isSystem
                    )
                }
            }
        }

        func stat(path: String) async throws -> SMBBackendEntry {
            try await enqueue(timeout: .seconds(12)) { client in
                let stat = try await client.fileStat(path: path)
                return SMBBackendEntry(
                    name: URL(fileURLWithPath: path).lastPathComponent,
                    kind: stat.isDirectory ? .directory : .file,
                    size: stat.isDirectory ? nil : Int64(clamping: stat.size),
                    modifiedAt: stat.lastWriteTime,
                    createdAt: stat.creationTime
                )
            }
        }

        func readSmallFile(path: String, maximumBytes: Int) async throws -> Data {
            let stat = try await stat(path: path)
            guard stat.kind == .file,
                  let size = stat.size,
                  size <= maximumBytes else {
                throw MediaTransportError.invalidInput(reason: "small-file bound exceeded")
            }

            let reader = try await enqueue(timeout: .seconds(12)) { client in
                client.fileReader(path: path)
            }
            do {
                let data = try await enqueue(timeout: .seconds(20)) { _ in
                    try await reader.read(offset: 0, length: UInt32(maximumBytes + 1))
                }
                try? await enqueue(timeout: .seconds(5)) { _ in
                    try await reader.close()
                }
                guard data.count <= maximumBytes else {
                    throw MediaTransportError.invalidInput(reason: "small-file bound exceeded")
                }
                return data
            } catch {
                try? await enqueue(timeout: .seconds(5)) { _ in
                    try await reader.close()
                }
                throw error
            }
        }

        func openSource(
            path: String,
            expectedRepresentation: RemoteFileRepresentation
        ) async throws -> any MediaTransportByteSource {
            let current = try await stat(path: path)
            try validateSMBRepresentation(current, against: expectedRepresentation)
            guard let currentSize = current.size else {
                throw MediaTransportError.sourceChanged(reason: "missing SMB file size")
            }

            let reader = try await enqueue(timeout: .seconds(12)) { client in
                client.fileReader(path: path)
            }
            return SMBFileByteSource(
                byteSize: currentSize,
                path: path,
                expectedRepresentation: expectedRepresentation,
                reader: reader,
                backend: self
            )
        }

        func read(
            reader: FileReader,
            path: String,
            expectedRepresentation: RemoteFileRepresentation,
            offset: Int64,
            length: Int
        ) async throws -> Data {
            guard offset >= 0,
                  length > 0,
                  length <= Int(UInt32.max) else {
                throw MediaTransportError.invalidInput(reason: "invalid SMB read")
            }
            return try await enqueue(timeout: .seconds(20)) { client in
                let stat = try await client.fileStat(path: path)
                let current = SMBBackendEntry(
                    name: URL(fileURLWithPath: path).lastPathComponent,
                    kind: stat.isDirectory ? .directory : .file,
                    size: stat.isDirectory ? nil : Int64(clamping: stat.size),
                    modifiedAt: stat.lastWriteTime,
                    createdAt: stat.creationTime
                )
                try validateSMBRepresentation(current, against: expectedRepresentation)
                return try await reader.read(offset: UInt64(offset), length: UInt32(length))
            }
        }

        func close(reader: FileReader) async {
            try? await enqueue(timeout: .seconds(5)) { _ in
                try await reader.close()
            }
        }

        func shutdown() async {
            let client = self.client
            self.client = nil
            isClosed = true
            client?.session.disconnect()
        }

        private func enqueue<Value: Sendable>(
            timeout: Duration,
            operation: @escaping @Sendable (SMBClient) async throws -> Value
        ) async throws -> Value {
            guard !isClosed, let client else {
                throw MediaTransportError.transport(code: -1)
            }

            let previous = operationTail
            let task = Task {
                await previous.value
                try Task.checkCancellation()
                return try await operation(client)
            }
            operationTail = Task {
                _ = await task.result
            }

            do {
                return try await SMBOperationDeadline.run(
                    task: task,
                    timeout: timeout,
                    onAbandon: { client.session.disconnect() }
                )
            } catch {
                if error is CancellationError || error as? MediaTransportError == .timeout {
                    isClosed = true
                }
                throw error
            }
        }

    }
}

private final class SMBCursorIsolatedFileByteSource:
    MediaTransportCursorIsolatedByteSource,
    @unchecked Sendable
{
    let byteSize: Int64

    private let directCursorID = UUID()
    private let state: State

    init(
        byteSize: Int64,
        path: String,
        expectedRepresentation: RemoteFileRepresentation,
        sourceFactory: @escaping SMBFileSourceFactory
    ) {
        self.byteSize = byteSize
        state = State(
            path: path,
            expectedRepresentation: expectedRepresentation,
            sourceFactory: sourceFactory
        )
    }

    func read(at offset: Int64, length: Int) async throws -> Data {
        try await read(
            cursorID: directCursorID,
            at: offset,
            length: length
        )
    }

    func read(
        cursorID: UUID,
        at offset: Int64,
        length: Int
    ) async throws -> Data {
        try await state.read(
            cursorID: cursorID,
            offset: offset,
            length: length
        )
    }

    func release(cursorID: UUID) async {
        await state.release(cursorID: cursorID)
    }

    func shutdown() async {
        await state.shutdown()
    }

    private actor State {
        private struct ChannelEntry {
            let id: UUID
            let task: Task<SMBFileSourceChannel, Error>
        }

        private let path: String
        private let expectedRepresentation: RemoteFileRepresentation
        private let sourceFactory: SMBFileSourceFactory
        private var channels: [UUID: ChannelEntry] = [:]
        private var closing: [UUID: Task<Void, Never>] = [:]
        private var isClosed = false

        init(
            path: String,
            expectedRepresentation: RemoteFileRepresentation,
            sourceFactory: @escaping SMBFileSourceFactory
        ) {
            self.path = path
            self.expectedRepresentation = expectedRepresentation
            self.sourceFactory = sourceFactory
        }

        func read(
            cursorID: UUID,
            offset: Int64,
            length: Int
        ) async throws -> Data {
            let entry = try channelEntry(for: cursorID)
            let channel: SMBFileSourceChannel
            do {
                channel = try await withTaskCancellationHandler {
                    try await entry.task.value
                } onCancel: {
                    entry.task.cancel()
                }
            } catch {
                await discard(entry, for: cursorID)
                throw mapSMBError(error)
            }

            do {
                return try await channel.source.read(at: offset, length: length)
            } catch {
                await discard(entry, for: cursorID)
                throw mapSMBError(error)
            }
        }

        func release(cursorID: UUID) async {
            guard let entry = channels.removeValue(forKey: cursorID) else {
                return
            }
            await close(entry)
        }

        func shutdown() async {
            guard !isClosed else {
                for task in closing.values {
                    await task.value
                }
                return
            }
            isClosed = true

            let active = Array(channels.values)
            channels.removeAll()
            for entry in active {
                _ = beginClosing(entry)
            }

            let closeTasks = Array(closing.values)
            for task in closeTasks {
                await task.value
            }
            closing.removeAll()
        }

        private func channelEntry(for cursorID: UUID) throws -> ChannelEntry {
            guard !isClosed else {
                throw MediaTransportError.cancelled
            }
            if let entry = channels[cursorID] {
                return entry
            }

            let path = self.path
            let representation = expectedRepresentation
            let sourceFactory = self.sourceFactory
            let entry = ChannelEntry(
                id: UUID(),
                task: Task.detached(priority: .userInitiated) {
                    try await sourceFactory(path, representation)
                }
            )
            channels[cursorID] = entry
            return entry
        }

        private func discard(
            _ entry: ChannelEntry,
            for cursorID: UUID
        ) async {
            guard channels[cursorID]?.id == entry.id else { return }
            channels.removeValue(forKey: cursorID)
            await close(entry)
        }

        private func close(_ entry: ChannelEntry) async {
            let task = beginClosing(entry)
            await task.value
            closing.removeValue(forKey: entry.id)
        }

        private func beginClosing(_ entry: ChannelEntry) -> Task<Void, Never> {
            if let task = closing[entry.id] {
                return task
            }
            let task = Task.detached(priority: .utility) {
                entry.task.cancel()
                if case .success(let channel) = await entry.task.result {
                    await channel.shutdown()
                }
            }
            closing[entry.id] = task
            return task
        }
    }
}

private final class SMBFileByteSource: MediaTransportByteSource, @unchecked Sendable {
    let byteSize: Int64

    private let state: State

    init(
        byteSize: Int64,
        path: String,
        expectedRepresentation: RemoteFileRepresentation,
        reader: FileReader,
        backend: SMBClientBackend.State
    ) {
        self.byteSize = byteSize
        state = State(
            path: path,
            expectedRepresentation: expectedRepresentation,
            reader: reader,
            backend: backend
        )
    }

    func read(at offset: Int64, length: Int) async throws -> Data {
        try await state.read(offset: offset, length: length)
    }

    func shutdown() async {
        await state.shutdown()
    }

    private actor State {
        private let path: String
        private let expectedRepresentation: RemoteFileRepresentation
        private let reader: FileReader
        private let backend: SMBClientBackend.State
        private var isClosed = false

        init(
            path: String,
            expectedRepresentation: RemoteFileRepresentation,
            reader: FileReader,
            backend: SMBClientBackend.State
        ) {
            self.path = path
            self.expectedRepresentation = expectedRepresentation
            self.reader = reader
            self.backend = backend
        }

        func read(offset: Int64, length: Int) async throws -> Data {
            guard !isClosed else {
                throw MediaTransportError.cancelled
            }
            return try await backend.read(
                reader: reader,
                path: path,
                expectedRepresentation: expectedRepresentation,
                offset: offset,
                length: length
            )
        }

        func shutdown() async {
            guard !isClosed else { return }
            isClosed = true
            await backend.close(reader: reader)
        }
    }
}

private enum SMBOperationDeadline {
    static func run<Value: Sendable>(
        task: Task<Value, Error>,
        timeout: Duration,
        onAbandon: @escaping @Sendable () -> Void
    ) async throws -> Value {
        let race = ResultRace<Value>()

        let timeoutTask = Task {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            if race.resolve(.failure(MediaTransportError.timeout)) {
                task.cancel()
                onAbandon()
            }
        }
        race.install(timeoutTask: timeoutTask)

        Task {
            race.resolve(await task.result)
        }

        return try await withTaskCancellationHandler {
            try await race.value()
        } onCancel: {
            if race.resolve(.failure(CancellationError())) {
                task.cancel()
                onAbandon()
            }
        }
    }

    private final class ResultRace<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value, Error>?
        private var result: Result<Value, Error>?
        private var timeoutTask: Task<Void, Never>?
        private var isResolved = false

        func install(timeoutTask: Task<Void, Never>) {
            lock.lock()
            if isResolved {
                lock.unlock()
                timeoutTask.cancel()
                return
            }
            self.timeoutTask = timeoutTask
            lock.unlock()
        }

        func value() async throws -> Value {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let result {
                    lock.unlock()
                    continuation.resume(with: result)
                    return
                }
                self.continuation = continuation
                lock.unlock()
            }
        }

        @discardableResult
        func resolve(_ result: Result<Value, Error>) -> Bool {
            lock.lock()
            guard !isResolved else {
                lock.unlock()
                return false
            }
            isResolved = true
            let continuation = self.continuation
            self.continuation = nil
            if continuation == nil {
                self.result = result
            }
            let timeoutTask = self.timeoutTask
            self.timeoutTask = nil
            lock.unlock()

            timeoutTask?.cancel()
            continuation?.resume(with: result)
            return true
        }
    }
}

private func validateSMBRepresentation(
    _ entry: SMBBackendEntry,
    against representation: RemoteFileRepresentation
) throws {
    guard entry.kind == .file,
          entry.size == representation.size,
          representation.consistency == .changeDetecting,
          representation.identity.kind == .modificationTime,
          entry.modifiedAt == representation.identity.modifiedAt else {
        throw MediaTransportError.sourceChanged(reason: "SMB representation changed")
    }
}

private func normalizedRelativePath(
    _ path: String,
    allowEmpty: Bool = false
) throws -> String {
    guard !path.contains("\0") else {
        throw MediaTransportError.invalidInput(reason: "invalid SMB path")
    }

    let standardized = path.replacingOccurrences(of: "\\", with: "/")
    let components = standardized.split(separator: "/", omittingEmptySubsequences: true)
    var normalized: [Substring] = []
    normalized.reserveCapacity(components.count)

    for component in components {
        switch component {
        case ".":
            continue
        case "..":
            guard !normalized.isEmpty else {
                throw MediaTransportError.invalidInput(reason: "SMB path traversal")
            }
            normalized.removeLast()
        default:
            normalized.append(component)
        }
    }

    let result = normalized.joined(separator: "/")
    guard allowEmpty || !result.isEmpty else {
        throw MediaTransportError.invalidInput(reason: "empty SMB path")
    }
    return result
}

private func mapSMBError(_ error: Error) -> MediaTransportError {
    if let transportError = error as? MediaTransportError {
        return transportError
    }
    if error is CancellationError {
        return .cancelled
    }
    if let response = error as? ErrorResponse {
        let status = ErrorCode(rawValue: response.header.status)
        switch status {
        case .logonFailure:
            return .authentication(reason: "SMB logon failed")
        case .accessDenied:
            return .permissionDenied
        case .ioTimeout:
            return .timeout
        default:
            return .transport(code: Int(response.header.status))
        }
    }
    return .transport(code: (error as NSError).code)
}
