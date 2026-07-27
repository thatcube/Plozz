import Foundation

/// Copy that appears in more than one Settings surface, so tvOS and iOS can never
/// drift apart on the wording — and, now that it is localized, so the string is
/// translated once rather than once per shell.
///
/// `LocalizedStringResource` rather than `String`: `Text(aString)` renders
/// verbatim, so copy typed as `String` is invisible to both the String Catalog and
/// the compiler's string extraction, and would silently stay English.
public enum SettingsCopy {
    public static let libraries = LocalizedStringResource(
        "settings.nav.libraries",
        defaultValue: "Libraries",
        comment: "Navigation row and page heading for the screen listing the user's media libraries."
    )
    public static let attributions = LocalizedStringResource(
        "settings.nav.attributions",
        defaultValue: "Attributions",
        comment: "Navigation row for the screen crediting third-party software and data sources."
    )
}
