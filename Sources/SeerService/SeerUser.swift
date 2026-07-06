import Foundation
import CoreModels

/// A Seerr (Overseerr / Jellyseerr) user, provider-agnostic, as surfaced to the
/// app so a household profile can be mapped to "request as this person". Built
/// from the internal ``SeerUserDTO`` with a resolved avatar URL.
public struct SeerUser: Identifiable, Equatable, Sendable {
    public let id: Int
    /// Best available display name (Overseerr's `displayName`, falling back
    /// through usernames / email / "User <id>").
    public let name: String
    /// A secondary line for disambiguation in the picker (email or username),
    /// when it differs from `name`.
    public let subtitle: String?
    /// Fully-resolved avatar URL (relative Overseerr paths are resolved against
    /// the server base URL; absolute URLs like Gravatar pass through).
    public let avatarURL: URL?

    public init(id: Int, name: String, subtitle: String? = nil, avatarURL: URL? = nil) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.avatarURL = avatarURL
    }
}

extension SeerUser {
    /// Maps an internal DTO to the public model, resolving the avatar against the
    /// Seerr `baseURL` (Overseerr often returns a relative `/avatarproxy/…` path;
    /// Gravatar returns an absolute URL).
    static func from(_ dto: SeerUserDTO, baseURL: URL?) -> SeerUser {
        let name = [dto.displayName, dto.username, dto.plexUsername, dto.jellyfinUsername, dto.email]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? "User \(dto.id)"

        // A subtitle only when it adds information beyond the name.
        let subtitleCandidate = [dto.email, dto.username]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty && $0 != name })

        let avatar = dto.avatar.flatMap { raw -> URL? in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
                return URL(string: trimmed)
            }
            guard let baseURL else { return nil }
            let path = trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
            return URL(string: path, relativeTo: baseURL)?.absoluteURL
        }

        return SeerUser(id: dto.id, name: name, subtitle: subtitleCandidate, avatarURL: avatar)
    }
}

// MARK: - Request outcome

/// The result of a one-tap Seerr request. Unlike the old optional
/// `MediaAvailabilityStatus?`, a failure carries a **specific, user-facing
/// reason** so the UI can explain what happened (no keyboard needed on tvOS) and
/// offer a real recovery action.
public enum SeerRequestOutcome: Equatable, Sendable {
    /// The request was accepted. The carried status is the title's resulting
    /// availability — note `.pending` here means "created, awaiting approval",
    /// which is a **success**, not a failure.
    case success(MediaAvailabilityStatus)
    /// The request could not be created; the reason is user-facing.
    case failure(SeerRequestFailure)
}

/// Why a Seerr request failed, mapped from the HTTP status + Overseerr's error
/// message body. ⚠️ The message-string matching is best-effort and must be
/// verified against a real instance before relying on the fine distinctions
/// (e.g. quota vs. no-defaults, which Overseerr can both surface via 403/500).
public enum SeerRequestFailure: Equatable, Sendable {
    /// The acting Seerr user has no default server / quality profile set, so
    /// Overseerr couldn't resolve where to send the request. Recovery: set
    /// defaults in the Seerr web UI, or use the Advanced picker (Phase 2).
    case noDefaults
    /// The acting user lacks permission to request (or to auto-request).
    case noPermission
    /// The acting user is over their request quota.
    case quotaExceeded
    /// The title was already requested (globally). Not really an error — the UI
    /// can reflect "Already requested".
    case alreadyRequested
    /// The `X-API-User` didn't resolve to a real Seerr user (stale/deleted
    /// mapping). Recovery: re-link the profile in Settings.
    case invalidActingUser
    /// The server couldn't be reached (transport failure / timeout).
    case unreachable
    /// Something else went wrong; carries the server message when present.
    case unknown(String?)

    /// Classifies a failed request from its HTTP status and decoded error message.
    /// `message` is Overseerr's `{ "message": … }` body when present.
    static func classify(status: Int, message: String?) -> SeerRequestFailure {
        let lowered = message?.lowercased() ?? ""
        func mentions(_ needles: String...) -> Bool { needles.contains { lowered.contains($0) } }

        switch status {
        case 409:
            return .alreadyRequested
        case 401:
            return .invalidActingUser
        case 403:
            if mentions("quota", "limit") { return .quotaExceeded }
            if mentions("default", "no server", "no radarr", "no sonarr", "profile", "root folder") {
                return .noDefaults
            }
            return .noPermission
        default:
            if mentions("quota", "limit") { return .quotaExceeded }
            if mentions("default", "no server", "no radarr", "no sonarr", "profile", "root folder") {
                return .noDefaults
            }
            if mentions("permission", "not authorized", "forbidden") { return .noPermission }
            return .unknown(message)
        }
    }
}
