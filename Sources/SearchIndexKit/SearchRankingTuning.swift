import Foundation

public struct SearchRankingTuning: Codable, Equatable, Sendable {
    public let exactTitleWeight: Float
    public let partialTitleWeight: Float
    public let tokenCoverageWeight: Float
    public let minimumSemanticScore: Float

    public init(
        exactTitleWeight: Float = 1,
        partialTitleWeight: Float = 0.25,
        tokenCoverageWeight: Float = 0.35,
        minimumSemanticScore: Float = 0.2
    ) {
        self.exactTitleWeight = exactTitleWeight
        self.partialTitleWeight = partialTitleWeight
        self.tokenCoverageWeight = tokenCoverageWeight
        self.minimumSemanticScore = minimumSemanticScore
    }

    public static let `default` = SearchRankingTuning()

    public var weights: HybridRankingWeights {
        HybridRankingWeights(
            exactTitle: exactTitleWeight,
            partialTitle: partialTitleWeight,
            tokenCoverage: tokenCoverageWeight
        )
    }
}
