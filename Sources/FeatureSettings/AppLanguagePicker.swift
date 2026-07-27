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
                    // Verbatim: an endonym like "Español" is a proper noun that
                    // must read identically whatever the current UI language is.
                    // Routing it through a catalog lookup would both be wrong and
                    // be the key-from-a-runtime-string antipattern the guard
                    // rejects. ("System" is the one entry that IS copy, and
                    // AppLanguage.displayName localizes that case itself.)
                    Text(verbatim: language.displayName)
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
