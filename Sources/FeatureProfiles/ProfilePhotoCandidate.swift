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
    /// source that has no avatar URL — there's nothing to borrow — and any
    /// source whose avatar is a recognizable *default* placeholder (a generic
    /// silhouette / gravatar "mystery man"), since borrowing one of those as a
    /// "photo" just yields an icon-looking image the profile's own symbol does
    /// better (see `isLikelyDefaultAvatar`).
    public static func make(
        accounts: [Account],
        plexHomeUsersByAccount: [String: [PlexHomeUser]]
    ) -> [ProfilePhotoCandidate] {
        var out: [ProfilePhotoCandidate] = []

        // Jellyfin: one candidate per signed-in user with a *real* avatar.
        for account in accounts where account.server.provider.usesMediaBrowserAPI {
            guard let url = account.avatarURL, !isLikelyDefaultAvatar(url) else { continue }
            out.append(ProfilePhotoCandidate(
                providerLabel: account.server.provider.displayName,
                detailLabel: "\(account.userName) on \(account.server.name)",
                imageURL: url,
                sourceTag: "\(account.server.provider.rawValue).\(account.id)"
            ))
        }

        // Plex: one candidate per Home user with a *real* avatar, across all
        // signed-in Plex accounts.
        for account in accounts where account.server.provider == .plex {
            let users = plexHomeUsersByAccount[account.id] ?? []
            for user in users {
                guard let url = user.avatarURL, !isLikelyDefaultAvatar(url) else { continue }
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

    /// Whether an avatar URL is very likely a provider **default/placeholder**
    /// rather than a real uploaded photo, so we don't offer it as a borrowable
    /// picture. Deliberately conservative — it only matches signals that are
    /// unambiguous defaults, so a genuine custom photo is never hidden:
    ///
    /// - **Gravatar fallbacks:** a `d=`/`default=` query of `mm`/`mp`
    ///   (mystery-person), `blank`, or `404` — the values Gravatar serves when a
    ///   user has no image of their own. (An `identicon`/`retro`/`robohash`
    ///   fallback is left in; those are at least distinctive per-user.)
    /// - **Plex's built-in silhouette assets** shipped under `plex.tv`'s static
    ///   asset paths (e.g. `/assets/.../avatar` defaults), which every account
    ///   without a custom photo shares.
    ///
    /// Anything else is treated as a real photo. Tune here if a provider default
    /// slips through in practice.
    public static func isLikelyDefaultAvatar(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()
        let query = url.query?.lowercased() ?? ""

        if host.contains("gravatar.com") {
            // Gravatar's "no custom image" fallbacks.
            for marker in ["d=mm", "d=mp", "d=blank", "d=404", "default=mm", "default=mp", "default=blank", "default=404"] {
                if query.contains(marker) { return true }
            }
        }

        // Plex ships generic silhouette avatars from its static asset host; a
        // user's own upload never lives under `/assets/`.
        if host.contains("plex.tv") || host.contains("plex.direct") {
            if path.contains("/assets/") && path.contains("avatar") { return true }
            if path.hasSuffix("/avatar/default") { return true }
        }

        return false
    }
}
#endif
