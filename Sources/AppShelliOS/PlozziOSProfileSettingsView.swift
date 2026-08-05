#if os(iOS)
import CoreModels
import CoreUI
import FeatureProfiles
import SwiftUI

/// Settings → Everyone → Profiles → *one profile* on iPhone/iPad.
///
/// The iOS half of the same idea as tvOS: everything true *about* a profile as an
/// entity — appearance, whether it needs a PIN, whether it's restricted, whether
/// it exists — for any profile, not just the active one.
///
/// Managing every profile's lock from one screen is what Netflix does, and it's
/// the only arrangement that works here: a Kids Profile can't reach this section,
/// so a grown-up has to be able to set the child's restrictions (and their own
/// lock) from a profile the child isn't using.
struct PlozziOSProfileSettingsView: View {
    @Environment(\.themePalette) private var palette
    let appModel: PlozziOSAppModel
    let profileID: String

    @State private var showingEditor = false
    /// PIN setups are pushed onto the settings stack, matching tvOS. iOS Settings
    /// is itself a sheet, so a sheet-over-sheet here would be a presentation from
    /// inside a presentation.
    @State private var showingLockSetup = false
    @State private var showingParentalSetup = false

    /// Read live so the page reflects a lock added or the profile renamed.
    private var profile: Profile? {
        appModel.profiles.profiles.first(where: { $0.id == profileID })
    }

    private var canDelete: Bool {
        guard let profile else { return false }
        return !appModel.profiles.isDefault(profile)
    }


    var body: some View {
        List {
            if let profile {
                SettingsSectionGroup {
                    ProfileActionsList(
                        profile: profile,
                        syncEnabled: SyncSetupFeatureFlag().isEnabled,
                        offersPlexPINReuse: profile.playsAsPINProtectedPlexUser,
                        hasParentalPIN: appModel.profiles.parentalPIN != nil,
                        // Sealed only when this profile is BOTH a Kids Profile
                        // and the one currently open: a grown-up editing a
                        // child's profile from their own is exactly who should
                        // be able to change it.
                        restrictedActionsSealed: profile.isKids
                            && appModel.profiles.activeProfileID == profileID
                            && appModel.profiles.parentalPIN != nil,
                        onEditAppearance: { showingEditor = true },
                        onEditLock: { showingLockSetup = true },
                        onCreateParentalPIN: { showingParentalSetup = true },
                        onSetLock: { appModel.setLock($0, forProfile: profileID) },
                        onSetKids: { appModel.setKidsProfile($0, forProfile: profileID) },
                        onSetParentalPIN: { appModel.profiles.setParentalPIN($0) },
                        validatePlexPIN: {
                            await appModel.plexHomeUsers.validatePlexPIN(
                                $0,
                                forProfile: profileID
                            )
                        },
                        onDelete: canDelete ? { appModel.removeProfile(profileID) } : nil,
                        isUnlocked: appModel.isUnlockedThisRun(profileID),
                        onUnlock: { appModel.noteUnlocked(profileID) }
                    )
                }

            }
        }
        .settingsPageSurface()
        .navigationTitle(Text(verbatim: profile?.name ?? ""))
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showingLockSetup) {
            if let profile {
                ProfileLockSetupView(
                    profile: profile,
                    offersPlexPINReuse: profile.playsAsPINProtectedPlexUser,
                    syncEnabled: SyncSetupFeatureFlag().isEnabled,
                    validatePlexPIN: {
                        await appModel.plexHomeUsers.validatePlexPIN($0, forProfile: profileID)
                    },
                    onComplete: { lock in
                        appModel.setLock(lock, forProfile: profileID)
                        showingLockSetup = false
                    },
                    onCancel: { showingLockSetup = false }
                )
            }
        }
        .navigationDestination(isPresented: $showingParentalSetup) {
            ParentalPINSetupView(
                onComplete: { pin in
                    appModel.profiles.setParentalPIN(pin)
                    showingParentalSetup = false
                },
                onCancel: { showingParentalSetup = false }
            )
        }
        .sheet(isPresented: $showingEditor) {
            NavigationStack {
                PlozziOSProfileEditorHost(
                    appModel: appModel,
                    editingProfile: profile,
                    canDelete: false,
                    onFinished: { showingEditor = false }
                )
            }
            .preferredColorScheme(palette.isLight ? .light : .dark)
        }
    }
}
#endif
