#if os(iOS)
import CoreModels
import CoreUI
import FeatureProfiles
import SwiftUI

/// The Parental PIN prompt that unseals a Kids Profile's restricted settings on
/// iPhone/iPad.
///
/// Pushed onto the settings stack rather than presented: iOS Settings is itself
/// a sheet, so a sheet from here would be a presentation from inside a
/// presentation. Pops itself on success, landing the person back on the list
/// with the previously-sealed rows now present.
struct PlozziOSGrownUpsUnlockView: View {
    let appModel: PlozziOSAppModel
    let onUnlock: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: LocalizedStringResource?

    var body: some View {
        ParentalPINView(
            errorMessage: errorMessage,
            onSubmit: submit,
            onCancel: { dismiss() }
        )
    }

    private func submit(_ pin: String) {
        guard appModel.profiles.matchesParentalPIN(pin) else {
            errorMessage = ProfileLockCopy.incorrectPIN
            return
        }
        errorMessage = nil
        onUnlock()
        dismiss()
    }
}
#endif
