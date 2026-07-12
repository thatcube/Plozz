import Foundation

#if canImport(Accelerate)
import Accelerate
#endif

public enum VectorStorageFormat: String, Codable, CaseIterable, Sendable {
    case float32
    case float16
    case int8
}

public enum VectorCodecError: Error, Equatable {
    case invalidDimension
    case invalidByteCount
    case zeroMagnitude
}

public enum DotProductImplementation: Sendable {
    case automatic
    case scalar
    case accelerate
}

public enum VectorMath {
    public static func normalized(_ vector: [Float]) throws -> [Float] {
        guard !vector.isEmpty else { throw VectorCodecError.invalidDimension }
        var squaredMagnitude: Float = 0
        for value in vector {
            squaredMagnitude += value * value
        }
        guard squaredMagnitude.isFinite, squaredMagnitude > 0 else {
            throw VectorCodecError.zeroMagnitude
        }
        let inverseMagnitude = 1 / sqrt(squaredMagnitude)
        return vector.map { $0 * inverseMagnitude }
    }

    public static func dot(
        _ lhs: [Float],
        _ rhs: [Float],
        implementation: DotProductImplementation = .automatic
    ) -> Float {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return -.infinity }
        switch implementation {
        case .scalar:
            return scalarDot(lhs, rhs)
        case .automatic, .accelerate:
            #if canImport(Accelerate)
            var result: Float = 0
            vDSP_dotpr(lhs, 1, rhs, 1, &result, vDSP_Length(lhs.count))
            return result
            #else
            return scalarDot(lhs, rhs)
            #endif
        }
    }

    private static func scalarDot(_ lhs: [Float], _ rhs: [Float]) -> Float {
        var result: Float = 0
        for index in lhs.indices {
            result += lhs[index] * rhs[index]
        }
        return result
    }
}

public enum VectorCodec {
    public static func encode(
        _ vector: [Float],
        format: VectorStorageFormat
    ) throws -> Data {
        guard !vector.isEmpty else { throw VectorCodecError.invalidDimension }
        switch format {
        case .float32:
            return vector.withUnsafeBytes { Data($0) }
        case .float16:
            let values = vector.map(Float16.init)
            return values.withUnsafeBytes { Data($0) }
        case .int8:
            let maximum = vector.reduce(Float.zero) { max($0, abs($1)) }
            guard maximum > 0 else { throw VectorCodecError.zeroMagnitude }
            var scale = maximum / 127
            let quantized: [Int8] = vector.map { value in
                let rounded = (value / scale).rounded()
                return Int8(clamping: Int(rounded))
            }
            var data = withUnsafeBytes(of: &scale) { Data($0) }
            data.append(contentsOf: quantized.map { UInt8(bitPattern: $0) })
            return data
        }
    }

    public static func decode(
        _ data: Data,
        format: VectorStorageFormat,
        dimension: Int
    ) throws -> [Float] {
        guard dimension > 0 else { throw VectorCodecError.invalidDimension }
        switch format {
        case .float32:
            guard data.count == dimension * MemoryLayout<Float>.stride else {
                throw VectorCodecError.invalidByteCount
            }
            var values = [Float](repeating: 0, count: dimension)
            values.withUnsafeMutableBytes { destination in
                _ = data.copyBytes(to: destination)
            }
            return values
        case .float16:
            guard data.count == dimension * MemoryLayout<Float16>.stride else {
                throw VectorCodecError.invalidByteCount
            }
            var values = [Float16](repeating: 0, count: dimension)
            values.withUnsafeMutableBytes { destination in
                _ = data.copyBytes(to: destination)
            }
            return values.map(Float.init)
        case .int8:
            let headerSize = MemoryLayout<Float>.stride
            guard data.count == headerSize + dimension else {
                throw VectorCodecError.invalidByteCount
            }
            var scale: Float = 0
            withUnsafeMutableBytes(of: &scale) { destination in
                _ = data.copyBytes(to: destination, from: 0..<headerSize)
            }
            return data.dropFirst(headerSize).map {
                Float(Int8(bitPattern: $0)) * scale
            }
        }
    }
}

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

public enum SemanticRanker {
    public static func topMatches(
        query: [Float],
        candidates: [SemanticCandidate],
        limit: Int,
        minimumScore: Float = -.infinity,
        implementation: DotProductImplementation = .automatic
    ) async throws -> [SemanticVectorScore] {
        guard limit > 0 else { return [] }
        var best: [SemanticVectorScore] = []

        for (index, candidate) in candidates.enumerated() {
            if index.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
            let score = candidate.vectors
                .filter { $0.count == query.count }
                .map { VectorMath.dot(query, $0, implementation: implementation) }
                .max() ?? -.infinity
            guard score >= minimumScore else { continue }

            let match = SemanticVectorScore(sourceKey: candidate.sourceKey, score: score)
            let worst = best.last
            let shouldInsert = best.count < limit ||
                score > (worst?.score ?? -.infinity) ||
                (score == worst?.score && candidate.sourceKey < (worst?.sourceKey ?? ""))
            if shouldInsert {
                let insertion = best.firstIndex { existing in
                    score > existing.score ||
                        (score == existing.score && candidate.sourceKey < existing.sourceKey)
                } ?? best.endIndex
                best.insert(match, at: insertion)
                if best.count > limit {
                    best.removeLast()
                }
            }

        }
        return best
    }
}

public enum HybridSearchScorer {
    public static func lexicalBoost(
        query: String,
        title: String,
        metadataText: String
    ) -> Float {
        let normalizedQuery = SearchDocumentBuilder.normalized(query)
        let normalizedTitle = SearchDocumentBuilder.normalized(title)
        let exactBoost: Float
        if normalizedTitle == normalizedQuery {
            exactBoost = 1
        } else if normalizedTitle.contains(normalizedQuery) ||
                    normalizedQuery.contains(normalizedTitle) {
            exactBoost = 0.25
        } else {
            exactBoost = 0
        }

        let queryTokens = Set(normalizedQuery.split(separator: " ").map(String.init))
        guard !queryTokens.isEmpty else { return exactBoost }
        let metadataTokens = Set(
            SearchDocumentBuilder.normalized(metadataText)
                .split(separator: " ")
                .map(String.init)
        )
        let coverage = Float(queryTokens.intersection(metadataTokens).count) /
            Float(queryTokens.count)
        return exactBoost + coverage * 0.35
    }
}
