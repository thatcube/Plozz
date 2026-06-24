import Foundation
import Observation
import CoreModels
import CoreNetworking

/// Drives a *sparse* library grid: it loads the first page to learn the
/// library's total size, then lazily fetches each further page only when a cell
/// that belongs to it scrolls into view. The grid is sized to the full
/// `totalCount` up front (so the scroll bar reflects the whole library and tiles
/// render as placeholders until their page arrives), which keeps libraries with
/// hundreds or thousands of items fast and memory-light — only on-screen pages
/// are ever requested or held.
@MainActor
@Observable
public final class LibraryBrowseViewModel {
    /// State of the *first* page load, whose value is the library's total item
    /// count. Once loaded, individual pages fill in behind the scenes via
    /// `loaded` without disturbing this state, so a late page failure never
    /// wipes the grid.
    public private(set) var state: LoadState<Int> = .idle

    /// Sparse, index-addressed backing store sized to `totalCount`. A `nil`
    /// slot is a not-yet-loaded item that renders as a placeholder tile.
    public private(set) var loaded: [MediaItem?] = []
    /// Total items reported by the server (0 until the first page loads).
    public private(set) var totalCount: Int = 0
    /// A non-fatal error from loading a follow-up page, if any. Surfaced for
    /// diagnostics; the failed page is retried when its cells reappear.
    public private(set) var pageError: AppError?

    private let provider: any MediaProvider
    private let containerID: String
    private let containerKind: MediaItemKind
    private let pageSize: Int
    private let defaults: UserDefaults
    /// The account this library belongs to, stamped onto every emitted item so a
    /// tapped grid cell routes to the right provider. `nil` outside aggregated flows.
    private let sourceAccountID: String?

    /// The order the grid is currently sorted by. Changing it via `setSort`
    /// restarts paging from the first page and persists the choice per container
    /// kind so it is restored next time a library of that kind is opened.
    public private(set) var sort: CoreModels.SortDescriptor

    /// Page indices whose load is in flight — guards against duplicate requests
    /// for the same page when several of its cells appear at once.
    private var pagesInFlight: Set<Int> = []
    /// Page indices that have been fully loaded.
    private var pagesLoaded: Set<Int> = []

    public init(
        provider: any MediaProvider,
        containerID: String,
        containerKind: MediaItemKind,
        pageSize: Int = PageRequest.defaultLimit,
        defaults: UserDefaults = .standard,
        sourceAccountID: String? = nil
    ) {
        self.provider = provider
        self.containerID = containerID
        self.containerKind = containerKind
        self.pageSize = pageSize
        self.defaults = defaults
        self.sourceAccountID = sourceAccountID
        self.sort = Self.loadSort(for: containerKind, from: defaults)
    }

    /// The item at `index`, or `nil` if it hasn't been loaded yet (placeholder).
    public func item(at index: Int) -> MediaItem? {
        guard index >= 0, index < loaded.count else { return nil }
        return loaded[index]
    }

    /// Number of items actually loaded so far (non-placeholder). Test/diagnostic.
    public var loadedCount: Int { loaded.reduce(0) { $0 + ($1 == nil ? 0 : 1) } }

    /// Loads (or reloads) the first page and sizes the grid to the full library.
    public func loadFirstPage() async {
        state = .loading
        loaded = []
        totalCount = 0
        pageError = nil
        pagesInFlight = []
        pagesLoaded = []
        PlozzLog.app.info("LibraryBrowse: loading first page for \(containerID) (\(containerKind.rawValue))")
        do {
            let page = try await provider.items(in: containerID, kind: containerKind, page: pageRequest(forPage: 0))
            guard !Task.isCancelled else { return }
            totalCount = page.totalCount
            loaded = Array(repeating: nil, count: page.totalCount)
            fill(page)
            pagesLoaded.insert(0)
            state = page.totalCount == 0 ? .empty : .loaded(page.totalCount)
        } catch is CancellationError {
            return
        } catch let error as AppError {
            PlozzLog.app.error("LibraryBrowse: first page failed for \(containerID): \(String(describing: error))")
            state = .failed(error)
        } catch {
            PlozzLog.app.error("LibraryBrowse: first page failed for \(containerID): \(String(describing: error))")
            state = .failed(.unknown(""))
        }
    }

    /// Called when the cell at `index` appears. Loads the page that owns `index`
    /// (and prefetches the next page when `index` is in the back half of its
    /// page) so content arrives just ahead of the user's scroll.
    public func itemAppeared(at index: Int) async {
        guard !Task.isCancelled, state.value != nil, index >= 0, index < totalCount else { return }
        let page = index / pageSize
        await ensurePageLoaded(page)
        if index % pageSize >= pageSize / 2 {
            await ensurePageLoaded(page + 1)
        }
    }

    private func ensurePageLoaded(_ page: Int) async {
        guard page >= 0 else { return }
        let start = page * pageSize
        guard start < totalCount else { return }
        guard !pagesLoaded.contains(page), !pagesInFlight.contains(page) else { return }

        pagesInFlight.insert(page)
        defer { pagesInFlight.remove(page) }
        do {
            let response = try await provider.items(in: containerID, kind: containerKind, page: pageRequest(forPage: page))
            guard !Task.isCancelled else { return }
            // Total can shift if the library changed; keep the grid in sync.
            if response.totalCount != totalCount {
                totalCount = response.totalCount
                resize(to: response.totalCount)
            }
            fill(response)
            pagesLoaded.insert(page)
            pageError = nil
        } catch is CancellationError {
            return
        } catch let error as AppError {
            PlozzLog.app.error("LibraryBrowse: page \(page) failed for \(containerID): \(String(describing: error))")
            pageError = error
        } catch {
            PlozzLog.app.error("LibraryBrowse: page \(page) failed for \(containerID): \(String(describing: error))")
            pageError = .unknown("")
        }
    }

    private func pageRequest(forPage page: Int) -> PageRequest {
        PageRequest(startIndex: page * pageSize, limit: pageSize, sort: sort)
    }

    /// Applies a new sort order: persists the choice and, if it actually changed,
    /// resets paging and reloads the first page so the grid re-sorts from the
    /// top rather than fetching the whole library at once.
    public func setSort(_ newSort: CoreModels.SortDescriptor) async {
        guard newSort != sort else { return }
        sort = newSort
        Self.saveSort(newSort, for: containerKind, to: defaults)
        await loadFirstPage()
    }

    private static func defaultsKey(for kind: MediaItemKind) -> String {
        "LibraryBrowse.sort.\(kind.rawValue)"
    }

    private static func loadSort(for kind: MediaItemKind, from defaults: UserDefaults) -> CoreModels.SortDescriptor {
        guard
            let data = defaults.data(forKey: defaultsKey(for: kind)),
            let descriptor = try? JSONDecoder().decode(CoreModels.SortDescriptor.self, from: data)
        else { return .default }
        return descriptor
    }

    private static func saveSort(_ sort: CoreModels.SortDescriptor, for kind: MediaItemKind, to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(sort) else { return }
        defaults.set(data, forKey: defaultsKey(for: kind))
    }

    /// Writes a fetched page's items into their absolute slots.
    private func fill(_ page: MediaPage) {
        guard !page.items.isEmpty else { return }
        if loaded.count < page.startIndex + page.items.count {
            resize(to: page.startIndex + page.items.count)
        }
        for (offset, item) in page.items.enumerated() {
            loaded[page.startIndex + offset] = tagged(item)
        }
    }

    /// Stamps an item with this library's owning account (if any).
    private func tagged(_ item: MediaItem) -> MediaItem {
        guard let sourceAccountID else { return item }
        return item.taggingSource(sourceAccountID)
    }

    private func resize(to count: Int) {
        if count > loaded.count {
            loaded.append(contentsOf: Array(repeating: nil, count: count - loaded.count))
        } else if count < loaded.count {
            loaded.removeLast(loaded.count - count)
        }
    }
}
