import XCTest
@testable import SearchIndexKit

#if canImport(NaturalLanguage)
final class AppleEmbeddingTests: XCTestCase {
    func testEnglishSentenceEmbeddingIsAvailable() async throws {
        let provider = AppleSentenceEmbeddingProvider()
        let descriptor = await provider.descriptor(for: .english)
        XCTAssertNotNil(descriptor)
        XCTAssertEqual(descriptor?.dimension, 512)

        guard let descriptor else { return }
        let vector = await provider.vector(
            for: "An episode about friends waiting at a restaurant.",
            using: descriptor
        )
        XCTAssertEqual(vector?.count, descriptor.dimension)
    }

    func testLanguageDetectorAndSentenceSegmenter() async {
        let languages = await AppleSearchLanguageDetector().hypotheses(
            for: "A mystery unfolds in a quiet village.",
            maximumCount: 2
        )
        XCTAssertEqual(languages.first, .english)

        let sentences = AppleSentenceTextSegmenter().sentences(
            in: "The storm arrives. Everyone takes shelter."
        )
        XCTAssertEqual(sentences, ["The storm arrives.", "Everyone takes shelter."])
    }
}
#endif
