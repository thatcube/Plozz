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

    private let provider: any MediaProvider
    private let limit: Int
    private let debounce: Duration

    public init(
        provider: any MediaProvider,
        limit: Int = 40,
        debounceMilliseconds: Int = 350
    ) {
        self.provider = provider
        self.limit = limit
        self.debounce = .milliseconds(debounceMilliseconds)
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
        do {
            let items = try await provider.search(query: requested, limit: limit)
            guard SearchPolicy.isCurrent(requestedQuery: requested, liveQuery: query) else { return }
            let sections = SearchSection.sections(from: items)
            state = sections.isEmpty ? .empty : .loaded(sections)
        } catch let error as AppError {
            guard SearchPolicy.isCurrent(requestedQuery: requested, liveQuery: query) else { return }
            state = .failed(error)
        } catch {
            guard SearchPolicy.isCurrent(requestedQuery: requested, liveQuery: query) else { return }
            state = .failed(.unknown(""))
        }
    }
}
