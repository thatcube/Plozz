import Foundation
import CoreModels

/// Persists the last successfully-used server so relaunch can offer one-tap
/// reconnect. This is **non-secret** metadata only — never tokens.
public protocol LastServerStoring: Sendable {
    var lastServer: MediaServer? { get set }
}

/// `UserDefaults`-backed implementation. Stores a JSON blob of `MediaServer`.
public final class UserDefaultsLastServerStore: LastServerStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "com.plizz.lastServer"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var lastServer: MediaServer? {
        get {
            guard let data = defaults.data(forKey: key) else { return nil }
            return try? JSONDecoder().decode(MediaServer.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }
}
