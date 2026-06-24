import Foundation

/// A household **profile** (e.g. "Mom", "Dad", "Sister").
///
/// Profiles layer *on top of* the multi-account core: one iCloud/device
/// household can hold several profiles, each scoping the per-user state —
/// which accounts/libraries it uses, its theme, spoiler/caption/diagnostics
/// settings, and Home customization.
///
/// A `Profile` is **non-secret** metadata persisted to `UserDefaults` (see
/// `ProfileStore`). It never holds tokens: the shared account pool and its
/// Keychain tokens stay household-global in `AccountStore`; a profile merely
/// *selects a subset* of those accounts as its active set (stored alongside the
/// profile, see `ProfilePersisting.activeAccountIDs(forProfile:)`).
///
/// `id` doubles as the per-profile `UserDefaults` key namespace used to scope
/// the settings stores. The first/default profile intentionally uses a `nil`
/// namespace so an upgrading install keeps its existing settings seamlessly
/// (see `ProfileStore.migrateLegacyIfNeeded()`); additional profiles use their
/// `id`.
public struct Profile: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// SF Symbol name shown on the picker tile (no photo upload needed on tvOS).
    public var avatarSymbol: String
    /// Index into `Profile.tileColors` for the tile's accent color.
    public var colorIndex: Int
    /// When the profile was created — used for stable ordering.
    public var createdAt: Date
    /// Optional `Account.id` this profile is *backed by* (e.g. a signed-in Plex
    /// or Jellyfin account). Seeds the name/avatar and narrows the active set;
    /// `nil` for a plain app-owned profile.
    public var linkedAccountID: String?
    /// When this profile maps to a **Plex Home** user ("Who's watching?"), the
    /// Home user's `uuid`. Activating the profile switches the Plex identity for
    /// `plexHomeUserAccountID` to this user. `nil` = not mapped to a Plex user.
    public var plexHomeUserID: String?
    /// Display name of the linked Plex Home user (cached so the picker/editor can
    /// label it without a network fetch).
    public var plexHomeUserName: String?
    /// The `Account.id` of the Plex account whose Home this user belongs to. The
    /// account's stored (admin) token authorizes the switch.
    public var plexHomeUserAccountID: String?
    /// Whether switching to the linked Plex Home user needs a PIN. Cached from
    /// the Home-users list so Plozz knows to prompt without refetching. The PIN
    /// itself is never stored.
    public var plexHomeUserRequiresPIN: Bool?
    /// Cached Plex `thumb` URL for the linked Home user, so Settings can show
    /// the Plex avatar inline without re-hitting the network on every render.
    public var plexHomeUserAvatarURL: String?

    /// Per–Plex-account Home-user mappings. Keyed by the Plex `Account.id`,
    /// so a profile with TWO distinct Plex sign-ins can have a different
    /// Home user on each.
    ///
    /// Optional + lazily migrated: pre-existing profiles encoded before this
    /// field existed will decode with `nil` here, and the
    /// `homeUserBinding(forPlexAccount:)` helper falls back to the legacy
    /// single-mapping fields above. When a new selection is written we update
    /// this dict (authoritative) AND mirror the just-written entry to the
    /// legacy fields so older readers stay coherent.
    public var plexHomeUserBindings: [String: PlexHomeUserBinding]?

    /// Optional real photo for the profile (opt-in). When non-nil the picker
    /// tile and Settings hero render this image (a Plex Home-user avatar or
    /// a Jellyfin user avatar that the household has "borrowed"); when nil
    /// the profile falls back to `avatarSymbol` + `colorIndex` as before.
    ///
    /// Purely cosmetic identity — has no effect on which Plex Home user is
    /// played as (see `plexHomeUserBindings`). Decoded with `decodeIfPresent`
    /// so older profile JSON without this field migrates to `nil` cleanly.
    public var avatarImageURL: String?

    public init(
        id: String = UUID().uuidString,
        name: String,
        avatarSymbol: String = Profile.defaultAvatarSymbols[0],
        colorIndex: Int = 0,
        createdAt: Date = Date(),
        linkedAccountID: String? = nil,
        plexHomeUserID: String? = nil,
        plexHomeUserName: String? = nil,
        plexHomeUserAccountID: String? = nil,
        plexHomeUserRequiresPIN: Bool? = nil,
        plexHomeUserAvatarURL: String? = nil,
        plexHomeUserBindings: [String: PlexHomeUserBinding]? = nil,
        avatarImageURL: String? = nil
    ) {
        self.id = id
        self.name = name
        self.avatarSymbol = avatarSymbol
        self.colorIndex = colorIndex
        self.createdAt = createdAt
        self.linkedAccountID = linkedAccountID
        self.plexHomeUserID = plexHomeUserID
        self.plexHomeUserName = plexHomeUserName
        self.plexHomeUserAccountID = plexHomeUserAccountID
        self.plexHomeUserRequiresPIN = plexHomeUserRequiresPIN
        self.plexHomeUserAvatarURL = plexHomeUserAvatarURL
        self.plexHomeUserBindings = plexHomeUserBindings
        self.avatarImageURL = avatarImageURL
    }

    /// Stable namespace used to scope this profile's settings stores. The
    /// default/primary profile (`isDefault`) returns `nil` so it reads the
    /// legacy un-suffixed keys; every other profile namespaces by `id`.
    public func settingsNamespace(isDefault: Bool) -> String? {
        isDefault ? nil : id
    }
}

extension Profile {
    /// Curated, tvOS-friendly SF Symbols offered as profile avatars.
    public static let defaultAvatarSymbols: [String] = [
        "person.crop.circle.fill",
        "person.fill",
        "figure.child.circle.fill",
        "star.circle.fill",
        "heart.circle.fill",
        "gamecontroller.fill",
        "music.note",
        "film.fill",
        "sparkles",
        "leaf.fill",
        "pawprint.fill",
        "moon.stars.fill"
    ]

    /// Palette indices for `colorIndex`. Resolved to concrete colors in the UI
    /// layer so `CoreModels` stays Foundation-only.
    public static let tileColorCount = 8

    /// A clamped, valid color index for `colorIndex`.
    public var clampedColorIndex: Int {
        guard Profile.tileColorCount > 0 else { return 0 }
        return ((colorIndex % Profile.tileColorCount) + Profile.tileColorCount) % Profile.tileColorCount
    }
}

extension Profile: CustomStringConvertible {
    /// Profiles carry no secret; keep logging terse and stable.
    public var description: String {
        "Profile(id: \(id), name: \(name))"
    }
}

/// One profile's Plex Home-user selection for ONE Plex account. A profile
/// can hold several of these (keyed by `Account.id`) so each distinct
/// `plex.tv` sign-in plays as the right Home user.
public struct PlexHomeUserBinding: Codable, Hashable, Sendable {
    public var homeUserID: String
    public var name: String
    public var avatarURL: String?
    public var requiresPIN: Bool?

    public init(homeUserID: String, name: String, avatarURL: String? = nil, requiresPIN: Bool? = nil) {
        self.homeUserID = homeUserID
        self.name = name
        self.avatarURL = avatarURL
        self.requiresPIN = requiresPIN
    }
}

extension Profile {
    /// Returns this profile's Plex Home-user binding for `accountID`, falling
    /// back to the legacy single-mapping fields (`plexHomeUserID` et al.)
    /// when no per-account dict exists yet. This is the **upgrade path**:
    /// profiles encoded before the per-account map shipped continue to work
    /// transparently.
    public func homeUserBinding(forPlexAccount accountID: String) -> PlexHomeUserBinding? {
        if let dict = plexHomeUserBindings, let entry = dict[accountID] {
            return entry
        }
        // Legacy single-mapping fallback: only honor it when it actually
        // targets this account.
        guard plexHomeUserAccountID == accountID,
              let id = plexHomeUserID else { return nil }
        return PlexHomeUserBinding(
            homeUserID: id,
            name: plexHomeUserName ?? "",
            avatarURL: plexHomeUserAvatarURL,
            requiresPIN: plexHomeUserRequiresPIN
        )
    }

    /// Writes (or clears) the Plex Home-user binding for `accountID`. Returns
    /// the updated profile. Authoritative storage is the dict; the legacy
    /// single-mapping fields are mirrored to the just-written entry so older
    /// readers still see a coherent (most-recent) selection. Clearing the
    /// last entry clears the legacy fields too.
    public func settingHomeUserBinding(_ binding: PlexHomeUserBinding?, forPlexAccount accountID: String) -> Profile {
        var copy = self
        var dict = copy.plexHomeUserBindings ?? [:]
        // Seed dict from legacy fields on first migration so we don't lose
        // an existing single mapping when we add a NEW per-account entry.
        if copy.plexHomeUserBindings == nil,
           let legacyID = copy.plexHomeUserID,
           let legacyAcct = copy.plexHomeUserAccountID,
           dict[legacyAcct] == nil {
            dict[legacyAcct] = PlexHomeUserBinding(
                homeUserID: legacyID,
                name: copy.plexHomeUserName ?? "",
                avatarURL: copy.plexHomeUserAvatarURL,
                requiresPIN: copy.plexHomeUserRequiresPIN
            )
        }
        if let binding {
            dict[accountID] = binding
            copy.plexHomeUserID = binding.homeUserID
            copy.plexHomeUserName = binding.name
            copy.plexHomeUserAccountID = accountID
            copy.plexHomeUserRequiresPIN = binding.requiresPIN
            copy.plexHomeUserAvatarURL = binding.avatarURL
        } else {
            dict.removeValue(forKey: accountID)
            if copy.plexHomeUserAccountID == accountID {
                copy.plexHomeUserID = nil
                copy.plexHomeUserName = nil
                copy.plexHomeUserAccountID = nil
                copy.plexHomeUserRequiresPIN = nil
                copy.plexHomeUserAvatarURL = nil
            }
            // If another binding still exists, surface one of them in the
            // legacy fields so an older build/codepath that only reads them
            // sees *something* sane (deterministic — the lex-first key).
            if copy.plexHomeUserAccountID == nil,
               let next = dict.sorted(by: { $0.key < $1.key }).first {
                copy.plexHomeUserAccountID = next.key
                copy.plexHomeUserID = next.value.homeUserID
                copy.plexHomeUserName = next.value.name
                copy.plexHomeUserAvatarURL = next.value.avatarURL
                copy.plexHomeUserRequiresPIN = next.value.requiresPIN
            }
        }
        copy.plexHomeUserBindings = dict.isEmpty ? nil : dict
        return copy
    }
}
