import Foundation
import Observation
import CoreModels

/// Drives the Search screen: holds the live query, debounces input, runs the
/// provider search, and guards against stale (out-of-order) responses.
///
/// The owning view binds `query` to a `.searchable` field and re-runs `search()`
/// via `.task(id: query)`, so SwiftUI cancels the previous in-flight task each
/// time the query changes. The debounce + cancellation checks here turn that
/// into a single trailing-edge request per pause in typing.
@MainActor
@Observable
public final class SearchViewModel {
    public var query: String = ""
    public private(set) var state: LoadState<[SearchSection]> = .idle

    private let accounts: [ResolvedAccount]
    private let limit: Int
    private let debounce: Duration
    /// Shared identity-index lookup folded into dedup so each result card carries
    /// its full cross-server source set even before the detail picker probes.
    private let identitySources: @Sendable (MediaItem) -> [MediaSourceRef]
    /// The profile's app-wide **disabled** library keys (`"accountID:libraryID"`),
    /// read fresh per search so a disabled library is kept out of results. Empty
    /// (the default) means every library is searchable — the zero-cost common path.
    /// Called only on the main actor (its `Set` result — `Sendable` — is what the
    /// per-account search tasks capture), so it needn't be `@Sendable` itself.
    private let disabledLibraryKeys: () -> Set<String>
    /// Optional Seerr (Overseerr/Jellyseerr) discovery search. When set, its hits
    /// are folded into a trailing "Not in Your Library" section — titles the user
    /// can request rather than play. Runs concurrently with the library search and
    /// must never throw (swallow errors to `[]` at the call site) so a Seerr outage
    /// can't break library search. `nil` disables the discovery section entirely
    /// (the zero-cost path when Seerr isn't connected).
    private let seerSearch: (@Sendable (String) async -> [MediaItem])?
    /// Resolves season-level coverage only for a partial Seerr series that also
    /// matched a playable library result. The cue is shown only when at least one
    /// season is genuinely requestable, never from aggregate partial status alone.
    private let seerRequestAvailability: (@Sendable (MediaItem) async -> MediaRequestAvailability?)?

    public init(
        accounts: [ResolvedAccount],
        limit: Int = 40,
        debounceMilliseconds: Int = 350,
        identitySources: @escaping @Sendable (MediaItem) -> [MediaSourceRef] = { _ in [] },
        disabledLibraryKeys: @escaping () -> Set<String> = { [] },
        seerSearch: (@Sendable (String) async -> [MediaItem])? = nil,
        seerRequestAvailability: (@Sendable (MediaItem) async -> MediaRequestAvailability?)? = nil
    ) {
        self.accounts = accounts
        self.limit = limit
        self.debounce = .milliseconds(debounceMilliseconds)
        self.identitySources = identitySources
        self.disabledLibraryKeys = disabledLibraryKeys
        self.seerSearch = seerSearch
        self.seerRequestAvailability = seerRequestAvailability
    }

    /// Runs a debounced search for the current `query`. Safe to call on every
    /// keystroke via `.task(id: query)`: an empty query resets to idle, and a
    /// query that changes mid-flight discards the obsolete result.
    public func search() async {
        let requested = SearchPolicy.normalized(query)

        guard SearchPolicy.shouldSearch(requested) else {
            state = .idle
            return
        }

        // Trailing-edge debounce: wait out the typing burst. If the query
        // changes, `.task(id:)` cancels this task and `Task.sleep` throws.
        do {
            try await Task.sleep(for: debounce)
        } catch {
            return
        }
        guard !Task.isCancelled else { return }

        state = .loading

        // Start the discovery (Seerr) search concurrently with the library search
        // so the two round-trips overlap. Structured `async let` so cancelling this
        // task (the user kept typing) cancels the discovery child too. Never throws
        // — a Seerr outage yields `[]` and leaves the library results intact.
        let discoverySearch = seerSearch
        async let discoveryItemsTask: [MediaItem] = {
            guard let discoverySearch else { return [] }
            return await discoverySearch(requested)
        }()

        // The library search may throw only when EVERY account fails; capture that
        // rather than throwing, so a library outage still lets Seerr hits show.
        var libraryItems: [MediaItem] = []
        var libraryError: AppError?
        do {
            libraryItems = try await aggregatedSearch(query: requested)
        } catch let error as AppError {
            libraryError = error
        } catch {
            libraryError = .unknown("")
        }

        let discoveryItems = await discoveryItemsTask
        guard SearchPolicy.isCurrent(requestedQuery: requested, liveQuery: query) else { return }

        let serverInfo = accounts.sourceServerInfo()
        let dedupedLibrary = SearchDeduplicator.deduplicate(
            libraryItems,
            identitySources: identitySources,
            serverInfo: { serverInfo[$0] }
        )
        let requestableSeriesTmdbIDs = await requestablePartialSeriesTmdbIDs(
            discoveryResults: discoveryItems,
            libraryResults: dedupedLibrary
        )
        guard SearchPolicy.isCurrent(requestedQuery: requested, liveQuery: query) else { return }
        let libraryWithAvailability = SearchSection.mergingDiscoveryAvailability(
            into: dedupedLibrary,
            discoveryResults: discoveryItems,
            requestableSeriesTmdbIDs: requestableSeriesTmdbIDs
        )
        var sections = SearchSection.sections(from: libraryWithAvailability)
        if let notInLibrary = SearchSection.notInLibrarySection(
            discoveryResults: discoveryItems,
            libraryResults: libraryWithAvailability,
            limit: limit
        ) {
            sections.append(notInLibrary)
        }

        if !sections.isEmpty {
            state = .loaded(sections)
        } else if let libraryError {
            // Nothing to show and the library search failed outright — surface the
            // error (matches prior behaviour). A Seerr-only failure just reads empty.
            state = .failed(libraryError)
        } else {
            state = .empty
        }
    }

    /// Applies a watched-state mutation to the loaded result sections **in place**
    /// so affected cards just flip their watched badge, keeping the grid and the
    /// user's focus stable (no re-search).
    public func applyWatchedState(_ mutation: MediaItemMutation) {
        guard case let .loaded(sections) = state else { return }
        state = .loaded(sections.map { section in
            SearchSection(title: section.title, items: section.items.map { item in
                mutation.applied(to: item)
            })
        })
    }

    private func requestablePartialSeriesTmdbIDs(
        discoveryResults: [MediaItem],
        libraryResults: [MediaItem]
    ) async -> Set<String> {
        guard let seerRequestAvailability else { return [] }
        let libraryTmdbIDs = Set(libraryResults.compactMap { item in
            item.kind == .series ? item.providerIDs["Tmdb"] : nil
        })
        let candidates = discoveryResults.filter { item in
            guard item.kind == .series,
                  item.availability == .partiallyAvailable,
                  let tmdbID = item.providerIDs["Tmdb"]
            else { return false }
            return libraryTmdbIDs.contains(tmdbID)
        }
        return await withTaskGroup(of: String?.self) { group in
            for item in candidates {
                group.addTask {
                    guard let tmdbID = item.providerIDs["Tmdb"],
                          let availability = await seerRequestAvailability(item),
                          !availability.requestableSeasonNumbers.isEmpty
                    else { return nil }
                    return tmdbID
                }
            }
            var result: Set<String> = []
            for await tmdbID in group {
                if let tmdbID { result.insert(tmdbID) }
            }
            return result
        }
    }

    /// Searches every active account concurrently and round-robin interleaves the
    /// per-account hits, tagging each with its owning account so a tapped result
    /// routes to the right provider. Resilient: if some accounts fail their hits
    /// are simply omitted; only when **every** account fails is the error
    /// surfaced, so a single server being down still shows results from the rest.
    private func aggregatedSearch(query: String) async throws -> [MediaItem] {
        let perAccountLimit = limit
        // Snapshot the disabled-library keys once for this search so results from a
        // library the user turned off app-wide are excluded. Only accounts that
        // actually have a disabled library take the scoped path (see providers).
        let disabledKeys = disabledLibraryKeys()
        let results = await withTaskGroup(of: (Int, Result<[MediaItem], AppError>).self) { group in
            for (index, resolved) in accounts.enumerated() {
                group.addTask {
                    let accountID = resolved.account.id
                    let disabledForAccount: [String] = disabledKeys.compactMap { key in
                        let prefix = "\(accountID):"
                        return key.hasPrefix(prefix) ? String(key.dropFirst(prefix.count)) : nil
                    }
                    do {
                        if let interactive = resolved.provider as? any InteractiveBrowseActivityReporting {
                            await interactive.noteInteractiveBrowseActivity()
                        }
                        let hits = try await resolved.provider.search(query: query, limit: perAccountLimit, excludingLibraries: disabledForAccount)
                        return (index, .success(hits.map { $0.taggingSource(accountID) }))
                    } catch let error as AppError {
                        return (index, .failure(error))
                    } catch {
                        return (index, .failure(.unknown("")))
                    }
                }
            }
            var byIndex: [Int: Result<[MediaItem], AppError>] = [:]
            for await (index, result) in group { byIndex[index] = result }
            return accounts.indices.map { byIndex[$0] ?? .success([]) }
        }

        var groups: [[MediaItem]] = []
        var firstError: AppError?
        var anySuccess = false
        for result in results {
            switch result {
            case let .success(hits):
                groups.append(hits)
                anySuccess = true
            case let .failure(error):
                if firstError == nil { firstError = error }
            }
        }
        if !anySuccess, let firstError { throw firstError }
        return Self.interleave(groups)
    }

    /// Round-robin interleave preserving each account's relevance order.
    static func interleave<T>(_ groups: [[T]]) -> [T] {
        let maxCount = groups.map(\.count).max() ?? 0
        var result: [T] = []
        for offset in 0..<maxCount {
            for group in groups where offset < group.count {
                result.append(group[offset])
            }
        }
        return result
    }
}
