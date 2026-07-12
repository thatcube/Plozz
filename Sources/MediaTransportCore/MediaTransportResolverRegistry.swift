import CoreModels
import Foundation

public typealias MediaTransportSessionFinalizer =
    @Sendable (any MediaTransportSession) async -> Void

public final class MediaTransportResolverLease: @unchecked Sendable {
    public let key: MediaTransportSessionKey
    public let session: any MediaTransportSession

    private let registry: MediaTransportResolverRegistry
    private let lock = NSLock()
    private var isReleased = false

    fileprivate init(
        key: MediaTransportSessionKey,
        session: any MediaTransportSession,
        registry: MediaTransportResolverRegistry
    ) {
        self.key = key
        self.session = session
        self.registry = registry
    }

    deinit {
        release()
    }

    public func release() {
        let shouldRelease = lock.withLock {
            guard !isReleased else { return false }
            isReleased = true
            return true
        }
        if shouldRelease {
            let registry = self.registry
            let key = self.key
            Task { [registry, key] in
                await registry.release(key: key)
            }
        }
    }
}

public actor MediaTransportResolverRegistry: MediaTransportResolving {
    private struct RevisionScope: Hashable {
        let accountID: String
        let credentialRevision: CredentialRevision
    }

    private struct Record {
        let session: any MediaTransportSession
        let finalizer: MediaTransportSessionFinalizer
        var leaseCount: Int
        var retired: Bool
    }

    private var adapters: [String: any MediaTransportAdapter] = [:]
    private var records: [MediaTransportSessionKey: Record] = [:]
    private var retiredScopes: Set<RevisionScope> = []

    public init() {}

    public init(adapter: any MediaTransportAdapter) {
        adapters[adapter.transportIdentifier.lowercased()] = adapter
    }

    public init(adapters: [any MediaTransportAdapter]) throws {
        for adapter in adapters {
            let identifier = adapter.transportIdentifier.lowercased()
            guard self.adapters[identifier] == nil else {
                throw MediaTransportError.invalidInput(reason: "adapter already registered")
            }
            self.adapters[identifier] = adapter
        }
    }

    public func register(adapter: any MediaTransportAdapter) throws {
        let identifier = adapter.transportIdentifier.lowercased()
        guard adapters[identifier] == nil else {
            throw MediaTransportError.invalidInput(reason: "adapter already registered")
        }
        adapters[identifier] = adapter
    }

    /// Test/composition seam for an already-connected session.
    public func register(
        session: any MediaTransportSession,
        finalizer: MediaTransportSessionFinalizer? = nil
    ) throws {
        let scope = RevisionScope(
            accountID: session.key.accountID,
            credentialRevision: session.key.credentialRevision
        )
        guard !retiredScopes.contains(scope) else {
            throw MediaTransportError.cancelled
        }
        guard records[session.key] == nil else {
            throw MediaTransportError.invalidInput(reason: "session already registered")
        }
        records[session.key] = Record(
            session: session,
            finalizer: finalizer ?? { session in await session.shutdown() },
            leaseCount: 0,
            retired: false
        )
    }

    public func lease(for key: MediaTransportSessionKey) async throws -> MediaTransportResolverLease {
        let scope = RevisionScope(
            accountID: key.accountID,
            credentialRevision: key.credentialRevision
        )
        guard !retiredScopes.contains(scope) else {
            throw MediaTransportError.cancelled
        }
        if var record = records[key] {
            guard !record.retired else { throw MediaTransportError.cancelled }
            record.leaseCount += 1
            records[key] = record
            return MediaTransportResolverLease(key: key, session: record.session, registry: self)
        }
        guard let adapter = adapters[key.endpoint.transportIdentifier] else {
            throw MediaTransportError.unsupportedCapability("transport adapter")
        }

        let connected = try await adapter.connect(for: key)
        guard connected.key == key else {
            await connected.shutdown()
            throw MediaTransportError.protocolViolation(reason: "adapter returned wrong session key")
        }

        guard !retiredScopes.contains(scope) else {
            await connected.shutdown()
            throw MediaTransportError.cancelled
        }
        if records[key] != nil {
            await connected.shutdown()
            return try await lease(for: key)
        }
        records[key] = Record(
            session: connected,
            finalizer: { session in await session.shutdown() },
            leaseCount: 1,
            retired: false
        )
        return MediaTransportResolverLease(key: key, session: connected, registry: self)
    }

    /// Retires one immutable credential revision. New leases are rejected while
    /// existing leases remain valid until their final release.
    public func retire(accountID: String, credentialRevision: CredentialRevision) async {
        let scope = RevisionScope(
            accountID: accountID,
            credentialRevision: credentialRevision
        )
        retiredScopes.insert(scope)
        let keys = records.keys.filter {
            $0.accountID == accountID && $0.credentialRevision == credentialRevision
        }
        for key in keys {
            guard var record = records[key] else { continue }
            record.retired = true
            if record.leaseCount == 0 {
                records.removeValue(forKey: key)
                await record.finalizer(record.session)
            } else {
                records[key] = record
            }
        }
    }

    public var liveSessionCount: Int { records.count }

    fileprivate func release(key: MediaTransportSessionKey) async {
        guard var record = records[key], record.leaseCount > 0 else { return }
        record.leaseCount -= 1
        if record.retired, record.leaseCount == 0 {
            records.removeValue(forKey: key)
            await record.finalizer(record.session)
        } else {
            records[key] = record
        }
    }
}
