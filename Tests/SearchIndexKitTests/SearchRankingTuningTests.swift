import XCTest
@testable import SearchIndexKit

final class SearchRankingTuningTests: XCTestCase {
    func testDefaultTuningMatchesProductionWeights() {
        let tuning = SearchRankingTuning.default
        XCTAssertEqual(tuning.weights, HybridRankingWeights())
        XCTAssertEqual(tuning.minimumSemanticScore, 0.2)
    }

    func testTuningRoundTripsForEvaluationTools() throws {
        let tuning = SearchRankingTuning(
            exactTitleWeight: 0.8,
            partialTitleWeight: 0.2,
            tokenCoverageWeight: 0.5,
            minimumSemanticScore: 0.3
        )
        let decoded = try JSONDecoder().decode(
            SearchRankingTuning.self,
            from: JSONEncoder().encode(tuning)
        )
        XCTAssertEqual(decoded, tuning)
    }
}
