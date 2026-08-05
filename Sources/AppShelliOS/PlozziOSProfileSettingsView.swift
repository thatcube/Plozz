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

    /// Read live so the page reflects a lock added or the profile renamed.
    private var profile: Profile? {
        appModel.profiles.profiles.first(where: { $0.id == profileID })
    }

    private var canDelete: Bool {
        guard let profile else { return false }
        return !appModel.profiles.isDefault(profile)
    }


    /// Whether any *other* profile carries a lock — a Kids Profile only contains
    /// anyone if there's something locked to keep them out of.
    private var householdHasAnyLock: Bool {
        appModel.profiles.profiles.contains { $0.id != profileID && $0.isLocked }
    }

    var body: some View {
        List {
            if let profile {
                SettingsSectionGroup {
                    ProfileActionsList(
                        profile: profile,
                        syncEnabled: SyncSetupFeatureFlag().isEnabled,
                        offersPlexPINReuse: profile.playsAsPINProtectedPlexUser,
                        householdHasOtherLock: householdHasAnyLock,
                        onEditAppearance: { showingEditor = true },
                        onSetLock: { appModel.setLock($0, forProfile: profileID) },
                        onSetKids: { appModel.setKidsProfile($0, forProfile: profileID) },
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
