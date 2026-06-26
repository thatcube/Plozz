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

    private let store: MusicAvailabilityStoring

    public init(store: MusicAvailabilityStoring = MusicAvailabilityStore()) {
        self.store = store
    }

    /// Synchronously shows the Music tab on the first frame using the last
    /// persisted result, with **no network**. Only accounts that are both cached
    /// *and* currently signed-in and music-capable are seeded, so a removed
    /// account never resurrects a phantom tab. The subsequent `probe` refreshes
    /// and corrects this.
    public func seedFromCache(accounts: [ResolvedAccount]) {
        guard !didProbe else { return }
        let cachedIDs = store.load()
        guard !cachedIDs.isEmpty else { return }
        let seeded = accounts.filter { cachedIDs.contains($0.account.id) && $0.provider is MusicProvider }
        guard !seeded.isEmpty else { return }
        detectedAccounts = seeded
        hasMusic = true
    }

    /// Probes every account's `musicLibraries()` **in parallel** and records which
    /// have music. Cheap (one `/Users/{id}/Views` call per account) and resilient
    /// — an account that errors is treated as having no music. The refreshed set
    /// is persisted for the next launch's instant seed, and the published state is
    /// only reassigned when the detected set actually changes, so a relaunch that
    /// confirms the cache causes no tab flicker. Scales to ~10 accounts without
    /// summing per-account latency.
    public func probe(accounts: [ResolvedAccount]) async {
        let results = await withTaskGroup(of: (index: Int, hasMusic: Bool).self) { group -> [(index: Int, hasMusic: Bool)] in
            for (index, account) in accounts.enumerated() {
                guard let music = account.provider as? MusicProvider else { continue }
                group.addTask {
                    let hasMusic = ((try? await music.musicLibraries())?.isEmpty == false)
                    return (index, hasMusic)
                }
            }
            var out: [(index: Int, hasMusic: Bool)] = []
            for await result in group { out.append(result) }
            return out
        }

        let hasMusicByIndex = Dictionary(results.map { ($0.index, $0.hasMusic) }, uniquingKeysWith: { $1 })
        var detected: [ResolvedAccount] = []
        for (index, account) in accounts.enumerated() where hasMusicByIndex[index] == true {
            detected.append(account)
        }

        let detectedIDs = Set(detected.map { $0.account.id })
        store.save(detectedIDs)
        didProbe = true
        if detectedIDs != Set(detectedAccounts.map { $0.account.id }) {
            detectedAccounts = detected
            hasMusic = !detected.isEmpty
        }
    }
}
