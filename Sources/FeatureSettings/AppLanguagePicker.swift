#if canImport(SwiftUI)
import SwiftUI
import Foundation
import CoreModels
import CoreUI

/// Picker for the app's own UI language.
///
/// The option list is built from `AppLanguage.available()`, which reads what the
/// bundle actually ships — so a newly translated language appears here on its own,
/// and a non-source language can never be offered without strings behind it.
/// English is always offered because it is the source/development localization and
/// Xcode may omit it from `Bundle.localizations` when no `en.lproj` is needed. In
/// DEBUG this also offers in-progress languages for review.
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

    /// A native pop-up menu rather than an inline list.
    ///
    /// Every release-ready language is offered — 37 rows and counting — and as a
    /// list that is a settings page you scroll for several screens to reach the
    /// one control on it. The same call was already made one file over for the
    /// audio-language preference ("too long for the inline pill picker"); this is
    /// the same list, only longer.
    ///
    /// The menu collapses it to a single row showing the current choice, and the
    /// platform gets to present the options the way it presents every other long
    /// menu — which on tvOS is a scrollable overlay the remote is already good at.
    @ViewBuilder
    private var languageMenu: some View {
        Menu {
            Picker("Language", selection: $model.language) {
                ForEach(languages) { language in
                    label(for: language).tag(language)
                }
            }
        } label: {
            Label {
                label(for: model.language)
            } icon: {
                Image(systemName: "globe")
            }
        }
        .menuStyle(.button)
    }

    /// An endonym ("Español") is a proper noun and must read identically whatever
    /// the UI language is, so it is verbatim. "System" is the one row that is
    /// genuinely copy, so it stays a resource and re-resolves with the injected
    /// locale.
    ///
    /// A DEBUG build offers languages that are still being translated, so say
    /// which those are — otherwise a half-English screen reads as a bug rather
    /// than as work in progress. Never shown in a release build.
    private func label(for language: AppLanguage) -> Text {
        guard let endonym = language.endonym else {
            return Text(AppLanguage.systemOptionTitle)
        }
        if case let .explicit(code) = language, AppLanguage.isInProgress(code) {
            return Text(verbatim: endonym) + Text(verbatim: "  ") + Text("(in progress)")
        }
        return Text(verbatim: endonym)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            languageMenu

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
