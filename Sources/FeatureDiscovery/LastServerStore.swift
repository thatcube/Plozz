import Foundation
import CoreModels

/// Persists recently-used servers (most recent first) so relaunch and the
/// add-account flow can offer one-tap reconnect — including servers that were
/// entered manually or reached over Tailscale, which LAN discovery can never
/// re-find on its own. This is **non-secret** metadata only — never tokens.
public protocol LastServerStoring: Sendable {
    /// Recently-used servers, ordered most-recent-first.
    var recentServers: [MediaServer] { get set }
}

public extension LastServerStoring {
    /// The single most-recently-used server, if any.
    var lastServer: MediaServer? { recentServers.first }

    /// Records `server` as the most-recently-used one: moves it to the front,
    /// de-duplicates by server identity, and caps the list so it stays a short
    /// "recents" menu rather than an ever-growing history.
    mutating func remember(_ server: MediaServer, limit: Int = 8) {
        var list = recentServers.filter { !ServerIdentity.isSame($0, server) }
        list.insert(server, at: 0)
        if list.count > limit { list = Array(list.prefix(limit)) }
        recentServers = list
    }
}

/// Server-identity matching shared by the store and the picker view model:
/// prefer the backend server id when both sides have one, else fall back to
/// host + port so the same box entered two ways still de-duplicates.
enum ServerIdentity {
    static func isSame(_ a: MediaServer, _ b: MediaServer) -> Bool {
        if !a.id.isEmpty, !b.id.isEmpty, a.id == b.id { return true }
        return a.baseURL.host == b.baseURL.host && a.baseURL.port == b.baseURL.port
    }

    /// A stable dictionary key for a server (id when present, else host:port).
    static func key(for server: MediaServer) -> String {
        if !server.id.isEmpty { return "id:\(server.id)" }
        let host = server.baseURL.host ?? server.baseURL.absoluteString
        let port = server.baseURL.port.map { ":\($0)" } ?? ""
        return "url:\(host)\(port)"
    }
}

/// `UserDefaults`-backed implementation. Stores a JSON array of `MediaServer`,
/// migrating transparently from the older single-server blob.
public final class UserDefaultsLastServerStore: LastServerStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let recentsKey = "com.plozz.recentServers"
    private let legacyKey = "com.plozz.lastServer"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var recentServers: [MediaServer] {
        get {
            if let data = defaults.data(forKey: recentsKey),
               let list = try? JSONDecoder().decode([MediaServer].self, from: data) {
                return list
            }
            // One-time migration: seed the recents list from the old single
            // "last server" blob so an upgrading user keeps their reconnect entry.
            if let data = defaults.data(forKey: legacyKey),
               let one = try? JSONDecoder().decode(MediaServer.self, from: data) {
                return [one]
            }
            return []
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: recentsKey)
            } else {
                defaults.removeObject(forKey: recentsKey)
            }
            // The legacy single-server key is fully superseded once we've
            // written the array form.
            defaults.removeObject(forKey: legacyKey)
        }
    }
}
