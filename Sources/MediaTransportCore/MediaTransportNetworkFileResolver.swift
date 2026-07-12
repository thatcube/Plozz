import CoreModels
import Foundation

public protocol MediaTransportNetworkFileResolving: Sendable {
    func resolve(_ locator: NetworkFileLocator) async throws -> MediaTransportResolvedSource
}

/// Owns both an opened source and the resolver session that created it. The
/// session remains pinned to the locator's credential revision until the final
/// independent source cursor drains.
public final class MediaTransportResolvedSource: @unchecked Sendable {
    public let sourceLease: MediaTransportSourceLease

    private let sessionLease: MediaTransportResolverLease
    private let lock = NSLock()
    private var releaseTask: Task<Void, Never>?

    init(
        sourceLease: MediaTransportSourceLease,
        sessionLease: MediaTransportResolverLease
    ) {
        self.sourceLease = sourceLease
        self.sessionLease = sessionLease
    }

    deinit {
        startRelease()
    }

    public func waitForFinalShutdown() async {
        await startRelease().value
    }

    @discardableResult
    private func startRelease() -> Task<Void, Never> {
        lock.lock()
        defer { lock.unlock() }
        if let releaseTask {
            return releaseTask
        }

        let sourceLease = sourceLease
        let sessionLease = sessionLease
        let task = Task.detached {
            sourceLease.close()
            await sourceLease.waitForFinalShutdown()
            sessionLease.release()
        }
        releaseTask = task
        return task
    }
}

public struct MediaTransportNetworkFileResolver: MediaTransportNetworkFileResolving {
    public typealias SessionKeyProvider = @Sendable (
        _ locator: NetworkFileLocator
    ) async throws -> MediaTransportSessionKey

    private let registry: MediaTransportResolverRegistry
    private let sessionKeyProvider: SessionKeyProvider

    public init(
        registry: MediaTransportResolverRegistry,
        sessionKeyProvider: @escaping SessionKeyProvider
    ) {
        self.registry = registry
        self.sessionKeyProvider = sessionKeyProvider
    }

    public func resolve(_ locator: NetworkFileLocator) async throws -> MediaTransportResolvedSource {
        let key = try await sessionKeyProvider(locator)
        guard key.accountID == locator.accountID,
              key.credentialRevision == locator.credentialRevision,
              key.role == .playback else {
            throw MediaTransportError.invalidInput(reason: "network-file session identity mismatch")
        }

        let sessionLease = try await registry.lease(for: key)
        do {
            let sourceLease = try await sessionLease.session.fileSystem.openSource(for: locator)
            return MediaTransportResolvedSource(
                sourceLease: sourceLease,
                sessionLease: sessionLease
            )
        } catch {
            sessionLease.release()
            throw error
        }
    }
}
