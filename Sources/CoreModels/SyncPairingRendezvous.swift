import Foundation

// MARK: - Same-Apple-ID pairing rendezvous (CloudKit-brokered key authentication)
//
// The zero-typing, tvOS-friendly path to credential sharing. It reuses the exact
// same HPKE-sealed, LAN Bonjour credential transfer the QR/SAS pairing already
// uses — the ONLY thing this adds is an out-of-band way to authenticate the
// host's ephemeral public key WITHOUT a camera or a typed code.
//
// How the trust works (why this is as strong as scanning a QR):
//   • A device that wants to be set up (e.g. a new Apple TV) mints an ephemeral
//     pairing identity and starts advertising a one-time Bonjour service, exactly
//     as in the QR flow. It ALSO publishes this NON-SECRET rendezvous — the
//     Bonjour service name + its ephemeral PUBLIC key — to the user's CloudKit
//     PRIVATE database.
//   • Only devices signed into the SAME Apple ID can read that private database.
//     So when an already-configured device (e.g. the user's phone) reads the
//     rendezvous, CloudKit has already authenticated that the public key was
//     published by one of the user's own devices. The phone then connects to the
//     Bonjour service and PINS that public key (`expectedPublicKey`) — a LAN
//     man-in-the-middle can't substitute its own key, identical to the QR path.
//   • Because the key is authenticated out-of-band (by iCloud account membership
//     instead of a camera), the numeric SAS comparison is skipped: no code to
//     read, no number to type. QED — QR-equivalent security, zero friction.
//
// A public key is safe to publish; NOTHING secret is ever placed in CloudKit. The
// credentials themselves still travel ONLY over the HPKE-sealed, device-targeted,
// LAN pairing channel (see SyncSecrets / SyncPairingCrypto).

/// A device's NON-SECRET offer to be set up from another same-Apple-ID device.
/// Published to the CloudKit private DB; read by the user's other devices.
public struct SyncPairingRendezvous: Codable, Hashable, Sendable, Identifiable {
    /// The one-time Bonjour service name to connect to (== the short pairing code).
    public var serviceName: String
    /// The host's ephemeral pairing PUBLIC key — safe to publish, pinned by the
    /// source so a LAN MITM can't impersonate the host.
    public var publicKeyData: Data
    /// Friendly device name for any "Signing in your Apple TV…" UI.
    public var deviceName: String
    /// The publishing device's stable install id, so a device never adopts itself
    /// and the source can pick a specific target.
    public var deviceID: String
    /// Absolute expiry (epoch seconds). A stale rendezvous is ignored and cleaned up.
    public var expiresAtEpoch: Int
    /// Schema guard for forward compatibility.
    public var protocolVersion: Int

    public static let currentProtocolVersion = 1

    public init(
        serviceName: String,
        publicKeyData: Data,
        deviceName: String,
        deviceID: String,
        expiresAtEpoch: Int,
        protocolVersion: Int = SyncPairingRendezvous.currentProtocolVersion
    ) {
        self.serviceName = serviceName
        self.publicKeyData = publicKeyData
        self.deviceName = deviceName
        self.deviceID = deviceID
        self.expiresAtEpoch = expiresAtEpoch
        self.protocolVersion = protocolVersion
    }

    /// Convenience initializer that derives the expiry from a TTL.
    public init(
        serviceName: String,
        publicKeyData: Data,
        deviceName: String,
        deviceID: String,
        ttlSeconds: Int,
        now: Date = Date()
    ) {
        self.init(
            serviceName: serviceName,
            publicKeyData: publicKeyData,
            deviceName: deviceName,
            deviceID: deviceID,
            expiresAtEpoch: Int(now.timeIntervalSince1970) + ttlSeconds
        )
    }

    /// Stable CloudKit record name: one active rendezvous per publishing device, so
    /// re-publishing overwrites the device's own prior offer instead of piling up.
    public var id: String { "rendezvous:\(deviceID)" }

    public func isExpired(now: Date = Date()) -> Bool {
        Int(now.timeIntervalSince1970) > expiresAtEpoch
    }

    /// A rendezvous is only usable if the schema matches, it hasn't expired, and it
    /// carries a plausible key + service name.
    public func isUsable(now: Date = Date()) -> Bool {
        protocolVersion == SyncPairingRendezvous.currentProtocolVersion
            && !isExpired(now: now)
            && !serviceName.isEmpty
            && !publicKeyData.isEmpty
    }
}

// MARK: - Matcher (pure target-selection logic)

/// Decides which published rendezvous, if any, this device should act on. Pure and
/// fully unit-testable: the app feeds in the records it fetched from CloudKit plus
/// this device's own id; the matcher filters out self, expired, and malformed
/// offers and picks the freshest remaining target.
public enum PairingRendezvousMatcher {

    /// Select the best rendezvous to adopt from another device, or nil if none.
    /// - Parameters:
    ///   - rendezvous: everything fetched from the private DB.
    ///   - thisDeviceID: this device's install id (never adopt our own offer).
    ///   - now: clock (injected for tests).
    public static func target(
        from rendezvous: [SyncPairingRendezvous],
        thisDeviceID: String,
        now: Date = Date()
    ) -> SyncPairingRendezvous? {
        rendezvous
            .filter { $0.deviceID != thisDeviceID && $0.isUsable(now: now) }
            // Freshest offer first; deviceID as a deterministic tie-break so two
            // devices never oscillate over which to service.
            .sorted { lhs, rhs in
                if lhs.expiresAtEpoch != rhs.expiresAtEpoch {
                    return lhs.expiresAtEpoch > rhs.expiresAtEpoch
                }
                return lhs.deviceID < rhs.deviceID
            }
            .first
    }

    /// All valid, adoptable targets (excluding self / expired), freshest first —
    /// for UI that lists every device currently asking to be set up.
    public static func targets(
        from rendezvous: [SyncPairingRendezvous],
        thisDeviceID: String,
        now: Date = Date()
    ) -> [SyncPairingRendezvous] {
        rendezvous
            .filter { $0.deviceID != thisDeviceID && $0.isUsable(now: now) }
            .sorted { lhs, rhs in
                if lhs.expiresAtEpoch != rhs.expiresAtEpoch {
                    return lhs.expiresAtEpoch > rhs.expiresAtEpoch
                }
                return lhs.deviceID < rhs.deviceID
            }
    }
}

// MARK: - Rendezvous store (iCloud KVS, per-device keys)

/// Reads/writes pairing rendezvous offers. Abstracted so the iCloud-backed store can
/// be swapped for an in-memory one in tests. Each device writes its OWN offer under a
/// per-device key, and any same-Apple-ID device can enumerate all current offers.
public protocol PairingRendezvousStoring: Sendable {
    /// Publish (or refresh) this device's offer to be set up.
    func publish(_ rendezvous: SyncPairingRendezvous)
    /// Remove this device's offer (pairing finished or the screen closed).
    func withdraw(deviceID: String)
    /// Every offer currently visible to this Apple ID (callers filter with the matcher).
    func all() -> [SyncPairingRendezvous]
}

/// In-memory rendezvous store for tests/previews.
public final class InMemoryPairingRendezvousStore: PairingRendezvousStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var byDevice: [String: SyncPairingRendezvous] = [:]
    public init(_ initial: [SyncPairingRendezvous] = []) {
        for r in initial { byDevice[r.deviceID] = r }
    }
    public func publish(_ rendezvous: SyncPairingRendezvous) {
        lock.lock(); byDevice[rendezvous.deviceID] = rendezvous; lock.unlock()
    }
    public func withdraw(deviceID: String) {
        lock.lock(); byDevice[deviceID] = nil; lock.unlock()
    }
    public func all() -> [SyncPairingRendezvous] {
        lock.lock(); defer { lock.unlock() }; return Array(byDevice.values)
    }
}

/// iCloud key-value-store–backed rendezvous store (iOS + tvOS). Same transport as the
/// presence beacon: no CloudKit schema, small non-secret blobs, auto-synced across one
/// Apple ID's devices. Each offer lives under a per-device key so multiple devices can
/// advertise at once; a reader enumerates every `keyPrefix`-prefixed key. NOTHING
/// secret is stored — only a Bonjour service name and an ephemeral PUBLIC key, which
/// is exactly what authenticates the subsequent LAN credential transfer.
public final class UbiquitousPairingRendezvousStore: PairingRendezvousStoring, @unchecked Sendable {
    public static let keyPrefix = "com.plozz.syncSetup.rendezvous."
    private let store: NSUbiquitousKeyValueStore

    public init(store: NSUbiquitousKeyValueStore = .default) {
        self.store = store
        self.store.synchronize()
    }

    private func key(for deviceID: String) -> String { Self.keyPrefix + deviceID }

    public func publish(_ rendezvous: SyncPairingRendezvous) {
        guard let data = try? JSONEncoder().encode(rendezvous) else { return }
        store.set(data, forKey: key(for: rendezvous.deviceID))
        store.synchronize()
    }

    public func withdraw(deviceID: String) {
        store.removeObject(forKey: key(for: deviceID))
        store.synchronize()
    }

    public func all() -> [SyncPairingRendezvous] {
        store.synchronize()
        var out: [SyncPairingRendezvous] = []
        for (k, v) in store.dictionaryRepresentation where k.hasPrefix(Self.keyPrefix) {
            if let data = v as? Data,
               let r = try? JSONDecoder().decode(SyncPairingRendezvous.self, from: data) {
                out.append(r)
            }
        }
        return out
    }
}
