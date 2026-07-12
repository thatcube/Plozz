import XCTest
@testable import SearchIndexKit

#if DEBUG && canImport(NaturalLanguage)
final class SearchIndexSpikeTests: XCTestCase {
    func testModelQualityFormatsAndScale() async throws {
        let override = ProcessInfo.processInfo.environment["PLOZZ_SPIKE_DOCUMENT_COUNT"]
            .flatMap(Int.init)
        let report = try await SearchIndexSpikeRunner().run(
            scaleCounts: override.map { [$0] } ?? [10_000, 50_000, 100_000],
            sqliteScaleCounts: []
        )
        report.lines.forEach { print($0) }

        XCTAssertEqual(report.model.dimension, 512)
        for quality in report.quality {
            XCTAssertGreaterThanOrEqual(
                quality.topOneRate,
                0.8,
                "Format: \(quality.format.rawValue)"
            )
            XCTAssertGreaterThanOrEqual(
                quality.topFiveRate,
                0.95,
                "Format: \(quality.format.rawValue)"
            )
        }
        XCTAssertTrue(report.languageAvailability.contains { $0.hasPrefix("en=r") })
        XCTAssertEqual(report.scale.count, override == nil ? 3 : 1)
        XCTAssertGreaterThan(report.embeddingDocumentsPerSecond, 0)
    }
}
#endif
