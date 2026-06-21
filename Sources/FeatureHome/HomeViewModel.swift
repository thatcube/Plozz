import Foundation
import Observation
import CoreModels
import TopShelfKit

/// Loads and holds the unified Home screen's content rows, merged across every
/// active account/provider. Home-visibility filtering of the Libraries row is
/// applied reactively in the view (against the shared visibility model) so the
/// network result is held unfiltered and toggles take effect without a reload.
@MainActor
@Observable
public final class HomeViewModel {
    public struct Content: Equatable, Sendable {
        public var continueWatching: [MediaItem]
        public var latest: [MediaItem]
        /// Every discovered library (unfiltered), tagged with its owning account.
        public var libraries: [AggregatedLibrary]

        public var isEmpty: Bool {
            continueWatching.isEmpty && latest.isEmpty && libraries.isEmpty
        }
    }

    public private(set) var state: LoadState<Content> = .idle

    private let accounts: [ResolvedAccount]
    private let aggregator: HomeAggregator

    public init(
        accounts: [ResolvedAccount],
        aggregator: HomeAggregator = HomeAggregator()
    ) {
        self.accounts = accounts
        self.aggregator = aggregator
    }

    /// User-facing name for the greeting header — the primary (first) account.
    public var userName: String { accounts.first?.account.userName ?? "" }

    public func load() async {
        state = .loading

        let merged = await aggregator.content(from: accounts)
        let content = Content(
            continueWatching: merged.continueWatching,
            latest: merged.latest,
            libraries: merged.libraries
        )
        state = content.isEmpty ? .empty : .loaded(content)

        // Publish the playable rows to the App Group so the Top Shelf extension
        // can render them while the app is closed.
        TopShelfPublisher.publish(
            continueWatching: content.continueWatching,
            latest: content.latest
        )
    }
}
