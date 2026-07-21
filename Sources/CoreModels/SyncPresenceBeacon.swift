import Foundation

// MARK: - Non-secret presence beacon
//
// A tiny, NON-SECRET record a configured device publishes to the user's iCloud so
// a fresh device on the same Apple ID can offer "you already set up Plozz on your
// Apple TV — bring it here?". It contains NO token, password, hostname, or account
// id — only enough to prompt. Transport is `NSUbiquitousKeyValueStore` (supported
// on iOS + tvOS), chosen for v1 because it needs no CloudKit schema and syncs the
// small blob quickly. Nothing here moves a credential; sign-in still happens
// per-device (native provider linking).

/// A non-secret "a setup exists" beacon. Safe to replicate via iCloud KVS.
public struct SyncPresenceBeacon: Codable, Hashable, Sendable {
    public var setupExists: Bool
    /// Friendly device name that produced the setup (e.g. "Living Room"). Display
    /// only; no network identity.
    public var deviceName: String
    /// How many servers the setup has — for a richer prompt ("2 servers"). Count
    /// only; no server identity.
    public var serverCount: Int
    /// Number of profiles — display only.
    public var profileCount: Int
    public var schemaVersion: Int
    public var updatedAt: Date

    public static let currentSchemaVersion = 1

    public init(
        setupExists: Bool,
        deviceName: String,
        serverCount: Int,
        profileCount: Int,
        schemaVersion: Int = SyncPresenceBeacon.currentSchemaVersion,
        updatedAt: Date = Date()
    ) {
        self.setupExists = setupExists
        self.deviceName = deviceName
        self.serverCount = serverCount
        self.profileCount = profileCount
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
    }
}

/// Reads/writes the household presence beacon. Abstracted so the iCloud-backed
/// implementation can be swapped for an in-memory one in tests/previews.
public protocol PresenceBeaconStoring: Sendable {
    func read() -> SyncPresenceBeacon?
    func write(_ beacon: SyncPresenceBeacon)
    func clear()
}

/// In-memory beacon store for tests/previews (no iCloud).
public final class InMemoryPresenceBeaconStore: PresenceBeaconStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var beacon: SyncPresenceBeacon?
    public init(_ initial: SyncPresenceBeacon? = nil) { self.beacon = initial }
    public func read() -> SyncPresenceBeacon? { lock.lock(); defer { lock.unlock() }; return beacon }
    public func write(_ beacon: SyncPresenceBeacon) { lock.lock(); self.beacon = beacon; lock.unlock() }
    public func clear() { lock.lock(); beacon = nil; lock.unlock() }
}

/// iCloud key-value-store–backed beacon (iOS + tvOS). No-op-safe when iCloud is
/// unavailable (missing entitlement / signed out): writes/reads simply don't sync.
public final class UbiquitousPresenceBeaconStore: PresenceBeaconStoring, @unchecked Sendable {
    public static let key = "com.plozz.syncSetup.presenceBeacon"
    private let store: NSUbiquitousKeyValueStore

    public init(store: NSUbiquitousKeyValueStore = .default) {
        self.store = store
        self.store.synchronize()
    }

    public func read() -> SyncPresenceBeacon? {
        guard let data = store.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(SyncPresenceBeacon.self, from: data)
    }

    public func write(_ beacon: SyncPresenceBeacon) {
        guard let data = try? JSONEncoder().encode(beacon) else { return }
        store.set(data, forKey: Self.key)
        store.synchronize()
    }

    public func clear() {
        store.removeObject(forKey: Self.key)
        store.synchronize()
    }
}

/// Decides whether a fresh device should offer "bring your setup here".
public enum PresenceBeaconEvaluator {
    /// Show the continue-setup prompt when a beacon says a setup exists elsewhere
    /// AND this device isn't configured yet (no local accounts / not set up).
    public static func shouldOfferContinue(
        beacon: SyncPresenceBeacon?,
        thisDeviceIsConfigured: Bool
    ) -> Bool {
        guard let beacon, beacon.setupExists, beacon.serverCount > 0 else { return false }
        return !thisDeviceIsConfigured
    }
}
