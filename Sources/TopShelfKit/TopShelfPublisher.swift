import Foundation
import CoreModels

/// Maps the app's domain models onto a `TopShelfSnapshot` and publishes it to
/// the shared App Group container for the Top Shelf extension to render.
///
/// This file imports `CoreModels`, so it is compiled **only** into the app (via
/// the `TopShelfKit` package). The extension compiles just `TopShelfSnapshot`
/// and `TopShelfStore`, keeping `CoreModels` out of its memory budget.
public enum TopShelfPublisher {
    /// Builds and saves a snapshot from the Home screen's two playable rows.
    ///
    /// Empty rows are dropped; if nothing is playable the snapshot is still
    /// written (empty) so a freshly-signed-out state clears the shelf.
    public static func publish(continueWatching: [MediaItem], latest: [MediaItem]) {
        var sections: [TopShelfSnapshot.Section] = []

        let resume = items(from: continueWatching)
        if !resume.isEmpty {
            sections.append(.init(id: "continue", title: "Continue Watching", items: resume))
        }

        let recent = items(from: latest)
        if !recent.isEmpty {
            sections.append(.init(id: "latest", title: "Recently Added", items: recent))
        }

        TopShelfStore.save(TopShelfSnapshot(sections: sections))
    }

    private static func items(from media: [MediaItem]) -> [TopShelfSnapshot.Item] {
        media.map { item in
            TopShelfSnapshot.Item(
                id: item.id,
                title: item.title,
                subtitle: item.subtitle,
                imageURL: item.posterURL ?? item.backdropURL,
                playbackProgress: item.playedPercentage
            )
        }
    }
}
