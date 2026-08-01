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
    /// The viewer's own copies of a title, by strong external id, from the eager
    /// identity index.
    ///
    /// External credits arrive stamped `availability == .unknown` because the
    /// provider that supplied them has no idea what the viewer owns — it is a
    /// statement about TMDb, not about the library. Believing it literally put a
    /// "not in your library" mark on shows the viewer owns, because a server's
    /// person query is the wrong instrument for the question: Jellyfin returns
    /// only titles whose own People list names the person, and a series records
    /// its main cast rather than a guest voice part. For Hugh Jackman that meant
    /// 18 credits back, every one a film and not a single series, while The
    /// Simpsons and Rick and Morty — both owned — came back from TMDb flagged
    /// absent.
    ///
    /// Asking the index by id closes that gap without another network call.
    private let librarySources: @Sendable (MediaItem) -> [MediaSourceRef]
    private let limit: Int

    public init(
        person: MediaPerson,
        provider: (any MediaProvider)?,
        otherProviders: [any MediaProvider] = [],
        biographyProviders: [any PersonBiographyProvider] = [],
        creditsProviders: [any PersonCreditsProviding] = [],
        artworkResolver: (any PersonCreditArtworkResolving)? = nil,
        includeCredit: @escaping @Sendable (MediaItem) -> Bool = { _ in true },
        librarySources: @escaping @Sendable (MediaItem) -> [MediaSourceRef] = { _ in [] },
        limit: Int = 40
    ) {
        self.person = person
        self.provider = provider
        self.otherProviders = otherProviders
        self.biographyProviders = biographyProviders
        self.creditsProviders = creditsProviders
        self.artworkResolver = artworkResolver
        self.includeCredit = includeCredit
        self.librarySources = librarySources
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

    /// Rewrites an external credit the viewer turns out to own.
    ///
    /// Clears `availability` — the field is what marks a title as discovery, and
    /// keeping it while attaching real sources would leave the item claiming both
    /// — and attaches the index's source refs so the detail page can select a
    /// server and resolve the real library item id (the credit's own id is a
    /// provider id like `tmdb:tv:456`, which no server can load).
    ///
    /// Leaves everything else alone, including artwork and rank: ownership
    /// changes what the viewer can DO with a title, not what it is or how well
    /// known it is.
    private func reconciledWithLibrary(_ item: MediaItem) -> MediaItem {
        guard item.isNotInLibraryDiscovery else { return item }
        let owned = librarySources(item)
        guard !owned.isEmpty else { return item }
        var resolved = item
        resolved.availability = nil
        var seen = Set<String>()
        resolved.sources = (item.sources + owned).filter { seen.insert($0.id).inserted }
        return resolved
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

    /// Collapses duplicates within ONE server's answer.
    ///
    /// The cross-server merge deduped every server's list against the first
    /// one's, but the first one's was taken raw — so a title a single server
    /// returned twice was never checked against itself and reached the row as two
    /// posters. Ryan Reynolds showed Deadpool and Deadpool 2 twice each for
    /// exactly this reason: both copies carried an identical
    /// `movie|deadpool 2|2018` key, so they had simply never been compared.
    ///
    /// A server legitimately returns the same work more than once — the same film
    /// in two libraries, or as separate versions/editions — and for a credits row
    /// those are one title.
    ///
    /// Keeps the first occurrence so the server's own ordering survives, but
    /// takes a later copy's artwork if the winner had none: which duplicate came
    /// first is arbitrary, and a poster is not.
    static func collapsingDuplicates(_ items: [MediaItem]) -> [MediaItem] {
        var result: [MediaItem] = []
        var indexByKey: [String: Int] = [:]
        for item in items {
            let key = dedupeKey(item)
            guard let existing = indexByKey[key] else {
                indexByKey[key] = result.count
                result.append(item)
                continue
            }
            if result[existing].posterURL == nil, let poster = item.posterURL {
                result[existing].posterURL = poster
            }
        }
        return result
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
            libraryCredits = Self.collapsingDuplicates(items.filter(includeCredit))
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
            // Snapshotted before the external rungs are folded in, so the log
            // below can show what the servers actually answered with.
            let ownedKeysForDiagnostics = merged.map {
                "\($0.kind.rawValue)|\($0.title)|\($0.productionYear.map(String.init) ?? "-")"
            }
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
            // Before anything is ranked or displayed, ask the index which of
            // these the viewer actually owns. A credit that resolves stops being
            // a discovery title everywhere at once: no "not in your library"
            // mark on its poster, and its detail page opens on the real library
            // copy with Play instead of a request pill.
            merged = merged.map(reconciledWithLibrary)
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
            // TEMPORARY (issue: owned titles wearing the not-in-library mark).
            // Counts alone cannot say WHICH entry failed to dedupe, so list the
            // keys on both sides: what the servers own, and what survived from
            // the external rungs still flagged unowned. The overlap between
            // those two lists is the bug.
            PersonDiagnostics.emit(
                "person.owned-keys name=\(person.name) "
                + ownedKeysForDiagnostics.joined(separator: " ~ ")
            )
            PersonDiagnostics.emit(
                "person.unowned-keys name=\(person.name) "
                + merged.filter(\.isNotInLibraryDiscovery)
                    .map { "\($0.kind.rawValue)|\($0.title)|\($0.productionYear.map(String.init) ?? "-")" }
                    .joined(separator: " ~ ")
            )
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
#endif
