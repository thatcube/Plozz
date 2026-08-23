@testable import CoreModels
@testable import FeatureWatchlistCore
import XCTest

/// `MediaAliasDuplicateReconciler.reconcile` runs on every ledger write, so its
/// cost lands on the viewer's press. Measured on the Apple TV with 1,106 records
/// it took 5.5-8.2 seconds, and because the ledger is an actor the watchlist
/// button queued behind whichever write was already in flight.
///
/// These cover both halves of replacing the scan with an evidence index: that it
/// produces exactly what the scan produced, and that it is no longer quadratic.
final class MediaAliasDuplicateReconcilerScaleTests: XCTestCase {
    /// The original algorithm, kept here as the oracle.
    ///
    /// The optimisation is only worth anything if it is indistinguishable from
    /// this, so the equivalence is asserted against the real thing rather than
    /// against a description of it.
    private func referenceReconcile(
        _ input: [MediaAliasID: MediaAliasRecord]
    ) -> [MediaAliasID: MediaAliasRecord] {
        var records = input.mapValues { record -> MediaAliasRecord in
            var canonical = record.canonicalized()
            canonical.redirectTarget = nil
            return canonical
        }
        let ordered = records.values.sorted(by: MediaAliasDuplicateReconciler.wins)
        var clusters: [[MediaAliasID]] = []

        for record in ordered {
            let compatibleCluster = clusters.firstIndex { cluster in
                let members = cluster.compactMap { records[$0] }
                return members.contains {
                    MediaAliasDuplicateReconciler.sharesIdentityEvidence(record, $0)
                } && members.allSatisfy {
                    MediaAliasDuplicateReconciler.areCompatible(record, $0)
                }
            }
            if let compatibleCluster {
                clusters[compatibleCluster].append(record.id)
            } else {
                clusters.append([record.id])
            }
        }

        for cluster in clusters where cluster.count > 1 {
            guard let winnerID = cluster.compactMap({ records[$0] })
                .sorted(by: MediaAliasDuplicateReconciler.wins)
                .first?
                .id else { continue }
            for loserID in cluster where loserID != winnerID {
                records[loserID]?.redirectTarget = winnerID
                records[loserID]?.canonicalize()
            }
        }
        return records
    }

    /// A corpus shaped like a real ledger: mostly weak title/year records, some
    /// with catalogue ids, deliberate duplicates across both, and titles that
    /// share a name and year while carrying different strong ids — the case the
    /// clustering rules exist to keep apart.
    private func corpus(titles: Int, seed: UInt64) -> [MediaAliasID: MediaAliasRecord] {
        var rng = SeededGenerator(seed: seed)
        var result: [MediaAliasID: MediaAliasRecord] = [:]
        var createdAt: TimeInterval = 1_600_000_000

        for index in 0..<titles {
            let kind: MediaItemKind = index.isMultiple(of: 3) ? .series : .movie
            let title = "Title \(index)"
            let year = 1970 + (index % 55)
            let copies = 1 + Int(rng.next() % 3)

            for copy in 0..<copies {
                createdAt += 1
                var strong: [MediaAliasStrongEvidence] = []
                // Some copies carry ids, some don't, and a few carry a DIFFERENT
                // id for the same title/year.
                switch rng.next() % 4 {
                case 0:
                    strong = [
                        MediaAliasStrongEvidence(
                            kind: kind, namespace: .tmdb, value: "t\(index)"
                        )!
                    ]
                case 1:
                    strong = [
                        MediaAliasStrongEvidence(
                            kind: kind, namespace: .imdb, value: "tt\(index)\(copy)"
                        )!
                    ]
                default:
                    break
                }
                let record = MediaAliasRecord(
                    id: MediaAliasID(UUID()),
                    kind: kind,
                    createdAt: Date(timeIntervalSince1970: createdAt),
                    strongEvidence: strong,
                    weakEvidence: [
                        MediaAliasWeakEvidence(kind: kind, title: title, year: year)!
                    ]
                )!
                result[record.id] = record
            }
        }
        return result
    }

    func testIndexedClusteringMatchesTheOriginalScan() {
        for seed in UInt64(1)...5 {
            let input = corpus(titles: 120, seed: seed)
            let expected = referenceReconcile(input)
            let actual = MediaAliasDuplicateReconciler.reconcile(input)

            XCTAssertEqual(
                actual.count,
                expected.count,
                "seed \(seed): record count must be unchanged"
            )
            for (id, expectedRecord) in expected {
                XCTAssertEqual(
                    actual[id]?.redirectTarget,
                    expectedRecord.redirectTarget,
                    "seed \(seed): \(id) must collapse to the same winner as the scan"
                )
                XCTAssertEqual(
                    actual[id],
                    expectedRecord,
                    "seed \(seed): \(id) must be byte-identical to the scan's output"
                )
            }
        }
    }

    /// The ledger on the device holds ~1,100 records and is still growing. The
    /// scan was superlinear in that count; this pins that it no longer is.
    ///
    /// The bound is deliberately loose — it is here to catch a return to
    /// quadratic behaviour, not to police milliseconds on shared CI hardware.
    func testReconcileStaysFastAtLedgerScale() {
        let input = corpus(titles: 1_500, seed: 99)
        XCTAssertGreaterThan(input.count, 1_500)

        let started = Date()
        _ = MediaAliasDuplicateReconciler.reconcile(input)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(
            elapsed,
            2.0,
            "Reconciling \(input.count) records took \(elapsed)s — the watchlist press waits on this."
        )
    }

    /// Deterministic, so a failure is reproducible rather than a one-off shape.
    private struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64

        init(seed: UInt64) { state = seed &* 2_862_933_555_777_941_757 &+ 3_037_000_493 }

        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
    }
}
