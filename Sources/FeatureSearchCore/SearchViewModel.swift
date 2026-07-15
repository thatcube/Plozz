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
    public private(set) var isSemanticIndexBuilding = false

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
    private let semanticSearch: (@Sendable (String, Set<String>) async -> [MediaItem])?
    private let semanticIndexBuilding: (@Sendable () async -> Bool)?
    /// Best-effort cue enrichment runs after the playable search results publish.
    /// A new query cancels it so stale availability can never mutate fresh results.
    private nonisolated(unsafe) var availabilityCueEnrichmentTask: Task<Void, Never>?
    private nonisolated(unsafe) var semanticEnrichmentTask: Task<Void, Never>?

    public init(
        accounts: [ResolvedAccount],
        limit: Int = 40,
        debounceMilliseconds: Int = 350,
        identitySources: @escaping @Sendable (MediaItem) -> [MediaSourceRef] = { _ in [] },
        disabledLibraryKeys: @escaping () -> Set<String> = { [] },
        seerSearch: (@Sendable (String) async -> [MediaItem])? = nil,
        seerRequestAvailability: (@Sendable (MediaItem) async -> MediaRequestAvailability?)? = nil,
        semanticSearch: (@Sendable (String, Set<String>) async -> [MediaItem])? = nil,
        semanticIndexBuilding: (@Sendable () async -> Bool)? = nil
    ) {
        self.accounts = accounts
        self.limit = limit
        self.debounce = .milliseconds(debounceMilliseconds)
        self.identitySources = identitySources
        self.disabledLibraryKeys = disabledLibraryKeys
        self.seerSearch = seerSearch
        self.seerRequestAvailability = seerRequestAvailability
        self.semanticSearch = semanticSearch
        self.semanticIndexBuilding = semanticIndexBuilding
    }

    deinit {
        availabilityCueEnrichmentTask?.cancel()
        semanticEnrichmentTask?.cancel()
    }

    /// Runs a debounced search for the current `query`. Safe to call on every
    /// keystroke via `.task(id: query)`: an empty query resets to idle, and a
    /// query that changes mid-flight discards the obsolete result.
    public func search() async {
        availabilityCueEnrichmentTask?.cancel()
        availabilityCueEnrichmentTask = nil
        semanticEnrichmentTask?.cancel()
        semanticEnrichmentTask = nil
        isSemanticIndexBuilding = false
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
        var sections = SearchSection.sections(from: dedupedLibrary)
        if let notInLibrary = SearchSection.notInLibrarySection(
            discoveryResults: discoveryItems,
            libraryResults: dedupedLibrary,
            limit: limit
        ) {
            sections.append(notInLibrary)
        }

        if !sections.isEmpty {
            state = .loaded(sections)
            scheduleAvailabilityCueEnrichment(
                requestedQuery: requested,
                discoveryResults: discoveryItems,
                libraryResults: dedupedLibrary
            )
            scheduleSemanticEnrichment(
                requestedQuery: requested,
                existingItems: sections.flatMap(\.items)
            )
        } else {
            if semanticSearch != nil {
                state = .empty
                scheduleSemanticEnrichment(
                    requestedQuery: requested,
                    existingItems: [],
                    fallbackError: libraryError
                )
            } else {
                state = libraryError.map(LoadState.failed) ?? .empty
            }
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

    /// Synchronization seam for deterministic tests of the off-critical-path cue.
    /// Production UI never waits for this work.
    func waitForAvailabilityCueEnrichment() async {
        await availabilityCueEnrichmentTask?.value
    }

    func waitForSemanticEnrichment() async {
        await semanticEnrichmentTask?.value
    }

    private func semanticItems(_ items: [MediaItem]) -> [MediaItem] {
        let serverInfo = accounts.sourceServerInfo()
        return SearchDeduplicator.deduplicate(
            items,
            identitySources: identitySources,
            serverInfo: { serverInfo[$0] }
        )
    }

    private func scheduleSemanticEnrichment(
        requestedQuery: String,
        existingItems: [MediaItem],
        fallbackError: AppError? = nil
    ) {
        guard let semanticSearch else { return }
        let excluded = disabledLibraryKeys()
        semanticEnrichmentTask = Task { [weak self] in
            let results = await semanticSearch(requestedQuery, excluded)
            let indexIsBuilding = await self?.semanticIndexBuilding?() ?? false
            guard !Task.isCancelled, let self else { return }
            guard SearchPolicy.isCurrent(
                requestedQuery: requestedQuery,
                liveQuery: self.query
            ) else { return }
            let deduped = self.semanticItems(results)
            guard let section = SearchSection.matchesByDescriptionSection(
                semanticResults: deduped,
                existingItems: existingItems,
                limit: self.limit
            ) else {
                self.isSemanticIndexBuilding = indexIsBuilding
                if let fallbackError, case .empty = self.state {
                    self.state = .failed(fallbackError)
                    self.isSemanticIndexBuilding = false
                }
                return
            }
            switch self.state {
            case let .loaded(currentSections):
                guard !currentSections.contains(where: {
                    $0.title == SearchSection.matchesByDescriptionTitle
                }) else { return }
                self.state = .loaded(currentSections + [section])
            case .empty:
                self.state = .loaded([section])
            default:
                return
            }
        }
    }

    private func scheduleAvailabilityCueEnrichment(
        requestedQuery: String,
        discoveryResults: [MediaItem],
        libraryResults: [MediaItem]
    ) {
        guard let seerRequestAvailability else { return }
        let accounts = accounts
        availabilityCueEnrichmentTask = Task { [weak self] in
            let requestableSeriesTmdbIDs = await Self.requestablePartialSeriesTmdbIDs(
                discoveryResults: discoveryResults,
                libraryResults: libraryResults,
                accounts: accounts,
                availabilityResolver: seerRequestAvailability
            )
            guard !Task.isCancelled, !requestableSeriesTmdbIDs.isEmpty, let self else { return }
            guard SearchPolicy.isCurrent(requestedQuery: requestedQuery, liveQuery: self.query),
                  case let .loaded(currentSections) = self.state
            else { return }
            self.state = .loaded(currentSections.map { section in
                SearchSection(
                    title: section.title,
                    items: SearchSection.mergingDiscoveryAvailability(
                        into: section.items,
                        discoveryResults: discoveryResults,
                        requestableSeriesTmdbIDs: requestableSeriesTmdbIDs
                    )
                )
            })
        }
    }

    private nonisolated static func requestablePartialSeriesTmdbIDs(
        discoveryResults: [MediaItem],
        libraryResults: [MediaItem],
        accounts: [ResolvedAccount],
        availabilityResolver: @escaping @Sendable (MediaItem) async -> MediaRequestAvailability?
    ) async -> Set<String> {
        let libraryTmdbIDs = Set(libraryResults.compactMap { item in
            item.kind == .series ? item.providerIDs["Tmdb"] : nil
        })
        let partialDiscoveryByTmdbID = Dictionary(
            discoveryResults.compactMap { item -> (String, MediaItem)? in
                guard item.kind == .series,
                      item.availability == .partiallyAvailable,
                      let tmdbID = item.providerIDs["Tmdb"],
                      libraryTmdbIDs.contains(tmdbID)
                else { return nil }
                return (tmdbID, item)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let candidates = libraryResults.compactMap { libraryItem -> (String, MediaItem, MediaItem)? in
            guard libraryItem.kind == .series,
                  let tmdbID = libraryItem.providerIDs["Tmdb"],
                  let discoveryItem = partialDiscoveryByTmdbID[tmdbID]
            else { return nil }
            return (tmdbID, libraryItem, discoveryItem)
        }
        return await withTaskGroup(of: String?.self) { group in
            for (tmdbID, libraryItem, discoveryItem) in candidates {
                group.addTask {
                    guard let availability = await availabilityResolver(discoveryItem),
                          let ownedSeasonNumbers = await ownedSeasonNumbers(
                            for: libraryItem,
                            accounts: accounts
                          )
                    else { return nil }
                    let reconciled = availability.markingAvailable(Array(ownedSeasonNumbers))
                    return reconciled.requestableSeasonNumbers.isEmpty ? nil : tmdbID
                }
            }
            var result: Set<String> = []
            for await tmdbID in group {
                if let tmdbID { result.insert(tmdbID) }
            }
            return result
        }
    }

    /// Returns `nil` unless ownership could be checked on every known source.
    /// Search cues are optional, so incomplete cross-server data fails closed
    /// rather than advertising seasons that detail may discover are already owned.
    private nonisolated static func ownedSeasonNumbers(
        for item: MediaItem,
        accounts: [ResolvedAccount]
    ) async -> Set<Int>? {
        var sources = item.sources
        if let sourceAccountID = item.sourceAccountID,
           !sources.contains(where: { $0.accountID == sourceAccountID && $0.itemID == item.id }) {
            sources.append(MediaSourceRef(accountID: sourceAccountID, itemID: item.id, kind: item.kind))
        }
        var seen = Set<String>()
        sources = sources.filter { seen.insert($0.id).inserted }
        guard !sources.isEmpty else { return nil }

        let providers = Dictionary(
            accounts.map { ($0.account.id, $0.provider) },
            uniquingKeysWith: { first, _ in first }
        )
        return await withTaskGroup(of: Set<Int>?.self) { group in
            for source in sources {
                guard let provider = providers[source.accountID] else { return nil }
                group.addTask {
                    do {
                        let children = try await provider.children(of: source.itemID)
                        return Set(children.compactMap { child in
                            child.kind == .season || child.kind == .episode ? child.seasonNumber : nil
                        })
                    } catch {
                        return nil
                    }
                }
            }
            var owned: Set<Int> = []
            for await sourceSeasons in group {
                guard let sourceSeasons else {
                    group.cancelAll()
                    return nil
                }
                owned.formUnion(sourceSeasons)
            }
            return owned
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
