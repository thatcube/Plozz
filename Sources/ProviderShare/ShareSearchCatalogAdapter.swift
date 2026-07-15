import Foundation
import CoreModels

/// Side-effect-free view of an existing share catalog.
///
/// The adapter deliberately cannot create a store, trigger a scan/enrichment
/// pass, access credentials, or acquire a transport lease. All media-share
/// transports converge into the same committed SQLite catalog.
public struct ShareSearchCatalogAdapter: SearchCatalogProviding {
    public let accountID: String
    private let coordinator: ShareCatalogCoordinator

    public init(accountID: String, coordinator: ShareCatalogCoordinator) {
        self.accountID = accountID
        self.coordinator = coordinator
    }

    public func searchCatalogPage(
        _ request: SearchCatalogPageRequest
    ) async throws -> SearchCatalogPage {
        let offset: Int
        if let cursor = request.cursor {
            guard let decoded = try? JSONDecoder().decode(
                ShareSearchCatalogCursor.self,
                from: cursor
            ) else {
                throw AppError.decoding
            }
            offset = decoded.offset
        } else {
            offset = 0
        }
        guard let store = await coordinator.existingStore(accountKey: accountID) else {
            return SearchCatalogPage(records: [], nextCursor: nil, totalCount: 0)
        }
        let page = await store.searchCatalogItems(
            libraryID: request.libraryID,
            kind: request.kind,
            offset: offset,
            limit: request.limit
        )
        let nextCursor: Data?
        if !page.items.isEmpty, page.hasMore {
            nextCursor = try JSONEncoder().encode(
                ShareSearchCatalogCursor(offset: page.endIndex)
            )
        } else {
            nextCursor = nil
        }
        return SearchCatalogPage(
            records: page.items.map { SearchCatalogRecord(item: $0) },
            nextCursor: nextCursor,
            totalCount: page.totalCount
        )
    }
}

private struct ShareSearchCatalogCursor: Codable {
    let offset: Int
}
