#if canImport(Libmpv) && canImport(UIKit)
import XCTest
@testable import EngineMPV

final class MPVSafeAudioTests: XCTestCase {
    private func makeDefaults(function: String = #function) -> UserDefaults {
        // Isolated suite per test so the global standard defaults are never touched.
        let suite = "MPVSafeAudioTests.\(function)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testFlagKeyIsTheDocumentedNamespacedKey() {
        XCTAssertEqual(MPVSafeAudio.flagKey, "com.plozz.playback.mpvSafeAudio")
    }

    func testDefaultsOffWhenFlagAbsent() {
        let defaults = makeDefaults()
        XCTAssertFalse(
            MPVSafeAudio.isEnabled(defaults: defaults),
            "Safe-audio must default OFF so it never changes behavior unless explicitly opted in"
        )
        XCTAssertTrue(
            MPVSafeAudio.options(defaults: defaults).isEmpty,
            "With the flag off, no mpv audio options are applied (no behavior change)"
        )
    }

    func testEnabledWhenLaunchArgSetsFlag() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: MPVSafeAudio.flagKey)
        XCTAssertTrue(MPVSafeAudio.isEnabled(defaults: defaults))
    }

    func testEnabledOptionsForceStereoDownmixAndPinAudioUnit() {
        let options = MPVSafeAudio.options(enabled: true)
        let map = Dictionary(uniqueKeysWithValues: options.map { ($0.key, $0.value) })

        XCTAssertEqual(
            map["audio-channels"], "stereo",
            "The actual fix: force a stereo downmix so the audiounit ao never negotiates a crashing multichannel layout"
        )
        XCTAssertEqual(
            map["ao"], "audiounit",
            "Pin the one real (and tvOS-correct) audio output so we never auto-probe into the pcm/null fallbacks"
        )
        XCTAssertEqual(options.count, 2, "Exactly the two safe-audio options, nothing more")
    }

    func testDisabledOptionsAreEmpty() {
        XCTAssertTrue(MPVSafeAudio.options(enabled: false).isEmpty)
    }

    func testResolvedOptionsFollowTheFlag() {
        let defaults = makeDefaults()
        XCTAssertTrue(MPVSafeAudio.options(defaults: defaults).isEmpty)

        defaults.set(true, forKey: MPVSafeAudio.flagKey)
        let enabled = MPVSafeAudio.options(defaults: defaults)
        XCTAssertEqual(enabled.map(\.key).sorted(), ["ao", "audio-channels"])
    }
}
#endif
