import XCTest
@testable import CoreModels

final class LocalRemuxModelsTests: XCTestCase {
    private func descriptor(
        container: String = "mkv",
        videoRangeType: String = "DOVIWithHDR10",
        dolbyVisionProfile: Int? = 8,
        videoProfile: String? = nil,
        bitDepth: Int? = nil,
        audioCodec: String = "eac3",
        audioChannels: Int? = 6
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
                    profile: videoProfile,
                    bitDepth: bitDepth,
                    videoRangeType: videoRangeType,
                    dolbyVisionProfile: dolbyVisionProfile
                ),
                audio: .init(codec: audioCodec, channels: audioChannels)
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

    // MARK: - Widened gate (B2 debug flag: com.plozz.playback.remuxHevcAny)

    /// A display route with NO Dolby Vision — proves HDR10/SDR HEVC qualify for the
    /// widened gate without needing the DoVi route the narrow gate requires.
    private let nonDoViCaps = MediaCapabilities(
        supportsHEVC: true, supportsHDR10: true, supportsDolbyVision: false)

    func testHDR10HevcEAC3IsEligibleWhenWidened() {
        let source = descriptor(
            videoRangeType: "HDR10", dolbyVisionProfile: nil,
            videoProfile: "Main 10", bitDepth: 10, audioCodec: "eac3", audioChannels: 6)
        if case .ineligible(let reason) = source.eligibility(
            capabilities: nonDoViCaps, allowAnyDecodableHEVC: true) {
            XCTFail("Expected HDR10 HEVC E-AC-3 5.1 to be eligible when widened, got \(reason)")
        }
        XCTAssertTrue(source.shouldPreferLocalRemux(
            capabilities: nonDoViCaps, allowAnyDecodableHEVC: true))
    }

    func testSDRTenBitHevcEAC3IsEligibleWhenWidened() {
        let source = descriptor(
            videoRangeType: "SDR", dolbyVisionProfile: nil,
            videoProfile: "Main 10", bitDepth: 10, audioCodec: "eac3", audioChannels: 6)
        if case .ineligible(let reason) = source.eligibility(
            capabilities: nonDoViCaps, allowAnyDecodableHEVC: true) {
            XCTFail("Expected SDR 10-bit HEVC E-AC-3 5.1 to be eligible when widened, got \(reason)")
        }
    }

    func testDoViProfileSevenStaysIneligibleWhenWidened() {
        let eligibility = descriptor(videoRangeType: "DOVI", dolbyVisionProfile: 7)
            .eligibility(capabilities: nonDoViCaps, allowAnyDecodableHEVC: true)
        XCTAssertEqual(eligibility, .ineligible("Dolby Vision Profile 7 stays on the hybrid engine"))
    }

    func testTrueHDStaysIneligibleWhenWidened() {
        let eligibility = descriptor(
            videoRangeType: "HDR10", dolbyVisionProfile: nil, audioCodec: "truehd")
            .eligibility(capabilities: nonDoViCaps, allowAnyDecodableHEVC: true)
        XCTAssertEqual(eligibility, .ineligible("TrueHD stays on the hybrid engine"))
    }

    func testHevcRangeExtensionsStayIneligibleWhenWidened() {
        let eligibility = descriptor(
            videoRangeType: "SDR", dolbyVisionProfile: nil,
            videoProfile: "Rext 4:2:2 10", bitDepth: 12)
            .eligibility(capabilities: nonDoViCaps, allowAnyDecodableHEVC: true)
        XCTAssertEqual(
            eligibility,
            .ineligible("HEVC Range Extensions (4:2:2/4:4:4/12-bit) stay on the hybrid engine"))
    }

    func testHDR10HevcStaysIneligibleByDefaultGate() {
        // Flag OFF (default): HDR10/SDR HEVC must NOT be diverted off the existing
        // routing — only single-layer Dolby Vision qualifies. Guards isolation.
        let eligibility = descriptor(videoRangeType: "HDR10", dolbyVisionProfile: nil)
            .eligibility(capabilities: nonDoViCaps)
        XCTAssertEqual(
            eligibility, .ineligible("Current display route does not advertise Dolby Vision"))
    }

    func testNonHevcCodecStaysIneligibleWhenWidened() {
        // H.264 is B4's scope, not B2's — the widened HEVC gate must leave it alone.
        var meta = descriptor().sourceMetadata
        meta.video = .init(codec: "h264", videoRangeType: "SDR")
        let source = LocalRemuxSourceDescriptor(
            itemID: "item1", provider: .jellyfin,
            originalURL: URL(string: "http://host/x.mkv")!,
            byteRangeSupported: true, sourceMetadata: meta)
        let eligibility = source.eligibility(
            capabilities: nonDoViCaps, allowAnyDecodableHEVC: true)
        XCTAssertEqual(eligibility, .ineligible("Video is not HEVC"))
    }

    func testPlaybackPreferencesRoundTripLocalRemuxStrategy() {
        let defaults = UserDefaults(suiteName: "PlaybackPreferencesStore.localRemux")!
        defaults.removePersistentDomain(forName: "PlaybackPreferencesStore.localRemux")
        let store = PlaybackPreferencesStore(defaults: defaults)

        // With nothing persisted the active strategy is the built-in default, which
        // is now the production full-timeline localhost VOD remux engine (it owns
        // the whole stream so AVPlayer seek-ahead never 404s) for eligible titles.
        XCTAssertEqual(store.loadLocalRemuxStrategyID(), LocalRemuxStrategyChoice.fullTimelineVODID)
        XCTAssertEqual(LocalRemuxStrategyChoice.defaultID, LocalRemuxStrategyChoice.fullTimelineVODID)

        store.saveLocalRemuxStrategyID(LocalRemuxStrategyChoice.referenceServerRemuxID)
        XCTAssertEqual(store.loadLocalRemuxStrategyID(), LocalRemuxStrategyChoice.referenceServerRemuxID)

        store.saveLocalRemuxStrategyID("unknown.future.strategy")
        XCTAssertEqual(store.loadLocalRemuxStrategyID(), LocalRemuxStrategyChoice.disabledID)
    }

    func testStaleServerBaselineDefaultIsMigratedToWorkingEngineOnce() {
        let suite = "PlaybackPreferencesStore.localRemux.migration"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        // Simulate a device left on the shared-foundation era default: the broken
        // "Server HLS baseline" passthrough persisted as the override, with no
        // migration flag yet. (Write the raw key the store uses.)
        let key = SettingsKey.scoped("com.plozz.playback.localRemuxStrategy", namespace: nil)
        defaults.set(LocalRemuxStrategyChoice.referenceServerRemuxID, forKey: key)

        // Constructing the store runs the one-time migration, which drops the stale
        // stub so eligible Dolby Vision titles default to the working engine instead
        // of the seek-broken server passthrough.
        let migrated = PlaybackPreferencesStore(defaults: defaults)
        XCTAssertEqual(migrated.loadLocalRemuxStrategyID(), LocalRemuxStrategyChoice.fullTimelineVODID)

        // A *deliberate* later pick of the baseline (for A/B) must stick — the
        // migration is one-shot and never reverts an explicit choice.
        migrated.saveLocalRemuxStrategyID(LocalRemuxStrategyChoice.referenceServerRemuxID)
        let reopened = PlaybackPreferencesStore(defaults: defaults)
        XCTAssertEqual(reopened.loadLocalRemuxStrategyID(), LocalRemuxStrategyChoice.referenceServerRemuxID)
    }

    func testMigrationLeavesNonBaselineOverridesUntouched() {
        let suite = "PlaybackPreferencesStore.localRemux.migration.noop"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        // A device explicitly set to "Off" must not be flipped to the engine by the
        // migration — only the legacy server-baseline default is upgraded.
        let key = SettingsKey.scoped("com.plozz.playback.localRemuxStrategy", namespace: nil)
        defaults.set(LocalRemuxStrategyChoice.disabledID, forKey: key)

        let store = PlaybackPreferencesStore(defaults: defaults)
        XCTAssertEqual(store.loadLocalRemuxStrategyID(), LocalRemuxStrategyChoice.disabledID)
    }
}
