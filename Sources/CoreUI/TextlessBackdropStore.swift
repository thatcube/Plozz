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

    /// What the router had to say about a show's clean wide art.
    enum Outcome: Equatable {
        /// A textless backdrop, already fetched and decoded.
        case available(URL)
        /// The router looked and there is none. This is the *conclusive* answer,
        /// distinct from having no entry at all, and it is the only thing that
        /// licenses suppressing a logo.
        case none
    }

    /// Series key → what we know. Absent means "not answered yet", which is not
    /// the same as ``Outcome/none`` and must never be treated as it.
    private var outcomes: [String: Outcome] = [:]
    /// In flight or already answered, so a row that re-appears never re-asks.
    private var attempted: Set<String> = []
    /// First logo decision made for a show, kept for the session. See
    /// ``suppressesLogo(for:)``.
    private var logoDecisions: [String: Bool] = [:]

    public init() {}

    /// The textless backdrop for `item`'s show, or `nil` if none is known *yet*.
    ///
    /// Synchronous and side-effect free so it can be read from a view body. A
    /// `nil` here is not "there is none" — it is "not in time", which the caller
    /// must treat as final for that card rather than waiting.
    public func backdrop(for item: MediaItem) -> URL? {
        guard case .available(let url) = outcomes[Self.key(for: item)] else { return nil }
        return url
    }

    /// Whether this card should leave its logo off because the picture it is about
    /// to draw almost certainly has the title in it already.
    ///
    /// Two conditions, and both are required:
    ///
    /// 1. The router **conclusively** found no textless backdrop. Not "hasn't
    ///    answered" — actually looked and came back empty. When a source that
    ///    labels its own textless art has none, the art we are left with is the
    ///    server's promotional key art, which is where burned-in titles live.
    /// 2. The item is anime.
    ///
    /// Condition 2 on its own was tried and reverted: it took Arcane's logo away
    /// along with every other anime's. What makes it safe here is that it is
    /// second. Arcane fails condition 1 — TMDb has clean art for it — so it never
    /// reaches the anime test at all, and neither does any other show with a
    /// textless backdrop to its name. And because condition 1 comes first, no
    /// live-action show is affected whatever its artwork situation, so the mass
    /// logo loss cannot recur. What is left is the narrow case the row actually
    /// has: niche anime, no clean art anywhere, title baked into the only picture
    /// there is.
    ///
    /// ### Decided once per show per session
    ///
    /// Body runs constantly on tvOS — every focus move re-renders the row — so a
    /// decision that could flip mid-life would take a logo off a card the viewer
    /// is looking at. The first answer is memoized and kept. A card that renders
    /// before the router replies therefore keeps its logo for this session and
    /// corrects on the next launch, when the answer is already on disk. That is
    /// the same bargain the artwork makes, and for the same reason: being right
    /// one launch late is much cheaper than changing under the viewer.
    func suppressesLogo(for item: MediaItem) -> Bool {
        let key = Self.key(for: item)
        if let decided = logoDecisions[key] { return decided }
        let decision = outcomes[key] == Outcome.none && ContentClassifier.isAnime(item)
        logoDecisions[key] = decision
        return decision
    }

    /// Resolves and warms `item`'s textless backdrop, once per show per session.
    ///
    /// Called from the row's existing forward-window prefetch, so the work is
    /// already done by the time the card is reached. The first-ever launch is the
    /// only one that pays a network cost: the router memoizes the URL to disk —
    /// *and memoizes the misses too*, which is what makes condition 1 above cheap
    /// on every later launch.
    public func warm(for item: MediaItem, variant: ArtworkImageVariant) {
        #if canImport(UIKit)
        let key = Self.key(for: item)
        guard !attempted.contains(key) else { return }
        attempted.insert(key)
        let seriesItem = Self.seriesItem(for: item)
        Task { [weak self] in
            var cancelled = false
            let url = await ArtworkSession.artworkResolveLimiter.run { () -> URL? in
                if Task.isCancelled { cancelled = true; return nil }
                return await ArtworkRouter.shared.artworkURL(.hero, for: seriesItem)
            }
            // A cancelled resolve proves nothing about what exists, so it must not
            // be recorded as a conclusive miss — that would suppress a logo on the
            // strength of a scroll that happened to interrupt us.
            guard !cancelled else { self?.forget(key); return }
            guard let url else { self?.record(.none, for: key); return }
            // Decode before publishing — see the type's note. `background: true`
            // keeps the decode off the main thread so a scrolling row never
            // stutters for art no card is waiting on.
            guard await ArtworkImageCache.shared.image(
                for: url, variant: variant, background: true
            ) != nil else {
                // The art exists, we just could not load it this time. Also not a
                // miss: leave it unknown so a later launch retries.
                self?.forget(key)
                return
            }
            self?.record(.available(url), for: key)
        }
        #endif
    }

    private func record(_ outcome: Outcome, for key: String) {
        outcomes[key] = outcome
    }

    /// Seeds an outcome without going near the network, so the decision table
    /// above can be exercised directly.
    func recordForTesting(_ outcome: Outcome, for item: MediaItem) {
        record(outcome, for: Self.key(for: item))
    }

    /// Drops an inconclusive attempt so the next appearance tries again.
    private func forget(_ key: String) {
        attempted.remove(key)
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
