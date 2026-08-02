import CoreModels
import Foundation
import XCTest
@testable import FeatureWatchlistCore

final class MediaAliasResolverTests: XCTestCase {
    func testKindScopedExternalCollisionDoesNotMergeMovieAndSeries() {
        let movie = record(
            id: id("00000000-0000-0000-0000-000000000001"),
            kind: .movie,
            strong: [strong(.movie, .tmdb, "42")]
        )
        let series = record(
            id: id("00000000-0000-0000-0000-000000000002"),
            kind: .series,
            strong: [strong(.series, .tmdb, "42")]
        )
        let snapshot = MediaAliasSnapshot(records: [movie, series])

        XCTAssertEqual(
            MediaAliasResolver.lookup(
                evidence: evidence(.movie, strong: [strong(.movie, .tmdb, "42")]),
                in: snapshot
            ),
            movie.id
        )
        XCTAssertEqual(
            MediaAliasResolver.lookup(
                evidence: evidence(.series, strong: [strong(.series, .tmdb, "42")]),
                in: snapshot
            ),
            series.id
        )
    }

    func testSameNamespaceConflictStaysSplit() {
        let existing = record(
            id: id("00000000-0000-0000-0000-000000000001"),
            kind: .movie,
            strong: [
                strong(.movie, .imdb, "tt1"),
                strong(.movie, .tmdb, "1"),
            ]
        )
        let snapshot = MediaAliasSnapshot(records: [existing])
        let incoming = evidence(
            .movie,
            strong: [
                strong(.movie, .imdb, "tt1"),
                strong(.movie, .tmdb, "2"),
            ]
        )

        XCTAssertNil(MediaAliasResolver.lookup(evidence: incoming, in: snapshot))
        let enriched = MediaAliasResolver.enriched(
            existing,
            with: incoming,
            at: Date(timeIntervalSince1970: 20)
        )
        XCTAssertEqual(
            enriched.strongEvidence.filter { $0.namespace == .tmdb }.map(\.value),
            ["1"]
        )
        XCTAssertEqual(enriched.conflicts.count, 1)
    }

    func testExplicitResolveCreatesSeparateAliasForConflictingStrongID() async throws {
        let existing = record(
            id: id("00000000-0000-0000-0000-000000000001"),
            kind: .movie,
            strong: [
                strong(.movie, .imdb, "tt1"),
                strong(.movie, .tmdb, "1"),
            ]
        )
        let ledger = try MediaAliasLedger(
            profileID: "p",
            store: InMemoryMediaAliasStore(
                MediaAliasLedgerState(records: [existing])
            )
        )
        let incoming = evidence(
            .movie,
            strong: [
                strong(.movie, .imdb, "tt1"),
                strong(.movie, .tmdb, "2"),
            ]
        )

        let created = try await ledger.resolveOrCreate(evidence: incoming)
        let snapshot = await ledger.snapshot()
        XCTAssertNotEqual(created, existing.id)
        XCTAssertEqual(snapshot.activeRecordCount, 2)
    }

    func testCompatibleCrossNamespaceEvidenceMatches() {
        let existing = record(
            id: id("00000000-0000-0000-0000-000000000001"),
            kind: .movie,
            strong: [
                strong(.movie, .imdb, "tt1"),
                strong(.movie, .tmdb, "1"),
            ]
        )
        let incoming = evidence(
            .movie,
            strong: [
                strong(.movie, .imdb, "tt1"),
                strong(.movie, .tvdb, "7"),
            ]
        )

        XCTAssertEqual(
            MediaAliasResolver.lookup(
                evidence: incoming,
                in: MediaAliasSnapshot(records: [existing])
            ),
            existing.id
        )
    }

    func testExactWeakTitleYearMatchesMoviesAndSeries() {
        let movieWeak = weak(.movie, "Dune", 2021)
        let seriesWeak = weak(.series, "Shōgun", 2024)
        let movie = record(
            id: id("00000000-0000-0000-0000-000000000001"),
            kind: .movie,
            weak: [movieWeak]
        )
        let series = record(
            id: id("00000000-0000-0000-0000-000000000002"),
            kind: .series,
            weak: [seriesWeak]
        )
        let snapshot = MediaAliasSnapshot(records: [movie, series])

        XCTAssertEqual(
            MediaAliasResolver.lookup(
                evidence: evidence(.movie, weak: weak(.movie, "dune", 2021)),
                in: snapshot
            ),
            movie.id
        )
        XCTAssertEqual(
            MediaAliasResolver.lookup(
                evidence: evidence(.series, weak: weak(.series, "shogun", 2024)),
                in: snapshot
            ),
            series.id
        )
        XCTAssertNil(MediaAliasResolver.lookup(
            evidence: evidence(.series, weak: weak(.series, "shogun", 2023)),
            in: snapshot
        ))
    }

    func testWeakEvidenceCannotTransitivelyBridgeConflictingAliases() {
        let sharedWeak = weak(.movie, "Collision", 2020)
        let first = record(
            id: id("00000000-0000-0000-0000-000000000001"),
            kind: .movie,
            strong: [strong(.movie, .tmdb, "1")],
            weak: [sharedWeak]
        )
        let second = record(
            id: id("00000000-0000-0000-0000-000000000002"),
            kind: .movie,
            strong: [strong(.movie, .tmdb, "2")],
            weak: [sharedWeak]
        )

        XCTAssertNil(MediaAliasResolver.lookup(
            evidence: evidence(.movie, weak: sharedWeak),
            in: MediaAliasSnapshot(records: [first, second])
        ))
    }

    func testBindingHintRequiresReceiverLocalValidation() throws {
        let binding = try XCTUnwrap(MediaAliasProviderBindingKey(
            providerKind: .plex,
            accountDescriptorID: "00000000-0000-0000-0000-000000000010",
            providerItemID: "99"
        ))
        let hint = MediaAliasProviderBindingHint(binding: binding)
        let alias = try XCTUnwrap(MediaAliasRecord(
            id: id("00000000-0000-0000-0000-000000000001"),
            kind: .movie,
            bindingHints: [hint],
            locallyValidatedBindings: [binding]
        ))
        let unvalidated = evidence(.movie, hints: [hint])
        let validated = evidence(.movie, hints: [hint], validated: [binding])
        let snapshot = MediaAliasSnapshot(records: [alias])

        XCTAssertNil(MediaAliasResolver.lookup(evidence: unvalidated, in: snapshot))
        XCTAssertEqual(
            MediaAliasResolver.lookup(evidence: validated, in: snapshot),
            alias.id
        )
    }

    func testInternallyConflictingEvidenceIsRejected() {
        XCTAssertNil(MediaAliasEvidence(
            kind: .movie,
            strong: [
                strong(.movie, .tmdb, "1"),
                strong(.movie, .tmdb, "2"),
            ]
        ))
    }

    func testLookupDoesNotMintAndExplicitResolveCreatesRandomAlias() async throws {
        let ledger = try MediaAliasLedger(
            profileID: "p1",
            store: InMemoryMediaAliasStore()
        )
        let request = evidence(.movie, weak: weak(.movie, "New", 2026))

        let missing = await ledger.lookup(evidence: request)
        let emptySnapshot = await ledger.snapshot()
        XCTAssertNil(missing)
        XCTAssertEqual(emptySnapshot.recordCount, 0)

        let first = try await ledger.resolveOrCreate(evidence: request)
        let populatedSnapshot = await ledger.snapshot()
        let found = await ledger.lookup(evidence: request)
        XCTAssertEqual(populatedSnapshot.recordCount, 1)
        XCTAssertEqual(found, first)

        let secondLedger = try MediaAliasLedger(
            profileID: "p2",
            store: InMemoryMediaAliasStore()
        )
        let second = try await secondLedger.resolveOrCreate(evidence: request)
        XCTAssertNotEqual(first, second)
    }

    private func id(_ value: String) -> MediaAliasID {
        MediaAliasID(UUID(uuidString: value)!)
    }

    private func strong(
        _ kind: MediaItemKind,
        _ namespace: ProviderIDNamespace,
        _ value: String
    ) -> MediaAliasStrongEvidence {
        MediaAliasStrongEvidence(kind: kind, namespace: namespace, value: value)!
    }

    private func weak(
        _ kind: MediaItemKind,
        _ title: String,
        _ year: Int
    ) -> MediaAliasWeakEvidence {
        MediaAliasWeakEvidence(kind: kind, title: title, year: year)!
    }

    private func evidence(
        _ kind: MediaItemKind,
        strong: [MediaAliasStrongEvidence] = [],
        weak: MediaAliasWeakEvidence? = nil,
        hints: [MediaAliasProviderBindingHint] = [],
        validated: Set<MediaAliasProviderBindingKey> = []
    ) -> MediaAliasEvidence {
        MediaAliasEvidence(
            kind: kind,
            strong: strong,
            weak: weak,
            bindingHints: hints,
            locallyValidatedBindings: validated
        )!
    }

    private func record(
        id: MediaAliasID,
        kind: MediaItemKind,
        strong: [MediaAliasStrongEvidence] = [],
        weak: [MediaAliasWeakEvidence] = []
    ) -> MediaAliasRecord {
        MediaAliasRecord(
            id: id,
            kind: kind,
            createdAt: Date(timeIntervalSince1970: 10),
            strongEvidence: strong,
            weakEvidence: weak
        )!
    }
}
