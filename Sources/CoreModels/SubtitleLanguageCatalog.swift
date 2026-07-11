import Foundation

/// A short, common-language list for the subtitle/audio language pickers. Codes
/// are 2-letter ISO-639-1; the provider normalises to the server's expected form.
///
/// Lives in `CoreModels` (Foundation-only) so both the Settings behaviour rows
/// and any future in-player language picker share one list. Previously a static
/// on the retired `CaptionSettingsCard`.
public enum SubtitleLanguageCatalog {
    public static let languages: [(code: String, name: String)] = [
        ("en", "English"), ("es", "Spanish"), ("fr", "French"), ("de", "German"),
        ("it", "Italian"), ("pt", "Portuguese"), ("nl", "Dutch"), ("sv", "Swedish"),
        ("no", "Norwegian"), ("da", "Danish"), ("fi", "Finnish"), ("pl", "Polish"),
        ("ru", "Russian"), ("ja", "Japanese"), ("ko", "Korean"), ("zh", "Chinese"),
        ("ar", "Arabic"), ("tr", "Turkish")
    ]

    /// The human-readable language name for an ISO-639 code (2- or 3-letter,
    /// with any region/script suffix), or `nil` when unknown. Folds 3-letter
    /// codes to their 2-letter base via `LanguageMatch` so `eng`/`en-US` both
    /// resolve to "English".
    public static func displayName(forCode code: String?) -> String? {
        guard let normalized = LanguageMatch.normalized(code) else { return nil }
        return languages.first { $0.code == normalized }?.name
    }
}
