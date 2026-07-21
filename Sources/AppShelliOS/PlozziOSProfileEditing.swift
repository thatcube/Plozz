#if os(iOS)
import CoreModels
import FeatureProfiles
import SwiftUI

/// The settings entry point shown across the iOS app — Home, Search, Downloads
/// and the empty-library shell. It renders the **active profile's real avatar**
/// (borrowed photo, emoji, or symbol on its chosen colour, via the shared
/// `ProfileAvatarView`) instead of a generic gear, so the control both opens
/// Settings and shows "who's watching." Reads the active profile from the
/// environment app model so any toolbar can drop it in with just an action.
struct PlozziOSSettingsAvatarButton: View {
    @Environment(PlozziOSAppModel.self) private var appModel
    var size: CGFloat = 44
    let action: () -> Void

    var body: some View {
        let profile = appModel.profiles.activeProfile
        let showsRealProfile = appModel.profiles.profilesEnabled
            || appModel.profiles.hasRememberedSelection
        let displayedProfile = showsRealProfile
            ? profile
            : Self.genericProfile
        Button(action: action) {
            ProfileAvatarView(profile: displayedProfile, size: size)
                .frame(width: size, height: size)
                .clipShape(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .buttonBorderShape(.circle)
        .accessibilityLabel(
            showsRealProfile
                ? Text("Settings for \(profile.name)")
                : Text("Settings")
        )
    }

    private static let genericProfile = Profile(
        id: "generic-profile",
        name: "Profile",
        avatarSymbol: "person.fill",
        colorIndex: 33,
        createdAt: .distantPast
    )
}

/// Thin host wrapping the shared `ProfileEditorView` for iOS create / edit /
/// delete. All persistence flows through the single draft-based
/// `PlozziOSAppModel.saveProfile(_:)` / `removeProfile(_:)` path — the same
/// model and fields tvOS uses — so there's one source of truth for profile
/// policy. Photo candidates come from the household accounts and each Plex
/// account's Home users, exactly like tvOS.
struct PlozziOSProfileEditorHost: View {
    let appModel: PlozziOSAppModel
    let editingProfile: Profile?
    let canDelete: Bool
    let onFinished: () -> Void

    init(
        appModel: PlozziOSAppModel,
        editingProfile: Profile? = nil,
        canDelete: Bool = false,
        onFinished: @escaping () -> Void
    ) {
        self.appModel = appModel
        self.editingProfile = editingProfile
        self.canDelete = canDelete
        self.onFinished = onFinished
    }

    var body: some View {
        ProfileEditorView(
            editingProfile: editingProfile,
            canDelete: canDelete,
            photoSourceAccounts: appModel.accountsProviders.accounts,
            existingColorIndices: appModel.profiles.profiles.map(\.colorIndex),
            plexHomeUsersFetcher: { accountID in
                await appModel.plexHomeUsers.plexHomeUsers(forAccountID: accountID)
            },
            onSave: { draft in
                appModel.saveProfile(draft)
                onFinished()
            },
            onDelete: deleteHandler,
            onCancel: onFinished
        )
    }

    private var deleteHandler: (() -> Void)? {
        guard canDelete, let id = editingProfile?.id else { return nil }
        return {
            appModel.removeProfile(id)
            onFinished()
        }
    }
}
#endif
