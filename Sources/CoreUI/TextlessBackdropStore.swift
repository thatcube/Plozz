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
    /// Where last session's answers are kept, so this session starts knowing them.
    private let store: TextlessBackdropIndex
    /// Whether ``outcomes`` has been seeded from disk yet. Deferred to first use
    /// rather than done in `init` so constructing the shared instance costs
    /// nothing, and the read lands with the first card that actually needs it.
    private var didSeed = false
    /// Cards currently waiting to hear about a show, by show key.
    private var waiters: [String: [UUID: CheckedContinuation<Void, Never>]] = [:]

    public init(store: TextlessBackdropIndex? = nil) {
        self.store = store ?? .sharedIndex
    }

    /// Reads last session's answers in, once.
    ///
    /// Every public entry point calls this, because the whole value of the file is
    /// that it is present on the *first frame*: the row's first screenful renders
    /// before any async work can finish, and a card that guesses wrong there stays
    /// wrong until it happens to be rebuilt.
    private func seedIfNeeded() {
        guard !didSeed else { return }
        didSeed = true
        outcomes = store.load()
    }

    /// The textless backdrop for `item`'s show, or `nil` if none is known *yet*.
    ///
    /// Synchronous and side-effect free so it can be read from a view body. A
    /// `nil` here is not "there is none" — it is "not in time", which the caller
    /// must treat as final for that card rather than waiting.
    public func backdrop(for item: MediaItem) -> URL? {
        seedIfNeeded()
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
    /// ### Answered from the outcome, never memoized
    ///
    /// Body runs constantly on tvOS, so this is read very often, and the obvious
    /// instinct is to memoize the first answer to stop it flipping under the
    /// viewer. That was tried and removed: an outcome only ever moves from unknown
    /// to conclusive and never back, so this is monotonic and cannot oscillate —
    /// the memo protected against nothing. What it *did* do was freeze a
    /// first-encounter guess, so a show seen for the first time kept its doubled
    /// title for the whole session no matter what the router later found.
    func suppressesLogo(for item: MediaItem) -> Bool {
        seedIfNeeded()
        return outcomes[Self.key(for: item)] == Outcome.none && ContentClassifier.isAnime(item)
    }

    /// Resolves and warms `item`'s textless backdrop, once per show per session.
    ///
    /// Called from the row's existing forward-window prefetch, so the work is
    /// already done by the time the card is reached. The first-ever launch is the
    /// only one that pays a network cost: the router memoizes the URL to disk —
    /// *and memoizes the misses too* — and this store keeps its own copy of the
    /// answer, which is what makes it available on the first frame rather than
    /// merely fast.
    public func warm(for item: MediaItem, variant: ArtworkImageVariant) {
        #if canImport(UIKit)
        seedIfNeeded()
        let key = Self.key(for: item)
        guard !attempted.contains(key) else { return }
        attempted.insert(key)
        // Already answered last session, and re-read on the first frame. Warm the
        // picture so the card can paint it, but don't re-ask the router.
        if case .available(let known) = outcomes[key] {
            ArtworkImageCache.shared.prefetch(known, variant: variant)
            return
        }
        if outcomes[key] == Outcome.none { return }
        let seriesItem = Self.seriesItem(for: item)
        Task { [weak self] in
            let url = await ArtworkSession.artworkResolveLimiter.run { () -> URL? in
                if Task.isCancelled { return nil }
                return await ArtworkRouter.shared.artworkURL(.hero, for: seriesItem)
            }
            // A cancelled resolve proves nothing about what exists, so it must not
            // be recorded as a conclusive miss — that would suppress a logo on the
            // strength of a scroll that happened to interrupt us.
            guard !Task.isCancelled else { self?.forget(key); return }
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
        store.save(outcome, for: key)
        // Wake anything waiting on this show. Without this the answer lands in a
        // dictionary no view is watching, and the card goes on drawing what it
        // decided before the answer existed — which is why a newly seen show
        // stayed wrong until scrolling happened to rebuild it.
        if let waiting = waiters.removeValue(forKey: key) {
            waiting.values.forEach { $0.resume() }
        }
    }

    /// Whether this show's answer is known *now*, synchronously.
    ///
    /// Lets a card avoid painting art it may be about to replace. On any launch
    /// after the first this is true on the very first frame, because the answers
    /// are read back from disk synchronously — so the common path pays nothing.
    func hasAnswer(for item: MediaItem) -> Bool {
        seedIfNeeded()
        return outcomes[Self.key(for: item)] != nil
    }

    /// Suspends until this show's answer is known, returning immediately if it
    /// already is.
    ///
    /// Deliberately per-show rather than making the whole store observable: an
    /// answer concerns exactly one card, and publishing a store-wide change would
    /// re-render every card in the row for each of the twenty-odd shows that
    /// resolve on a cold launch.
    func answerSettled(for item: MediaItem) async {
        seedIfNeeded()
        let key = Self.key(for: item)
        guard outcomes[key] == nil else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // Re-checked inside the continuation: the answer can land between
                // the guard above and this line, and a waiter registered after the
                // wake-up would never be resumed.
                guard outcomes[key] == nil else { return continuation.resume() }
                waiters[key, default: [:]][id] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.stopWaiting(id, for: key) }
        }
    }

    /// Resumes and drops a cancelled waiter. A continuation that is never resumed
    /// leaks its task, so cancellation has to resume it rather than just forget it.
    private func stopWaiting(_ id: UUID, for key: String) {
        waiters[key]?.removeValue(forKey: id)?.resume()
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
