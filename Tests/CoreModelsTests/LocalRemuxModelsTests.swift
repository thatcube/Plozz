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
