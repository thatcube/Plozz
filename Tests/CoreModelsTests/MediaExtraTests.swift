import XCTest
@testable import CoreModels

final class MediaExtraTests: XCTestCase {
    func testProviderTypesNormalizeWithoutDroppingUnknownValues() {
        XCTAssertEqual(MediaExtraKind(rawProviderValue: "behindTheScenes"), .behindTheScenes)
        XCTAssertEqual(MediaExtraKind(rawProviderValue: "Deleted Scene"), .deletedScene)
        XCTAssertEqual(MediaExtraKind(rawProviderValue: "sceneOrSample"), .sceneOrSample)
        XCTAssertEqual(MediaExtraKind(rawProviderValue: "LiveMusicVideo"), .musicPerformance)
        XCTAssertEqual(MediaExtraKind(rawProviderValue: "FutureServerType"), .unknown)
    }

    func testOrderingUsesCategoriesAndPreservesOrderWithinCategory() {
        let extras = [
            extra("other", kind: .other),
            extra("trailer-1", kind: .trailer),
            extra("deleted", kind: .deletedScene),
            extra("trailer-2", kind: .trailer),
            extra("featurette", kind: .featurette)
        ]

        XCTAssertEqual(
            MediaExtra.ordered(extras).map(\.item.id),
            ["trailer-1", "trailer-2", "featurette", "deleted", "other"]
        )
    }

    func testOrderingDeduplicatesByPlayableIdentity() {
        let duplicate = extra("same", kind: .trailer)
        XCTAssertEqual(MediaExtra.ordered([duplicate, duplicate]).count, 1)
    }

    func testNonResumableExtraClearsResumeStateForPlayback() {
        let item = MediaItem(
            id: "sample",
            title: "Sample",
            kind: .video,
            runtime: 120,
            resumePosition: 60,
            playedPercentage: 0.5
        )
        let extra = MediaExtra(item: item, kind: .sample, supportsResume: false)

        XCTAssertNil(extra.playbackItem.resumePosition)
        XCTAssertNil(extra.playbackItem.playedPercentage)
    }

    private func extra(_ id: String, kind: MediaExtraKind) -> MediaExtra {
        MediaExtra(
            item: MediaItem(id: id, title: id, kind: .video),
            kind: kind
        )
    }
}
