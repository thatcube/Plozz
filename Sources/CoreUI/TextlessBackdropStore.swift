import CoreModels
import Foundation
import MetadataKit

#if canImport(UIKit)
import UIKit
#endif

/// Clean, textless wide art for the cards that draw a logo over their picture.
///
/// A Continue Watching card lays the show's wordmark over the show's backdrop, so
/// a backdrop that already has the title burned into it prints the name twice.
/// The server's own art is the usual culprit — anime scraped from AniDB/Shoko is
/// promotional key art built around the title — and nothing in the metadata says
/// so. Whether a picture has words in it is a fact about the pixels, and two
/// attempts to infer it from genres and provider ids were wrong in both
/// directions at once.
///
/// So don't infer it: *ask for art that is textless by construction.* The
/// metadata router already ranks TMDb's language-neutral backdrops (TMDb's
/// convention for "no lettering") ahead of English ahead of anything, and
/// already memoizes what it resolves in the persistent ``MetadataDiskCache``.
/// The only reason the card never saw that art is that the router sits at the
/// *end* of its candidate list, reached only when the server has nothing — and
/// the server always has something.
///
/// This store moves that resolution ahead of the card instead of behind it.
///
/// ### Why it publishes so late
///
/// The card reads this store synchronously while building its candidate list, so
/// an answer that lands mid-life changes the list and re-runs the image load.
/// That is only acceptable while nothing is on screen. So an entry is published
/// **after the picture has been fetched and decoded**, never merely resolved:
/// by the time a card can see a URL here, `ArtworkImageCache` can satisfy it
/// synchronously, and the switch costs no placeholder frame. Publishing on
/// resolution instead would trade a doubled title for a visible flash, which is
/// the worse of the two.
///
/// Combined with the card pinning its choice once it has painted (see
/// `FallbackAsyncImage`'s `pinIdentity`), the guarantee is: a card either shows
/// textless art from its very first frame, or shows the server's art and keeps
/// it. It never changes under the viewer.
@MainActor
public final class TextlessBackdropStore {
    public static let shared = TextlessBackdropStore()

    /// Series key → decoded, resident textless backdrop.
    private var resolved: [String: URL] = [:]
    /// In flight or already answered, so a row that re-appears never re-asks.
    private var attempted: Set<String> = []

    public init() {}

    /// The textless backdrop for `item`'s show, or `nil` if none is known *yet*.
    ///
    /// Synchronous and side-effect free so it can be read from a view body. A
    /// `nil` here is not "there is none" — it is "not in time", which the caller
    /// must treat as final for that card rather than waiting.
    public func backdrop(for item: MediaItem) -> URL? {
        resolved[Self.key(for: item)]
    }

    /// Resolves and warms `item`'s textless backdrop, once per show per session.
    ///
    /// Called from the row's existing forward-window prefetch, so the work is
    /// already done by the time the card is reached. The first-ever launch is the
    /// only one that pays a network cost: the router memoizes the URL to disk, so
    /// every later launch resolves it locally and only the picture is fetched —
    /// and that is usually already in the image cache too.
    public func warm(for item: MediaItem, variant: ArtworkImageVariant) {
        #if canImport(UIKit)
        let key = Self.key(for: item)
        guard !attempted.contains(key) else { return }
        attempted.insert(key)
        let seriesItem = Self.seriesItem(for: item)
        Task { [weak self] in
            let url = await ArtworkSession.artworkResolveLimiter.run { () -> URL? in
                if Task.isCancelled { return nil }
                return await ArtworkRouter.shared.artworkURL(.hero, for: seriesItem)
            }
            guard let url else { return }
            // Decode before publishing — see the type's note. `background: true`
            // keeps the decode off the main thread so a scrolling row never
            // stutters for art no card is waiting on.
            guard await ArtworkImageCache.shared.image(
                for: url, variant: variant, background: true
            ) != nil else { return }
            self?.publish(url, for: key)
        }
        #endif
    }

    private func publish(_ url: URL, for key: String) {
        resolved[key] = url
    }

    /// Continue Watching is one card per *show*, so an episode's art is keyed by
    /// its series — otherwise every episode of the same show resolves separately
    /// and the row asks the router once per card instead of once per show.
    static func key(for item: MediaItem) -> String {
        item.kind == .episode ? (item.seriesID ?? item.id) : item.id
    }

    private static func seriesItem(for item: MediaItem) -> MediaItem {
        item.kind == .episode ? PosterCardView.seriesArtworkItem(for: item) : item
    }
}
