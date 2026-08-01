#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI
import MetadataKit

/// The credits a person page can show, and how they were obtained.
///
/// Deliberately server-first. `libraryCredits` comes from the source the person
/// was seen on, using that source's own person id, so it needs no third party,
/// resolves no identities, and every entry is a title the viewer owns and can
/// play. A metadata outage costs this page its biography, not its usefulness.
@MainActor
@Observable
public final class PersonDetailViewModel {
    public enum LoadState: Equatable {
        case loading
        case loaded
        /// The source could not answer. The page still renders its header — the
        /// person's name, role and headshot all arrived with the item they were
        /// listed on, so there is always something to show.
        case unavailable
    }

    public private(set) var state: LoadState = .loading
    public private(set) var libraryCredits: [MediaItem] = []
    /// Whether the credit ORDER is settled.
    ///
    /// The list grows in rungs, and the last rung re-sorts everything by how
    /// prominent the person was. A surface that shows credits the moment they
    /// exist therefore shows them in the wrong order and visibly reshuffles a
    /// second later. Anywhere that cannot afford that — the in-player card,
    /// which the viewer is watching at the moment it happens — waits for this
    /// instead of for the whole load.
    ///
    /// Distinct from "everything finished": the biography can still be in
    /// flight, and it renders in its own place without disturbing the row.
    public private(set) var creditsAreFinal = false
    /// Filled only if the source keeps person records with one. Loaded alongside
    /// the credits and independently of them: a source can answer for one and not
    /// the other, and neither absence should block the other from showing.
    public private(set) var biography: String?
    /// "1937 · Memphis, Tennessee, USA", when a source can say. Independent of
    /// the biography: a source can place someone it cannot describe.
    public private(set) var lifeSummary: String?

    /// Fired after each rung of the ladder lands, so a caller that cannot
    /// observe this object directly can still render progressively.
    ///
    /// The page itself needs no such thing — it observes the properties — but
    /// the in-player card takes a snapshot through a closure, and without this
    /// it could only take one: at the very end, behind the slowest rung.
    public var onProgress: (@MainActor () -> Void)?

    private let person: MediaPerson
    private let provider: (any MediaProvider)?
    /// The viewer's *other* signed-in servers. Empty for the single-server case,
    /// which is most people — and when it is empty this class does exactly what
    /// it did before, one request, no extra latency.
    private let otherProviders: [any MediaProvider]
    /// Consulted in order, and only once every server has come back without a
    /// biography. Several rather than one so no single provider is load-bearing:
    /// drop them all and the page still shows who the person is and what the
    /// viewer owns with them.
    private let biographyProviders: [any PersonBiographyProvider]
    /// Consulted only when no server the viewer owns has a single title with
    /// this person. For a share-only library that is always — shares keep no
    /// person records at all — which is the whole reason this rung exists.
    private let creditsProviders: [any PersonCreditsProviding]
    private let artworkResolver: (any PersonCreditArtworkResolving)?
    /// Drops credits the caller does not want counted — in practice the title
    /// currently playing, which every one of its own cast is trivially in.
    ///
    /// Applied HERE rather than by the caller, because the ladder branches on
    /// whether anything was found: filtering afterwards meant the servers always
    /// looked like they had answered (a person is always in what you are
    /// watching), so the rung that exists for when they have not could never
    /// fire.
    private let includeCredit: @Sendable (MediaItem) -> Bool
    private let limit: Int

    public init(
        person: MediaPerson,
        provider: (any MediaProvider)?,
        otherProviders: [any MediaProvider] = [],
        biographyProviders: [any PersonBiographyProvider] = [],
        creditsProviders: [any PersonCreditsProviding] = [],
        artworkResolver: (any PersonCreditArtworkResolving)? = nil,
        includeCredit: @escaping @Sendable (MediaItem) -> Bool = { _ in true },
        limit: Int = 40
    ) {
        self.person = person
        self.provider = provider
        self.otherProviders = otherProviders
        self.biographyProviders = biographyProviders
        self.creditsProviders = creditsProviders
        self.artworkResolver = artworkResolver
        self.includeCredit = includeCredit
        self.limit = limit
    }

    /// Folds the viewer's other servers in, keyed by the person's **name** since
    /// ids do not cross servers.
    ///
    /// Additive only: anything these return is extra, and any that fail simply
    /// contribute nothing. A second server can also supply the biography the
    /// first one lacked, which is how a Plex-sourced person gets one without any
    /// third party being involved.
    private func mergeOtherServers() async {
        let name = person.name
        guard !name.isEmpty else { return }
        let limit = self.limit

        var merged = libraryCredits
        var seen = Set(merged.map(Self.dedupeKey))

        await withTaskGroup(of: (([MediaItem])?, MediaPerson?).self) { group in
            for other in otherProviders {
                group.addTask {
                    async let items = try? other.items(withPersonNamed: name, limit: limit)
                    async let record = try? other.person(named: name)
                    return (await items, await record ?? nil)
                }
            }
            for await (items, record) in group {
                if biography == nil {
                    biography = record?.biography.flatMap { $0.isEmpty ? nil : $0 }
                }
                PersonDiagnostics.emit(
                    "person.server name=\(name) items=\(items?.count ?? -1) "
                    + "record=\(record == nil ? "nil" : "yes") "
                    + "bio=\(record?.biography?.isEmpty == false ? "yes" : "no")"
                )
                for item in items ?? [] where includeCredit(item)
                    && seen.insert(Self.dedupeKey(item)).inserted {
                    merged.append(item)
                }
            }
        }

        libraryCredits = merged
        // A server that had nothing to say about the home source's failure should
        // not leave the page reading "unavailable" when others answered.
        if !merged.isEmpty { state = .loaded }
    }

    /// The keyless biography lookup, started EARLY and consulted late.
    ///
    /// Measured on device: the person's own server answers in 11-28ms, the other
    /// servers in 120-380ms, and Wikipedia in 200-335ms — but Wikipedia is where
    /// the biography actually comes from every single time, because a server
    /// only keeps the bios it happened to download and in practice has none. So
    /// running it strictly last meant waiting 140-400ms for two servers to say
    /// "no" before even starting the request that answers.
    ///
    /// Kicked off alongside them instead, and still consulted only after both
    /// have failed to supply one — the ladder's ORDER of preference is unchanged,
    /// only the order in which the work starts. The cost is one speculative
    /// request on the rare occasion a server does have a biography; it is
    /// keyless, unauthenticated and its result is simply dropped.
    /// STRUCTURED, deliberately — an `async let` owns this, not a `Task`.
    ///
    /// It began as `Task.detached`, which does not inherit cancellation, so
    /// moving to the next face left the previous person's lookup running.
    /// Browsing a cast row therefore left a pile of orphaned requests competing
    /// with the ones that mattered, and on device that starved the server
    /// queries badly enough that one took 19.6 seconds and returned nothing —
    /// an empty pane for an actor with plenty to show. Cancelled with its
    /// parent, abandoning a person abandons their lookup too.
    private func fetchExternalBiography() async -> String? {
        guard !biographyProviders.isEmpty else { return nil }
        let name = person.name
        guard !name.isEmpty else { return nil }
        for provider in biographyProviders {
            if Task.isCancelled { return nil }
            if let text = await provider.biography(for: name, role: person.kind), !text.isEmpty {
                return text
            }
        }
        return nil
    }

    /// See the known-for merge: title and kind, deliberately without a year.
    /// Wide enough that no provider's list can run into the next provider's
    /// range, so ordering stays "everything Wikidata ranked, then everything
    /// TVmaze ranked" rather than interleaving two incomparable scales.
    private static let providerRankStride = 1_000

    /// Finds artwork for credits that arrived without any, changing nothing else.
    ///
    /// Runs AFTER the order is settled and only ever writes `posterURL`, so the
    /// row cannot reshuffle underneath the viewer. That separation is the whole
    /// design: the obvious way to get artwork was to let the source that has it
    /// reach further down the row, and that was measured making the ranking
    /// worse — Hailee Steinfeld lost Hawkeye, Clancy Brown lost Rick and Morty.
    /// Rank first, decorate second.
    ///
    /// Measured across 600 credits from 50 people spanning film, television,
    /// animation, anime, Korean and Indian cinema: 97% of credits arrive with
    /// artwork and this lifts it to 99.5%. The largest gains are where a keyless
    /// source carried the whole row — Trey Parker 58% to 100%, Shah Rukh Khan
    /// 75% to 100%.
    private func backfillArtwork() async {
        guard let artworkResolver, !Task.isCancelled else { return }
        let missing = libraryCredits.enumerated().filter { $0.element.posterURL == nil }
        guard !missing.isEmpty else { return }

        let stage = Date()
        let resolved: [(Int, URL?)] = await withTaskGroup(of: (Int, URL?).self) { group in
            for (index, item) in missing {
                let title = item.title
                let year = item.productionYear
                let isSeries = item.kind == .series || item.kind == .episode
                group.addTask {
                    (index, await artworkResolver.posterURL(
                        title: title, year: year, isSeries: isSeries
                    ))
                }
            }
            var found: [(Int, URL?)] = []
            for await result in group { found.append(result) }
            return found
        }
        guard !Task.isCancelled else { return }

        var updated = libraryCredits
        var filled = 0
        for (index, url) in resolved {
            guard let url, index < updated.count else { continue }
            updated[index].posterURL = url
            filled += 1
        }
        guard filled > 0 else { return }
        libraryCredits = updated
        PersonDiagnostics.emit(
            "person.artwork name=\(person.name) asked=\(missing.count) filled=\(filled) "
            + "ms=\(Int(Date().timeIntervalSince(stage) * 1000))"
        )
        onProgress?()
    }

    /// How long any one rung gets before the row goes on without it.
    ///
    /// Measured p50 20ms and p90 922ms, against a 12s HTTP timeout — so the
    /// tail here is not a slow answer, it is no answer at all. Waiting the full
    /// timeout held the row for twelve seconds to eventually add nothing.
    ///
    /// Well clear of normal completion, so this never truncates a rung that was
    /// going to answer; it only bounds the case where one never will. These run
    /// concurrently, so capping each one caps the stage.
    private static let rungDeadline: TimeInterval = 4

    /// A rung's credits, or nothing if it takes too long.
    ///
    /// The row is an enhancement rather than the pane's reason for existing:
    /// the viewer already has a face, a name and a biography while this runs.
    /// Nothing here is worth twelve seconds of an empty lane.
    private static func creditsBeforeDeadline(
        from provider: any PersonCreditsProviding,
        name: String,
        limit: Int
    ) async -> [MediaItem] {
        await withTaskGroup(of: [MediaItem]?.self) { group in
            group.addTask { await provider.credits(for: name, limit: limit) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(rungDeadline * 1_000_000_000))
                return nil
            }
            // Whichever lands first decides it; the loser is cancelled rather
            // than left running against a pane the viewer may have closed.
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? []
        }
    }

    private static func knownForKey(_ item: MediaItem) -> String {
        "\(item.kind.rawValue)|\(MediaItemIdentity.normalizedTitle(item.title))"
    }

    /// A provider's family, for telemetry — so a log line says WHICH kind of
    /// server answered, not just that one did.
    private static func kind(of provider: any MediaProvider) -> String {
        String(describing: type(of: provider))
            .replacingOccurrences(of: "Provider", with: "")
    }

    /// Collapses the same title held on more than one server into one entry.
    ///
    /// Title+year rather than external ids: this is a display row, the two copies
    /// are interchangeable for the viewer, and being wrong costs a duplicate
    /// poster rather than the wrong thing playing — which is why this can be
    /// looser than `RelatedTitleMatcher`, where a false match means the wrong
    /// show starts.
    private static func dedupeKey(_ item: MediaItem) -> String {
        let title = MediaItemIdentity.normalizedTitle(item.title)
        guard let year = item.productionYear else {
            // No year is not evidence of sameness. Two different films can share a
            // normalized title, and collapsing them would silently remove one the
            // viewer owns — a worse outcome than the duplicate poster this exists
            // to prevent. Fall back to the id, which never merges anything.
            return "id|\(item.id)"
        }
        return "\(item.kind.rawValue)|\(title)|\(year)"
    }

    public func load() async {
        guard state == .loading else { return }
        // Settled on EVERY exit, including the early ones.
        //
        // Surfaces wait on this before drawing a row, so a path that returns
        // without setting it leaves them on a spinner forever — and the paths
        // that do return early are the failure ones, which is exactly when that
        // is least acceptable. A `defer` makes it structural rather than
        // something each new branch has to remember.
        defer { creditsAreFinal = true }
        let started = Date()
        func elapsed(_ from: Date) -> Int { Int(Date().timeIntervalSince(from) * 1000) }
        // In flight while the servers are asked, and cancelled with this task if
        // the viewer moves on; see the method.
        async let externalBiography = fetchExternalBiography()
        guard let provider else {
            state = .unavailable
            _ = await externalBiography
            PersonDiagnostics.emit(
                "person.load name=\(person.name) result=no-provider ms=\(elapsed(started))"
            )
            return
        }
        // The person's own server, asked by its own exact id. Independent and
        // separately fallible from the biography: a source can list credits and
        // keep no person record, or the reverse, and neither absence should
        // suppress the other.
        async let credits = try? provider.items(withPerson: person.id, limit: limit)
        async let record = try? provider.person(id: person.id)

        // `try?` over an already-Optional return nests the optionals, so flatten
        // both once: "the call failed" and "the source had nothing" mean the same
        // thing to this page.
        let items: [MediaItem]? = await credits
        let personRecord: MediaPerson? = await record ?? nil

        biography = personRecord?.biography.flatMap { $0.isEmpty ? nil : $0 }
        if let items {
            libraryCredits = items.filter(includeCredit)
            state = .loaded
        } else {
            state = .unavailable
        }
        PersonDiagnostics.emit(
            "person.own name=\(person.name) provider=\(Self.kind(of: provider)) "
            + "credits=\(items?.count ?? -1) record=\(personRecord == nil ? "nil" : "yes") "
            + "bio=\(biography == nil ? "no" : "yes") ms=\(elapsed(started))"
        )
        onProgress?()

        if Task.isCancelled { return }

        // The source's own global handle, where it keeps one. Plex is the only
        // provider that does, and for a Plex-sourced person this is the sole
        // route to a biography — the server itself has no person records at
        // all, only actor tags on titles.
        if biography == nil, let externalID = person.externalID, !externalID.isEmpty {
            let stage = Date()
            let record = await provider.person(externalID: externalID, name: person.name)
            if let text = record?.biography, !text.isEmpty { biography = text }
            if let life = record?.lifeSummary, !life.isEmpty { lifeSummary = life }
            PersonDiagnostics.emit(
                "person.external-id name=\(person.name) "
                + "bio=\(biography == nil ? "MISS" : "hit") ms=\(elapsed(stage))"
            )
            onProgress?()
        }

        // Render what the home server gave us before consulting anyone else, so
        // time-to-content never depends on how many servers are signed in.
        if !otherProviders.isEmpty {
            let stage = Date()
            await mergeOtherServers()
            PersonDiagnostics.emit(
                "person.others name=\(person.name) servers=\(otherProviders.count) "
                + "credits=\(libraryCredits.count) bio=\(biography == nil ? "no" : "yes") "
                + "ms=\(elapsed(stage))"
            )
            onProgress?()
        }

        let stage = Date()
        let external = await externalBiography
        // Servers still win: this is only consulted because none had one.
        if biography == nil, let external, !external.isEmpty { biography = external }
        PersonDiagnostics.emit(
            "person.external name=\(person.name) "
            + "bio=\(biography == nil ? "MISS" : "hit") waited=\(elapsed(stage))"
        )
        onProgress?()
        // What they are KNOWN FOR, always — not only when the viewer's servers
        // came up empty.
        //
        // Someone opens this pane because they half-recognise a face, and the
        // answer is whatever that person is famous for; whether the viewer
        // happens to own it is a detail of their library, not of the question.
        // Asking only on failure meant the row showed a character actor's two
        // obscure titles and hid the one everybody knows them from.
        //
        // Owned copies still win on collision: they are merged in FIRST and
        // dedupe keeps the local entry, so a title held locally stays playable
        // and appears once.
        //
        // Winning the collision is NOT the same as leading the row, and
        // conflating the two was a real bug: because owned titles were merged
        // first they also came first, so the library decided the order. Martin
        // Freeman opened on Wakanda Forever, Black Panther and Civil War —
        // every one of them owned, none of them what he is known for — while
        // Sherlock and The Hobbit sat off the end of the row. Ownership is a
        // fact about the viewer's disk, not about the actor, so the ranking
        // below is applied after the merge and independently of it.
        if !creditsProviders.isEmpty, !Task.isCancelled {
            let stage = Date()
            var merged = libraryCredits
            // Keyed on title alone, NOT title+year like the cross-server merge.
            //
            // An outside source dates a series by its premiere while a library
            // dates it by whatever the scanner found, and the two disagree often
            // enough that a year-sensitive key let the same show appear twice.
            // In a known-for row a duplicate poster is the worse failure: the
            // titles are famous ones, so a genuine collision between two works
            // of the same name is rare, and losing one to the other costs a row
            // entry rather than something the viewer owns.
            var seen = Set(merged.map(Self.knownForKey))
            // Concurrent, but merged in declaration order. Serially these cost
            // the sum of the slowest of each — Wikidata's SPARQL endpoint alone
            // runs to seconds — and the row cannot appear until the last one
            // lands. Fanning out costs the slowest single provider instead.
            //
            // Order still matters after the fact: dedupe keeps whichever entry
            // arrives first, so a stable declaration order is what stops the
            // same person's row from being assembled differently run to run.
            let name = person.name
            let limit = limit
            let ordered: [[MediaItem]] = await withTaskGroup(
                of: (Int, [MediaItem]).self
            ) { group in
                for (index, provider) in creditsProviders.enumerated() {
                    group.addTask {
                        let started = Date()
                        let items = await Self.creditsBeforeDeadline(
                            from: provider, name: name, limit: limit
                        )
                        // Per rung, because "the row was slow" is not something
                        // anyone can act on. One stalled request used to hold
                        // the whole row for the full 12s HTTP timeout, and
                        // without this there was no way to tell which.
                        PersonDiagnostics.emit(
                            "person.credits-rung index=\(index) name=\(name) "
                            + "items=\(items.count) ms=\(Int(Date().timeIntervalSince(started) * 1000))"
                        )
                        return (index, items)
                    }
                }
                var results = [[MediaItem]](repeating: [], count: creditsProviders.count)
                for await (index, credits) in group { results[index] = credits }
                return results
            }
            guard !Task.isCancelled else { return }
            // Rank by position in the external lists, which arrive ordered by
            // fame — Wikidata by how many Wikipedia editions carry an article on
            // the work, which puts Sherlock and Black Panther at the top where
            // they belong. A provider's whole list is ranked ahead of the next
            // provider's, so the fame-ranked source leads and the others fill in
            // behind it.
            var rank: [String: Int] = [:]
            var indexByKey: [String: Int] = [:]
            for (providerIndex, credits) in ordered.enumerated() {
                for (position, item) in credits.enumerated() {
                    // First writer wins, so an earlier provider's opinion of a
                    // shared title is not overwritten by a later one's.
                    let key = Self.knownForKey(item)
                    if rank[key] == nil {
                        rank[key] = providerIndex * Self.providerRankStride + position
                    }
                    guard includeCredit(item) else { continue }
                    guard seen.insert(key).inserted else {
                        // Wikidata is ranked first because it knows what a person
                        // is famous for, but it carries no artwork. When a later
                        // provider has a poster for a title already held without
                        // one, take it: the winning entry keeps its identity and
                        // its rank, and only gains an image it was missing.
                        if let index = indexByKey[key],
                           merged[index].posterURL == nil,
                           let poster = item.posterURL {
                            merged[index].posterURL = poster
                        }
                        continue
                    }
                    indexByKey[key] = merged.count
                    merged.append(item)
                }
            }
            // Titles nobody outside the library associates with this person sort
            // last rather than being dropped: the viewer owns them, which is a
            // reason to keep them reachable, just not to lead with them.
            merged = merged.enumerated().sorted { lhs, rhs in
                let lhsRank = rank[Self.knownForKey(lhs.element)] ?? Int.max
                let rhsRank = rank[Self.knownForKey(rhs.element)] ?? Int.max
                // Ties broken by original position so the order stays stable and
                // the row does not reshuffle between openings.
                return lhsRank == rhsRank ? lhs.offset < rhs.offset : lhsRank < rhsRank
            }.map(\.element)
            // Compared by identity and ORDER, not by count. Ranking can leave
            // the set untouched and still change the row completely — reordering
            // four owned titles so the famous one leads adds nothing and matters
            // a great deal — and a count check would silently discard exactly
            // that case.
            if merged.map(\.id) != libraryCredits.map(\.id) {
                libraryCredits = merged
                state = .loaded
            }
            // Announced BEFORE artwork is fetched, deliberately.
            //
            // The order is settled at this point, which is all a surface is
            // waiting on; artwork only ever adds a poster to a row already in
            // its final sequence. Waiting for it too would hold the row for
            // another network pass to change nothing about what is in it or
            // where. The `defer` above still covers the early exits.
            creditsAreFinal = true
            await backfillArtwork()
            PersonDiagnostics.emit(
                "person.known-for name=\(person.name) total=\(libraryCredits.count) "
                + "ms=\(elapsed(stage))"
            )
            onProgress?()
        }


        PersonDiagnostics.emit(
            "person.done name=\(person.name) credits=\(libraryCredits.count) "
            + "bio=\(biography == nil ? "MISS" : "hit") ms=\(elapsed(started))"
        )
    }
}

/// A person's page: who they are, and what else the viewer owns with them.
///
/// The header is free — name, character and headshot all arrive with the item
/// the person was listed on — so the page is never empty even when the source
/// cannot answer for credits.
public struct PersonDetailView: View {
    private let person: MediaPerson
    /// `@State`, not `let`: a `navigationDestination` closure re-runs on every
    /// render pass while its page is on the stack, so a plain stored property
    /// would be replaced by a freshly-built model — reset to `.loading` — on each
    /// one, while `.task` (keyed to the unchanged view identity) never ran again.
    /// The spinner then never resolved. `ItemDetailView` keeps its model the same
    /// way, and for the same reason.
    @State private var viewModel: PersonDetailViewModel
    private let onSelectItem: (MediaItem) -> Void

    @Environment(\.plozzMetrics) private var metrics
    @Environment(\.dismiss) private var dismiss

    /// Until credits arrive there is nothing focusable on this page, and on tvOS a
    /// screen with no focusable element makes Menu quit the app rather than pop —
    /// the same hazard the empty/loading folder states guard against. So every
    /// creditless state carries a focused Back button.
    @FocusState private var backFocused: Bool

    private static let headshotDiameter: CGFloat = 220
    /// Reading measure for the biography — roughly 90 characters at this size.
    private static let biographyWidth: CGFloat = 1000

    /// Display name for each library id the viewer has, so owned credits can be
    /// shelved under the libraries they actually came from.
    ///
    /// Keyed by the provider-local library id that `MediaItem.libraryID` carries.
    /// Empty is a supported state — a viewer whose libraries have not been
    /// discovered yet falls back to shelving by kind.
    private let libraryNames: [String: String]

    public init(
        person: MediaPerson,
        viewModel: PersonDetailViewModel,
        libraryNames: [String: String] = [:],
        onSelectItem: @escaping (MediaItem) -> Void
    ) {
        self.person = person
        _viewModel = State(initialValue: viewModel)
        self.libraryNames = libraryNames
        self.onSelectItem = onSelectItem
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PlozzTheme.Spacing.large) {
                header
                credits
            }
            .padding(.top, PlozzTheme.Spacing.large)
        }
        .task { await viewModel.load() }
    }

    /// Headshot on the left, name and biography beside it, the pair centred on
    /// screen.
    ///
    /// No character name. This page is about the person, not the one title the
    /// viewer happened to arrive from — "Bilbo Baggins" is a fact about The
    /// Hobbit, and it reads as a subtitle on a page that then lists a dozen
    /// other roles.
    private var header: some View {
        HStack(alignment: .center, spacing: PlozzTheme.Spacing.large) {
            headshot
            VStack(alignment: .leading, spacing: PlozzTheme.Spacing.small) {
                Text(person.name)
                    .font(.system(size: metrics.sectionHeaderFontSize * 1.6, weight: .bold))
                if let kind = person.kind, !kind.isEmpty, !person.isCast {
                    // Crew keep their discipline (Director, Writer): unlike a
                    // character it describes the person, not one credit.
                    Text(kind)
                        .font(.system(size: metrics.sectionHeaderFontSize * 0.8))
                        .plozzForeground(.secondary)
                }
                if let biography = viewModel.biography {
                    ExpandableOverviewText(
                        text: biography,
                        title: person.name,
                        lineLimit: 3,
                        font: .system(size: metrics.sectionHeaderFontSize * 0.72)
                    )
                    .plozzForeground(.secondary)
                    .padding(.top, PlozzTheme.Spacing.small)
                }
            }
            // Held well short of the screen: a full-width line of body text is
            // far past a comfortable reading measure at this size, and from
            // across a room it becomes hard to track from the end of one line to
            // the start of the next.
            .frame(maxWidth: Self.biographyWidth, alignment: .leading)
        }
        // The pair sits centred, rather than pinned to the leading edge.
        .frame(maxWidth: .infinity)
        .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
        // A full-width focus section, because the only focusable thing up here
        // is the biography — and it sits to the RIGHT of the headshot. Without
        // this, pressing Up from the left-most credit finds nothing above it
        // (the headshot is not focusable) and the press dies. A section captures
        // the movement across the whole width and redirects it inward, so Up
        // reaches the biography from anywhere along the row. Same fix, and the
        // same reason, as the player's bottom tab row.
        .personFocusSection()
    }

    @ViewBuilder
    private var headshot: some View {
        Group {
            if let url = person.imageURL {
                FallbackAsyncImage(urls: [url], variant: .personHeadshot) { headshotPlaceholder }
            } else {
                headshotPlaceholder
            }
        }
        .frame(width: Self.headshotDiameter, height: Self.headshotDiameter)
        .clipShape(Circle())
    }

    /// Initials on a tinted disc — the same fallback the cast rail uses, so a
    /// person with no headshot reads as "no photo" rather than a broken image.
    private var headshotPlaceholder: some View {
        ZStack {
            Circle().fill(Color.primary.opacity(0.12))
            Text(initials)
                .font(.system(size: Self.headshotDiameter * 0.28, weight: .semibold))
                .plozzForeground(.secondary)
        }
    }

    private var initials: String {
        let parts = person.name.split(separator: " ").prefix(2)
        return parts.compactMap(\.first).map(String.init).joined().uppercased()
    }

    @ViewBuilder
    private var credits: some View {
        switch viewModel.state {
        // Waits for the ORDER to settle, not merely for credits to exist.
        //
        // The viewer's own server answers in tens of milliseconds and the
        // outside rungs take up to a few seconds, and the last thing they do is
        // re-sort everything by how prominent the person was — so rendering on
        // arrival puts the page up in library order and visibly reshuffles it
        // underneath whoever is already reading it. The header, headshot and
        // biography are unaffected and still appear immediately, so the page is
        // never blank while this waits.
        case .loaded where !viewModel.libraryCredits.isEmpty && viewModel.creditsAreFinal:
            // Rows are focusable, so this is the one state that needs no Back
            // button of its own.
            VStack(alignment: .leading, spacing: 0) {
                // What they are known for, in the order the ranking produced.
                //
                // First and unsegmented, because splitting by kind is what
                // destroys that ranking: the whole point is that Sherlock
                // outranks a film, and a Movies shelf above a TV Shows shelf
                // cannot say so. It also answers for a voice actor whose entire
                // body of work is animation without the app having to decide
                // what counts as anime.
                shelf(
                    LocalizedStringResource(
                        "Known for",
                        comment: "Heading for a shelf of the titles a person is best known for, shown at the top of their page. Includes titles the viewer does not own."
                    ),
                    items: viewModel.libraryCredits
                )

                // Then what the viewer actually owns, shelved by the library it
                // came from.
                ForEach(ownedShelves, id: \.key) { group in
                    shelfBody(group.title.text, items: group.items)
                }
            }
        case .loading, .loaded where !viewModel.creditsAreFinal:
            creditlessState { ProgressView().scaleEffect(1.5) }
        case .loaded, .unavailable:
            // A source that couldn't answer and a person with genuinely nothing
            // else are indistinguishable here, and either way the honest thing to
            // say is that there is nothing to show.
            creditlessState {
                Text(
                    "Nothing else in your library with \(person.name).",
                    comment: "Empty state on a person's page. The placeholder is a person's name. Means the viewer owns nothing else featuring them, not that a lookup failed."
                )
                    .font(.system(size: metrics.sectionHeaderFontSize))
                    .multilineTextAlignment(.center)
                    .plozzForeground(.secondary)
            }
        }
    }

    /// One shelf of the person's work, or nothing when they have none of that
    /// kind. Split by kind because a prolific actor's single mixed row buries
    /// films among a dozen series (and vice versa), and the two are usually
    /// looked for separately.
    ///
    /// `kinds: nil` means "everything not claimed by a named row above", so no
    /// item can be silently dropped by adding a row.
    @ViewBuilder
    private func shelf(_ title: LocalizedStringResource, items: [MediaItem]) -> some View {
        shelfBody(Text(title), items: items)
    }

    @ViewBuilder
    private func shelfBody(_ title: Text, items: [MediaItem]) -> some View {
        if !items.isEmpty {
            MediaRowView(title: title, items: items, onSelect: onSelectItem)
                // Each shelf is its own focus section, which MediaRowView
                // deliberately does NOT do by default — ordinary rows stay
                // unsectioned to preserve tvOS's column-aligned projection.
                //
                // This page has to override that, because its header cannot
                // satisfy the projection: the biography is the only focusable
                // thing up there and it sits to the RIGHT of the headshot, so
                // nothing focusable is ever above a left-most card. With a
                // single movie at the left edge, Down from the biography found
                // no candidate in its corridor and skipped the whole Movies row
                // to land in TV Shows. A section captures the movement across
                // the full width instead, and remembers the last card focused
                // within it, so returning to a shelf comes back where you left.
                .personFocusSection()
        }
    }

    /// The owned credits, grouped into the shelves shown beneath "Known for".
    ///
    /// Grouped by the LIBRARY each title came from rather than by its kind, so
    /// the page mirrors how the viewer actually organises their media. Someone
    /// who keeps a separate Anime library gets an Anime shelf without the app
    /// classifying anything — which matters, because per-title anime detection
    /// is a heuristic that gets Arcane, Castlevania and Blue Eye Samurai wrong
    /// in one direction or the other. Someone with a Documentaries library gets
    /// that shelf too, for free.
    ///
    /// Keyed on the library's NAME, not its id, so the same library on two
    /// servers — a very common setup — collapses into one shelf instead of two
    /// identically titled ones.
    private var ownedShelves: [(key: String, title: ShelfTitle, items: [MediaItem])] {
        let owned = viewModel.libraryCredits.filter { $0.availability != .unknown }
        guard !owned.isEmpty else { return [] }

        var groups: [String: [MediaItem]] = [:]
        var titles: [String: ShelfTitle] = [:]
        var order: [String] = []
        for item in owned {
            let title = item.libraryID.flatMap { libraryNames[$0] }
                .map(ShelfTitle.library) ?? Self.fallbackTitle(item)
            let key = title.key
            if groups[key] == nil { order.append(key); titles[key] = title }
            groups[key, default: []].append(item)
        }

        var shelves = order.map {
            (key: $0, title: titles[$0] ?? .other, items: groups[$0] ?? [])
        }
        // A page of one-title shelves is worse than a page of two useful ones.
        // Past a handful of libraries the smallest are folded together rather
        // than each taking a full row's height for a single poster.
        if shelves.count > Self.maximumOwnedShelves {
            let sorted = shelves.sorted { $0.items.count > $1.items.count }
            let kept = Array(sorted.prefix(Self.maximumOwnedShelves - 1))
            let rest = sorted.dropFirst(Self.maximumOwnedShelves - 1).flatMap(\.items)
            shelves = kept
            if !rest.isEmpty {
                shelves.append((key: ShelfTitle.other.key, title: .other, items: rest))
            }
        }
        return shelves
    }

    /// A shelf heading, which is either the server's own library name or Plozz's
    /// wording — and those are localized differently.
    ///
    /// A library's name is content: it is whatever the viewer called their
    /// library and must render verbatim. Everything else here is app copy and
    /// has to go through the catalog, which is exactly the distinction the
    /// localization guard exists to enforce.
    private enum ShelfTitle {
        case library(String)
        case movies
        case series
        case other

        var key: String {
            switch self {
            case .library(let name): return "library:\(name)"
            case .movies: return "kind:movies"
            case .series: return "kind:series"
            case .other: return "kind:other"
            }
        }

        var text: Text {
            switch self {
            case .library(let name):
                return Text(verbatim: name)
            case .movies:
                return Text("Movies")
            case .series:
                return Text("TV Shows")
            case .other:
                return Text(LocalizedStringResource(
                    "person.shelf.inYourLibrary",
                    defaultValue: "In your library",
                    comment: "Heading for a shelf of titles the viewer owns featuring this person, used when the title's library is unknown or several small libraries are folded together."
                ))
            }
        }
    }

    /// Used when a title carries no library — a share catalog answering from its
    /// own records, or libraries that have not been discovered yet.
    private static func fallbackTitle(_ item: MediaItem) -> ShelfTitle {
        switch item.kind {
        case .movie: return .movies
        case .series, .episode: return .series
        default: return .other
        }
    }

    private static let maximumOwnedShelves = 4

    /// Any state with no credits row: the given content plus the focusable Back
    /// button that keeps Menu working.
    private func creditlessState(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(spacing: PlozzTheme.Spacing.large) {
            content()
            Button {
                dismiss()
            } label: {
                Label("Go Back", systemImage: "chevron.backward")
                    .frame(minWidth: 260)
            }
            .buttonStyle(.borderedProminent)
            .focused($backFocused)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
        .defaultFocus($backFocused, true)
    }
}
private extension View {
    /// `focusSection()` where it exists. tvOS-only API, and this view also builds
    /// for iOS.
    @ViewBuilder
    func personFocusSection() -> some View {
        #if os(tvOS)
        focusSection()
        #else
        self
        #endif
    }
}
#endif
