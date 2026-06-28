// LocalRemuxProbe — a COMPILE/LINK-ONLY harness for the local-remux engine.
//
// `LocalRemux` is the Infuse-style localhost HLS origin: it links the same
// locally-built FFmpeg xcframeworks EngineMPV uses (via the `CRemuxCore` C core)
// to `-c copy` remux the original MKV into a full-timeline VOD playlist AVPlayer
// can seek natively. In the shipping app it is pulled in transitively through
// AppShell, but this tiny tvOS framework target lets CI / the build gate prove
// `LocalRemux` + `CRemuxCore` compile and LINK against the tvOS SDK with their
// FFmpeg + libdovi dependencies in isolation. Build it via the `LocalRemuxProbe`
// scheme:
//
//   xcodebuild build -project Plozz.xcodeproj -scheme LocalRemuxProbe \
//     -destination 'generic/platform=tvOS' CODE_SIGNING_ALLOWED=NO
//
// Referencing `FullTimelineVODStreamer` forces the linker to pull in the engine's
// real symbols (server, segmenter, CRemuxCore), not just the module's existence.

#if canImport(LocalRemux) && canImport(UIKit)
import LocalRemux

enum LocalRemuxProbe {
    /// Forces the linker to pull in the full-timeline VOD streamer and, through
    /// it, the hardened localhost origin + `CRemuxCore` libavformat remux core.
    @MainActor
    static func register() {
        FullTimelineVODEngine.register()
        _ = FullTimelineVODStreamer()
    }
}
#endif
