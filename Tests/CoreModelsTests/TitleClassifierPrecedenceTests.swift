import XCTest
@testable import CoreModels

/// The two questions the universal identity work had to answer about ownership,
/// pinned so neither can quietly regress.
///
/// Both were reviewed by two independent models; where they disagreed the decision
/// and its reasoning are recorded in ``TitleClassifier``'s doc comments.
final class TitleClassifierPrecedenceTests: XCTestCase {
    private func validated(_ availability: MediaAvailabilityStatus?) -> MediaItem {
        var item = MediaItem(
            id: "lib-1",
            title: "Owned",
            kind: .movie,
            locallyValidatedPlayableSource: true
        )
        item.availability = availability
        return item
    }

    // MARK: - Question A: local proof outranks a provider's availability

    /// A copy the app validated keeps its library page whatever a metadata or Seerr
    /// provider says about it — for every availability case, with no index peer.
    func testLocalValidationOutranksEveryDiscoveryAvailability() {
        for availability in [
            MediaAvailabilityStatus.unknown,
            .pending,
            .processing,
            .deleted,
        ] {
            let item = validated(availability)
            XCTAssertFalse(
                TitleClassifier.isDiscoveryRouting(item, identitySources: []),
                "\(availability) must not strip a validated page"
            )
            XCTAssertEqual(
                item.heroCTA(seerConnected: true),
                .play,
                "routing must stay the exact complement of the CTA for \(availability)"
            )
        }
    }

    /// The other side: nothing validated and no indexed peer still routes to
    /// discovery, so dropping the clause cannot start claiming ownership.
    func testUnvalidatedTitleWithNoIndexPeerStillRoutesToDiscovery() {
        var item = MediaItem(
            id: "seer:1",
            title: "Missing",
            kind: .movie,
            locallyValidatedPlayableSource: false
        )
        item.availability = .unknown

        XCTAssertTrue(TitleClassifier.isDiscoveryRouting(item, identitySources: []))
    }

    /// Routing is the exact complement of `canPlay`. Stated as a test because the
    /// two are separate fields and someone will otherwise "simplify" one of them.
    func testRoutingIsTheComplementOfOwnership() {
        for validatedFlag in [true, false] {
            for sources in [[], [MediaSourceRef(accountID: "a", itemID: "1", kind: .movie)]] {
                var item = MediaItem(
                    id: "x",
                    title: "X",
                    kind: .movie,
                    locallyValidatedPlayableSource: validatedFlag
                )
                item.availability = .unknown
                XCTAssertEqual(
                    TitleClassifier.isDiscoveryRouting(item, identitySources: sources),
                    !item.ownershipPresentation(additionalSources: sources).canPlay
                )
            }
        }
    }

    // MARK: - Question B: liveness never gates classification

    /// Which page a tap opens must not depend on whether the index happened to warm.
    /// This was the real defect behind the old routing clause.
    func testRoutingIsIdenticalColdAndWarm() {
        let item = validated(.unknown)
        let warm = [MediaSourceRef(accountID: "a", itemID: "1", kind: .movie)]

        XCTAssertEqual(
            TitleClassifier.isDiscoveryRouting(item, identitySources: []),
            TitleClassifier.isDiscoveryRouting(item, identitySources: warm)
        )
    }

    /// Airplane mode: no account is reachable and the index is empty, and a
    /// downloaded title must still present as owned and playable. This is the
    /// constraint that rules out gating classification on liveness outright.
    func testDownloadedTitleStaysPlayableWithAnEmptyIndex() {
        let item = MediaItem(
            id: "dl-1",
            title: "Downloaded",
            kind: .movie,
            locallyValidatedPlayableSource: true
        )

        XCTAssertFalse(TitleClassifier.isDiscoveryRouting(item, identitySources: []))
        XCTAssertFalse(TitleClassifier.isNotOwnedForBadge(item))
    }

    /// A tripwire, and worth writing precisely because it looks vacuous: the badge
    /// takes no index input at all, so a mark cannot flip while the viewer is
    /// looking at a screen. It fails the moment anyone threads the index in.
    func testBadgeIsInvariantAcrossIndexWarming() {
        var item = MediaItem(
            id: "c-1",
            title: "Card",
            kind: .movie,
            locallyValidatedPlayableSource: false
        )
        item.availability = .unknown
        let before = TitleClassifier.isNotOwnedForBadge(item)

        // Every "warmth" a card could ever be handed — the signature admits none.
        XCTAssertEqual(TitleClassifier.isNotOwnedForBadge(item), before)
        XCTAssertTrue(before)
    }

    // MARK: - One ruleset, two questions

    /// The weak-evidence asymmetry, pinned on both sides so neither half is
    /// "corrected" into the other. See ``MediaAliasWeakEvidence``'s doc for why.
    func testWeakEvidenceRulesetIsConsistentlyConservative() {
        // The ledger admits a series — but only with a year, which is what makes it
        // safe. Without one it refuses, for movies and series alike.
        XCTAssertNotNil(MediaAliasWeakEvidence(kind: .series, title: "Foundation", year: 2021))
        XCTAssertNil(MediaAliasWeakEvidence(kind: .series, title: "Foundation", year: nil))
        XCTAssertNil(MediaAliasWeakEvidence(kind: .movie, title: "Dune", year: nil))
        // And never a kind that cannot own durable identity.
        XCTAssertNil(MediaAliasWeakEvidence(kind: .episode, title: "Pilot", year: 2021))

        // The merger stays movies-only: two series sharing a title and year must not
        // be handed each other's servers, because being wrong there plays the wrong
        // thing rather than merging two rows.
        let seriesTitleIdentities = MediaItemIdentity.identities(
            for: MediaItem(id: "s", title: "Foundation", kind: .series, productionYear: 2021)
        )
        XCTAssertFalse(seriesTitleIdentities.contains { identity in
            if case .title = identity { return true }
            return false
        })
        let movieTitleIdentities = MediaItemIdentity.identities(
            for: MediaItem(id: "m", title: "Dune", kind: .movie, productionYear: 2021)
        )
        XCTAssertTrue(movieTitleIdentities.contains { identity in
            if case .title = identity { return true }
            return false
        })
    }

    /// The producer-side half of the badge decision: once a genuinely validated
    /// member folds in, the stale discovery availability is cleared, so no item ever
    /// reaches a card both validated and flagged — which is what stops the card and
    /// the page it opens from disagreeing while the badge stays fail-closed.
    func testMergeClearsAStaleDiscoveryAvailabilityOnceOwnedCopyFoldsIn() {
        var discovery = MediaItem(
            id: "seer:1",
            title: "Dune",
            kind: .movie,
            productionYear: 2021,
            providerIDs: ["Tmdb": "438631"],
            locallyValidatedPlayableSource: false
        )
        discovery.availability = .pending
        var owned = MediaItem(
            id: "jf-1",
            title: "Dune",
            kind: .movie,
            productionYear: 2021,
            providerIDs: ["Tmdb": "438631"],
            locallyValidatedPlayableSource: true
        )
        owned.sourceAccountID = "jf"

        let merged = MediaItemMerger.merge([discovery, owned])

        XCTAssertEqual(merged.count, 1)
        guard let item = merged.first else { return XCTFail("merge dropped the title") }
        XCTAssertNil(item.availability)
        XCTAssertFalse(TitleClassifier.isNotOwnedForBadge(item))
        XCTAssertFalse(TitleClassifier.isDiscoveryRouting(item, identitySources: []))
    }

    /// And the converse: a merge with nothing validated keeps the discovery
    /// availability, so the badge still fires.
    func testMergeKeepsDiscoveryAvailabilityWhenNothingIsValidated() {
        var a = MediaItem(
            id: "seer:1",
            title: "Dune",
            kind: .movie,
            productionYear: 2021,
            providerIDs: ["Tmdb": "438631"],
            locallyValidatedPlayableSource: false
        )
        a.availability = .pending
        var b = MediaItem(
            id: "seer:2",
            title: "Dune",
            kind: .movie,
            productionYear: 2021,
            providerIDs: ["Tmdb": "438631"],
            locallyValidatedPlayableSource: false
        )
        b.availability = .pending

        let merged = MediaItemMerger.merge([a, b])

        guard let item = merged.first else { return XCTFail("merge dropped the title") }
        XCTAssertEqual(item.availability, .pending)
        XCTAssertTrue(TitleClassifier.isNotOwnedForBadge(item))
    }

    /// The badge deliberately keeps the availability clause routing drops, because
    /// `locallyValidatedPlayableSource` defaults to `true` and a badge resting on it
    /// alone would fail *open* — silently claiming ownership of anything a future
    /// producer forgot to flag.
    func testBadgeStaysFailClosedForAFlaggedItemWithTheDefaultValidationBit() {
        var item = MediaItem(id: "d-1", title: "Discovery", kind: .movie)
        item.availability = .unknown

        XCTAssertTrue(item.locallyValidatedPlayableSource, "default is the trap")
        XCTAssertTrue(TitleClassifier.isNotOwnedForBadge(item))
    }
}
