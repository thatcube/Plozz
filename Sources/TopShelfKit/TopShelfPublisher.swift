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
    /// Continue-Watching items that are mid-playback get a poster with the resume
    /// bar composited into the artwork (posters can't show the native Top Shelf
    /// progress bar — see `TopShelfPosterComposer`); everything else uses its
    /// plain remote poster. Empty rows are dropped; if nothing is playable the
    /// snapshot is still written (empty) so a freshly-signed-out state clears the
    /// shelf. Stale composited art is pruned each publish.
    public static func publish(continueWatching: [MediaItem], latest: [MediaItem]) async {
        var sections: [TopShelfSnapshot.Section] = []

        let resume = await items(from: continueWatching, compositeProgress: true)
        if !resume.isEmpty {
            sections.append(.init(id: "continue", title: "Continue Watching", items: resume))
        }

        let recent = await items(from: latest)
        if !recent.isEmpty {
            sections.append(.init(id: "latest", title: "Recently Added", items: recent))
        }

        // Drop any composited poster no longer referenced by this snapshot.
        let keptArtwork = Set(
            sections
                .flatMap(\.items)
                .compactMap(\.imageURL)
                .filter(\.isFileURL)
                .map(\.lastPathComponent)
        )
        TopShelfStore.pruneArtwork(keeping: keptArtwork)

        TopShelfStore.save(TopShelfSnapshot(sections: sections))
    }

    /// Maps domain items onto snapshot items. When `compositeProgress` is set, a
    /// mid-playback item's poster is replaced by a locally composited poster that
    /// has the progress bar burned in; on any failure it falls back to the plain
    /// remote poster (still a poster card, just without a bar).
    private static func items(
        from media: [MediaItem],
        compositeProgress: Bool = false
    ) async -> [TopShelfSnapshot.Item] {
        var result: [TopShelfSnapshot.Item] = []
        result.reserveCapacity(media.count)

        for item in media {
            let posterURL = Self.posterArtworkURL(for: item)
            var imageURL = posterURL

            if compositeProgress,
               let progress = item.playedPercentage,
               let poster = posterURL,
               let composited = await TopShelfPosterComposer.compositedPosterURL(
                   id: item.id, posterURL: poster, progress: progress
               ) {
                imageURL = composited
            }

            result.append(
                TopShelfSnapshot.Item(
                    id: item.id,
                    title: item.title,
                    subtitle: item.subtitle,
                    imageURL: imageURL,
                    playbackProgress: item.playedPercentage
                )
            )
        }

        return result
    }

    /// Picks true **vertical poster** art (2:3) for the shelf card, mirroring
    /// `PosterCardView.artworkCandidates(for: .poster)`: an episode uses its
    /// *series* poster (never its own 16:9 still), then its own poster, then the
    /// spoiler-safe parent fallback. A 16:9 backdrop is deliberately *not* a
    /// candidate — stretching it into a poster frame is what made some cards look
    /// massively zoomed. May be `nil` when the item has no vertical art at all.
    private static func posterArtworkURL(for item: MediaItem) -> URL? {
        if item.kind == .episode {
            return item.seriesPosterURL ?? item.posterURL ?? item.fallbackArtworkURL
        }
        return item.posterURL ?? item.fallbackArtworkURL
    }
}
