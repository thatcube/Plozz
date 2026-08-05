#if canImport(SwiftUI)
import CoreModels
import CoreUI
import FeatureProfiles
import SwiftUI

/// The Parental PIN prompt that unseals a Kids Profile's restricted settings.
///
/// A pushed page rather than a modal. Modals asked for from inside the Settings
/// tab are unreliable — `RootView` stacks several `fullScreenCover` modifiers on
/// one host and a contested slot is silently dropped, which is exactly how the
/// profile Edit button ended up doing nothing. Pushing uses the navigation stack
/// this page already lives in.
///
/// On success it pops itself, so the person lands back on the settings list with
/// the previously-sealed rows now present — no extra tap to "continue".
struct GrownUpsUnlockView: View {
    let context: SettingsContext

    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?

    var body: some View {
        ParentalPINView(
            errorMessage: errorMessage,
            onSubmit: submit,
            onCancel: { dismiss() }
        )
    }

    private func submit(_ pin: String) {
        guard context.matchesParentalPIN(pin) else {
            errorMessage = String(localized: "Incorrect PIN. Try again.")
            return
        }
        errorMessage = nil
        context.onParentalUnlock()
        dismiss()
    }
}
#endif
