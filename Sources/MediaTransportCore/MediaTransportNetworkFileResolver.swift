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
    private let playbackLease: MediaIOPlaybackLease?
    private let lock = NSLock()
    private var releaseTask: Task<Void, Never>?

    init(
        sourceLease: MediaTransportSourceLease,
        sessionLease: MediaTransportResolverLease,
        playbackLease: MediaIOPlaybackLease?
    ) {
        self.sourceLease = sourceLease
        self.sessionLease = sessionLease
        self.playbackLease = playbackLease
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
        let playbackLease = playbackLease
        let task = Task.detached {
            sourceLease.close()
            await sourceLease.waitForFinalShutdown()
            sessionLease.release()
            await playbackLease?.releaseAndWait()
        }
        releaseTask = task
        return task
    }
}

public struct MediaTransportNetworkFileResolver: MediaTransportNetworkFileResolving {
    public typealias SessionKeyProvider = @Sendable (
        _ locator: NetworkFileLocator
    ) async throws -> MediaTransportSessionKey
    public typealias PlaybackLeaseProvider = @Sendable (
        _ locator: NetworkFileLocator
    ) async throws -> MediaIOPlaybackLease?

    private let registry: MediaTransportResolverRegistry
    private let sessionKeyProvider: SessionKeyProvider
    private let playbackLeaseProvider: PlaybackLeaseProvider

    public init(
        registry: MediaTransportResolverRegistry,
        playbackLeaseProvider: @escaping PlaybackLeaseProvider = { _ in nil },
        sessionKeyProvider: @escaping SessionKeyProvider
    ) {
        self.registry = registry
        self.playbackLeaseProvider = playbackLeaseProvider
        self.sessionKeyProvider = sessionKeyProvider
    }

    public func resolve(_ locator: NetworkFileLocator) async throws -> MediaTransportResolvedSource {
        let key = try await sessionKeyProvider(locator)
        guard key.accountID == locator.accountID,
              key.credentialRevision == locator.credentialRevision,
              key.role == .playback else {
            throw MediaTransportError.invalidInput(reason: "network-file session identity mismatch")
        }

        let playbackLease = try await playbackLeaseProvider(locator)
        let sessionLease: MediaTransportResolverLease
        do {
            sessionLease = try await registry.lease(for: key)
        } catch {
            await playbackLease?.releaseAndWait()
            throw error
        }
        do {
            let sourceLease = try await sessionLease.session.fileSystem.openSource(for: locator)
            return MediaTransportResolvedSource(
                sourceLease: sourceLease,
                sessionLease: sessionLease,
                playbackLease: playbackLease
            )
        } catch {
            sessionLease.release()
            await playbackLease?.releaseAndWait()
            throw error
        }
    }
}
