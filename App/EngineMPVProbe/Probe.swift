// EngineMPVProbe — a COMPILE-ONLY harness.
//
// EngineMPV is intentionally NOT linked into the Plozz app (we don't want two
// heavy on-device decoding engines — VLCKit and mpv — bundled at once while the
// engine is still being validated). This tiny tvOS framework target exists only
// so CI / the build gate can prove `EngineMPV` compiles and links against the
// tvOS SDK with its libmpv + FFmpeg xcframeworks, without touching the shipping
// app. Build it via the `EngineMPVProbe` scheme:
//
//   xcodebuild build -project Plozz.xcodeproj -scheme EngineMPVProbe \
//     -destination 'generic/platform=tvOS Simulator' CODE_SIGNING_ALLOWED=NO
//
// The orchestrator decides the VLCKit→mpv swap (linking EngineMPV into AppShell)
// separately.

#if canImport(EngineMPV) && canImport(UIKit)
import EngineMPV
import FeaturePlayback

enum EngineMPVProbe {
    /// Forces the linker to pull in `MPVVideoEngine` so the probe genuinely
    /// exercises the engine's symbols, not just the module's existence.
    @MainActor
    static func makeEngine() -> any VideoEngine {
        MPVVideoEngineFactory.makeEngine()
    }
}
#endif
