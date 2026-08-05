#if canImport(SwiftUI)
import CoreModels
import CoreUI
import FeatureProfiles
import SwiftUI

/// The household's Parental PIN: create it, change it, or remove it.
///
/// Lives in the **Everyone** section rather than on any one profile, because
/// that's what it is — one PIN for the household, not a property of a person.
/// Putting it on a profile is what would push someone toward setting a PIN on
/// every grown-up account.
struct ParentalPINDetailView: View {
    let context: SettingsContext

    @Environment(\.themePalette) private var palette
    /// Setup is a pushed page, not a modal — modals asked for from inside the
    /// Settings tab are unreliable (see the Edit button note in `SettingsView`).
    @State private var isSettingPIN = false
    @State private var confirmRemove = false

    private var hasPIN: Bool { context.hasParentalPIN }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                SettingsPageHeader(
                    KidsProfileCopy.parentalPIN,
                    subtitle: KidsProfileCopy.parentalPINExplanation
                )

                SettingsPanel {
                    VStack(spacing: 14) {
                        Button {
                            isSettingPIN = true
                        } label: {
                            SettingsRowLabel(
                                icon: hasPIN ? "lock.fill" : "lock.open",
                                title: hasPIN
                                    ? KidsProfileCopy.parentalPINChange
                                    : KidsProfileCopy.parentalPINCreate
                            ) {
                                Text(hasPIN ? ProfileLockCopy.on : ProfileLockCopy.off)
                                    .settingsRowSecondary()
                            }
                        }

                        if hasPIN {
                            Button(role: .destructive) {
                                confirmRemove = true
                            } label: {
                                Label {
                                    Text(KidsProfileCopy.parentalPINRemove)
                                } icon: {
                                    Image(systemName: "lock.slash")
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .tvOSFocusSection()
                }
            }
            .frame(maxWidth: PlozzTheme.Metrics.settingsContentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
            .padding(.vertical, 24)
        }
        .scrollClipDisabled()
        .navigationDestination(isPresented: $isSettingPIN) {
            ParentalPINSetupView(
                isReplacing: hasPIN,
                onComplete: { pin in
                    context.onSetParentalPIN(pin)
                    isSettingPIN = false
                },
                onCancel: { isSettingPIN = false }
            )
            .toolbar(.hidden, for: .tabBar)
        }
        .alert(
            Text(KidsProfileCopy.parentalPINRemove),
            isPresented: $confirmRemove
        ) {
            Button(role: .destructive) {
                context.onSetParentalPIN(nil)
            } label: {
                Text(KidsProfileCopy.parentalPINRemove)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(KidsProfileCopy.parentalPINRemoveDetail)
        }
    }
}
#endif
