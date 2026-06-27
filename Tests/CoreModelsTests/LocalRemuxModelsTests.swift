import XCTest
@testable import CoreModels

final class LocalRemuxModelsTests: XCTestCase {
    private func descriptor(
        container: String = "mkv",
        videoRangeType: String = "DOVIWithHDR10",
        dolbyVisionProfile: Int? = 8,
        audioCodec: String = "eac3"
    ) -> LocalRemuxSourceDescriptor {
        LocalRemuxSourceDescriptor(
            itemID: "item1",
            mediaSourceID: "src1",
            provider: .jellyfin,
            originalURL: URL(string: "http://host/Videos/item1/stream.mkv?static=true&api_key=TOKEN")!,
            referencePlaybackURL: URL(string: "http://host/videos/item1/master.m3u8?api_key=TOKEN")!,
            durationSeconds: 7200,
            byteRangeSupported: true,
            sourceMetadata: MediaSourceMetadata(
                container: container,
                video: .init(
                    codec: "hevc",
                    videoRangeType: videoRangeType,
                    dolbyVisionProfile: dolbyVisionProfile
                ),
                audio: .init(codec: audioCodec)
            )
        )
    }

    func testDolbyVisionEAC3MatroskaIsEligibleForLocalRemux() {
        let caps = MediaCapabilities(supportsHEVC: true, supportsDolbyVision: true)
        if case .ineligible(let reason) = descriptor().eligibility(capabilities: caps) {
            XCTFail("Expected eligible local-remux source, got \(reason)")
        }
        XCTAssertTrue(descriptor().shouldPreferLocalRemux(capabilities: caps))
    }

    func testProfileSevenStaysOffLocalRemuxPath() {
        let caps = MediaCapabilities(supportsHEVC: true, supportsDolbyVision: true)
        let eligibility = descriptor(videoRangeType: "DOVI", dolbyVisionProfile: 7).eligibility(capabilities: caps)
        XCTAssertEqual(eligibility, .ineligible("Dolby Vision Profile 7 stays on the hybrid engine"))
    }

    func testTrueHDStaysOffLocalRemuxPath() {
        let caps = MediaCapabilities(supportsHEVC: true, supportsDolbyVision: true)
        let eligibility = descriptor(audioCodec: "truehd").eligibility(capabilities: caps)
        XCTAssertEqual(eligibility, .ineligible("TrueHD stays on the hybrid engine"))
    }

    func testPlaybackPreferencesRoundTripLocalRemuxStrategy() {
        let defaults = UserDefaults(suiteName: "PlaybackPreferencesStore.localRemux")!
        defaults.removePersistentDomain(forName: "PlaybackPreferencesStore.localRemux")
        let store = PlaybackPreferencesStore(defaults: defaults)

        XCTAssertEqual(store.loadLocalRemuxStrategyID(), LocalRemuxStrategyChoice.referenceServerRemuxID)

        store.saveLocalRemuxStrategyID(LocalRemuxStrategyChoice.referenceServerRemuxID)
        XCTAssertEqual(store.loadLocalRemuxStrategyID(), LocalRemuxStrategyChoice.referenceServerRemuxID)

        store.saveLocalRemuxStrategyID("unknown.future.strategy")
        XCTAssertEqual(store.loadLocalRemuxStrategyID(), LocalRemuxStrategyChoice.disabledID)
    }
}
