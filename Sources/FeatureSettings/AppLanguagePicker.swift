#if canImport(SwiftUI)
import SwiftUI
import Foundation
import CoreModels
import CoreUI

/// Picker for the app's own UI language.
///
/// The option list is built from `AppLanguage.available()`, which reads what the
/// bundle actually ships — so a newly translated language appears here on its own,
/// and a language can never be offered that has no strings behind it. In DEBUG it
/// also offers languages that are still in progress, marked as such, so a partial
/// translation can be reviewed without changing the whole device's language.
struct AppLanguagePicker: View {
    @Bindable var model: AppLanguageSettingsModel
    @Environment(\.locale) private var locale

    private var languages: [AppLanguage] { AppLanguage.available() }

    /// The language currently drawn on screen, not merely the picker's stored
    /// override. In System mode the OS can select a bundled localization while
    /// `model.language == .system`; that user still needs the correction link.
    private var displayedLanguageCode: String? {
        if case let .explicit(code) = model.language { return code }
        let preferred = Bundle.preferredLocalizations(
            from: Bundle.main.localizations,
            forPreferences: [locale.identifier]
        ).first
        guard let preferred, preferred != "Base", preferred != "en" else {
            return nil
        }
        return preferred
    }

    /// A correction path that needs no translation-platform account. The issue
    /// starts with the language and asks GitHub for the screen/current/better
    /// wording; native speakers can report one bad phrase without editing JSON.
    private var translationIssueURL: URL? {
        guard let code = displayedLanguageCode else { return nil }
        var components = URLComponents(
            string: "https://github.com/thatcube/Plozz/issues/new"
        )
        components?.queryItems = [
            URLQueryItem(name: "title", value: "[Translation] \(code): "),
            URLQueryItem(
                name: "body",
                value: """
                Language: \(code)
                Screen:
                Current wording:
                Better wording:
                Why (optional):
                """
            ),
            URLQueryItem(name: "labels", value: "translation"),
        ]
        return components?.url
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsOptionList(
                options: languages,
                selection: $model.language,
                title: { language in
                    // An endonym ("Español") is a proper noun and must read
                    // identically whatever the UI language is, so it is verbatim.
                    // "System" is the one row that is genuinely copy, so it stays
                    // a resource and re-resolves with the injected locale.
                    if let endonym = language.endonym {
                        // A DEBUG build offers languages that are still being
                        // translated, so say which those are — otherwise a
                        // half-English screen reads as a bug rather than as
                        // work in progress. Never shown in a release build.
                        if case let .explicit(code) = language, AppLanguage.isInProgress(code) {
                            Text(verbatim: endonym) + Text(verbatim: "  ") + Text("(in progress)")
                        } else {
                            Text(verbatim: endonym)
                        }
                    } else {
                        Text(AppLanguage.systemOptionTitle)
                    }
                }
            )

            if languages.count == 1 {
                Text("Plozz is only available in English for now. More languages are on the way.")
                    .settingsHelperText()
            } else {
                // Deliberately no longer claims the Top Shelf follows the Apple
                // TV's language — it follows this setting now, because the app
                // resolves those titles before handing them to the extension.
                Text("System prompts and the player's own on-screen controls follow the Apple TV's language, not this setting.")
                    .settingsHelperText()
            }

            if let translationIssueURL {
                #if os(tvOS)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Send Feedback")
                        .font(.headline)
                    SettingsQRCode(
                        string: translationIssueURL.absoluteString,
                        correctionLevel: "M"
                    )
                    .frame(width: 180, height: 180)
                }
                #else
                Link(destination: translationIssueURL) {
                    Label("Send Feedback", systemImage: "exclamationmark.bubble")
                }
                #endif
            }
        }
    }
}
#endif
