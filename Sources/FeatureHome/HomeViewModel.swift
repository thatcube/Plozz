import Foundation
import Observation
import CoreModels
import TopShelfKit

/// Loads and holds the Home screen's content rows.
@MainActor
@Observable
public final class HomeViewModel {
    public struct Content: Equatable, Sendable {
        public var continueWatching: [MediaItem]
        public var latest: [MediaItem]
        public var libraries: [MediaLibrary]

        public var isEmpty: Bool {
            continueWatching.isEmpty && latest.isEmpty && libraries.isEmpty
        }
    }

    public private(set) var state: LoadState<Content> = .idle

    private let provider: any MediaProvider

    public init(provider: any MediaProvider) {
        self.provider = provider
    }

    /// User-facing name for the greeting header.
    public var userName: String { provider.session.userName }

    public func load() async {
        state = .loading
        do {
            // Fetch the three rows concurrently; a failure in any one fails the
            // screen so the user sees a single, clear error/retry.
            async let resume = provider.continueWatching(limit: 20)
            async let recent = provider.latest(limit: 20)
            async let libs = provider.libraries()

            let content = Content(
                continueWatching: try await resume,
                latest: try await recent,
                libraries: try await libs
            )
            state = content.isEmpty ? .empty : .loaded(content)

            // Publish the playable rows to the App Group so the Top Shelf
            // extension can render them while the app is closed.
            TopShelfPublisher.publish(
                continueWatching: content.continueWatching,
                latest: content.latest
            )
        } catch let error as AppError {
            state = .failed(error)
        } catch {
            state = .failed(.unknown(""))
        }
    }
}
