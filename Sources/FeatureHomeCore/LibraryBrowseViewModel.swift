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
    ///
    /// Each slot is a small `@Observable` reference (``LibrarySlot``) rather than a
    /// bare `MediaItem?` so that filling one page mutates only *those* slots'
    /// `.item` — re-rendering just those cells — instead of touching this array
    /// property and invalidating **every** visible cell that read it. With a fast
    /// SMB library paging in every few milliseconds, whole-array observation churn
    /// was re-diffing the entire visible grid on each page fill (the scroll
    /// choppiness); per-slot observation confines each fill to its own cells. The
    /// array itself is sized once to the library total and never reassigned during
    /// paging, so reading it to subscript never registers a firing dependency.
    public private(set) var loaded: [LibrarySlot] = []
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
    /// Scan-completion refresh is relevant only to the device-local SMB catalog.
    public var isMediaShare: Bool { provider.kind == .mediaShare }
    /// Stable share id used to select this grid's status from ShareScanStatusModel.
    public var sourceServerID: String { provider.session.server.id }

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
    /// the same cell don't inflate `visibleCellCountsByPage`. Kept out of
    /// observation: it mutates on every cell appear/disappear (dozens of times a
    /// second while scrolling), and the only thing the UI cares about — the
    /// top-most visible index — is published separately via `topVisibleIndex`, so
    /// observing this raw set would needlessly churn the alphabet rail.
    @ObservationIgnored private var visibleIndices: Set<Int> = []
    /// Last index whose cell appeared. Large jumps imply a fast scroll and trigger
    /// deeper look-ahead prefetching.
    private var lastAppearedIndex: Int?
    /// Monotonic token bumped on every `loadFirstPage`. A rapid sort toggle (or a
    /// container change) can leave two first-page loads in flight on a slow/large
    /// library; each runs as its own unstructured `Task`, so neither cancels the
    /// other. Capturing the generation at request time and re-checking it after the
    /// network round-trip guarantees only the newest load applies its results —
    /// otherwise an older response could paint stale-sorted items over the grid.
    @ObservationIgnored private var loadGeneration = 0

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
        return loaded[index].item
    }

    /// The observable slot backing `index`, or `nil` when out of range. The grid
    /// passes this into a per-cell view that observes only `slot.item`, so filling
    /// one slot re-renders just that cell. Reading `loaded` here registers a
    /// dependency on the (paging-stable) array, not on any slot's contents.
    public func slot(at index: Int) -> LibrarySlot? {
        guard index >= 0, index < loaded.count else { return nil }
        return loaded[index]
    }

    /// Number of items actually loaded so far (non-placeholder). Test/diagnostic.
    public var loadedCount: Int { loaded.reduce(0) { $0 + ($1.item == nil ? 0 : 1) } }

    /// Called when a cell leaves the visible viewport. Used to cancel stale,
    /// off-screen page loads so bandwidth/CPU goes to visible content.
    public func itemDisappeared(at index: Int) {
        guard index >= 0 else { return }
        let page = pageForIndex(index)
        guard visibleIndices.remove(index) != nil else { return }
        updateTopVisibleIndex()
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
        await noteInteractiveBrowseActivity()
        loadGeneration += 1
        let generation = loadGeneration
        state = .loading
        loaded = []
        totalCount = 0
        pageError = nil
        cancelAllPageLoads()
        pagesInFlight = []
        pagesLoaded = []
        visibleCellCountsByPage = [:]
        visibleIndices = []
        topVisibleIndex = nil
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
            guard !Task.isCancelled, generation == loadGeneration else { return }
            totalCount = page.totalCount
            loaded = Self.makeSlots(count: page.totalCount)
            fill(page)
            pagesLoaded.insert(0)
            state = page.totalCount == 0 ? .empty : .loaded(page.totalCount)
            loadLetterIndexIfNeeded()
        } catch is CancellationError {
            return
        } catch let error as AppError {
            PlozzLog.app.error("LibraryBrowse: first page failed for \(containerID): \(String(describing: error))")
            guard generation == loadGeneration else { return }
            state = .failed(error)
        } catch {
            PlozzLog.app.error("LibraryBrowse: first page failed for \(containerID): \(String(describing: error))")
            guard generation == loadGeneration else { return }
            state = .failed(.unknown(""))
        }
    }

    /// Silently replace stale sparse pages after an SMB catalog scan completes.
    /// Unlike `loadFirstPage`, this keeps the current loaded/empty presentation
    /// until the fresh first page arrives, avoiding a full-screen loading flash.
    /// Resetting `pagesLoaded` ensures any currently-visible deeper page refetches
    /// against the new catalog instead of retaining pre-scan cards.
    public func refreshAfterCatalogChange() async {
        switch state {
        case .idle, .loading: return
        case .loaded, .empty, .failed: break
        }
        loadGeneration += 1
        let generation = loadGeneration
        let visiblePages = Set(visibleIndices.map(pageForIndex)).subtracting([0])
        do {
            let firstPage = try await Self.fetchPage(
                provider: provider,
                containerID: containerID,
                containerKind: containerKind,
                request: pageRequest(forPage: 0),
                priority: .userInitiated
            )
            var refreshed: [(index: Int, page: MediaPage)] = [(0, firstPage)]
            // Local SQLite reads are fast; fetch every currently-visible page before
            // replacing slots so focused content never turns into a placeholder.
            for pageIndex in visiblePages.sorted()
                where startIndex(forPage: pageIndex) < firstPage.totalCount {
                let page = try await Self.fetchPage(
                    provider: provider,
                    containerID: containerID,
                    containerKind: containerKind,
                    request: pageRequest(forPage: pageIndex),
                    priority: .userInitiated
                )
                refreshed.append((pageIndex, page))
            }
            guard !Task.isCancelled, generation == loadGeneration else { return }
            cancelAllPageLoads()
            pagesInFlight = []
            pagesLoaded = []
            pageError = nil
            totalCount = firstPage.totalCount
            loaded = Self.makeSlots(count: firstPage.totalCount)
            for entry in refreshed {
                fill(entry.page)
                pagesLoaded.insert(entry.index)
            }
            state = firstPage.totalCount == 0 ? .empty : .loaded(firstPage.totalCount)
            letterIndexTask?.cancel()
            letterEntries = []
            loadLetterIndexIfNeeded()
        } catch {
            // Keep the still-usable old page on a transient refresh failure; normal
            // page/retry behavior remains available.
            PlozzLog.app.error(
                "LibraryBrowse: catalog refresh failed for \(containerID): \(String(describing: error))"
            )
        }
    }

    /// Applies the app's provider-neutral watch-state mutation directly to loaded
    /// slots. Plex, Jellyfin, SMB, and future share transports all use this path, so
    /// badges and progress bars update immediately without a provider refetch.
    public func applyWatchedState(_ mutation: MediaItemMutation) {
        for slot in loaded {
            guard let item = slot.item else { continue }
            let updated = mutation.applied(to: item)
            if updated != item {
                slot.item = updated
            }
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
    /// Stored — not computed off `visibleIndices` — so the alphabet rail (its only
    /// observer) re-renders solely when the top row crosses into a new index, not
    /// on every one of the dozens of cell appear/disappear ticks a scroll fires.
    /// Retains its last non-nil value while the grid momentarily recycles every
    /// visible cell, so the highlight doesn't flash back to the first letter
    /// mid-library.
    public private(set) var topVisibleIndex: Int?

    /// Recompute `topVisibleIndex` from the live visible set, publishing only a
    /// genuine change and never nil-ing out during a transient empty frame, so the
    /// rail highlight stays put and observers aren't churned needlessly.
    private func updateTopVisibleIndex() {
        guard let newTop = visibleIndices.min() else { return }
        if topVisibleIndex != newTop { topVisibleIndex = newTop }
    }

    /// Called when the cell at `index` appears. Loads the page that owns `index`
    /// (and prefetches the next page when `index` is in the back half of its
    /// page) so content arrives just ahead of the user's scroll.
    public func itemAppeared(at index: Int) async {
        guard !Task.isCancelled, state.value != nil, index >= 0, index < totalCount else { return }
        let page = pageForIndex(index)
        if visibleIndices.insert(index).inserted {
            visibleCellCountsByPage[page, default: 0] += 1
            updateTopVisibleIndex()
        }
        await noteInteractiveBrowseActivity()
        guard !Task.isCancelled, visibleIndices.contains(index) else { return }
        await ensurePageLoaded(page)
        let lookAhead = prefetchLookAheadPages(for: index, inPage: page)
        if lookAhead > 0 {
            for offset in 1...lookAhead {
                schedulePageLoad(page + offset)
            }
        }
        pruneInFlightPages(around: page, lookAhead: lookAhead)
        if visibleIndices.contains(index) { lastAppearedIndex = index }
    }

    private func ensurePageLoaded(_ page: Int) async {
        guard let task = startPageLoadIfNeeded(page) else { return }
        await task.value
    }

    private func schedulePageLoad(_ page: Int) {
        _ = startPageLoadIfNeeded(page)
    }

    /// Kicks off loading for the page a rail jump is about to land on — plus the
    /// following page, which covers the rest of the on-screen viewport after a
    /// `.top`-anchored jump — at interactive priority, *before* the scroll
    /// completes. Without this, a deep jump into a large library lands on
    /// non-focusable placeholder cells (pages only load once their cells appear),
    /// so moving focus into the grid can feel stuck until the round-trip finishes.
    /// The target's cells will re-await this same in-flight task when they appear,
    /// so there is no duplicate request; small libraries jump within the first
    /// (already-loaded) page, so this is effectively a no-op for them.
    public func prepareJump(toIndex index: Int) {
        guard index >= 0, index < totalCount else { return }
        let page = pageForIndex(index)
        _ = startPageLoadIfNeeded(page, priority: .userInitiated)
        _ = startPageLoadIfNeeded(page + 1, priority: .userInitiated)
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

    private func startPageLoadIfNeeded(_ page: Int, priority forcedPriority: TaskPriority? = nil) -> Task<Void, Never>? {
        guard page >= 0 else { return nil }
        let start = startIndex(forPage: page)
        guard start < totalCount else { return nil }
        guard !pagesLoaded.contains(page) else { return nil }
        if let existing = pageTasks[page] { return existing }

        pagesInFlight.insert(page)
        let request = pageRequest(forPage: page)
        let priority: TaskPriority = forcedPriority ?? ((visibleCellCountsByPage[page] ?? 0) > 0 ? .userInitiated : .utility)
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
                // Keep `state` (which drives the grid's rendered `0..<total` range)
                // in step with the corrected count — otherwise the grid keeps
                // rendering the old total, leaving new items unreachable or stale
                // placeholder slots behind.
                state = response.totalCount == 0 ? .empty : .loaded(response.totalCount)
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

    /// Writes a fetched page's items into their absolute slots. Mutates each
    /// slot's `.item` (per-slot observation) rather than the `loaded` array, so a
    /// fill re-renders only the affected cells — not the whole visible grid.
    private func fill(_ page: MediaPage) {
        guard !page.items.isEmpty else { return }
        if loaded.count < page.startIndex + page.items.count {
            resize(to: page.startIndex + page.items.count)
        }
        for (offset, item) in page.items.enumerated() {
            loaded[page.startIndex + offset].item = tagged(item)
        }
    }

    /// Stamps an item with this library's owning account (if any).
    private func tagged(_ item: MediaItem) -> MediaItem {
        guard let sourceAccountID else { return item }
        return item.taggingSource(sourceAccountID)
    }

    private func noteInteractiveBrowseActivity() async {
        guard let interactive = provider as? any InteractiveBrowseActivityReporting else { return }
        await interactive.noteInteractiveBrowseActivity()
    }

    /// A fresh array of `count` empty placeholder slots. Each is a distinct
    /// instance (never `Array(repeating:)`, which would share one slot across
    /// every index).
    private static func makeSlots(count: Int) -> [LibrarySlot] {
        guard count > 0 else { return [] }
        return (0..<count).map { _ in LibrarySlot() }
    }

    private func resize(to count: Int) {
        if count > loaded.count {
            loaded.append(contentsOf: Self.makeSlots(count: count - loaded.count))
        } else if count < loaded.count {
            loaded.removeLast(loaded.count - count)
        }
    }
}

/// One grid slot's contents: an `@Observable` box holding the loaded `MediaItem`
/// (or `nil` while it's still a placeholder). Boxing each slot separately means a
/// page fill mutates only the touched slots' `.item`, re-rendering just those
/// cells instead of every cell that read the parent `loaded` array. See
/// ``LibraryBrowseViewModel/loaded``.
@MainActor
@Observable
public final class LibrarySlot {
    public var item: MediaItem?
    public init(_ item: MediaItem? = nil) { self.item = item }
}
