#if canImport(SwiftUI)
import Foundation
import CoreModels

/// One borrowable real photo offered to the profile editor's Photo mode.
/// Sourced from a signed-in Jellyfin user (`Account.avatarURL`) or a Plex
/// Home user (`PlexHomeUser.avatarURL`). Purely cosmetic — picking one only
/// writes `Profile.avatarImageURL`; it never re-binds playback identity.
public struct ProfilePhotoCandidate: Identifiable, Hashable, Sendable {
    public var id: String { "\(sourceTag).\(imageURL.absoluteString)" }
    /// "Plex" or "Jellyfin" (matches `Provider.displayName` casing).
    public let providerLabel: String
    /// Where this photo comes from, e.g. "Mom on Allie's Jellyfin".
    public let detailLabel: String
    /// The borrowable image.
    public let imageURL: URL
    /// Stable disambiguator so two candidates with the same URL on different
    /// accounts/users still hash distinctly.
    public let sourceTag: String

    public init(providerLabel: String, detailLabel: String, imageURL: URL, sourceTag: String) {
        self.providerLabel = providerLabel
        self.detailLabel = detailLabel
        self.imageURL = imageURL
        self.sourceTag = sourceTag
    }

    /// Builds the photo-borrow list from the household's accounts plus the
    /// already-fetched Plex Home users per Plex account. Filters out any
    /// source that has no avatar URL — there's nothing to borrow.
    public static func make(
        accounts: [Account],
        plexHomeUsersByAccount: [String: [PlexHomeUser]]
    ) -> [ProfilePhotoCandidate] {
        var out: [ProfilePhotoCandidate] = []

        // Jellyfin: one candidate per signed-in user with an avatar.
        for account in accounts where account.server.provider == .jellyfin {
            guard let url = account.avatarURL else { continue }
            out.append(ProfilePhotoCandidate(
                providerLabel: "Jellyfin",
                detailLabel: "\(account.userName) on \(account.server.name)",
                imageURL: url,
                sourceTag: "jellyfin.\(account.id)"
            ))
        }

        // Plex: one candidate per Home user with an avatar, across all
        // signed-in Plex accounts.
        for account in accounts where account.server.provider == .plex {
            let users = plexHomeUsersByAccount[account.id] ?? []
            for user in users {
                guard let url = user.avatarURL else { continue }
                out.append(ProfilePhotoCandidate(
                    providerLabel: "Plex",
                    detailLabel: "\(user.name) on \(account.server.name)",
                    imageURL: url,
                    sourceTag: "plex.\(account.id).\(user.id)"
                ))
            }
        }

        return out
    }
}
#endif
