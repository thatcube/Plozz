import Foundation

// MARK: - Sync record map (V3 wire schema)
//
// Translates the app's four synced entity types to/from the flat
// `[recordName: canonicalValueBytes]` map the `SyncLedger` moves. The critical
// contract is the round-trip invariant
//
//     canonicalCapture(exactApply(record)) == record.value
//
// Without it, a receiver re-derives different bytes than it received, the ledger
// thinks the user edited, and it clobbers the peer (the V2 bug). Every DTO here is
// therefore a SMALL, explicit, non-secret projection encoded with sorted keys, and
// applying one MERGES only its own fields — never touching device-local state — so
// a re-capture reproduces the exact same bytes.
//
// Record names: "descriptor:<accountID>", "profile:<profileID>",
// "membership:<profileID>", "setting:<profileID|__default__>:<baseKey>".
// The core is entity-agnostic; only this file knows the schema.

public enum SyncRecordKind: String, Sendable, CaseIterable {
    case descriptor, profile, membership, setting
}

/// A parsed record name: its kind and the id parts after the prefix.
public struct SyncRecordKey: Hashable, Sendable {
    public let kind: SyncRecordKind
    /// The primary entity id (account id / profile id).
    public let id: String
    /// For `.setting`, the settings base key; empty otherwise.
    public let subkey: String

    public init(kind: SyncRecordKind, id: String, subkey: String = "") {
        self.kind = kind; self.id = id; self.subkey = subkey
    }

    /// Sentinel used in a record name for the un-namespaced default profile, whose
    /// real id can contain characters (it doesn't) — kept explicit for clarity.
    public static let defaultProfileToken = "__default__"

    public var recordName: String {
        switch kind {
        case .setting: return "setting:\(id):\(subkey)"
        default:       return "\(kind.rawValue):\(id)"
        }
    }

    /// Parse a record name back into a key. Settings names carry a third segment;
    /// the id itself never contains a colon (account/profile ids are UUIDs or the
    /// fixed default token), so splitting on ":" is unambiguous.
    public static func parse(_ recordName: String) -> SyncRecordKey? {
        let parts = recordName.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, let kind = SyncRecordKind(rawValue: parts[0]) else { return nil }
        switch kind {
        case .setting:
            // setting:<id>:<baseKey> — baseKey may itself contain dots but not colons.
            guard parts.count >= 3 else { return nil }
            let id = parts[1]
            let subkey = parts[2...].joined(separator: ":")
            return SyncRecordKey(kind: .setting, id: id, subkey: subkey)
        default:
            guard parts.count == 2 else { return nil }
            return SyncRecordKey(kind: kind, id: parts[1])
        }
    }
}

// MARK: - Canonical JSON

/// Deterministic JSON so the SAME logical value always yields the SAME bytes
/// (sorted keys). This is the backbone of the round-trip invariant.
public enum CanonicalJSON {
    public static func encode<T: Encodable>(_ value: T) -> Data? {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        // Dates as a stable numeric interval (default) — deterministic across runs.
        return try? e.encode(value)
    }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }
}

// MARK: - Profile sync DTO (cosmetic identity only)

/// The ONLY profile fields that sync across devices: the shared household identity
/// (name + avatar + color + creation order). Every account-linked field
/// (Plex Home / Seerr / linked account / bindings) is DELIBERATELY excluded — those
/// depend on a local sign-in and are device-specific, and including them is exactly
/// what broke the round-trip invariant in V2.
public struct ProfileSyncDTO: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var avatarSymbol: String
    public var colorIndex: Int
    public var createdAt: Date
    public var avatarImageURL: String?
    public var avatarEmoji: String?
    public var avatarEmojiColorIndex: Int?

    public init(profile p: Profile) {
        self.id = p.id
        self.name = p.name
        self.avatarSymbol = p.avatarSymbol
        self.colorIndex = p.colorIndex
        self.createdAt = p.createdAt
        // SECURITY: an avatar image URL may embed a bearer token (e.g. Jellyfin
        // `?api_key=…`). Strip it before syncing; never publish a credential.
        self.avatarImageURL = SyncURLSanitizer.sanitize(string: p.avatarImageURL)
        self.avatarEmoji = p.avatarEmoji
        self.avatarEmojiColorIndex = p.avatarEmojiColorIndex
    }

    /// Merge this DTO's cosmetic fields into an existing profile, preserving ALL
    /// device-local fields (Plex Home / Seerr / bindings / linkedAccountID).
    public func merged(into existing: Profile) -> Profile {
        var p = existing
        p.name = name
        p.avatarSymbol = avatarSymbol
        p.colorIndex = colorIndex
        p.createdAt = createdAt
        // Preserve this device's LOCAL (tokenized) avatar URL when it refers to the
        // same resource as the synced (stripped) one — so the local image keeps
        // rendering without re-fetching a token, while a genuinely different remote
        // avatar still replaces it. Keeps capture==apply: capture re-strips the
        // local URL and gets exactly `avatarImageURL` back.
        if let local = existing.avatarImageURL,
           SyncURLSanitizer.sanitize(string: local) == avatarImageURL {
            p.avatarImageURL = local
        } else {
            p.avatarImageURL = avatarImageURL
        }
        p.avatarEmoji = avatarEmoji
        p.avatarEmojiColorIndex = avatarEmojiColorIndex
        return p
    }

    /// A fresh profile from this DTO (for a profile that doesn't exist locally yet).
    public func makeProfile() -> Profile {
        Profile(
            id: id, name: name, avatarSymbol: avatarSymbol, colorIndex: colorIndex,
            createdAt: createdAt, avatarImageURL: avatarImageURL,
            avatarEmoji: avatarEmoji, avatarEmojiColorIndex: avatarEmojiColorIndex)
    }
}
