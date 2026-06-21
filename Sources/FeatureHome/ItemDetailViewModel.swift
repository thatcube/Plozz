import Foundation
import Observation
import CoreModels
import RatingsService

/// Loads full detail for an item plus its children (episodes/seasons), and
/// asynchronously enriches it with external ratings (IMDb/RT/Metacritic).
@MainActor
@Observable
public final class ItemDetailViewModel {
    public struct Detail: Equatable, Sendable {
        public var item: MediaItem
        public var children: [MediaItem]
    }

    public private(set) var state: LoadState<Detail> = .idle

    private let provider: any MediaProvider
    private let itemID: String
    private let ratingsProvider: any ExternalRatingsProviding

    public init(
        provider: any MediaProvider,
        itemID: String,
        ratingsProvider: any ExternalRatingsProviding = DisabledRatingsProvider()
    ) {
        self.provider = provider
        self.itemID = itemID
        self.ratingsProvider = ratingsProvider
    }

    public func load() async {
        state = .loading
        do {
            let item = try await provider.item(id: itemID)
            // Series/seasons have children to list; leaf items don't.
            let children: [MediaItem]
            switch item.kind {
            case .series, .season, .folder, .collection:
                children = try await provider.children(of: itemID)
            default:
                children = []
            }
            state = .loaded(Detail(item: item, children: children))
            await enrichRatings(for: item)
        } catch let error as AppError {
            state = .failed(error)
        } catch {
            state = .failed(.unknown(""))
        }
    }

    /// Fetches external ratings off the critical path and merges them into the
    /// already-loaded detail. Failures are silent — the screen keeps whatever
    /// backend-native ratings it already has.
    private func enrichRatings(for item: MediaItem) async {
        let external = await ratingsProvider.ratings(for: item)
        guard !external.isEmpty else { return }
        guard case var .loaded(detail) = state, detail.item.id == item.id else { return }
        detail.item.ratings = detail.item.ratings.mergedWithAuthoritative(external)
        state = .loaded(detail)
    }

    /// Label for the primary action button, reflecting resume vs. play.
    public func playButtonTitle(for item: MediaItem) -> String {
        if let resume = item.resumePosition, resume > 1 {
            return "Resume"
        }
        return "Play"
    }
}
