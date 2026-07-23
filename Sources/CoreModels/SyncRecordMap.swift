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
    /// A household-wide "this server was removed" tombstone (accountID → removal
    /// marker). Propagates a "Remove Everywhere" so every device signs the account
    /// out and stops re-publishing its descriptor. Absence = the removal was undone
    /// (the server was re-added somewhere).
    case removal
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

    /// Parse a record name back into a key. Settings names carry a third segment.
    ///
    /// The id CAN contain colons: media-share account ids are structured strings like
    /// `share:nfs://host:2049/export#guest` (see MediaShareAccountConfigurationService),
    /// so a descriptor record name is `descriptor:share:nfs://host:2049/export#guest`.
    /// We therefore split only the LEADING `kind:` prefix off and treat the entire
    /// remainder as the id. This preserves the round-trip `recordName -> parse -> id`
    /// exactly (the id is re-joined verbatim). Profile ids are UUIDs / the default
    /// token (never contain a colon), so `.setting`'s `setting:<id>:<baseKey>` split is
    /// still unambiguous — the FIRST post-kind segment is the profile id, the rest is
    /// the base key.
    public static func parse(_ recordName: String) -> SyncRecordKey? {
        guard let firstColon = recordName.firstIndex(of: ":") else { return nil }
        let kindRaw = String(recordName[..<firstColon])
        guard let kind = SyncRecordKind(rawValue: kindRaw) else { return nil }
        let remainder = String(recordName[recordName.index(after: firstColon)...])
        guard !remainder.isEmpty else { return nil }
        switch kind {
        case .setting:
            // setting:<profileID>:<baseKey> — profileID has no colon; baseKey may.
            guard let sep = remainder.firstIndex(of: ":") else { return nil }
            let id = String(remainder[..<sep])
            let subkey = String(remainder[remainder.index(after: sep)...])
            guard !id.isEmpty else { return nil }
            return SyncRecordKey(kind: .setting, id: id, subkey: subkey)
        default:
            // descriptor / profile / membership / removal — the id is the whole
            // remainder (may legitimately contain colons for media shares).
            return SyncRecordKey(kind: kind, id: remainder)
        }
    }
}

// MARK: - Capture fallback (out-of-order / deletion disambiguation)

/// Shared, pure helper for the app-layer `captureSyncRecords`. After the app builds
/// the live record map from its stores, it back-fills setting/membership records for
/// profiles it can't currently express — but ONLY when the profile is genuinely
/// not-yet-hydrated (also absent from the last-synced `fallback`), never when the
/// profile is being deleted (still present in `fallback`, so its children must delete
/// too). Extracted here so both app models share ONE implementation and it's unit
/// tested directly.
public enum SyncCaptureFallback {
    public static func merge(
        live: [SyncRecordID: Data],
        fallback: [SyncRecordID: Data],
        localProfileIDs: Set<String>
    ) -> [SyncRecordID: Data] {
        var out = live
        for (name, data) in fallback where out[name] == nil {
            guard let key = SyncRecordKey.parse(name) else { continue }
            switch key.kind {
            case .setting, .membership:
                let parent = SyncRecordKey(kind: .profile, id: key.id).recordName
                if !localProfileIDs.contains(key.id) && fallback[parent] == nil {
                    out[name] = data
                }
            case .profile, .descriptor, .removal:
                break   // authoritative on this device: absence is a genuine deletion
            }
        }
        return out
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
        // Defense in depth: a peer (or an older app version) could send a tokenized
        // avatar URL — sanitize the incoming value before it is stored/rendered.
        let cleanIncoming = SyncURLSanitizer.sanitize(string: avatarImageURL)
        // Preserve this device's LOCAL (tokenized) avatar URL when it refers to the
        // same resource — so the local image keeps rendering without re-fetching a
        // token, while a genuinely different remote avatar still replaces it. Keeps
        // capture==apply: capture re-strips the local URL back to `cleanIncoming`.
        if let local = existing.avatarImageURL,
           SyncURLSanitizer.sanitize(string: local) == cleanIncoming {
            p.avatarImageURL = local
        } else {
            p.avatarImageURL = cleanIncoming
        }
        p.avatarEmoji = avatarEmoji
        p.avatarEmojiColorIndex = avatarEmojiColorIndex
        return p
    }

    /// A fresh profile from this DTO (for a profile that doesn't exist locally yet).
    public func makeProfile() -> Profile {
        Profile(
            id: id, name: name, avatarSymbol: avatarSymbol, colorIndex: colorIndex,
            createdAt: createdAt,
            avatarImageURL: SyncURLSanitizer.sanitize(string: avatarImageURL),
            avatarEmoji: avatarEmoji, avatarEmojiColorIndex: avatarEmojiColorIndex)
    }
}
