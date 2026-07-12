import Foundation
import MediaTransportCore

public typealias ShareTransportSessionFactory =
    @Sendable (MediaTransportRole) async throws -> any MediaTransportSession

actor ShareTransportBrowser {
    enum BrowserError: Swift.Error, Equatable {
        case closed
    }

    private let sessionFactory: ShareTransportSessionFactory
    private let role: MediaTransportRole
    private var session: (any MediaTransportSession)?
    private var operationTail = Task<Void, Never> {}
    private var isClosed = false

    init(
        role: MediaTransportRole,
        sessionFactory: @escaping ShareTransportSessionFactory
    ) {
        self.role = role
        self.sessionFactory = sessionFactory
    }

    func listDirectory(_ path: String) async throws -> [RemoteFileEntry] {
        try await enqueue { fileSystem in
            try await fileSystem.list(relativePath: path)
        }
    }

    func readFile(_ path: String, maximumBytes: Int = 16 * 1_024 * 1_024) async throws -> Data {
        try await enqueue { fileSystem in
            try await fileSystem.readSmallFile(
                relativePath: path,
                maximumBytes: maximumBytes
            )
        }
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        let session = self.session
        self.session = nil
        await session?.shutdown()
    }

    private func enqueue<Value: Sendable>(
        operation: @escaping @Sendable (any MediaTransportFileSystem) async throws -> Value
    ) async throws -> Value {
        guard !isClosed else {
            throw BrowserError.closed
        }

        let previous = operationTail
        let task = Task {
            await previous.value
            try Task.checkCancellation()
            return try await self.perform(operation: operation)
        }
        operationTail = Task {
            _ = await task.result
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func perform<Value: Sendable>(
        operation: @escaping @Sendable (any MediaTransportFileSystem) async throws -> Value
    ) async throws -> Value {
        let session = try await activeSession()
        do {
            return try await operation(session.fileSystem)
        } catch {
            guard shouldReconnect(after: error), !isClosed else {
                throw error
            }
            self.session = nil
            await session.shutdown()
            let replacement = try await activeSession()
            return try await operation(replacement.fileSystem)
        }
    }

    private func activeSession() async throws -> any MediaTransportSession {
        guard !isClosed else {
            throw BrowserError.closed
        }
        if let session {
            return session
        }
        let session = try await sessionFactory(role)
        guard !isClosed else {
            await session.shutdown()
            throw BrowserError.closed
        }
        self.session = session
        return session
    }

    private func shouldReconnect(after error: Swift.Error) -> Bool {
        guard let transportError = error as? MediaTransportError else {
            return true
        }
        switch transportError {
        case .timeout, .transport:
            return true
        case .invalidInput, .unsupportedCapability, .unsupportedRange,
             .authentication, .trust, .permissionDenied, .protocolViolation,
             .resourceBusy, .sourceChanged, .cancelled:
            return false
        }
    }
}
