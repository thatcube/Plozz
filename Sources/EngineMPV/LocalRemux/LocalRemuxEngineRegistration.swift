#if canImport(AVFoundation)
import Foundation
import CoreModels
import FeaturePlayback

public extension LocalRemuxStrategyChoice {
    /// Stable id for the cue-driven localhost-HLS engine. Persisted by
    /// `PlaybackPreferencesStore` and selectable from the Remux overlay picker.
    static let cueLocalhostHLSID = "cue.localhost-hls"

    /// The user-visible choice this engine contributes to the strategy registry.
    static let cueLocalhostHLS = LocalRemuxStrategyChoice(
        id: cueLocalhostHLSID,
        displayName: "Cue-driven localhost HLS",
        detail: "App-owned stream: parse MKV cues, declare the full VOD timeline up front, and serve keyframe-aligned fMP4 segments on demand from a loopback server so far seeks resolve locally and never 404."
    )
}

/// Registration entry point for the cue-driven local remux engine. Called once at
/// app launch from AppShell (under `#if canImport(UIKit)`) so the choice appears in
/// the Remux overlay and `LocalRemuxStrategyRegistry.makeStreamer(for:)` can build
/// it when selected. Idempotent.
public enum CueDrivenLocalRemuxEngine {
    public static func register() {
        LocalRemuxStrategyRegistry.register(choice: .cueLocalhostHLS) {
            CueDrivenLocalRemuxStreamer()
        }
    }
}
#endif
