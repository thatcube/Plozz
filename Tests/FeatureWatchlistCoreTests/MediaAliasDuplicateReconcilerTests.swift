import CoreModels
import Foundation
import XCTest
@testable import FeatureWatchlistCore

final class MediaAliasDuplicateReconcilerTests: XCTestCase {
    func testOldestAliasWinsAndRedirectEvidenceStillResolves() {
        let shared = strong(.movie, .imdb, "tt1")
        let older = record(
            id: id("ffffffff-ffff-ffff-ffff-ffffffffffff"),
            createdAt: 10,
            strong: [shared, strong(.movie, .tmdb, "1")]
        )
        let newer = record(
            id: id("00000000-0000-0000-0000-000000000001"),
            createdAt: 20,
            strong: [shared, strong(.movie, .tvdb, "2")]
        )

        let result = MediaAliasDuplicateReconciler.reconcile([
            older.id: older,
            newer.id: newer,
        ])

        XCTAssertEqual(result[newer.id]?.redirectTarget, older.id)
        XCTAssertEqual(result[older.id]!.strongEvidence, older.strongEvidence)
        let snapshot = MediaAliasSnapshot(records: Array(result.values))
        XCTAssertEqual(
            snapshot.aliases(for: strong(.movie, .tvdb, "2")),
            [older.id]
        )
    }

    func testLexicalUUIDBreaksCreatedAtTie() {
        let low = record(
            id: id("00000000-0000-0000-0000-000000000001"),
            createdAt: 10,
            strong: [strong(.movie, .tmdb, "1")]
        )
        let high = record(
            id: id("ffffffff-ffff-ffff-ffff-ffffffffffff"),
            createdAt: 10,
            strong: [strong(.movie, .tmdb, "1")]
        )

        let result = MediaAliasDuplicateReconciler.reconcile([
            high.id: high,
            low.id: low,
        ])

        XCTAssertNil(result[low.id]?.redirectTarget)
        XCTAssertEqual(result[high.id]?.redirectTarget, low.id)
    }

    func testReconciliationIsIdempotentAndFlattensRedirect() {
        let evidence = strong(.series, .tvdb, "7")
        let first = record(
            id: id("00000000-0000-0000-0000-000000000001"),
            createdAt: 1,
            kind: .series,
            strong: [evidence]
        )
        let second = record(
            id: id("00000000-0000-0000-0000-000000000002"),
            createdAt: 2,
            kind: .series,
            strong: [evidence]
        )
        let third = record(
            id: id("00000000-0000-0000-0000-000000000003"),
            createdAt: 3,
            kind: .series,
            strong: [evidence]
        )

        let once = MediaAliasDuplicateReconciler.reconcile([
            first.id: first,
            second.id: second,
            third.id: third,
        ])
        let twice = MediaAliasDuplicateReconciler.reconcile(once)

        XCTAssertEqual(once, twice)
        XCTAssertEqual(once[second.id]?.redirectTarget, first.id)
        XCTAssertEqual(once[third.id]?.redirectTarget, first.id)
    }

    func testConflictingSameNamespaceEvidenceStaysSplit() {
        let sharedWeak = weak(.movie, "Same", 2020)
        let first = record(
            id: id("00000000-0000-0000-0000-000000000001"),
            createdAt: 1,
            strong: [strong(.movie, .tmdb, "1")],
            weak: [sharedWeak]
        )
        let second = record(
            id: id("00000000-0000-0000-0000-000000000002"),
            createdAt: 2,
            strong: [strong(.movie, .tmdb, "2")],
            weak: [sharedWeak]
        )

        let result = MediaAliasDuplicateReconciler.reconcile([
            first.id: first,
            second.id: second,
        ])

        XCTAssertNil(result[first.id]?.redirectTarget)
        XCTAssertNil(result[second.id]?.redirectTarget)
        XCTAssertEqual(result[first.id]?.strongEvidence, first.strongEvidence)
        XCTAssertEqual(result[second.id]?.strongEvidence, second.strongEvidence)
    }

    func testWeakMatchDoesNotTransitivelyBridgeStrongConflict() {
        let sharedWeak = weak(.movie, "Bridge", 2020)
        let firstStrong = strong(.movie, .tmdb, "1")
        let secondStrong = strong(.movie, .tmdb, "2")
        let first = record(
            id: id("00000000-0000-0000-0000-000000000001"),
            createdAt: 1,
            strong: [firstStrong],
            weak: [sharedWeak]
        )
        let middle = record(
            id: id("00000000-0000-0000-0000-000000000002"),
            createdAt: 2,
            weak: [sharedWeak]
        )
        let second = record(
            id: id("00000000-0000-0000-0000-000000000003"),
            createdAt: 3,
            strong: [secondStrong],
            weak: [sharedWeak]
        )

        let result = MediaAliasDuplicateReconciler.reconcile([
            first.id: first,
            middle.id: middle,
            second.id: second,
        ])
        let snapshot = MediaAliasSnapshot(records: Array(result.values))

        XCTAssertEqual(snapshot.activeRecordCount, 2)
        XCTAssertNotEqual(
            snapshot.resolvedAliasID(for: first.id),
            snapshot.resolvedAliasID(for: second.id)
        )
    }

    func testIncrementalBatchesConvergeAcrossNonTransitiveBridge() {
        let sharedWeak = weak(.movie, "Bridge", 2020)
        let first = record(
            id: id("00000000-0000-0000-0000-000000000001"),
            createdAt: 1,
            strong: [strong(.movie, .tmdb, "1")],
            weak: [sharedWeak]
        )
        let bridge = record(
            id: id("00000000-0000-0000-0000-000000000002"),
            createdAt: 2,
            weak: [sharedWeak]
        )
        let second = record(
            id: id("00000000-0000-0000-0000-000000000003"),
            createdAt: 3,
            strong: [strong(.movie, .tmdb, "2")],
            weak: [sharedWeak]
        )

        let firstBatch = MediaAliasDuplicateReconciler.reconcile([
            first.id: first,
            bridge.id: bridge,
        ])
        let firstThenSecond = MediaAliasDuplicateReconciler.reconcile(
            firstBatch.merging([second.id: second]) { _, incoming in incoming }
        )
        let secondBatch = MediaAliasDuplicateReconciler.reconcile([
            bridge.id: bridge,
            second.id: second,
        ])
        let secondThenFirst = MediaAliasDuplicateReconciler.reconcile(
            secondBatch.merging([first.id: first]) { _, incoming in incoming }
        )

        XCTAssertEqual(firstThenSecond, secondThenFirst)
        XCTAssertEqual(firstThenSecond[bridge.id]?.redirectTarget, first.id)
        XCTAssertNil(firstThenSecond[second.id]?.redirectTarget)
    }

    func testInvalidRemoteRedirectGraphIsRecomputed() {
        let shared = strong(.movie, .imdb, "tt1")
        var first = record(
            id: id("00000000-0000-0000-0000-000000000001"),
            createdAt: 1,
            strong: [shared]
        )
        var second = record(
            id: id("00000000-0000-0000-0000-000000000002"),
            createdAt: 2,
            strong: [shared]
        )
        first.redirectTarget = second.id
        second.redirectTarget = first.id

        let result = MediaAliasDuplicateReconciler.reconcile([
            first.id: first,
            second.id: second,
        ])

        XCTAssertNil(result[first.id]?.redirectTarget)
        XCTAssertEqual(result[second.id]?.redirectTarget, first.id)
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

    private func record(
        id: MediaAliasID,
        createdAt: TimeInterval,
        kind: MediaItemKind = .movie,
        strong: [MediaAliasStrongEvidence] = [],
        weak: [MediaAliasWeakEvidence] = []
    ) -> MediaAliasRecord {
        MediaAliasRecord(
            id: id,
            kind: kind,
            createdAt: Date(timeIntervalSince1970: createdAt),
            strongEvidence: strong,
            weakEvidence: weak
        )!
    }
}
