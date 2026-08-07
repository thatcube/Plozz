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
    /// Whether the Parental PIN has already been entered for this run of the
    /// settings screen. Without it a correct PIN left this page sealed, so the
    /// gate looked broken.
    var isParentalUnlocked: Bool = false

    /// The single pushed destination for this page — see `Route`.
    @State private var route: Route?

    @Environment(\.dismiss) private var dismiss

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
                            && appModel.profiles.parentalPIN != nil
                            && !isParentalUnlocked,
                        onEditAppearance: { route = .appearance },
                        onEditLock: { route = .lockSetup },
                        onCreateParentalPIN: { route = .parentalSetup },
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
        // ONE destination for this level. Three competing presentations lived
        // here — two boolean `navigationDestination`s plus a sheet — and Apple's
        // rule is one destination per level; with several attached the last can
        // win and the rest silently do nothing. Appearance moved from a sheet to
        // a push for the same reason: this page can itself be inside the Settings
        // sheet, and a modal from a covered view is dropped.
        .navigationDestination(item: $route) { route in
            destination(for: route)
        }
        // Deleting the profile this page is ABOUT leaves it describing something
        // that no longer exists, and rendering nothing at all. See the tvOS twin,
        // where the same shape reads as a dead black screen the remote can't
        // leave; here it is a blank page with a back button, which is milder but
        // just as wrong.
        .onChange(of: profile == nil) { _, profileIsGone in
            if profileIsGone { dismiss() }
        }
    }

    /// What this page can push. One case per destination, so they can't compete.
    private enum Route: Hashable, Identifiable {
        case lockSetup
        case parentalSetup
        case appearance
        var id: Self { self }
    }

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .lockSetup:
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
                        self.route = nil
                    },
                    onCancel: { self.route = nil }
                )
            }
        case .parentalSetup:
            ParentalPINSetupView(
                onComplete: { pin in
                    appModel.profiles.setParentalPIN(pin)
                    self.route = nil
                },
                onCancel: { self.route = nil }
            )
        case .appearance:
            PlozziOSProfileAppearancePage(appModel: appModel, profileID: profileID)
        }
    }
}
#endif
