#if os(iOS)
import CoreModels
import CoreUI
import FeatureProfiles
import SwiftUI

/// Wraps a destination that a Kids Profile may only reach with the Parental PIN.
///
/// The gate lives INSIDE the pushed page, so the row that pushed it keeps a
/// stable identity. The alternative — swapping which `NavigationLink` a row emits
/// based on the seal — meant a correct PIN removed the very destination the user
/// was standing on, popping them back to the list to tap the same row again.
///
/// Entering the PIN therefore carries you straight into the page you asked for,
/// which is what someone expects anyway.
struct PlozziOSParentalGate<Content: View>: View {
    let appModel: PlozziOSAppModel
    /// Whether the gate is closed right now. Owned by the settings screen so one
    /// unlock opens every gated row for that visit.
    let isSealed: Bool
    let onUnlock: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var errorMessage: LocalizedStringResource?

    var body: some View {
        if isSealed {
            ParentalPINView(
                errorMessage: errorMessage,
                onSubmit: submit,
                onCancel: { errorMessage = nil }
            )
        } else {
            content()
        }
    }

    private func submit(_ pin: String) {
        guard appModel.profiles.matchesParentalPIN(pin) else {
            errorMessage = ProfileLockCopy.incorrectPIN
            return
        }
        errorMessage = nil
        onUnlock()
    }
}
#endif
