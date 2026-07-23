import Foundation

// MARK: - Sync & Setup feature flag
//
// v1 cross-device Sync & Setup is ON by default: a fresh install participates in the
// household so the "open a new device and your stuff is already there" experience
// works without the user first hunting for a toggle. Turning it OFF is respected and
// sticky (an explicit `false` is never overridden). The flag is a plain,
// household/device-wide `UserDefaults` bool (NOT per-profile): syncing is a device
// capability, not a per-profile preference.

public struct SyncSetupFeatureFlag: Sendable {
    public static let storageKey = "com.plozz.syncSetup.enabled"

    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var isEnabled: Bool {
        // Default ON: an unset flag (fresh install, or an existing user who never
        // touched the toggle) reads as enabled. An explicit `false` the user chose
        // is preserved — we only default when no value has been written.
        get {
            guard defaults.object(forKey: Self.storageKey) != nil else { return true }
            return defaults.bool(forKey: Self.storageKey)
        }
        nonmutating set { defaults.set(newValue, forKey: Self.storageKey) }
    }
}

// MARK: - Descriptor / authorization split
//
// The core safety rule for cross-device sync (see the Sync & Setup research):
// *synced* data must be NON-SECRET and must NEVER be able to retarget the endpoint
// of a credential this device already holds. We therefore split an account into:
//
//   • `SyncedAccountDescriptor` — token-free, safe to replicate. Says *which*
//     account/server exists and how to reach it (advisory candidate URLs).
//   • `LocalAuthorization` — device-local only, never synced. Records that THIS
//     device actually minted a token, the origin it trusts, and its auth state.
//
// A descriptor can arrive before this device has any credential ("pending"); the
// device then signs in natively (Quick Connect / Plex link) to mint its OWN token.

/// A token-free, sync-safe description of an account the household uses.
///
/// Contains no token, password, or `deviceID`. `candidateBaseURLs` are *advisory*
/// — a new device may use them to reach the server for a fresh sign-in, but they
/// may never silently retarget an already-authorized credential (see
/// `LocalAuthorization.reconcile`).
public struct SyncedAccountDescriptor: Codable, Hashable, Identifiable, Sendable {
    /// Stable, app-minted logical account id (matches `Account.id`). Used as the
    /// join key to a device's `LocalAuthorization`.
    public var id: String
    public var provider: ProviderKind
    /// Backend-assigned server id (stable across reachable URLs).
    public var serverID: String
    public var serverName: String
    public var userID: String
    public var userName: String
    public var avatarURL: URL?
    /// Advisory reachable URLs, most-preferred first. Advisory only — see the doc
    /// note above. `nil`/empty is allowed (new device can rediscover).
    public var candidateBaseURLs: [URL]
    /// Monotonic per-record version for last-writer-wins reconciliation.
    public var recordVersion: Int
    /// Schema version so older clients can skip records they don't understand.
    public var schemaVersion: Int
    /// Friendly name of the device that first published this server ("Brando's TV"),
    /// for a "Set up with <device>" prompt. Non-secret; optional (older records + the
    /// publisher-unknown case decode nil). Preserved across re-publish (not overwritten
    /// per device), so it names the ORIGIN device.
    public var originDeviceName: String?
    /// Kind of the origin device ("tv" / "phone" / "pad" / "mac"), to pick an icon.
    public var originDeviceKind: String?

    public static let currentSchemaVersion = 1

    public init(
        id: String,
        provider: ProviderKind,
        serverID: String,
        serverName: String,
        userID: String,
        userName: String,
        avatarURL: URL? = nil,
        candidateBaseURLs: [URL] = [],
        recordVersion: Int = 1,
        schemaVersion: Int = SyncedAccountDescriptor.currentSchemaVersion,
        originDeviceName: String? = nil,
        originDeviceKind: String? = nil
    ) {
        self.id = id
        self.provider = provider
        self.serverID = serverID
        self.serverName = serverName
        self.userID = userID
        self.userName = userName
        self.avatarURL = avatarURL
        self.candidateBaseURLs = candidateBaseURLs
        self.recordVersion = recordVersion
        self.schemaVersion = schemaVersion
        self.originDeviceName = originDeviceName
        self.originDeviceKind = originDeviceKind
    }

    /// A copy stamped with this device as the origin — used only when FIRST publishing a
    /// locally-signed-in server (a fresh descriptor with no prior synced bytes to
    /// preserve). Excluded from `semanticallyEqualForSync`, so a re-publish reuses the
    /// original bytes and never overwrites the first publisher's name.
    public func stampingOrigin(name: String, kind: String) -> SyncedAccountDescriptor {
        var copy = self
        copy.originDeviceName = name
        copy.originDeviceKind = kind
        return copy
    }
}

public extension SyncedAccountDescriptor {
    /// Builds a token-free descriptor from a local `Account` (never copies a token
    /// — `Account` has none). Safe to hand to the sync layer.
    init(account: Account, recordVersion: Int = 1) {
        self.init(
            id: account.id,
            provider: account.server.provider,
            serverID: account.server.id,
            serverName: account.server.name,
            userID: account.userID,
            userName: account.userName,
            // SECURITY: strip any embedded credential (e.g. Jellyfin `?api_key=…`)
            // BEFORE the descriptor can be synced to CloudKit. The receiving device
            // re-signs image URLs with its own token at render time.
            avatarURL: SyncURLSanitizer.sanitize(account.avatarURL),
            candidateBaseURLs: (account.server.connectionURLs ?? [account.server.baseURL])
                .map(SyncURLSanitizer.sanitize),
            recordVersion: recordVersion
        )
    }

    /// A copy with every URL field stripped of credentials — applied to records
    /// RECEIVED from a peer too (defense in depth: never persist/display a token a
    /// misbehaving or older peer may have left in a URL).
    public func sanitizingURLs() -> SyncedAccountDescriptor {
        var copy = self
        copy.avatarURL = SyncURLSanitizer.sanitize(avatarURL)
        copy.candidateBaseURLs = candidateBaseURLs.map(SyncURLSanitizer.sanitize)
        return copy
    }

    /// Equality of the fields that MATTER for sync, EXCLUDING device-specific advisory
    /// hints (`candidateBaseURLs`, which legitimately differ per device/network) and
    /// per-record bookkeeping (`recordVersion`). A signed-in device uses this so it
    /// doesn't churn/clobber the shared record just because its reachable URL differs
    /// from a peer's — the record is only re-published when a meaningful field changes.
    public func semanticallyEqualForSync(to other: SyncedAccountDescriptor) -> Bool {
        provider == other.provider
            && serverID == other.serverID
            && serverName == other.serverName
            && userID == other.userID
            && userName == other.userName
            && avatarURL == other.avatarURL
    }

    /// A stable identity for the (server + user) this descriptor represents —
    /// provider + backend server id + user id — INDEPENDENT of the app-minted `id`.
    ///
    /// Plex/Jellyfin/Emby accounts get a fresh random `id` (UUID) on every sign-in, so
    /// the SAME server+user signed in on two devices has two different `id`s. Keying
    /// dedup on this semantic identity instead lets a device recognize "I'm already
    /// signed into this exact server as this user" and avoid prompting to "add" it
    /// again / surfacing a duplicate. (Media shares already dedup via a deterministic
    /// `id`; this covers the token-provider case.)
    var semanticServerKey: String { "\(provider.rawValue)|\(serverID)|\(userID)" }
}

public extension Array where Element == SyncedAccountDescriptor {
    /// Drop descriptors whose (server + user) identity matches one already present in
    /// `localSemanticKeys` — i.e. a server this device is already signed into, even if
    /// under a different app-minted `id`. Prevents duplicate prompts/pending entries
    /// for the same Plex/Jellyfin server+user across devices.
    func excludingSemanticMatches(of localSemanticKeys: Set<String>) -> [SyncedAccountDescriptor] {
        filter { !localSemanticKeys.contains($0.semanticServerKey) }
    }

    /// Collapse descriptors that share a (server + user) identity down to ONE, keeping
    /// the lowest `id` for a deterministic, cross-device-stable choice. Handles LEGACY
    /// duplicates already in iCloud from before token-provider dedup existed (the same
    /// Plex server+user published under two random ids), so the pending list / detected
    /// page shows a server once instead of twice.
    func dedupedBySemanticIdentity() -> [SyncedAccountDescriptor] {
        var byKey: [String: SyncedAccountDescriptor] = [:]
        for d in self {
            if let existing = byKey[d.semanticServerKey], existing.id <= d.id { continue }
            byKey[d.semanticServerKey] = d
        }
        // Preserve the original ordering by first-seen id.
        var seen = Set<String>()
        return filter { d in
            guard byKey[d.semanticServerKey]?.id == d.id, !seen.contains(d.semanticServerKey) else { return false }
            seen.insert(d.semanticServerKey)
            return true
        }
    }
}

/// Whether THIS device has usable credentials for a synced account.
public enum AuthorizationState: String, Codable, Hashable, Sendable {
    /// A descriptor exists but this device has no token yet — must sign in.
    case pending
    /// This device minted its own token and can use the account.
    case authorized
    /// Known-unusable here (e.g. revoked, or server permanently gone).
    case unavailable
}

/// Device-local authorization for one account. **Never synced.** Holds no token —
/// only a Keychain reference and the origin the token was actually minted against.
public struct LocalAuthorization: Codable, Hashable, Identifiable, Sendable {
    /// Matches `SyncedAccountDescriptor.id` / `Account.id`.
    public var id: String
    public var state: AuthorizationState
    /// Per-install device id this device presents to the provider (device-local).
    public var deviceID: String
    /// Random identity of the active Keychain credential; no secret material.
    public var credentialRevision: CredentialRevision?
    /// The exact origin(s) this device's token is trusted against. A synced
    /// descriptor may NOT move the account onto a new origin not listed here
    /// without explicit local re-verification.
    public var trustedOrigins: Set<String>

    public init(
        id: String,
        state: AuthorizationState = .pending,
        deviceID: String,
        credentialRevision: CredentialRevision? = nil,
        trustedOrigins: Set<String> = []
    ) {
        self.id = id
        self.state = state
        self.deviceID = deviceID
        self.credentialRevision = credentialRevision
        self.trustedOrigins = trustedOrigins
    }

    /// Canonical origin string for an URL: `scheme://host[:port]` (no path).
    public static func origin(of url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? "https"
        let host = url.host?.lowercased() ?? url.absoluteString
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }
}

public extension LocalAuthorization {
    /// Reconciles an incoming synced descriptor against this device's local
    /// authorization WITHOUT ever silently retargeting an authorized credential.
    ///
    /// Returns the URLs from the descriptor this device is allowed to use right
    /// now. When `authorized`, only origins already in `trustedOrigins` are
    /// returned — a new/unknown origin is withheld and requires explicit
    /// re-verification (the caller should prompt / re-authenticate). When
    /// `pending`, all candidates are usable for a fresh sign-in.
    func allowedURLs(from descriptor: SyncedAccountDescriptor) -> [URL] {
        switch state {
        case .authorized:
            return descriptor.candidateBaseURLs.filter {
                trustedOrigins.contains(LocalAuthorization.origin(of: $0))
            }
        case .pending:
            return descriptor.candidateBaseURLs
        case .unavailable:
            return []
        }
    }

    /// True if the descriptor introduces an origin this authorized device does not
    /// yet trust — i.e. applying it would be an endpoint retarget and must be
    /// gated behind local re-verification rather than applied automatically.
    func requiresReverification(for descriptor: SyncedAccountDescriptor) -> Bool {
        guard state == .authorized else { return false }
        let incoming = Set(descriptor.candidateBaseURLs.map { LocalAuthorization.origin(of: $0) })
        return !incoming.isSubset(of: trustedOrigins)
    }
}
