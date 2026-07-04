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
    private let firstPageSize: Int
    private let subsequentPageSize: Int
    private let defaults: UserDefaults
    /// The account this library belongs to, stamped onto every emitted item so a
    /// tapped grid cell routes to the right provider. `nil` outside aggregated flows.
    private let sourceAccountID: String?

    /// The order the grid is currently sorted by. Changing it via `setSort`
    /// restarts paging from the first page and persists the choice per container
    /// kind so it is restored next time a library of that kind is opened.
    public private(set) var sort: CoreModels.SortDescriptor

    /// The A–Z fast-scroll rail's jump targets: for each present letter, the
    /// grid index of its first item in the current sort. Populated (once, off the
    /// first page) only when sorting by **name** and the library is big enough to
    /// be worth an index; empty for every other sort, so the rail simply hides.
    public private(set) var letterEntries: [LibraryLetterIndexEntry] = []

    /// Whether the trailing alphabet rail should be shown — true only when a
    /// name-sort letter index resolved with at least a couple of letters.
    public var showsLetterRail: Bool { letterEntries.count > 1 }

    /// Below this library size the alphabet rail isn't worth showing (a short
    /// list scrolls fine on its own) or the round-trips to build it.
    private static let minItemsForLetterRail = 30

    /// In-flight letter-index build, cancelled when the sort changes or the grid
    /// reloads so a stale index never lands over a new sort.
    private var letterIndexTask: Task<Void, Never>?

    /// Page indices whose load is in flight — guards against duplicate requests
    /// for the same page when several of its cells appear at once.
    private var pagesInFlight: Set<Int> = []
    /// Page indices that have been fully loaded.
    private var pagesLoaded: Set<Int> = []
    /// Page load tasks keyed by page index. Coalesces concurrent requests for a
    /// page and lets stale/off-screen prefetches be cancelled.
    private var pageTasks: [Int: Task<Void, Never>] = [:]
    /// Visible-cell reference count per page. Used to keep visible-page loads alive
    /// while allowing off-screen page loads to be cancelled.
    private var visibleCellCountsByPage: [Int: Int] = [:]
    /// Tracks the currently visible indices so repeated `.task(id:)` restarts for
    /// the same cell don't inflate `visibleCellCountsByPage`.
    private var visibleIndices: Set<Int> = []
    /// Last index whose cell appeared. Large jumps imply a fast scroll and trigger
    /// deeper look-ahead prefetching.
    private var lastAppearedIndex: Int?

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
        let tuned = Self.tunedPageSizes(for: pageSize)
        self.firstPageSize = tuned.first
        self.subsequentPageSize = tuned.subsequent
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

    /// Called when a cell leaves the visible viewport. Used to cancel stale,
    /// off-screen page loads so bandwidth/CPU goes to visible content.
    public func itemDisappeared(at index: Int) {
        guard index >= 0 else { return }
        let page = pageForIndex(index)
        guard visibleIndices.remove(index) != nil else { return }
        let remaining = max(0, (visibleCellCountsByPage[page] ?? 0) - 1)
        if remaining == 0 {
            visibleCellCountsByPage[page] = nil
            if !pagesLoaded.contains(page) {
                cancelPageLoad(page)
            }
        } else {
            visibleCellCountsByPage[page] = remaining
        }
        let centerPage = lastAppearedIndex.map(pageForIndex) ?? page
        pruneInFlightPages(around: centerPage, lookAhead: 1)
    }

    /// Loads (or reloads) the first page and sizes the grid to the full library.
    public func loadFirstPage() async {
        state = .loading
        loaded = []
        totalCount = 0
        pageError = nil
        cancelAllPageLoads()
        pagesInFlight = []
        pagesLoaded = []
        visibleCellCountsByPage = [:]
        visibleIndices = []
        lastAppearedIndex = nil
        letterIndexTask?.cancel()
        letterEntries = []
        PlozzLog.app.info(
            "LibraryBrowse: loading first page for \(containerID) (\(containerKind.rawValue)) firstPage=\(firstPageSize) steadyPage=\(subsequentPageSize)"
        )
        do {
            let page = try await Self.fetchPage(
                provider: provider,
                containerID: containerID,
                containerKind: containerKind,
                request: pageRequest(forPage: 0),
                priority: .userInitiated
            )
            guard !Task.isCancelled else { return }
            totalCount = page.totalCount
            loaded = Array(repeating: nil, count: page.totalCount)
            fill(page)
            pagesLoaded.insert(0)
            state = page.totalCount == 0 ? .empty : .loaded(page.totalCount)
            loadLetterIndexIfNeeded()
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

    /// Builds the alphabet fast-scroll index in the background when the grid is
    /// sorted by name and large enough to warrant it. The provider returns an
    /// empty index for any other sort (or when it can't compute one), so the
    /// rail stays hidden. Runs once per browse session — cheap for Plex (one
    /// facet request), a bounded concurrent count fan-out for Jellyfin — and is
    /// cancelled if the sort changes before it lands.
    private func loadLetterIndexIfNeeded() {
        letterIndexTask?.cancel()
        guard sort.field == .name, totalCount >= Self.minItemsForLetterRail else {
            letterEntries = []
            return
        }
        let sortAtRequest = sort
        letterIndexTask = Task { [weak self] in
            guard let self else { return }
            let entries = (try? await self.provider.letterIndex(
                in: self.containerID, kind: self.containerKind, sort: sortAtRequest
            )) ?? []
            guard !Task.isCancelled, sortAtRequest == self.sort else { return }
            self.letterEntries = entries
        }
    }

    /// The rail letter whose range currently contains `index` — the last entry
    /// whose `startIndex` is `<= index`. Drives the "you are here" highlight as
    /// the grid scrolls. `nil` when there is no index or `index` precedes the
    /// first entry.
    public func letter(forIndex index: Int) -> String? {
        var match: String?
        for entry in letterEntries {
            if entry.startIndex <= index { match = entry.letter } else { break }
        }
        return match
    }

    /// The top-most currently-visible grid index (smallest visible index), used
    /// to keep the rail's current-letter highlight in sync with a manual scroll.
    public var topVisibleIndex: Int? { visibleIndices.min() }

    /// Called when the cell at `index` appears. Loads the page that owns `index`
    /// (and prefetches the next page when `index` is in the back half of its
    /// page) so content arrives just ahead of the user's scroll.
    public func itemAppeared(at index: Int) async {
        guard !Task.isCancelled, state.value != nil, index >= 0, index < totalCount else { return }
        let page = pageForIndex(index)
        if visibleIndices.insert(index).inserted {
            visibleCellCountsByPage[page, default: 0] += 1
        }
        await ensurePageLoaded(page)
        let lookAhead = prefetchLookAheadPages(for: index, inPage: page)
        if lookAhead > 0 {
            for offset in 1...lookAhead {
                schedulePageLoad(page + offset)
            }
        }
        pruneInFlightPages(around: page, lookAhead: lookAhead)
        lastAppearedIndex = index
    }

    private func ensurePageLoaded(_ page: Int) async {
        guard let task = startPageLoadIfNeeded(page) else { return }
        await task.value
    }

    private func schedulePageLoad(_ page: Int) {
        _ = startPageLoadIfNeeded(page)
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

    /// Tuned paging plan for library browse. The default provider limit (60) is
    /// split into a small first page for near-instant first paint and a larger
    /// steady-state page size for efficient long-scroll throughput.
    static func tunedPageSizes(for requestedPageSize: Int) -> (first: Int, subsequent: Int) {
        let clamped = max(requestedPageSize, 1)
        guard clamped == PageRequest.defaultLimit else { return (clamped, clamped) }
        let first = min(clamped, 7 * 4)        // 4 visible rows in a 7-column grid.
        let subsequent = min(clamped, 7 * 6)   // 6-row steady-state balance.
        return (max(first, 1), max(subsequent, 1))
    }

    private func pageRequest(forPage page: Int) -> PageRequest {
        PageRequest(
            startIndex: startIndex(forPage: page),
            limit: pageSpan(forPage: page),
            sort: sort
        )
    }

    private func startIndex(forPage page: Int) -> Int {
        if page <= 0 { return 0 }
        return firstPageSize + (page - 1) * subsequentPageSize
    }

    private func pageSpan(forPage page: Int) -> Int {
        page <= 0 ? firstPageSize : subsequentPageSize
    }

    private func pageForIndex(_ index: Int) -> Int {
        guard index >= firstPageSize else { return 0 }
        return 1 + ((index - firstPageSize) / max(subsequentPageSize, 1))
    }

    private func maxLookAheadPages(fromPage page: Int) -> Int {
        guard totalCount > 0 else { return 0 }
        let lastPage = pageForIndex(totalCount - 1)
        return max(0, lastPage - page)
    }

    private func prefetchLookAheadPages(for index: Int, inPage page: Int) -> Int {
        let pageStart = startIndex(forPage: page)
        let pageLength = max(pageSpan(forPage: page), 1)
        let indexInPage = index - pageStart
        var lookAhead = indexInPage >= pageLength / 2 ? 1 : 0
        if let previous = lastAppearedIndex {
            let jump = abs(index - previous)
            if jump >= pageLength * 2 {
                lookAhead = max(lookAhead, 3)
            } else if jump >= pageLength {
                lookAhead = max(lookAhead, 2)
            }
        }
        return min(lookAhead, maxLookAheadPages(fromPage: page))
    }

    private func startPageLoadIfNeeded(_ page: Int) -> Task<Void, Never>? {
        guard page >= 0 else { return nil }
        let start = startIndex(forPage: page)
        guard start < totalCount else { return nil }
        guard !pagesLoaded.contains(page) else { return nil }
        if let existing = pageTasks[page] { return existing }

        pagesInFlight.insert(page)
        let request = pageRequest(forPage: page)
        let priority: TaskPriority = (visibleCellCountsByPage[page] ?? 0) > 0 ? .userInitiated : .utility
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performPageLoad(page: page, request: request, priority: priority)
        }
        pageTasks[page] = task
        return task
    }

    private func performPageLoad(page: Int, request: PageRequest, priority: TaskPriority) async {
        defer { finishPageLoad(page) }
        do {
            let response = try await Self.fetchPage(
                provider: provider,
                containerID: containerID,
                containerKind: containerKind,
                request: request,
                priority: priority
            )
            guard !Task.isCancelled else { return }
            if response.totalCount != totalCount {
                totalCount = response.totalCount
                resize(to: response.totalCount)
                pagesLoaded = Set(pagesLoaded.filter { startIndex(forPage: $0) < response.totalCount })
            }
            fill(response)
            pagesLoaded.insert(page)
            pageError = nil
            cancelOutOfRangeInFlightPages()
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

    private func finishPageLoad(_ page: Int) {
        pageTasks[page] = nil
        pagesInFlight.remove(page)
    }

    private func cancelPageLoad(_ page: Int) {
        guard !pagesLoaded.contains(page) else { return }
        if let task = pageTasks[page] {
            task.cancel()
            pageTasks[page] = nil
        }
        pagesInFlight.remove(page)
    }

    private func cancelAllPageLoads() {
        for task in pageTasks.values {
            task.cancel()
        }
        pageTasks = [:]
    }

    private func pruneInFlightPages(around page: Int, lookAhead: Int) {
        let minKeep = max(0, page - 1)
        let maxKeep = page + max(lookAhead, 1) + 1
        for candidate in Array(pageTasks.keys) {
            if (visibleCellCountsByPage[candidate] ?? 0) > 0 { continue }
            if candidate < minKeep || candidate > maxKeep {
                cancelPageLoad(candidate)
            }
        }
    }

    private func cancelOutOfRangeInFlightPages() {
        for page in Array(pageTasks.keys) where startIndex(forPage: page) >= totalCount {
            cancelPageLoad(page)
        }
    }

    private nonisolated static func fetchPage(
        provider: any MediaProvider,
        containerID: String,
        containerKind: MediaItemKind,
        request: PageRequest,
        priority: TaskPriority
    ) async throws -> MediaPage {
        let task = Task.detached(priority: priority) {
            try await provider.items(in: containerID, kind: containerKind, page: request)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
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
