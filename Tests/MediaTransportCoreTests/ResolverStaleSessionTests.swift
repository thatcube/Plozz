import CoreModels
import Foundation
@testable import MediaTransportCore
import XCTest

/// Covers the resolver registry's stale-session eviction: an idle cached session
/// whose underlying connection dropped during a pause must NOT be handed back
/// dead — the registry probes `isHealthy()` before reuse and, when unhealthy,
/// evicts (finalizes) it and reconnects a fresh one. An in-use session is never
/// torn down. Stateless (default-healthy) sessions are reused as before.
final class ResolverStaleSessionTests: XCTestCase {
    /// A session with a toggleable liveness flag + shutdown counter.
    private final class HealthControllableSession: MediaTransportSession, @unchecked Sendable {
        let key: MediaTransportSessionKey
        let fileSystem: any MediaTransportFileSystem = FakeFileSystem()
        private let lock = NSLock()
        private var healthyStorage: Bool
        private var shutdownStorage = 0

        init(key: MediaTransportSessionKey, healthy: Bool = true) {
            self.key = key
            self.healthyStorage = healthy
        }

        var shutdownCount: Int { lock.withLock { shutdownStorage } }
        func setHealthy(_ value: Bool) { lock.withLock { healthyStorage = value } }

        func isHealthy() async -> Bool { lock.withLock { healthyStorage } }
        func shutdown() async { lock.withLock { shutdownStorage += 1 } }
    }

    /// An adapter that hands out a FRESH session per connect, so a reconnect is
    /// observable (distinct instance) and the connect count is assertable.
    private final class ReconnectingAdapter: MediaTransportAdapter, @unchecked Sendable {
        let transportIdentifier: String
        private let lock = NSLock()
        private var sessions: [HealthControllableSession] = []
        private var connectStorage = 0

        init(transportIdentifier: String) { self.transportIdentifier = transportIdentifier }

        var connectCount: Int { lock.withLock { connectStorage } }
        var producedSessions: [HealthControllableSession] { lock.withLock { sessions } }

        func connect(for key: MediaTransportSessionKey) async throws -> any MediaTransportSession {
            let session = HealthControllableSession(key: key)
            lock.withLock {
                connectStorage += 1
                sessions.append(session)
            }
            return session
        }
    }

    /// Deterministically waits for `release()` (fire-and-forget via a Task) to
    /// bring a key's active lease count to zero, so a subsequent lease exercises
    /// the idle-cached path rather than racing the release.
    private func waitForIdle(
        _ registry: MediaTransportResolverRegistry,
        key: MediaTransportSessionKey
    ) async {
        for _ in 0..<1_000 {
            if await registry.activeLeaseCount(for: key) == 0 { return }
            await Task.yield()
        }
    }

    func testHealthyIdleSessionIsReusedNotReconnected() async throws {
        let key = try makeSessionKey()
        let adapter = ReconnectingAdapter(transportIdentifier: key.endpoint.transportIdentifier)
        let registry = MediaTransportResolverRegistry()
        try await registry.register(adapter: adapter)

        let first = try await registry.lease(for: key)
        first.release()
        await waitForIdle(registry, key: key) // now idle-cached, still healthy

        let second = try await registry.lease(for: key)
        XCTAssertTrue(first.session === second.session, "healthy idle session must be reused")
        XCTAssertEqual(adapter.connectCount, 1, "no reconnect for a healthy idle session")
        second.release()
    }

    func testDeadIdleSessionIsEvictedAndReconnected() async throws {
        let key = try makeSessionKey()
        let adapter = ReconnectingAdapter(transportIdentifier: key.endpoint.transportIdentifier)
        let registry = MediaTransportResolverRegistry()
        try await registry.register(adapter: adapter)

        // First lease → session #1. Release + wait until it's genuinely idle.
        let first = try await registry.lease(for: key)
        let session1 = adapter.producedSessions[0]
        first.release()
        await waitForIdle(registry, key: key)

        // Simulate the connection dropping during the pause.
        session1.setHealthy(false)

        // Next lease must NOT hand back the dead session — evict + reconnect.
        let second = try await registry.lease(for: key)
        XCTAssertEqual(adapter.connectCount, 2, "dead idle session must trigger a reconnect")
        XCTAssertFalse(second.session === session1, "must not hand back the dead session")
        XCTAssertEqual(session1.shutdownCount, 1, "evicted dead session must be finalized (socket released)")
        second.release()
    }

    func testInUseSessionIsNeverEvictedEvenIfUnhealthy() async throws {
        let key = try makeSessionKey()
        let adapter = ReconnectingAdapter(transportIdentifier: key.endpoint.transportIdentifier)
        let registry = MediaTransportResolverRegistry()
        try await registry.register(adapter: adapter)

        // Hold an active lease, then mark the session unhealthy.
        let held = try await registry.lease(for: key)
        let session1 = adapter.producedSessions[0]
        session1.setHealthy(false)

        // A concurrent lease while it's IN USE must reuse it (never tear down
        // a session under an active consumer), regardless of health.
        let concurrent = try await registry.lease(for: key)
        XCTAssertTrue(concurrent.session === session1, "in-use session must be reused, not evicted")
        XCTAssertEqual(adapter.connectCount, 1, "no reconnect while the session is in use")
        XCTAssertEqual(session1.shutdownCount, 0, "in-use session must not be finalized")

        held.release()
        concurrent.release()
    }

    func testStatelessSessionUsesDefaultHealthyAndIsReused() async throws {
        // A session that does NOT override isHealthy() (default true) — the
        // WebDAV/HTTP shape — is always reused while idle.
        let key = try makeSessionKey()
        let session = FakeSession(key: key)
        let adapter = FakeAdapter(
            transportIdentifier: key.endpoint.transportIdentifier,
            session: session
        )
        let registry = MediaTransportResolverRegistry()
        try await registry.register(adapter: adapter)

        let first = try await registry.lease(for: key)
        first.release()
        await waitForIdle(registry, key: key)
        let second = try await registry.lease(for: key)
        XCTAssertTrue(second.session === session)
        XCTAssertEqual(adapter.connectCount, 1, "default-healthy session is reused, never reconnected")
        second.release()
    }
}
