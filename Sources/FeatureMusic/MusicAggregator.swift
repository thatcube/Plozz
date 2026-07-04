import Foundation
import Observation
import CoreModels

/// A signed-in account whose provider advertises (and actually exposes) music.
public struct ResolvedMusicAccount: Sendable {
    public let accountID: String
    public let provider: any MusicProvider
    /// The visible music library IDs to scope queries to, or `nil` for "all
    /// libraries" (the unscoped default). Driven by the per-profile library
    /// visibility toggles.
    public let libraryIDs: [String]?

    public init(accountID: String, provider: any MusicProvider, libraryIDs: [String]? = nil) {
        self.accountID = accountID
        self.provider = provider
        self.libraryIDs = libraryIDs
    }
}

/// Resolves `MusicProvider`s from the app's `[ResolvedAccount]` aggregation seam
/// and routes a tapped music item back to its owning provider via
/// `sourceAccountID`, exactly like the video Home does for `MediaItem`s.
public struct MusicContext: Sendable {
    public let accounts: [ResolvedAccount]
    /// Visible music library IDs per account (post visibility-filter), or `nil`
    /// to leave every library in scope. Scopes the landing/grid/recently-played
    /// queries so hidden libraries contribute no content.
    public let visibleLibraryIDs: [String: [String]]?

    public init(accounts: [ResolvedAccount], visibleLibraryIDs: [String: [String]]? = nil) {
        self.accounts = accounts
        self.visibleLibraryIDs = visibleLibraryIDs
    }

    /// Every account that exposes a `MusicProvider`, in stable order, each tagged
    /// with its visible library scope.
    public var musicAccounts: [ResolvedMusicAccount] {
        accounts.compactMap { resolved in
            (resolved.provider as? MusicProvider).map {
                ResolvedMusicAccount(
                    accountID: resolved.account.id,
                    provider: $0,
                    libraryIDs: visibleLibraryIDs?[resolved.account.id]
                )
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
    /// Accounts confirmed to have at least one *visible* music library.
    public private(set) var detectedAccounts: [ResolvedAccount] = []
    /// Visible music library IDs per detected account, after applying the
    /// per-profile visibility toggles. Scopes the tab's content.
    public private(set) var visibleLibraryIDs: [String: [String]] = [:]
    public private(set) var hasMusic = false
    /// `true` once a probe has completed, so the UI can avoid flicker on launch.
    public private(set) var didProbe = false

    private let store: MusicAvailabilityStoring

    public init(store: MusicAvailabilityStoring = MusicAvailabilityStore()) {
        self.store = store
    }

    /// Synchronously shows the Music tab on the first frame using the last
    /// persisted set of libraries, with **no network**, applying the *current*
    /// visibility so a library hidden while the app was closed never resurrects a
    /// phantom tab. The subsequent `probe` refreshes and corrects this.
    public func seedFromCache(accounts: [ResolvedAccount], visibility: HomeLibraryVisibility) {
        guard !didProbe else { return }
        let stored = store.load()
        guard !stored.isEmpty else { return }
        let resolved = Self.resolve(accounts: accounts, rawLibraries: stored, visibility: visibility)
        guard !resolved.detected.isEmpty else { return }
        detectedAccounts = resolved.detected
        visibleLibraryIDs = resolved.visible
        hasMusic = true
    }

    /// Probes every account's `musicLibraries()` **in parallel**, persists the raw
    /// library map for the next launch's instant seed, then applies the current
    /// visibility to decide the tab and its content scope. Resilient — an account
    /// that errors is treated as having no music. Published state is only
    /// reassigned when it actually changes, so a confirming relaunch (or a no-op
    /// visibility re-evaluation) causes no tab flicker. Scales to ~10 accounts
    /// without summing per-account latency.
    public func probe(accounts: [ResolvedAccount], visibility: HomeLibraryVisibility) async {
        let fetched = await withTaskGroup(of: (index: Int, libraryIDs: [String]).self) { group -> [(index: Int, libraryIDs: [String])] in
            for (index, account) in accounts.enumerated() {
                guard let music = account.provider as? MusicProvider else { continue }
                group.addTask {
                    let libraries = (try? await music.musicLibraries()) ?? []
                    return (index, libraries.map(\.id))
                }
            }
            var out: [(index: Int, libraryIDs: [String])] = []
            for await result in group { out.append(result) }
            return out
        }
        let rawByIndex = Dictionary(fetched.map { ($0.index, $0.libraryIDs) }, uniquingKeysWith: { $1 })

        var rawMap: [String: [String]] = [:]
        for (index, account) in accounts.enumerated() {
            guard let raw = rawByIndex[index], !raw.isEmpty else { continue }
            rawMap[account.account.id] = raw
        }
        store.save(rawMap)
        didProbe = true

        let resolved = Self.resolve(accounts: accounts, rawLibraries: rawMap, visibility: visibility)
        let changed = resolved.visible != visibleLibraryIDs
            || Set(resolved.detected.map { $0.account.id }) != Set(detectedAccounts.map { $0.account.id })
        if changed {
            detectedAccounts = resolved.detected
            visibleLibraryIDs = resolved.visible
            hasMusic = !resolved.detected.isEmpty
        }
    }

    /// Applies visibility to a raw `accountID → libraryIDs` map, yielding the
    /// detected accounts (those with ≥1 enabled library, in `accounts` order) and
    /// the per-account enabled library IDs. The key scheme `"<accountID>:<libraryID>"`
    /// matches `AggregatedLibrary.key`. The Music tab keys off the **app-wide
    /// enabled** state (`disabledKeys`), NOT the Home-only "Show on Home" bit — a
    /// library hidden from Home still appears in Music; only disabling it app-wide
    /// removes it here, matching the two-level visibility model.
    private static func resolve(
        accounts: [ResolvedAccount],
        rawLibraries: [String: [String]],
        visibility: HomeLibraryVisibility
    ) -> (detected: [ResolvedAccount], visible: [String: [String]]) {
        var detected: [ResolvedAccount] = []
        var visible: [String: [String]] = [:]
        for account in accounts where account.provider is MusicProvider {
            guard let raw = rawLibraries[account.account.id], !raw.isEmpty else { continue }
            let visibleLibs = raw.filter { visibility.isEnabled("\(account.account.id):\($0)") }
            guard !visibleLibs.isEmpty else { continue }
            detected.append(account)
            visible[account.account.id] = visibleLibs
        }
        return (detected, visible)
    }
}
