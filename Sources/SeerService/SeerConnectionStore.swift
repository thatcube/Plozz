import Foundation
import CoreModels

/// The **shared household** Seerr connection: one server URL + one admin API key
/// used by the whole household. Unlike the legacy per-profile ``SeerCredentials``,
/// this is a single connection every profile requests against — profiles differ
/// only by which Seerr *user* they act as (`Profile.seerrUserID` → `X-API-User`),
/// not by connection.
///
/// It is persisted through a ``CoreModels/SecureStoring`` that, in production, is
/// the **user-independent household Keychain** (the same mechanism backing
/// `ProfileStore`/`AccountStore`), so every Apple TV system user shares the one
/// connection. The acting-user id is NOT stored here — it lives per-profile on
/// `Profile` and is passed per request.
public struct SeerConnection: Codable, Equatable, Sendable {
    public var baseURL: URL
    public var apiKey: String

    public init(baseURL: URL, apiKey: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
    }
}

/// Persists the shared household Seerr connection. Abstracted behind a protocol so
/// the service can be unit-tested with an in-memory double.
public protocol SeerConnectionStoring: Sendable {
    func load() -> SeerConnection?
    func save(_ connection: SeerConnection) throws
    func clear() throws
}

/// Household connection store backed by a ``CoreModels/SecureStoring`` — in
/// production the user-independent household Keychain, so the connection is shared
/// across every tvOS system user. The connection is a single JSON blob under one
/// fixed key (no per-profile namespacing — it's household-wide by design).
public final class HouseholdSeerConnectionStore: SeerConnectionStoring, @unchecked Sendable {
    private let secureStore: SecureStoring
    private let key: String

    public init(secureStore: SecureStoring, key: String = "seer.household.connection") {
        self.secureStore = secureStore
        self.key = key
    }

    public func load() -> SeerConnection? {
        guard let json = secureStore.string(for: key),
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SeerConnection.self, from: data)
    }

    public func save(_ connection: SeerConnection) throws {
        let data = try JSONEncoder().encode(connection)
        guard let json = String(data: data, encoding: .utf8) else {
            throw SeerConnectionStoreError.encodingFailed
        }
        try secureStore.setString(json, for: key)
    }

    public func clear() throws {
        try secureStore.removeValue(for: key)
    }
}

public enum SeerConnectionStoreError: Error, Equatable {
    case encodingFailed
}

/// In-memory connection store for tests, previews, and non-Apple hosts. **Not**
/// secure.
public final class InMemorySeerConnectionStore: SeerConnectionStoring, @unchecked Sendable {
    private var connection: SeerConnection?
    private let lock = NSLock()

    public init(connection: SeerConnection? = nil) {
        self.connection = connection
    }

    public func load() -> SeerConnection? {
        lock.lock(); defer { lock.unlock() }
        return connection
    }

    public func save(_ connection: SeerConnection) throws {
        lock.lock(); defer { lock.unlock() }
        self.connection = connection
    }

    public func clear() throws {
        lock.lock(); defer { lock.unlock() }
        connection = nil
    }
}

// MARK: - Migration

/// Result of promoting a legacy per-profile Seerr connection into the shared
/// household slot.
public struct SeerConnectionMigrationResult: Equatable, Sendable {
    /// The connection now living in the household slot (either newly promoted, or
    /// the one already there), or `nil` if nothing was configured anywhere.
    public var connection: SeerConnection?
    /// True when a legacy per-profile connection was promoted this run.
    public var didPromote: Bool
    /// True when *another* legacy profile had a **different** server URL than the
    /// promoted one — so Settings can show a one-time "Seerr is now household-wide;
    /// using <server>" note.
    public var hadConflictingConnections: Bool
    /// The legacy `userId` (`X-API-User`) attached to the promoted connection, if
    /// any — so the caller can seed the corresponding profile's `seerrUserID`
    /// (the old field was off-by-default; usually `nil`).
    public var promotedUserID: Int?

    public init(
        connection: SeerConnection? = nil,
        didPromote: Bool = false,
        hadConflictingConnections: Bool = false,
        promotedUserID: Int? = nil
    ) {
        self.connection = connection
        self.didPromote = didPromote
        self.hadConflictingConnections = hadConflictingConnections
        self.promotedUserID = promotedUserID
    }
}

public enum SeerConnectionMigration {
    /// One-time promotion of a legacy per-profile Seerr connection into the shared
    /// household slot.
    ///
    /// - If the household slot is already configured, this is a **no-op** (returns
    ///   the existing connection) — never let an empty legacy slot clobber it.
    /// - Otherwise probes the legacy per-profile credential store across the given
    ///   `namespaces` (pass `nil` first for the default/primary profile) and
    ///   promotes the **first configured** one found (never empty-over-configured).
    /// - If any *other* probed namespace holds a connection with a **different**
    ///   base URL, flags `hadConflictingConnections` so the UI can note it.
    /// - Deletes every legacy item it read, so the per-profile credentials don't
    ///   linger after the household connection takes over.
    ///
    /// `namespaces` should be `[nil] + household profile ids`. The legacy store's
    /// namespace is mutated as we probe; callers pass a dedicated instance.
    @discardableResult
    public static func migrateIfNeeded(
        into household: SeerConnectionStoring,
        legacy: SeerCredentialStoring,
        namespaces: [String?]
    ) -> SeerConnectionMigrationResult {
        // Household already configured → nothing to do (but report what's there).
        if let existing = household.load() {
            return SeerConnectionMigrationResult(connection: existing, didPromote: false)
        }

        // De-dup namespaces, keeping order (nil/default first if the caller put it
        // first) so promotion is deterministic.
        var seen = Set<String>()
        var orderedNamespaces: [String?] = []
        for ns in namespaces {
            let sentinel = ns ?? "\u{0}<default>"
            if seen.insert(sentinel).inserted { orderedNamespaces.append(ns) }
        }

        var promoted: SeerCredentials?
        var conflicting = false
        var consumed: [String?] = []

        for ns in orderedNamespaces {
            legacy.setNamespace(ns)
            guard let creds = legacy.load() else { continue }
            consumed.append(ns)
            if promoted == nil {
                promoted = creds
            } else if creds.baseURL != promoted?.baseURL {
                conflicting = true
            }
        }

        guard let promoted else {
            return SeerConnectionMigrationResult(connection: nil, didPromote: false)
        }

        // Persist FIRST and only clear the legacy items once the household write is
        // confirmed. If the Keychain write fails, leave every legacy item intact and
        // report no promotion, so the next launch retries rather than losing the
        // connection from both places (loss-safe guarantee).
        let connection = SeerConnection(baseURL: promoted.baseURL, apiKey: promoted.apiKey)
        do {
            try household.save(connection)
        } catch {
            return SeerConnectionMigrationResult(connection: nil, didPromote: false)
        }

        // Remove every legacy item we consumed so it can't resurface.
        for ns in consumed {
            legacy.setNamespace(ns)
            try? legacy.clear()
        }

        return SeerConnectionMigrationResult(
            connection: connection,
            didPromote: true,
            hadConflictingConnections: conflicting,
            promotedUserID: promoted.userId
        )
    }
}
