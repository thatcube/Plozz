import Foundation
import CoreModels

/// Pure normalization of a provider's original-language value into a canonical
/// ISO-639-1 (2-letter, lowercased) code.
///
/// Providers report the original language in three shapes:
///   * TMDb `original_language` — already ISO-639-1 (`en`, `ja`).
///   * TheTVDB `originalLanguage` — usually ISO-639-1/2 (`eng`, `jpn`), sometimes
///     a bare code.
///   * TVmaze `language` — an English display *name* (`English`, `Japanese`).
///
/// A code-shaped input is folded through ``LanguageMatch`` (which maps ISO-639-2
/// → ISO-639-1 and drops any region/script suffix); a display name is matched
/// against a small English-name table. Unknown values return `nil` so the caller
/// simply omits the field rather than emitting a bogus code.
enum OriginalLanguageNormalizer {
    static func normalized(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let lowered = raw.lowercased()
        // Code-shaped (e.g. "en", "eng", "pt-BR"): fold to ISO-639-1 via LanguageMatch.
        if !lowered.contains(" "), lowered.count <= 3 || lowered.contains("-") || lowered.contains("_") {
            if let code = LanguageMatch.normalized(lowered), code.count == 2 {
                return code
            }
        }
        // Display name (e.g. "English", "Japanese").
        return nameToCode[lowered]
    }

    /// English language names → ISO-639-1, seeded from the shared picker catalog
    /// and extended with a few TVmaze/TheTVDB spellings.
    private static let nameToCode: [String: String] = {
        var map: [String: String] = [:]
        for entry in SubtitleLanguageCatalog.languages {
            map[entry.name.lowercased()] = entry.code
        }
        // Common alternate spellings providers emit.
        map["mandarin"] = "zh"
        map["mandarin chinese"] = "zh"
        map["cantonese"] = "zh"
        map["brazilian portuguese"] = "pt"
        map["greek"] = "el"
        map["hebrew"] = "he"
        map["hindi"] = "hi"
        map["thai"] = "th"
        map["ukrainian"] = "uk"
        map["czech"] = "cs"
        map["hungarian"] = "hu"
        map["romanian"] = "ro"
        map["indonesian"] = "id"
        map["vietnamese"] = "vi"
        map["catalan"] = "ca"
        return map
    }()
}
