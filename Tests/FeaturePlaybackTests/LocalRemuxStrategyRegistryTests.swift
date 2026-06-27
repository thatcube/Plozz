#if canImport(AVFoundation)
import XCTest
import CoreModels
@testable import FeaturePlayback

/// Covers the dynamic factory half of `LocalRemuxStrategyRegistry`: engine modules
/// register a choice + factory at launch and `makeStreamer(for:)` builds it.
final class LocalRemuxStrategyRegistryTests: XCTestCase {
    private static let testChoice = LocalRemuxStrategyChoice(
        id: "test.registry-factory",
        displayName: "Registry Factory (test)",
        detail: "Registered by LocalRemuxStrategyRegistryTests."
    )

    private struct StubStreamer: LocalRemuxStreamer {
        let strategy: LocalRemuxStrategyChoice
        @MainActor
        func openSession(source: LocalRemuxSourceDescriptor) async throws -> any LocalRemuxStreamingSession {
            throw AppError.notFound
        }
    }

    func testBuiltInReferenceStreamerStillResolves() {
        let streamer = LocalRemuxStrategyRegistry.makeStreamer(for: LocalRemuxStrategyChoice.referenceServerRemuxID)
        XCTAssertNotNil(streamer)
        XCTAssertEqual(streamer?.strategy.id, LocalRemuxStrategyChoice.referenceServerRemuxID)
    }

    func testUnknownStrategyReturnsNil() {
        XCTAssertNil(LocalRemuxStrategyRegistry.makeStreamer(for: "definitely.not.registered"))
    }

    func testRegisteredFactoryBuildsStreamerAndChoiceIsVisible() {
        LocalRemuxStrategyRegistry.register(choice: Self.testChoice) {
            StubStreamer(strategy: Self.testChoice)
        }

        // The choice surfaces through availableChoices (for the overlay picker).
        XCTAssertTrue(LocalRemuxStrategyRegistry.availableChoices.contains { $0.id == Self.testChoice.id })

        // The factory builds a streamer carrying the registered strategy.
        let streamer = LocalRemuxStrategyRegistry.makeStreamer(for: Self.testChoice.id)
        XCTAssertNotNil(streamer)
        XCTAssertEqual(streamer?.strategy.id, Self.testChoice.id)
    }
}
#endif
