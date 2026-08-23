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

/// Record key for durable Plozz-owned media state. It deliberately lives outside
/// ``SyncRecordKind`` so adding aliases does not alter the V3 config-sync schema.
public struct MediaStateRecordKey: Hashable, Sendable {
    public let profileID: String
    public let aliasID: MediaAliasID

    public init(profileID: String, aliasID: MediaAliasID) {
        self.profileID = profileID
        self.aliasID = aliasID
    }

    public var recordName: String {
        "alias:\(profileID):\(aliasID)"
    }

    public static func parse(_ recordName: String) -> Self? {
        let prefix = "alias:"
        guard recordName.hasPrefix(prefix) else { return nil }
        let remainder = recordName.dropFirst(prefix.count)
        guard let separator = remainder.lastIndex(of: ":") else { return nil }
        let profileID = String(remainder[..<separator])
        let rawAliasID = String(remainder[remainder.index(after: separator)...])
        guard !profileID.isEmpty,
              let aliasID = MediaAliasID(uuidString: rawAliasID) else {
            return nil
        }
        return Self(profileID: profileID, aliasID: aliasID)
    }
}

/// Disjoint media-state record key for the Plozz watchlist. Keeping this parser
/// separate from ``MediaStateRecordKey`` preserves alias and config-V3 semantics.
public struct WatchlistMediaStateRecordKey: Hashable, Sendable {
    public let profileID: String
    public let aliasID: MediaAliasID

    public init(profileID: String, aliasID: MediaAliasID) {
        self.profileID = profileID
        self.aliasID = aliasID
    }

    public var recordName: String {
        "watchlist:\(profileID):\(aliasID)"
    }

    public static func parse(_ recordName: String) -> Self? {
        let prefix = "watchlist:"
        guard recordName.hasPrefix(prefix) else { return nil }
        let remainder = recordName.dropFirst(prefix.count)
        guard let separator = remainder.lastIndex(of: ":") else { return nil }
        let profileID = String(remainder[..<separator])
        let rawAliasID = String(remainder[remainder.index(after: separator)...])
        guard !profileID.isEmpty,
              let aliasID = MediaAliasID(uuidString: rawAliasID) else {
            return nil
        }
        return Self(profileID: profileID, aliasID: aliasID)
    }
}

/// Non-secret, portable projection of a media alias. Receiver-local binding
/// validation is excluded; a peer's binding hint remains lookup-inert until this
/// device independently corroborates it.
public struct MediaAliasSyncDTO: Codable, Hashable, Sendable {
    public var id: MediaAliasID
    public var kind: MediaItemKind
    public var createdAt: Date
    public var updatedAt: Date
    public var strongEvidence: [MediaAliasStrongEvidence]
    public var weakEvidence: [MediaAliasWeakEvidence]
    public var presentation: MediaAliasPresentation?
    public var bindingHints: [MediaAliasProviderBindingHint]
    public var redirectTarget: MediaAliasID?
    public var conflicts: [MediaAliasConflict]

    public init(record: MediaAliasRecord) {
        let record = record.canonicalized()
        id = record.id
        kind = record.kind
        createdAt = record.createdAt
        updatedAt = record.updatedAt
        strongEvidence = record.strongEvidence
        weakEvidence = record.weakEvidence
        presentation = record.presentation.map {
            MediaAliasPresentation(title: $0.title, year: $0.year)
        }
        bindingHints = record.bindingHints.compactMap { $0.syncProjection() }
        redirectTarget = record.redirectTarget
        conflicts = record.conflicts
    }

    public func applying(to existing: MediaAliasRecord?) -> MediaAliasRecord? {
        guard existing == nil || existing?.kind == kind else { return nil }

        let combinedStrong = (existing?.strongEvidence ?? []) + strongEvidence
        let strongByNamespace = Dictionary(grouping: combinedStrong, by: \.namespace)
        var mergedStrong: [MediaAliasStrongEvidence] = []
        var mergedConflicts = Set(existing?.conflicts ?? [])
        mergedConflicts.formUnion(conflicts)
        let conflictDate = max(existing?.updatedAt ?? updatedAt, updatedAt)
        for namespace in strongByNamespace.keys.sorted(by: {
            $0.rawValue < $1.rawValue
        }) {
            let values = Array(Set(
                strongByNamespace[namespace, default: []].map(\.value)
            )).sorted()
            guard let accepted = values.first,
                  let evidence = MediaAliasStrongEvidence(
                    kind: kind,
                    namespace: namespace,
                    value: accepted
                  ) else {
                continue
            }
            mergedStrong.append(evidence)
            for rejected in values.dropFirst() {
                mergedConflicts.insert(MediaAliasConflict(
                    kind: .strongEvidence,
                    namespace: namespace,
                    existingValue: accepted,
                    rejectedValue: rejected,
                    recordedAt: conflictDate
                ))
            }
        }

        var hintsByBinding = Dictionary(
            uniqueKeysWithValues: (existing?.bindingHints ?? []).map {
                ($0.binding, $0)
            }
        )
        for hint in bindingHints {
            if let current = hintsByBinding[hint.binding] {
                hintsByBinding[hint.binding] = min(current, hint)
            } else {
                hintsByBinding[hint.binding] = hint
            }
        }
        let mergedHints = hintsByBinding.values.sorted()
        let mergedBindings = Set(mergedHints.map(\.binding))
        let localValidation = existing?.locallyValidatedBindings
            .intersection(mergedBindings) ?? []

        var appliedPresentation = presentation.map {
            MediaAliasPresentation(title: $0.title, year: $0.year)
        }
        if let local = existing?.presentation {
            let localUpdatedAt = existing?.updatedAt ?? .distantPast
            if appliedPresentation == nil
                || localUpdatedAt > updatedAt
                || (localUpdatedAt == updatedAt
                    && Self.presentationPrecedes(local, appliedPresentation!)) {
                appliedPresentation = local
            } else {
                appliedPresentation?.artworkURL = local.artworkURL
                appliedPresentation?.backdropURL = local.backdropURL
            }
        }
        return MediaAliasRecord(
            id: id,
            kind: kind,
            createdAt: min(existing?.createdAt ?? createdAt, createdAt),
            updatedAt: max(existing?.updatedAt ?? updatedAt, updatedAt),
            strongEvidence: mergedStrong,
            weakEvidence: Array(Set(
                (existing?.weakEvidence ?? []) + weakEvidence
            )).sorted(),
            presentation: appliedPresentation,
            bindingHints: mergedHints,
            locallyValidatedBindings: localValidation,
            // Device-local, and never carried over the wire: an account
            // descriptor plus a server-local item id means nothing on another
            // device. Preserved from the existing record so a cloud merge cannot
            // erase the only handle a title with no catalogue id is filed under.
            localSources: existing?.localSources ?? [],
            redirectTarget: redirectTarget,
            conflicts: Array(mergedConflicts).sorted()
        )
    }

    private static func presentationPrecedes(
        _ lhs: MediaAliasPresentation,
        _ rhs: MediaAliasPresentation
    ) -> Bool {
        if lhs.title != rhs.title {
            return lhs.title < rhs.title
        }
        return (lhs.year ?? Int.min) <= (rhs.year ?? Int.min)
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, createdAt, updatedAt, strongEvidence, weakEvidence
        case presentation, bindingHints, redirectTarget, conflicts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(MediaAliasID.self, forKey: .id)
        let kind = try container.decode(MediaItemKind.self, forKey: .kind)
        let createdAt = try container.decode(Date.self, forKey: .createdAt)
        let updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        let strong = try container.decodeIfPresent(
            [MediaAliasStrongEvidence].self,
            forKey: .strongEvidence
        ) ?? []
        let weak = try container.decodeIfPresent(
            [MediaAliasWeakEvidence].self,
            forKey: .weakEvidence
        ) ?? []
        let presentation = try container.decodeIfPresent(
            MediaAliasPresentation.self,
            forKey: .presentation
        )
        let hints = try container.decodeIfPresent(
            [MediaAliasProviderBindingHint].self,
            forKey: .bindingHints
        ) ?? []
        let redirect = try container.decodeIfPresent(
            MediaAliasID.self,
            forKey: .redirectTarget
        )
        let conflicts = try container.decodeIfPresent(
            [MediaAliasConflict].self,
            forKey: .conflicts
        ) ?? []
        guard let record = MediaAliasRecord(
            id: id,
            kind: kind,
            createdAt: createdAt,
            updatedAt: updatedAt,
            strongEvidence: strong,
            weakEvidence: weak,
            presentation: presentation,
            bindingHints: hints,
            redirectTarget: redirect,
            conflicts: conflicts
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Invalid media alias sync record."
            )
        }
        self.init(record: record)
    }

    public func encode(to encoder: Encoder) throws {
        guard let record = applying(to: nil) else {
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "Invalid media alias sync record."
                )
            )
        }
        let value = MediaAliasSyncDTO(record: record)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value.id, forKey: .id)
        try container.encode(value.kind, forKey: .kind)
        try container.encode(value.createdAt, forKey: .createdAt)
        try container.encode(value.updatedAt, forKey: .updatedAt)
        try container.encode(value.strongEvidence, forKey: .strongEvidence)
        try container.encode(value.weakEvidence, forKey: .weakEvidence)
        try container.encodeIfPresent(value.presentation, forKey: .presentation)
        try container.encode(value.bindingHints, forKey: .bindingHints)
        try container.encodeIfPresent(value.redirectTarget, forKey: .redirectTarget)
        try container.encode(value.conflicts, forKey: .conflicts)
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
    /// The profile's PIN gate, if any. Synced on purpose: a lock that only
    /// exists on one device isn't a lock, since the same profile is one tap away
    /// on every other device in the household. Carries a salted verifier only —
    /// never the PIN itself (see `ProfileLock`).
    public var lock: ProfileLock?
    /// Field-level revision: prevents a stale whole-profile record from erasing
    /// a newer lock during an unrelated name/avatar sync.
    public var lockRevision: ProfileLockRevision?
    /// Whether this is a restricted Kids Profile. Synced for the same reason the
    /// lock is: a restriction that only applied on one device wouldn't restrict
    /// anything.
    /// The household's Parental PIN, carried on the first profile's record.
    /// Synced for the same reason the lock is: a parental control that applied on
    /// one device only wouldn't control anything. Salted verifier, never the PIN.
    public var parentalPIN: ParentalPIN?
    /// Field-level revision, so an unrelated edit from a stale device can't erase
    /// a newly-set Parental PIN.
    public var parentalPINRevision: ProfileLockRevision?
    public var isKidsProfile: Bool?
    /// Field-level revision for the Kids flag — see ``Profile/kidsProfileRevision``.
    public var kidsProfileRevision: ProfileLockRevision?
    /// Whether the profile still owes its setup pass. Synced so a half-created
    /// profile doesn't start importing on a second device either.
    public var isAwaitingSetup: Bool?

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
        self.lock = p.lock
        self.lockRevision = p.effectiveLockRevision
        self.parentalPIN = p.parentalPIN
        self.parentalPINRevision = p.effectiveParentalPINRevision
        self.isKidsProfile = p.isKidsProfile
        self.kidsProfileRevision = p.effectiveKidsProfileRevision
        self.isAwaitingSetup = p.isAwaitingSetup
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
        let localRevision = existing.effectiveLockRevision
        if let incomingRevision = lockRevision {
            if localRevision == nil || incomingRevision > localRevision! {
                p.lock = lock
                p.lockRevision = incomingRevision
            }
        } else if localRevision == nil {
            // Legacy peer: honour it only when this device has no revisioned (or
            // legacy-baselined) lock state to protect.
            p.lock = lock
        }
        // Same revision rule as the lock, for the same reason.
        let localPINRevision = existing.effectiveParentalPINRevision
        if let incomingPINRevision = parentalPINRevision {
            if localPINRevision == nil || incomingPINRevision > localPINRevision! {
                p.parentalPIN = parentalPIN
                p.parentalPINRevision = incomingPINRevision
            }
        } else if localPINRevision == nil {
            p.parentalPIN = parentalPIN
        }
        // Same revision rule as the lock and the Parental PIN. Without it a
        // stale peer's unrelated edit could clear the Kids flag and silently
        // un-restrict the profile.
        let localKidsRevision = existing.effectiveKidsProfileRevision
        if let incomingKidsRevision = kidsProfileRevision {
            if localKidsRevision == nil || incomingKidsRevision > localKidsRevision! {
                p.isKidsProfile = isKidsProfile
                p.kidsProfileRevision = incomingKidsRevision
            }
        } else if localKidsRevision == nil {
            p.isKidsProfile = isKidsProfile
        }
        p.isAwaitingSetup = isAwaitingSetup
        return p
    }

    /// A fresh profile from this DTO (for a profile that doesn't exist locally yet).
    public func makeProfile() -> Profile {
        Profile(
            id: id, name: name, avatarSymbol: avatarSymbol, colorIndex: colorIndex,
            createdAt: createdAt,
            avatarImageURL: SyncURLSanitizer.sanitize(string: avatarImageURL),
            avatarEmoji: avatarEmoji, avatarEmojiColorIndex: avatarEmojiColorIndex,
            lock: lock, lockRevision: lockRevision,
            parentalPIN: parentalPIN, parentalPINRevision: parentalPINRevision,
            kidsProfileRevision: kidsProfileRevision,
            isKidsProfile: isKidsProfile, isAwaitingSetup: isAwaitingSetup)
    }
}
