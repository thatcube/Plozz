import Foundation
import Observation
import CoreModels

/// Drives a paginated library grid: loads the first page fast, then lazily
/// fetches further pages as the user scrolls, so libraries with hundreds of
/// items never block on a single all-items request.
@MainActor
@Observable
public final class LibraryBrowseViewModel {
    /// State of the *first* page load. Subsequent page loads append to the
    /// already-loaded items and surface via `isLoadingNextPage` / `pageError`
    /// instead of replacing this state, so a late failure never wipes content.
    public private(set) var state: LoadState<[MediaItem]> = .idle

    /// Accumulated items across all loaded pages.
    public private(set) var items: [MediaItem] = []
    /// Total items reported by the server across all pages (0 until first load).
    public private(set) var totalCount: Int = 0
    /// True while a *follow-up* page is loading (not the first page).
    public private(set) var isLoadingNextPage = false
    /// A non-fatal error from loading a follow-up page, if any.
    public private(set) var pageError: AppError?

    private let provider: any MediaProvider
    private let containerID: String
    private let pageSize: Int
    private var nextPage: PageRequest

    public init(
        provider: any MediaProvider,
        containerID: String,
        pageSize: Int = PageRequest.defaultLimit
    ) {
        self.provider = provider
        self.containerID = containerID
        self.pageSize = pageSize
        self.nextPage = PageRequest(startIndex: 0, limit: pageSize)
    }

    /// Whether more pages remain to be fetched.
    public var canLoadMore: Bool { items.count < totalCount }

    /// Loads (or reloads) the first page.
    public func loadFirstPage() async {
        state = .loading
        items = []
        totalCount = 0
        pageError = nil
        nextPage = PageRequest(startIndex: 0, limit: pageSize)
        do {
            let page = try await provider.items(in: containerID, page: nextPage)
            items = page.items
            totalCount = page.totalCount
            nextPage = nextPage.next()
            state = page.items.isEmpty ? .empty : .loaded(items)
        } catch let error as AppError {
            state = .failed(error)
        } catch {
            state = .failed(.unknown(""))
        }
    }

    /// Loads the next page when the given item is near the end of what's loaded.
    /// Safe to call repeatedly; it no-ops while a page is in flight, when there
    /// is nothing more to load, or before the first page has loaded.
    public func loadMoreIfNeeded(currentItemID: String) async {
        guard state.value != nil else { return }
        guard shouldPrefetch(for: currentItemID) else { return }
        await loadNextPage()
    }

    /// Retries a previously failed follow-up page load.
    public func retryNextPage() async {
        pageError = nil
        await loadNextPage()
    }

    private func shouldPrefetch(for itemID: String) -> Bool {
        guard canLoadMore, !isLoadingNextPage, pageError == nil else { return false }
        // Trigger when the focused item is within the last page-worth of items.
        let threshold = max(items.count - pageSize / 2, 0)
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return false }
        return index >= threshold
    }

    private func loadNextPage() async {
        guard canLoadMore, !isLoadingNextPage else { return }
        isLoadingNextPage = true
        defer { isLoadingNextPage = false }
        do {
            let page = try await provider.items(in: containerID, page: nextPage)
            // Guard against duplicate ids if the library changed between pages.
            let existing = Set(items.map(\.id))
            items.append(contentsOf: page.items.filter { !existing.contains($0.id) })
            totalCount = page.totalCount
            nextPage = nextPage.next()
            state = .loaded(items)
        } catch let error as AppError {
            pageError = error
        } catch {
            pageError = .unknown("")
        }
    }
}
