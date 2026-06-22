import Foundation
import Observation
import CoreModels

/// A signed-in account whose provider advertises (and actually exposes) music.
public struct ResolvedMusicAccount: Sendable {
    public let accountID: String
    public let provider: any MusicProvider

    public init(accountID: String, provider: any MusicProvider) {
        self.accountID = accountID
        self.provider = provider
    }
}

/// Resolves `MusicProvider`s from the app's `[ResolvedAccount]` aggregation seam
/// and routes a tapped music item back to its owning provider via
/// `sourceAccountID`, exactly like the video Home does for `MediaItem`s.
public struct MusicContext: Sendable {
    public let accounts: [ResolvedAccount]

    public init(accounts: [ResolvedAccount]) {
        self.accounts = accounts
    }

    /// Every account that exposes a `MusicProvider`, in stable order.
    public var musicAccounts: [ResolvedMusicAccount] {
        accounts.compactMap { resolved in
            (resolved.provider as? MusicProvider).map {
                ResolvedMusicAccount(accountID: resolved.account.id, provider: $0)
            }
        }
    }

    /// The music provider that owns `accountID`, falling back to the first
    /// music-capable account for untagged items.
    public func provider(for accountID: String?) -> (any MusicProvider)? {
        if let accountID,
           let match = accounts.first(where: { $0.account.id == accountID }),
           let music = match.provider as? MusicProvider {
            return music
        }
        return musicAccounts.first?.provider
    }
}

/// Detects whether any signed-in account actually exposes a music *library*
/// (not merely whether the provider could). Drives the conditional Music tab:
/// the tab and mini-player appear only when `hasMusic` is `true`, so video-only
/// users see the app exactly as before.
@MainActor
@Observable
public final class MusicAvailabilityModel {
    /// Accounts confirmed to have at least one music library.
    public private(set) var detectedAccounts: [ResolvedAccount] = []
    public private(set) var hasMusic = false
    /// `true` once a probe has completed, so the UI can avoid flicker on launch.
    public private(set) var didProbe = false

    public init() {}

    /// Probes every account's `musicLibraries()` and records which have music.
    /// Cheap (one `/Users/{id}/Views` call per account) and resilient — an
    /// account that errors is simply treated as having no music.
    public func probe(accounts: [ResolvedAccount]) async {
        var detected: [ResolvedAccount] = []
        for account in accounts {
            guard let music = account.provider as? MusicProvider else { continue }
            if let libraries = try? await music.musicLibraries(), !libraries.isEmpty {
                detected.append(account)
            }
        }
        detectedAccounts = detected
        hasMusic = !detected.isEmpty
        didProbe = true
    }
}
