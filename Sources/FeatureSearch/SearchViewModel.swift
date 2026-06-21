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

    public init(
        accounts: [ResolvedAccount],
        limit: Int = 40,
        debounceMilliseconds: Int = 350
    ) {
        self.accounts = accounts
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
            let items = try await aggregatedSearch(query: requested)
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

    /// Searches every active account concurrently and round-robin interleaves the
    /// per-account hits, tagging each with its owning account so a tapped result
    /// routes to the right provider. Resilient: if some accounts fail their hits
    /// are simply omitted; only when **every** account fails is the error
    /// surfaced, so a single server being down still shows results from the rest.
    private func aggregatedSearch(query: String) async throws -> [MediaItem] {
        let perAccountLimit = limit
        let results = await withTaskGroup(of: (Int, Result<[MediaItem], AppError>).self) { group in
            for (index, resolved) in accounts.enumerated() {
                group.addTask {
                    let accountID = resolved.account.id
                    do {
                        let hits = try await resolved.provider.search(query: query, limit: perAccountLimit)
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
