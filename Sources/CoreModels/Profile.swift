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

    public init(
        id: String = UUID().uuidString,
        name: String,
        avatarSymbol: String = Profile.defaultAvatarSymbols[0],
        colorIndex: Int = 0,
        createdAt: Date = Date(),
        linkedAccountID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.avatarSymbol = avatarSymbol
        self.colorIndex = colorIndex
        self.createdAt = createdAt
        self.linkedAccountID = linkedAccountID
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
