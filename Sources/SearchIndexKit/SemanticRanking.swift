import Foundation
import CoreModels

public struct SemanticCandidate: Sendable {
    public let sourceKey: String
    public let vectors: [[Float]]

    public init(sourceKey: String, vectors: [[Float]]) {
        self.sourceKey = sourceKey
        self.vectors = vectors
    }
}

public struct SemanticVectorScore: Equatable, Sendable {
    public let sourceKey: String
    public let score: Float

    public init(sourceKey: String, score: Float) {
        self.sourceKey = sourceKey
        self.score = score
    }
}

public struct SearchIndexMatch: Sendable {
    public let sourceKey: String
    public let item: MediaItem
    public let semanticScore: Float
    public let combinedScore: Float

    public init(
        sourceKey: String,
        item: MediaItem,
        semanticScore: Float,
        combinedScore: Float
    ) {
        self.sourceKey = sourceKey
        self.item = item
        self.semanticScore = semanticScore
        self.combinedScore = combinedScore
    }
}

private struct TopKValue<Value> {
    let value: Value
    let score: Float
    let key: String
}

private enum TopK {
    static func insert<Value>(
        _ value: Value,
        score: Float,
        key: String,
        into best: inout [TopKValue<Value>],
        limit: Int
    ) {
        guard limit > 0 else { return }
        if let worst = best.last,
           best.count >= limit,
           score < worst.score || (score == worst.score && key >= worst.key) {
            return
        }
        let insertion = best.firstIndex {
            score > $0.score || (score == $0.score && key < $0.key)
        } ?? best.endIndex
        best.insert(TopKValue(value: value, score: score, key: key), at: insertion)
        if best.count > limit {
            best.removeLast()
        }
    }
}

public enum SemanticRanker {
    public static func topMatches(
        query: [Float],
        candidates: [SemanticCandidate],
        limit: Int,
        minimumScore: Float = -.infinity,
        implementation: DotProductImplementation = .automatic
    ) async throws -> [SemanticVectorScore] {
        guard limit > 0 else { return [] }
        var best: [TopKValue<SemanticVectorScore>] = []

        for (index, candidate) in candidates.enumerated() {
            if index.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
            var score = -Float.infinity
            for vector in candidate.vectors where vector.count == query.count {
                score = max(
                    score,
                    VectorMath.dot(query, vector, implementation: implementation)
                )
            }
            guard score >= minimumScore else { continue }
            let match = SemanticVectorScore(sourceKey: candidate.sourceKey, score: score)
            TopK.insert(
                match,
                score: score,
                key: candidate.sourceKey,
                into: &best,
                limit: limit
            )
        }
        return best.map(\.value)
    }
}

public struct HybridRankingWeights: Equatable, Sendable {
    public let exactTitle: Float
    public let partialTitle: Float
    public let tokenCoverage: Float

    public init(
        exactTitle: Float = 1,
        partialTitle: Float = 0.25,
        tokenCoverage: Float = 0.35
    ) {
        self.exactTitle = exactTitle
        self.partialTitle = partialTitle
        self.tokenCoverage = tokenCoverage
    }
}

public struct HybridRankingInput: Sendable {
    public let sourceKey: String
    public let item: MediaItem
    public let metadataText: String
    public let semanticScore: Float

    public init(
        sourceKey: String,
        item: MediaItem,
        metadataText: String,
        semanticScore: Float
    ) {
        self.sourceKey = sourceKey
        self.item = item
        self.metadataText = metadataText
        self.semanticScore = semanticScore
    }
}

public struct HybridRankingPolicy: Sendable {
    public let weights: HybridRankingWeights

    public init(weights: HybridRankingWeights = HybridRankingWeights()) {
        self.weights = weights
    }

    public func lexicalBoost(
        query: String,
        title: String,
        metadataText: String
    ) -> Float {
        let normalizedQuery = SearchDocumentBuilder.normalized(query)
        let normalizedTitle = SearchDocumentBuilder.normalized(title)
        let titleBoost: Float
        if normalizedTitle == normalizedQuery {
            titleBoost = weights.exactTitle
        } else if normalizedTitle.contains(normalizedQuery) ||
                    normalizedQuery.contains(normalizedTitle) {
            titleBoost = weights.partialTitle
        } else {
            titleBoost = 0
        }

        let queryTokens = Set(normalizedQuery.split(separator: " ").map(String.init))
        guard !queryTokens.isEmpty else { return titleBoost }
        let metadataTokens = Set(
            SearchDocumentBuilder.normalized(metadataText)
                .split(separator: " ")
                .map(String.init)
        )
        let coverage = Float(queryTokens.intersection(metadataTokens).count) /
            Float(queryTokens.count)
        return titleBoost + coverage * weights.tokenCoverage
    }

    public func rank(
        _ inputs: [HybridRankingInput],
        query: String,
        limit: Int
    ) async throws -> [SearchIndexMatch] {
        var best: [TopKValue<SearchIndexMatch>] = []
        for (index, input) in inputs.enumerated() {
            if index.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            let combined = input.semanticScore + lexicalBoost(
                query: query,
                title: input.item.title,
                metadataText: input.metadataText
            )
            let match = SearchIndexMatch(
                sourceKey: input.sourceKey,
                item: input.item,
                semanticScore: input.semanticScore,
                combinedScore: combined
            )
            TopK.insert(
                match,
                score: combined,
                key: input.sourceKey,
                into: &best,
                limit: limit
            )
        }
        return best.map(\.value)
    }
}
