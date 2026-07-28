#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// Picker for the app's own UI language.
///
/// The option list is built from `AppLanguage.available()`, which reads what the
/// bundle actually ships — so a newly translated language appears here on its own,
/// and a language can never be offered that has no strings behind it.
struct AppLanguagePicker: View {
    @Bindable var model: AppLanguageSettingsModel

    private var languages: [AppLanguage] { AppLanguage.available() }

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
                        Text(verbatim: endonym)
                    } else {
                        Text(AppLanguage.systemOptionTitle)
                    }
                }
            )

            if languages.count == 1 {
                Text("Plozz is only available in English for now. More languages are on the way.")
                    .settingsHelperText()
            } else {
                Text("Player controls, system prompts, and the Top Shelf row follow the Apple TV's own language.")
                    .settingsHelperText()
            }
        }
    }
}
#endif
