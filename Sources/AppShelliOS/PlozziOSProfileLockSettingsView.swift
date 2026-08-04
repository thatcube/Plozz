import CoreModels
import CoreUI
import FeatureProfiles
import SwiftUI

/// Settings → Everyone → Profiles → *name* → **Profile Lock** on iPhone/iPad.
///
/// A summary page only. Choosing the PIN is `ProfileLockSetupView` presented
/// full-screen — the same flow tvOS and the profile picker use — so the
/// "type it, type it again" behaviour exists in exactly one place.
struct PlozziOSProfileLockSettingsView: View {
    let appModel: PlozziOSAppModel
    /// The profile being locked — not necessarily the active one.
    let profileID: String

    @State private var settingPIN = false
    @State private var confirmDelete = false

    private var profile: Profile? {
        appModel.profiles.profiles.first(where: { $0.id == profileID })
    }

    private var syncEnabled: Bool { SyncSetupFeatureFlag().isEnabled }

    /// Whether this profile plays as a Plex Home user that already asks for a
    /// PIN — the only case where offering to reuse it makes sense.
    private var boundToProtectedPlexUser: Bool {
        guard let profile else { return false }
        if profile.plexHomeUserRequiresPIN == true { return true }
        return profile.plexHomeUserBindings?.values.contains { $0.requiresPIN == true } ?? false
    }

    var body: some View {
        List {
            if let profile {
                SettingsSectionGroup {
                    Label {
                        Text(profile.isLocked ? ProfileLockCopy.on : ProfileLockCopy.off)
                    } icon: {
                        Image(systemName: profile.isLocked ? "lock.fill" : "lock.open")
                    }
                    Button {
                        settingPIN = true
                    } label: {
                        Text(profile.isLocked ? ProfileLockCopy.editPIN : ProfileLockCopy.create)
                    }
                    if profile.isLocked {
                        Button(role: .destructive) {
                            confirmDelete = true
                        } label: {
                            Text(ProfileLockCopy.delete)
                        }
                    }
                } footer: {
                    if syncEnabled {
                        Text(ProfileLockCopy.explanation)
                    } else {
                        Text(ProfileLockCopy.explanation)
                            + Text(verbatim: "\n\n")
                            + Text(ProfileLockCopy.lockIsDeviceOnly)
                    }
                }
            }
        }
        .settingsPageSurface()
        .navigationTitle(Text(ProfileLockCopy.title))
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $settingPIN) {
            if let profile {
                ProfileLockSetupView(
                    profile: profile,
                    offersPlexPINReuse: boundToProtectedPlexUser,
                    syncEnabled: syncEnabled,
                    onComplete: { lock in
                        appModel.setLock(lock, forProfile: profileID)
                        settingPIN = false
                    },
                    onCancel: { settingPIN = false }
                )
            }
        }
        .alert(Text(ProfileLockCopy.delete), isPresented: $confirmDelete) {
            Button(String(localized: ProfileLockCopy.delete), role: .destructive) {
                appModel.setLock(nil, forProfile: profileID)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(ProfileLockCopy.forgotPINDetail)
        }
    }
}
