import CoreModels
import Foundation

public protocol MediaTransportNetworkFileResolving: Sendable {
    func resolve(_ locator: NetworkFileLocator) async throws -> MediaTransportResolvedSource

    /// The same resolver, but WITHOUT playback admission.
    ///
    /// Acquiring a playback lease deliberately drains any running library scan —
    /// correct when a movie starts, wrong for the lightweight reads that share the
    /// playback resolver: a codec/Atmos probe, a trickplay thumbnail. Those fire
    /// from ordinary browsing, so on a share they cancelled the in-flight scan on
    /// every detail page open. A cancelled scan never stamps `last_full_scan_at`,
    /// so `scanIfStale` saw it as stale and restarted a FULL walk — forever. That
    /// loop, not the scan interval, was the app's battery drain.
    ///
    /// Defaulted to `self` so test doubles and resolvers with no admission concept
    /// need not implement it.
    func withoutPlaybackAdmission() -> any MediaTransportNetworkFileResolving
}

public extension MediaTransportNetworkFileResolving {
    func withoutPlaybackAdmission() -> any MediaTransportNetworkFileResolving { self }
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

    /// Drops playback admission only. The session identity/credential checks in
    /// `resolve` are untouched, so a lightweight read is still bound to the same
    /// account + credential revision as playback.
    public func withoutPlaybackAdmission() -> any MediaTransportNetworkFileResolving {
        MediaTransportNetworkFileResolver(
            registry: registry,
            playbackLeaseProvider: { _ in nil },
            sessionKeyProvider: sessionKeyProvider
        )
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
