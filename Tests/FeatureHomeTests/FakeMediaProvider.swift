import Foundation
import CoreModels

/// In-memory `MediaProvider` for testing feature view models without a network.
/// Only `items(in:page:)` is meaningfully implemented; other methods are stubs.
final class FakeMediaProvider: MediaProvider, @unchecked Sendable {
    let kind: ProviderKind = .jellyfin
    let session: UserSession

    /// Full backing list a container pages through.
    var allItems: [MediaItem]
    /// Optional per-parent children for `children(of:)`. When `nil`, the legacy
    /// behaviour (return `allItems`) is preserved for existing tests.
    var childrenByParent: [String: [MediaItem]]?
    /// How many times `children(of:)` was called for each parent id.
    private(set) var childrenCallCount: [String: Int] = [:]
    /// How many times `item(id:)` was called for each item id.
    private(set) var itemCallCounts: [String: Int] = [:]
    func itemCallCount(for id: String) -> Int { itemCallCounts[id, default: 0] }
    /// Optional per-item trailers for `trailers(of:)`. Inherits the protocol's
    /// empty default when `nil`.
    var trailersByItem: [String: [MediaItem]]?
    /// Optional per-item async gate that runs before `item(id:)` returns.
    var itemGate: [String: @Sendable () async -> Void]?
    /// Optional start index at which `items(in:page:)` throws once.
    var failAtStartIndex: Int?
    /// When `true`, every `items(in:page:)` call throws — simulates a server that
    /// is offline for the whole browse session.
    var alwaysFail = false
    private(set) var requestedPages: [PageRequest] = []
    /// Optional hook called as soon as `items(in:page:)` is requested.
    var onItemsRequest: (@Sendable (PageRequest) -> Void)?
    /// Optional per-page async hook that runs before the page response is returned.
    /// Useful for tests that need to hold/cancel a page load while it is in-flight.
    var pageHooks: [Int: @Sendable () async throws -> Void] = [:]
    /// Start indices whose page request was cancelled while awaiting `pageHooks`.
    private(set) var cancelledPageStartIndices: [Int] = []

    init(allItems: [MediaItem]) {
        self.allItems = allItems
        self.session = UserSession(
            server: MediaServer(id: "s", name: "Home", baseURL: URL(string: "http://host:8096")!, provider: .jellyfin),
            userID: "u1", userName: "Alice", deviceID: "d1", accessToken: "TOKEN"
        )
    }

    func libraries() async throws -> [MediaLibrary] {
        librariesCallCount += 1
        return []
    }
    /// How many times `libraries()` was called — lets a test prove whether the
    /// Home aggregator re-ran (e.g. that a redundant reload was skipped).
    private(set) var librariesCallCount = 0
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem {
        itemCallCounts[id, default: 0] += 1
        if let gate = itemGate?[id] {
            await gate()
        }
        guard let item = allItems.first(where: { $0.id == id }) else { throw AppError.notFound }
        return item
    }
    /// Optional gate that, when present for a given parent id, suspends the
    /// `children(of:)` call until released. Lets tests observe state published
    /// between an item arriving and its children arriving.
    var childrenGate: [String: @Sendable () async -> Void]?

    func children(of itemID: String) async throws -> [MediaItem] {
        childrenCallCount[itemID, default: 0] += 1
        if let gate = childrenGate?[itemID] {
            await gate()
        }
        if let childrenByParent {
            return childrenByParent[itemID] ?? []
        }
        return allItems
    }

    func trailers(for itemID: String) async throws -> [MediaItem] {
        guard let trailersByItem else { return [] }
        return trailersByItem[itemID] ?? []
    }

    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        requestedPages.append(page)
        if alwaysFail { throw AppError.serverUnreachable }
        onItemsRequest?(page)
        do {
            if let hook = pageHooks[page.startIndex] {
                try await hook()
            }
        } catch is CancellationError {
            cancelledPageStartIndices.append(page.startIndex)
            throw CancellationError()
        }
        if let failAt = failAtStartIndex, failAt == page.startIndex {
            failAtStartIndex = nil
            throw AppError.serverUnreachable
        }
        let start = min(page.startIndex, allItems.count)
        let end = min(start + page.limit, allItems.count)
        return MediaPage(
            items: Array(allItems[start..<end]),
            startIndex: page.startIndex,
            totalCount: allItems.count
        )
    }

    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }

    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}

func makeItems(_ count: Int) -> [MediaItem] {
    (0..<count).map { MediaItem(id: "i\($0)", title: "Item \($0)", kind: .movie) }
}
