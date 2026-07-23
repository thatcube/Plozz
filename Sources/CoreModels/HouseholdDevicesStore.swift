import Foundation

// MARK: - Household device presence registry
//
// A small, NON-SECRET per-device heartbeat so a device can tell whether the user
// has OTHER devices on the same iCloud account. Unlike `SyncPresenceBeacon` (a
// single shared last-writer-wins key), this is keyed per device id, so every
// sync-enabled device contributes one entry and any device can count the others.
//
// Used to decide whether the "Remove Everywhere" vs "Remove from This <device>"
// choice is even meaningful: with a single device there are no "other devices," so
// the UI shows a plain "Remove" instead. Carries only a device id + friendly name +
// last-seen time — no token, server, or account identity.

public struct HouseholdDeviceEntry: Codable, Hashable, Sendable {
    public var deviceID: String
    public var deviceName: String
    public var lastSeenEpoch: Int

    public init(deviceID: String, deviceName: String, lastSeenEpoch: Int) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.lastSeenEpoch = lastSeenEpoch
    }
}

/// iCloud-KVS registry of the household's devices (one entry per device id).
public final class HouseholdDevicesStore: @unchecked Sendable {
    public static let keyPrefix = "com.plozz.syncSetup.device."
    /// A device not seen within this window is treated as gone (won't count as an
    /// "other device"). Generous so an occasionally-used Apple TV still counts.
    public static let freshnessSeconds = 45 * 24 * 60 * 60

    private let store: NSUbiquitousKeyValueStore
    public init(store: NSUbiquitousKeyValueStore = .default) {
        self.store = store
        self.store.synchronize()
    }

    private func key(for deviceID: String) -> String { Self.keyPrefix + deviceID }

    /// Record that this device is present now.
    public func heartbeat(deviceID: String, deviceName: String, now: Date = Date()) {
        let entry = HouseholdDeviceEntry(
            deviceID: deviceID, deviceName: deviceName,
            lastSeenEpoch: Int(now.timeIntervalSince1970))
        guard let data = try? JSONEncoder().encode(entry) else { return }
        store.set(data, forKey: key(for: deviceID))
        store.synchronize()
    }

    /// All recorded device entries (including this device and any stale ones).
    public func all() -> [HouseholdDeviceEntry] {
        store.synchronize()
        var out: [HouseholdDeviceEntry] = []
        for (k, v) in store.dictionaryRepresentation where k.hasPrefix(Self.keyPrefix) {
            if let data = v as? Data,
               let entry = try? JSONDecoder().decode(HouseholdDeviceEntry.self, from: data) {
                out.append(entry)
            }
        }
        return out
    }

    /// Other (non-self), recently-seen devices on this account.
    public func otherDevices(excluding selfID: String, now: Date = Date()) -> [HouseholdDeviceEntry] {
        let cutoff = Int(now.timeIntervalSince1970) - Self.freshnessSeconds
        return all().filter { $0.deviceID != selfID && $0.lastSeenEpoch >= cutoff }
    }

    /// Remove this device's entry (sync turned off on it).
    public func remove(deviceID: String) {
        store.removeObject(forKey: key(for: deviceID))
        store.synchronize()
    }

    /// Wipe every device entry (debug reset).
    public func removeAll() {
        for k in store.dictionaryRepresentation.keys where k.hasPrefix(Self.keyPrefix) {
            store.removeObject(forKey: k)
        }
        store.synchronize()
    }
}
