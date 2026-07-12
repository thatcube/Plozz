import Foundation

#if canImport(NaturalLanguage)
@preconcurrency import NaturalLanguage
#endif

public struct EmbeddingLanguage: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let english = Self(rawValue: "en")
    public static let spanish = Self(rawValue: "es")
    public static let french = Self(rawValue: "fr")
    public static let german = Self(rawValue: "de")
    public static let italian = Self(rawValue: "it")
    public static let portuguese = Self(rawValue: "pt")
    public static let simplifiedChinese = Self(rawValue: "zh-Hans")
}

public struct EmbeddingModelDescriptor: Codable, Hashable, Sendable {
    public let language: EmbeddingLanguage
    public let revision: Int
    public let dimension: Int

    public init(language: EmbeddingLanguage, revision: Int, dimension: Int) {
        self.language = language
        self.revision = revision
        self.dimension = dimension
    }
}

public protocol SentenceEmbeddingProviding: Sendable {
    func descriptor(for language: EmbeddingLanguage) async -> EmbeddingModelDescriptor?
    func vector(
        for text: String,
        using descriptor: EmbeddingModelDescriptor
    ) async -> [Float]?
}

public protocol SearchLanguageDetecting: Sendable {
    func hypotheses(for text: String, maximumCount: Int) async -> [EmbeddingLanguage]
}

public protocol SearchTextSegmenting: Sendable {
    func sentences(in text: String) -> [String]
}

#if canImport(NaturalLanguage)
public actor AppleSentenceEmbeddingProvider: SentenceEmbeddingProviding {
    private var models: [EmbeddingModelDescriptor: NLEmbedding] = [:]

    public init() {}

    public func descriptor(for language: EmbeddingLanguage) -> EmbeddingModelDescriptor? {
        let nativeLanguage = NLLanguage(rawValue: language.rawValue)
        guard let model = NLEmbedding.sentenceEmbedding(for: nativeLanguage) else {
            return nil
        }
        let descriptor = EmbeddingModelDescriptor(
            language: language,
            revision: model.revision,
            dimension: model.dimension
        )
        models[descriptor] = model
        return descriptor
    }

    public func vector(
        for text: String,
        using descriptor: EmbeddingModelDescriptor
    ) -> [Float]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let model: NLEmbedding
        if let cached = models[descriptor] {
            model = cached
        } else {
            let language = NLLanguage(rawValue: descriptor.language.rawValue)
            guard let loaded = NLEmbedding.sentenceEmbedding(
                for: language,
                revision: descriptor.revision
            ), loaded.dimension == descriptor.dimension else {
                return nil
            }
            models[descriptor] = loaded
            model = loaded
        }
        guard let values = model.vector(for: trimmed),
              values.count == descriptor.dimension else {
            return nil
        }
        return values.map(Float.init)
    }
}

public struct AppleSearchLanguageDetector: SearchLanguageDetecting {
    public init() {}

    public func hypotheses(for text: String, maximumCount: Int) -> [EmbeddingLanguage] {
        guard maximumCount > 0 else { return [] }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.languageHypotheses(withMaximum: maximumCount)
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key.rawValue < rhs.key.rawValue
            }
            .map { EmbeddingLanguage(rawValue: $0.key.rawValue) }
    }
}

public struct AppleSentenceTextSegmenter: SearchTextSegmenting {
    public init() {}

    public func sentences(in text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var result: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = String(text[range])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty {
                result.append(sentence)
            }
            return true
        }
        return result
    }
}
#endif
