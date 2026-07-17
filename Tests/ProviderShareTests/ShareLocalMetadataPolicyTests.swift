import CoreModels
import Foundation
@testable import ProviderShare
import XCTest

final class ShareLocalMetadataPolicyTests: XCTestCase {
    func testFingerprintPolicyPrefersStrongFactsAndMarksWeakFacts() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(
            ShareSidecarFingerprintPolicy.evaluate(
                strongETag: "\"etag\"",
                changeToken: "token",
                stableFileID: "id",
                modifiedAt: date,
                size: 42
            ),
            .init(fingerprint: "etag:\"etag\"", scanGenerationBound: false)
        )
        XCTAssertEqual(
            ShareSidecarFingerprintPolicy.evaluate(
                strongETag: nil,
                changeToken: nil,
                stableFileID: nil,
                modifiedAt: date,
                size: 42
            ),
            .init(fingerprint: "mtime:1700000000:42", scanGenerationBound: true)
        )
    }

    func testAssociationPolicyEmitsOnlyApplicableLookups() {
        let lookups = ShareLocalMetadataAssociationPolicy.lookups(
            members: [
                .init(
                    relPath: "Movies/A/A.mkv",
                    isMovie: true,
                    genericRepresentativeRelPath: "Movies/A/A.mkv"
                ),
                .init(
                    relPath: "Movies/B/B.mkv",
                    isMovie: true,
                    genericRepresentativeRelPath: "Movies/B/Other.mkv"
                ),
            ],
            seriesRoots: ["TV/Show"]
        )
        XCTAssertEqual(Set(lookups), [
            .exactVideo(relPath: "Movies/A/A.mkv"),
            .genericMovie(parentDir: "Movies/A"),
            .exactVideo(relPath: "Movies/B/B.mkv"),
            .series(parentDir: "TV/Show"),
        ])
    }

    func testAssociationPolicyTargetsLogicalItemsFromPersistedFacts() {
        XCTAssertEqual(
            ShareLocalMetadataAssociationPolicy.itemID(
                for: .movieStem,
                associatedVideoRelPath: "Movies/A.mkv",
                facts: .init(
                    associatedVideoExists: true,
                    movieRepresentativeRelPath: "Movies/A 1080p.mkv"
                )
            ),
            ShareCatalogID.file("Movies/A 1080p.mkv")
        )
        XCTAssertNil(
            ShareLocalMetadataAssociationPolicy.itemID(
                for: .episodeStem,
                associatedVideoRelPath: "TV/Show/S01E01.mkv",
                facts: .init(associatedVideoExists: false)
            )
        )
        XCTAssertEqual(
            ShareLocalMetadataAssociationPolicy.itemID(
                for: .episodeStem,
                associatedVideoRelPath: "TV/Show/S01E01.mkv",
                facts: .init(associatedVideoExists: true)
            ),
            ShareCatalogID.file("TV/Show/S01E01.mkv")
        )
        XCTAssertEqual(
            ShareLocalMetadataAssociationPolicy.itemID(
                for: .series,
                associatedVideoRelPath: nil,
                facts: .init(seriesKey: "show")
            ),
            ShareCatalogID.series("show")
        )
    }

    func testReassociationPolicyReusesCacheWithoutRereading() {
        XCTAssertEqual(
            ShareLocalMetadataAssociationPolicy.reassociationPlan(
                priorItemID: nil,
                desiredItemID: "f:Movies/A.mkv",
                priorStatus: "ambiguous",
                cacheIsEmpty: false
            ),
            .init(status: "parsed", clearProcessedFingerprint: false)
        )
        XCTAssertEqual(
            ShareLocalMetadataAssociationPolicy.reassociationPlan(
                priorItemID: nil,
                desiredItemID: "f:Movies/A.mkv",
                priorStatus: "ambiguous",
                cacheIsEmpty: true
            ),
            .init(status: "pending", clearProcessedFingerprint: true)
        )
    }

    func testWinnerResolverRanksExactThenUsesGenericForMissingFields() {
        let winners = ShareLocalMetadataWinnerResolver.resolve([
            .init(
                relPath: "Movies/A/movie.nfo",
                kind: .movieGeneric,
                status: "parsed",
                fingerprint: "etag:generic",
                values: [.title: "\"Generic\"", .genres: "[\"Drama\"]"]
            ),
            .init(
                relPath: "Movies/A/A.nfo",
                kind: .movieStem,
                status: "parsed",
                fingerprint: "etag:exact",
                values: [.title: "\"Exact\""]
            ),
        ])
        let byField = Dictionary(uniqueKeysWithValues: winners.map { ($0.field, $0) })
        XCTAssertEqual(byField[.title]?.valueJSON, "\"Exact\"")
        XCTAssertEqual(byField[.genres]?.valueJSON, "[\"Drama\"]")
        XCTAssertEqual(byField[.title]?.source, .localNFO)
        XCTAssertFalse(byField[.title]?.sourceRevision?.contains("Movies/A/A.nfo") == true)
    }

    func testRepairPlannerSelectsOnlyStaleOrOutdatedItems() {
        let parsed = [
            ShareLocalMetadataParsedSidecar(sourceRevision: "current-a", itemID: "a"),
            ShareLocalMetadataParsedSidecar(sourceRevision: "current-b", itemID: "b"),
        ]
        let stored = [
            ShareLocalMetadataStoredValue(itemID: "a", sourceRevision: "current-a"),
            ShareLocalMetadataStoredValue(itemID: "stale", sourceRevision: "deleted"),
        ]
        XCTAssertEqual(
            ShareLocalMetadataRepairPlanner.itemIDsToRepair(
                parsedSidecars: parsed,
                storedValues: stored,
                localVersions: ["a": 1, "b": 0],
                currentVersion: 1
            ),
            ["b", "stale"]
        )
    }

    func testExplicitIDPolicyOmitsConflictsAndProjectsCompatibilityKeys() {
        XCTAssertEqual(
            ShareExplicitIDPolicy.canonicalize(namespace: "thetvdb", value: "81797")?.namespace,
            "tvdb"
        )
        XCTAssertEqual(
            ShareExplicitIDPolicy.unambiguous([
                ["tmdb": "100", "imdb": "tt123"],
                ["tmdb": "200", "imdb": "tt123"],
            ]),
            ["imdb": "tt123"]
        )
        XCTAssertEqual(
            ShareExplicitIDPolicy.unambiguous([
                ["tvdb": ShareExplicitIDPolicy.conflictMarker],
                ["tvdb": "100"],
            ]),
            [:]
        )
        XCTAssertEqual(ShareExplicitIDPolicy.projectedKey(namespace: "tmdb"), "Tmdb")
    }
}
