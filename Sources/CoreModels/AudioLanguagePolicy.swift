import Foundation

/// Pure, testable resolution of which audio **language(s)** to request when a
/// title loads. The result is an ordered list handed to the engine's initial
/// audio-track resolver (AetherEngine `LoadOptions.preferredAudioLanguages`,
/// which picks the first matching demuxed track with **no reload**). Keeping the
/// decision here — strings in, strings out — means the renderer/engine never
/// learn about profiles, series memory, or content types.
///
/// Precedence (highest first):
/// 1. **Remembered per-series** language (the viewer switched audio on some
///    episode and per-series memory is on).
/// 2. **Prefer original language** (when that preference is on and the item's
///    original language is known — e.g. anime → `ja`).
/// 3. **Device / explicit** language (the dub-friendly fallback).
///
/// An **empty** result means "express no preference" — the engine then plays the
/// container's default track, which is itself the best available proxy for the
/// original-language audio. So prefer-original with an *unknown* original
/// language still leans original by deferring to the container default rather
/// than forcing the device language.
public enum AudioLanguagePolicy {
    public static func preferredAudioLanguages(
        remembered: String?,
        preferOriginal: Bool,
        originalLanguage: String?,
        deviceLanguage: String?
    ) -> [String] {
        if let remembered = remembered?.trimmedNonEmpty {
            return [remembered]
        }
        if preferOriginal {
            if let original = originalLanguage?.trimmedNonEmpty {
                return [original]
            }
            // Original language unknown: defer to the container default (≈ original)
            // by expressing no preference, rather than pushing the device language.
            return []
        }
        if let device = deviceLanguage?.trimmedNonEmpty {
            return [device]
        }
        return []
    }
}

private extension String {
    /// The trimmed string, or nil when it is empty/whitespace-only.
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
