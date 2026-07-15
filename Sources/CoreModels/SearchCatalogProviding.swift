import Foundation

/// One physical provider item ready for local search indexing.
///
/// `providerUpdatedAt` is the provider's metadata-change timestamp, not watch
/// activity. It stays outside `MediaItem` because it is indexing state rather
/// than presentation data.
public struct SearchCatalogRecord: Sendable {
    public let item: MediaItem
    public let providerUpdatedAt: Date?

    public init(item: MediaItem, providerUpdatedAt: Date? = nil) {
        self.item = item
        self.providerUpdatedAt = providerUpdatedAt
    }
}

/// A request for one stable page of one library/kind partition.
///
/// Providers own the opaque cursor encoding. `nil` starts a fresh full scan.
public struct SearchCatalogPageRequest: Equatable, Sendable {
    public let libraryID: String
    public let kind: MediaItemKind
    public let cursor: Data?
    public let limit: Int

    public init(
        libraryID: String,
        kind: MediaItemKind,
        cursor: Data? = nil,
        limit: Int = 200
    ) {
        self.libraryID = libraryID
        self.kind = kind
        self.cursor = cursor
        self.limit = max(1, limit)
    }
}

/// One provider page. A `nil` next cursor completes this library/kind scan.
public struct SearchCatalogPage: Sendable {
    public let records: [SearchCatalogRecord]
    public let nextCursor: Data?
    public let totalCount: Int?

    public init(
        records: [SearchCatalogRecord],
        nextCursor: Data?,
        totalCount: Int? = nil
    ) {
        self.records = records
        self.nextCursor = nextCursor
        self.totalCount = totalCount
    }
}

/// Optional capability for providers that can enumerate their owned catalog for
/// Plozz's fully local search index.
public protocol SearchCatalogProviding: Sendable {
    func searchCatalogPage(
        _ request: SearchCatalogPageRequest
    ) async throws -> SearchCatalogPage
}
