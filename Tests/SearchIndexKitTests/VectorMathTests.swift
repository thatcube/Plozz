import XCTest
@testable import SearchIndexKit

final class VectorMathTests: XCTestCase {
    func testStorageFormatsRoundTripNormalizedVector() throws {
        let vector = try VectorMath.normalized([0.25, -0.5, 0.75, 0.125])
        let tolerances: [VectorStorageFormat: Float] = [
            .float32: 0.000_001,
            .float16: 0.001,
            .int8: 0.01
        ]

        for format in VectorStorageFormat.allCases {
            let data = try VectorCodec.encode(vector, format: format)
            let decoded = try VectorCodec.decode(
                data,
                format: format,
                dimension: vector.count
            )
            XCTAssertEqual(decoded.count, vector.count)
            for index in vector.indices {
                XCTAssertEqual(
                    decoded[index],
                    vector[index],
                    accuracy: tolerances[format] ?? 0
                )
            }
        }
    }

    func testAccelerateAndScalarDotProductsAgree() throws {
        let lhs = try VectorMath.normalized([1, 2, 3, 4])
        let rhs = try VectorMath.normalized([4, 3, 2, 1])
        let scalar = VectorMath.dot(lhs, rhs, implementation: .scalar)
        let accelerated = VectorMath.dot(lhs, rhs, implementation: .accelerate)
        XCTAssertEqual(accelerated, scalar, accuracy: 0.000_001)
    }

    func testRankerUsesBestSegmentAndStableTieBreak() async throws {
        let query = try VectorMath.normalized([1, 0])
        let matches = try await SemanticRanker.topMatches(
            query: query,
            candidates: [
                SemanticCandidate(sourceKey: "b", vectors: [[0, 1], [1, 0]]),
                SemanticCandidate(sourceKey: "a", vectors: [[1, 0]]),
                SemanticCandidate(sourceKey: "c", vectors: [[0, 1]])
            ],
            limit: 2
        )
        XCTAssertEqual(matches.map(\.sourceKey), ["a", "b"])
        XCTAssertEqual(matches.map(\.score), [1, 1])
    }

    func testRankerReplacesWorstBoundaryTieWithSmallerKey() async throws {
        let matches = try await SemanticRanker.topMatches(
            query: [1, 0],
            candidates: [
                SemanticCandidate(sourceKey: "b", vectors: [[1, 0]]),
                SemanticCandidate(sourceKey: "a", vectors: [[1, 0]])
            ],
            limit: 1
        )
        XCTAssertEqual(matches.map(\.sourceKey), ["a"])
    }

    func testInvalidPayloadIsRejected() {
        XCTAssertThrowsError(
            try VectorCodec.decode(Data([0, 1]), format: .float32, dimension: 2)
        )
    }

    func testHybridScorerBoostsMetadataOverlap() {
        let matching = HybridSearchScorer.lexicalBoost(
            query: "thieves take artwork during an event",
            title: "The Gallery",
            metadataText: "A detective prevents thieves from stealing a painting during a gala."
        )
        let unrelated = HybridSearchScorer.lexicalBoost(
            query: "thieves take artwork during an event",
            title: "Dinner",
            metadataText: "Amateur chefs compete to recreate a family recipe."
        )
        XCTAssertGreaterThan(matching, unrelated)
    }
}
