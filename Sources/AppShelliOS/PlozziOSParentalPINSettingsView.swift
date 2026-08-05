#if os(iOS)
import CoreModels
import CoreUI
import FeatureProfiles
import SwiftUI

/// The household's Parental PIN on iPhone/iPad: create it, change it, remove it.
///
/// Lives beside the other household settings rather than on any one profile,
/// because that's what it is — one PIN for everyone, not a property of a person.
/// Putting it on a profile is what would push someone toward setting a PIN on
/// every grown-up account.
///
/// The tvOS twin is `ParentalPINDetailView`; this one exists because iOS settings
/// are a `List`, not the panel-and-scroll layout the TV uses.
struct PlozziOSParentalPINSettingsView: View {
    let appModel: PlozziOSAppModel

    @State private var isSettingPIN = false
    @State private var confirmRemove = false

    private var hasPIN: Bool { appModel.profiles.parentalPIN != nil }

    var body: some View {
        List {
            SettingsSectionGroup {
                Button {
                    isSettingPIN = true
                } label: {
                    HStack {
                        Label {
                            Text(hasPIN
                                ? KidsProfileCopy.parentalPINChange
                                : KidsProfileCopy.parentalPINCreate)
                        } icon: {
                            Image(systemName: hasPIN ? "lock.fill" : "lock.open")
                        }
                        Spacer()
                        Text(hasPIN ? ProfileLockCopy.on : ProfileLockCopy.off)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if hasPIN {
                    Button(role: .destructive) {
                        confirmRemove = true
                    } label: {
                        Label {
                            Text(KidsProfileCopy.parentalPINRemove)
                        } icon: {
                            Image(systemName: "lock.slash")
                        }
                    }
                }
            } footer: {
                Text(KidsProfileCopy.parentalPINExplanation)
            }
        }
        .settingsPageSurface()
        .navigationTitle(Text(KidsProfileCopy.parentalPIN))
        .navigationBarTitleDisplayMode(.inline)
        // Pushed, not presented: iOS Settings is itself a sheet, so a sheet from
        // here would be a presentation from inside a presentation.
        .navigationDestination(isPresented: $isSettingPIN) {
            ParentalPINSetupView(
                isReplacing: hasPIN,
                onComplete: { pin in
                    appModel.profiles.setParentalPIN(pin)
                    isSettingPIN = false
                },
                onCancel: { isSettingPIN = false }
            )
        }
        .alert(
            Text(KidsProfileCopy.parentalPINRemove),
            isPresented: $confirmRemove
        ) {
            Button(role: .destructive) {
                appModel.profiles.setParentalPIN(nil)
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
