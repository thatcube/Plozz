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
    /// Optional start index at which `items(in:page:)` throws once.
    var failAtStartIndex: Int?
    private(set) var requestedPages: [PageRequest] = []

    init(allItems: [MediaItem]) {
        self.allItems = allItems
        self.session = UserSession(
            server: MediaServer(id: "s", name: "Home", baseURL: URL(string: "http://host:8096")!, provider: .jellyfin),
            userID: "u1", userName: "Alice", deviceID: "d1", accessToken: "TOKEN"
        )
    }

    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem {
        guard let item = allItems.first(where: { $0.id == id }) else { throw AppError.notFound }
        return item
    }
    func children(of itemID: String) async throws -> [MediaItem] {
        childrenCallCount[itemID, default: 0] += 1
        if let childrenByParent {
            return childrenByParent[itemID] ?? []
        }
        return allItems
    }

    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        requestedPages.append(page)
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
