import Foundation

/// A Plex **Home** user ("Who's watching?") belonging to a signed-in Plex
/// account. Plozz maps an app `Profile` to one of these so switching the active
/// profile switches the Plex identity (its own watch state / On Deck /
/// restrictions).
///
/// Plain value type so it can cross module boundaries (ProviderPlex produces it,
/// AppShell + FeatureProfiles consume it) without leaking Plex transport types.
public struct PlexHomeUser: Identifiable, Hashable, Sendable, Codable {
    /// Plex Home user `uuid` — the id used to switch to this user.
    public let id: String
    /// Display name (Plex `title`).
    public let name: String
    /// `true` when switching to this user requires a PIN (a password-protected
    /// Home user). Plozz prompts for the PIN on every switch and never stores it.
    public let requiresPIN: Bool
    /// `true` for the Home's admin/owner user.
    public let isAdmin: Bool
    /// `true` for a managed (restricted) user, e.g. a kid profile.
    public let isRestricted: Bool

    public init(
        id: String,
        name: String,
        requiresPIN: Bool,
        isAdmin: Bool = false,
        isRestricted: Bool = false
    ) {
        self.id = id
        self.name = name
        self.requiresPIN = requiresPIN
        self.isAdmin = isAdmin
        self.isRestricted = isRestricted
    }
}
