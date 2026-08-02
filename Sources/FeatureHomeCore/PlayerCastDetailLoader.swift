#if canImport(SwiftUI)
import Foundation
import CoreModels
import MetadataKit

/// Builds the in-player Cast card's detail loader — the "L2" page behind a face.
///
/// Lives here rather than in the tvOS shell so BOTH shells can reach it. It has
/// no tvOS-only dependency and never did; it simply grew up next to its one
/// caller, and the iPad card was left showing faces with no biography and no
/// known-for row because the loader it needs was on the other side of a target
/// boundary. `PersonDetailViewModel` moved here first, for the same reason.
/// See `PlayerCastDetail` for what the pane does with each partial answer.
@MainActor
public func makeCastDetailLoader(
    for item: MediaItem,
    accounts: [ResolvedAccount],
    /// The viewer's own copies of a credit, from the eager identity index. See
    /// `PersonDetailViewModel.librarySources` for why a credits row cannot answer
    /// "do I own this?" from a server's person query alone. Defaults to "cannot
    /// tell", which only costs an owned title a mark it shouldn't have.
    librarySources: @escaping @Sendable (MediaItem) -> [MediaSourceRef] = { _ in [] }
) -> PlayerCastDetailLoading {
    // Captured once, outside the returned closure: these are the same for every
    // person in this item's cast.
    let sourceAccountID = item.sourceAccountID
    // `resolveOptionalProvider`, never `resolveProvider`: the latter falls back
    // to the primary account, which sent Jellyfin and share person ids to Plex
    // and got nothing back. No account means no credits, not wrong credits.
    let ownProvider = sourceAccountID.flatMap { id in
        accounts.first(where: { $0.account.id == id })?.provider
    }
    let otherProviders = accounts
        .filter { $0.account.id != sourceAccountID }
        .map(\.provider)
    let playingID = item.id
    let playingTitle = MediaItemIdentity.normalizedTitle(item.title)

    let playingLabel = item.title
    // Completed answers for this item's cast, so returning to a face costs
    // nothing. Scoped to this loader, and therefore to the title on screen:
    // the current title is filtered OUT of the credits, so a cached answer
    // stops being correct the moment something else is playing.
    let cache = PlayerCastDetailCache()

    return { person in
        // What is playing, alongside who was opened. Without it a trace can say
        // a person had no credits but not what they had no credits IN, which
        // makes a report impossible to reconstruct afterwards.
        PersonDiagnostics.emit("cast.open person=\(person.name) in=\(playingLabel)")
        let model = PersonDetailViewModel(
            person: person,
            provider: ownProvider,
            otherProviders: otherProviders,
            biographyProviders: [WikipediaPersonBiographyProvider()],
            // Shared with the person page — see `PlayerCastCredits`.
            creditsProviders: PlayerCastCredits.providers,
            artworkResolver: PlayerCastCredits.artworkResolver,
            // Strike what is playing. By id AND by normalized title, since a
            // second server holding the same film answers with its own id.
            //
            // Given to the view model rather than applied to its output: it
            // branches on whether the servers found anything, and everyone in
            // this cast is in the film on screen — so filtering afterwards left
            // that branch permanently unreachable.
            includeCredit: { item in
                item.id != playingID
                    && MediaItemIdentity.normalizedTitle(item.title) != playingTitle
            },
            librarySources: librarySources,
            // Enough to fill the rail several times over. The person page is
            // where the complete list lives.
            limit: 24
        )
        return AsyncStream { continuation in
            // Served only when it is COMPLETE — every credit carrying artwork.
            //
            // Artwork is resolved by a network pass that can fail transiently, and
            // caching its result unconditionally made a single failure permanent:
            // the artless answer was stored, every later open replayed it, and
            // only relaunching the app cleared it. A cached miss is exactly the
            // thing worth NOT remembering, so an incomplete entry falls through
            // and asks again.
            if let cached = cache.value(for: person.id), cached.artworkIsComplete {
                PersonDiagnostics.emit("cast.cache-hit person=\(person.name)")
                continuation.yield(cached)
                continuation.finish()
                return
            }
            // Yield after every rung, so the credits the viewer's own server
            // already returned appear immediately instead of waiting behind a
            // biography lookup that may take a second or never answer at all.
            model.onProgress = { continuation.yield(snapshot(model)) }
            let task = Task { @MainActor in
                await model.load()
                let final = snapshot(model, isComplete: true)
                // Only the finished answer is kept. Caching a partial one would
                // pin whatever a slow rung had not yet returned, and a person
                // whose row was still loading would be permanently short.
                //
                // Stored even when artwork is incomplete, so a second open still
                // gets the row instantly — but `artworkIsComplete` means it is
                // re-resolved rather than replayed.
                cache.store(final, for: person.id)
                continuation.yield(final)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    @MainActor
    func snapshot(
        _ model: PersonDetailViewModel,
        isComplete: Bool = false
    ) -> PlayerCastDetail {
        PlayerCastDetail(
            // Strike what is playing. By id AND by normalized title, since a
            // second server holding the same film answers with its own id.
            // Withheld until the ORDER is settled, not merely until credits
            // exist. They arrive within ~30ms from the viewer's own server and
            // are then re-sorted by role prominence once the outside rungs land,
            // so publishing them early meant the row appeared in library order
            // and visibly reshuffled itself under the viewer a second later.
            //
            // The row simply arrives a beat later instead, in one piece. The
            // biography and headshot are unaffected and still stream, so the
            // pane is never empty while this waits.
            credits: model.creditsAreFinal ? foldDuplicateCredits(model.libraryCredits) : [],
            biography: model.biography,
            lifeSummary: model.lifeSummary,
            isComplete: isComplete
        )
    }
}

/// Collapses the same title held on more than one server into one poster.
///
/// The person page's own fold keys on title+year and falls back to the id when a
/// year is missing — right for a page that lists everything, where wrongly
/// merging two films would hide one the viewer owns. A ten-poster glance strip
/// has the opposite bias: the same film four times (which is what a share and a
/// Jellyfin library holding one copy each actually produced) is a worse failure
/// than two same-named films sharing a slot. So a year-less copy is folded into
/// a titled one, while two copies that BOTH state a year and disagree stay
/// apart — which is what keeps Dune (1984) and Dune (2021) separate.
private func foldDuplicateCredits(_ items: [MediaItem]) -> [MediaItem] {
    func titleKey(_ item: MediaItem) -> String {
        "\(item.kind.rawValue)|\(MediaItemIdentity.normalizedTitle(item.title))"
    }

    // Strong external identity first, through the shared `TitleDedupe` — that is what
    // folds the same film catalogued under two different titles, which no title
    // compare can see. Within each group keep whichever copy can actually show a
    // poster; a row of grey title tiles is the one outcome worse than a duplicate.
    let collapsed: [MediaItem] = TitleDedupe.collapsed(items) { item in
        "\(titleKey(item))|\(item.productionYear.map(String.init) ?? "")"
    }

    let titlesWithAYear = Set(
        collapsed.filter { $0.productionYear != nil }.map(titleKey)
    )
    return collapsed.filter {
        $0.productionYear != nil || !titlesWithAYear.contains(titleKey($0))
    }
}

/// Finished cast answers for the title currently playing.
///
/// Deliberately per-loader rather than global: the credits deliberately exclude
/// whatever is on screen, so an entry is only valid for the item it was built
/// for. A global cache would hand a viewer the wrong list the moment they
/// started something else.
@MainActor
public final class PlayerCastDetailCache {
    public init() {}
    private var entries: [String: PlayerCastDetail] = [:]

    public func value(for id: String) -> PlayerCastDetail? { entries[id] }

    public func store(_ detail: PlayerCastDetail, for id: String) { entries[id] = detail }
}

/// The credit sources shared by the in-player Cast card and the person page.
///
/// One definition, because the two surfaces answer the same question and had
/// already drifted: the player was given the full ladder while the person page
/// was left with servers alone, so its "Known for" row could only ever show
/// titles the viewer already owned — which is the one thing "known for" does not
/// mean.
public enum PlayerCastCredits {
    /// Order is load-bearing. The merge inherits the ranking of whichever rung
    /// names a title first, so the fame-ranked source has to lead.
    public static var providers: [any PersonCreditsProviding] {
        [
            TMDbPersonCreditsProvider(access: MetadataProviderConfig.resolved().tmdb),
            WikidataPersonCreditsProvider(),
            TVmazePersonCreditsProvider(),
        ]
    }

    public static var artworkResolver: any PersonCreditArtworkResolving {
        TMDbPersonCreditArtworkResolver(access: MetadataProviderConfig.resolved().tmdb)
    }
}
#endif
