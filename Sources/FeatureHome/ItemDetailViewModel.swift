import Foundation
import Observation
import CoreModels

/// Loads full detail for an item plus its children (episodes/seasons).
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

    public init(provider: any MediaProvider, itemID: String) {
        self.provider = provider
        self.itemID = itemID
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
        } catch let error as AppError {
            state = .failed(error)
        } catch {
            state = .failed(.unknown(""))
        }
    }

    /// Label for the primary action button, reflecting resume vs. play.
    public func playButtonTitle(for item: MediaItem) -> String {
        if let resume = item.resumePosition, resume > 1 {
            return "Resume"
        }
        return "Play"
    }
}
