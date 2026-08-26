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
    /// - Parameter locale: the language the APP is currently showing. The Top
    ///   Shelf extension is a separate process with its own bundle, so it can
    ///   neither read the app's catalog nor know about an in-app language
    ///   override — resolving there would silently fall back to the system
    ///   language and disagree with the app. So the app resolves the section
    ///   titles here and stores finished text; the extension only renders.
    ///   Eager resolution is correct in this one case precisely because the
    ///   value crosses a process boundary.
    /// How many titles each Top Shelf section carries.
    ///
    /// The shelf is a place to *launch* from, not to browse in. What gets clicked
    /// there is something newly added or something obviously in progress; anything
    /// requiring a search through a list is a reason to open the app instead. Three
    /// per section is what Plex settles on, and it holds up: a scrollable shelf
    /// nobody scrolls is just work done for an audience of none.
    ///
    /// Deliberately independent of the on-screen row's limit, which is sixty. That
    /// row is for browsing and should hold everything; this one should not.
    private static let maxItemsPerSection = 3

    public static func publish(
        continueWatching: [MediaItem],
        latest: [MediaItem],
        locale: Locale? = nil
    ) async {
        var sections: [TopShelfSnapshot.Section] = []

        let resume = await items(from: Array(continueWatching.prefix(maxItemsPerSection)), compositeProgress: true)
        if !resume.isEmpty {
            sections.append(.init(id: "continue",
                                  title: resolved("Continue Watching", locale),
                                  items: resume))
        }

        let recent = await items(from: Array(latest.prefix(maxItemsPerSection)))
        if !recent.isEmpty {
            sections.append(.init(id: "latest",
                                  title: resolved("Recently Added", locale),
                                  items: recent))
        }

        // Drop any composited poster no longer referenced by this snapshot. Guard
        // on cancellation first: a superseded publish (a newer one started while
        // this one was awaiting image fetches) must not prune the directory the
        // winning publish is writing, nor overwrite its snapshot.
        guard !Task.isCancelled else { return }
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
            // Composited artwork is cached by this id. A bare item id is unique only
            // within one server (Plex ratingKeys are small per-server integers), so
            // two accounts would otherwise overwrite each other's poster files and a
            // card could show the wrong title's art with the wrong resume bar.
            let artworkID = TopShelfSnapshot.Item(
                id: item.id,
                accountID: item.sourceAccountID,
                title: item.title
            ).shelfIdentifier
            let posterURL = Self.posterArtworkURL(for: item)
            let progress = compositeProgress ? item.playedPercentage : nil
            var imageURL: URL?

            if let poster = posterURL {
                if let progress,
                   let composited = await TopShelfPosterComposer.compositedPosterURL(
                       id: artworkID, posterURL: poster, progress: progress
                   ) {
                    imageURL = composited
                } else {
                    imageURL = poster
                }
            } else {
                // No vertical artwork anywhere: render a neutral title-card
                // placeholder (with the resume bar burned in when mid-playback)
                // instead of leaving a blank card or a zoomed backdrop.
                imageURL = TopShelfPosterComposer.placeholderPosterURL(
                    id: artworkID, title: item.title, progress: progress
                )
            }

            result.append(
                TopShelfSnapshot.Item(
                    id: item.id,
                    accountID: item.sourceAccountID,
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

    /// Resolves a section title against the app's current language. `nil` means
    /// "follow the system", which is what `LocalizedStringResource` already does.
    private static func resolved(_ resource: LocalizedStringResource, _ locale: Locale?) -> String {
        var resource = resource
        if let locale { resource.locale = locale }
        return String(localized: resource)   // l10n:content — deliberately resolved here: the value is written to an App Group file the Top Shelf extension reads in another process
    }
}
