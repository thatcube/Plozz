#if canImport(Libmpv) && canImport(UIKit)
import Foundation

/// Crash-proofing for mpv's audio output on this Apple TV build (B1 safety net).
///
/// ## Why this exists
/// `MPVVideoEngine` configures only the **video** output (`vo=gpu-next`,
/// `gpu-api=vulkan`, `gpu-context=moltenvk`, `hwdec=videotoolbox`) and historically
/// set **no** audio options, so mpv auto-probed its audio output and negotiated the
/// source's native channel layout. On this device that SIGSEGVs (signal 11) on **any
/// multichannel (5.1 / 6-channel) stream**, *codec-independent*: both `eac3` 5.1 and
/// `opus` 5.1 crash, while stereo always survives. The same mpv path powers the
/// Jellyfin provider, which is why multichannel Jellyfin titles regressed too.
///
/// ## Root cause (verified against the bundled framework)
/// The staged libmpv (MPVKit `0.41.0-n8.1`, mpv 0.41.0 + FFmpeg n8.1) is compiled
/// with **`audiounit` as its only real audio output** — its enabled-features list is
/// `audiounit … videotoolbox vulkan …` and the binary contains **no `coreaudio` ao**.
/// So pinning a *different* "known-good" ao is not possible: `audiounit` is the only
/// one, and its multichannel path (`ao_audiounit` channel-layout negotiation —
/// the binary carries the tell-tale `"unable to retrieve audio unit channel layout"`
/// / `"AU channel layout tag"` strings) is exactly what crashes on >2 channels. The
/// only reliable, codec-independent fix is therefore to force a **stereo downmix** so
/// `audiounit` only ever negotiates a 2-channel stream format — the path that never
/// crashes in the on-device matrix.
///
/// This is not a per-branch change to the ao binary: there's no evidence a working
/// multichannel ao ever shipped. The "regression" is that more multichannel MKVs now
/// reach mpv (as routing/remux fall-through grew), surfacing a latent `audiounit`
/// multichannel bug — not a change to the ao itself.
///
/// ## Isolation
/// Gated behind a single debug `UserDefaults` flag, **default OFF**, so the maintainer
/// can A/B exactly one change on the shared Apple TV. Enable it on-device with the
/// launch argument (Scheme ▸ Arguments, or `devicectl … --arguments`):
///
///     -com.plozz.playback.mpvSafeAudio YES
///
/// A native SIGSEGV cannot be caught in Swift, so prevention (forcing stereo) is the
/// only viable safety net. Expected promotion: once A/B'd, the maintainer will likely
/// flip this default ON. When ON, mpv-bound multichannel titles play in **stereo**
/// (strictly better than today's crash); surround/Atmos for those titles is preserved
/// only via the remux→AVPlayer paths (branches B2–B4), not the mpv fallback.
enum MPVSafeAudio {
    /// Debug `UserDefaults` / launch-argument key. A `-com.plozz.playback.mpvSafeAudio YES`
    /// launch argument is mirrored into `UserDefaults.standard` by Foundation.
    static let flagKey = "com.plozz.playback.mpvSafeAudio"

    /// Whether the safe-audio downmix is enabled. **Defaults to `false`** (mpv keeps
    /// its previous native-channel behavior) when the key is absent.
    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: flagKey)
    }

    /// The mpv `set_option_string` pairs to apply (before `mpv_initialize`) for the
    /// given flag state. Pure logic so it's unit-testable without libmpv.
    ///
    /// When enabled:
    /// - `audio-channels = stereo` — force a stereo downmix so the `audiounit` ao
    ///   never negotiates a crashing multichannel layout. This is the actual fix.
    /// - `ao = audiounit` — pin the one real (and tvOS-correct) audio output
    ///   deterministically so we never auto-probe into the `pcm`/`null` fallbacks and
    ///   silently lose audio. Harmless: it's already the selected ao; pinning only
    ///   removes auto-probe ambiguity.
    ///
    /// When disabled, returns an empty list (no behavior change).
    static func options(enabled: Bool) -> [(key: String, value: String)] {
        guard enabled else { return [] }
        return [
            ("audio-channels", "stereo"),
            ("ao", "audiounit"),
        ]
    }

    /// Convenience: resolve the flag and return the options in one call.
    static func options(defaults: UserDefaults = .standard) -> [(key: String, value: String)] {
        options(enabled: isEnabled(defaults: defaults))
    }
}
#endif
