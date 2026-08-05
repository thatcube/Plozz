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
    var size: CGFloat = 36
    let action: () -> Void

    var body: some View {
        let profile = appModel.profiles.activeProfile
        Button(action: action) {
            // Minimal label: the avatar already frames + circle-clips itself, so
            // hand the toolbar a plain circular button and let IT own the glass
            // pill and its full hit target — exactly like the sibling mute
            // button, whose whole pill is tappable. Every extra modifier we tried
            // here (`.buttonStyle(.plain)`, a second `.frame`/`.clipShape`, an
            // explicit `.contentShape`) opted out of that system treatment and
            // clamped taps to just the avatar. `.buttonBorderShape(.circle)`
            // keeps the pill round.
            ProfileAvatarView(profile: profile, size: size)
        }
        .buttonBorderShape(.circle)
        .accessibilityLabel(Text("Settings for \(profile.name)"))
    }
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
    /// Whether a newly created profile should be a Kids Profile.
    var createsKidsProfile: Bool = false

    init(
        appModel: PlozziOSAppModel,
        editingProfile: Profile? = nil,
        canDelete: Bool = false,
        createsKidsProfile: Bool = false,
        onFinished: @escaping () -> Void
    ) {
        self.appModel = appModel
        self.editingProfile = editingProfile
        self.canDelete = canDelete
        self.createsKidsProfile = createsKidsProfile
        self.onFinished = onFinished
    }

    var body: some View {
        ProfileEditorView(
            editingProfile: editingProfile,
            canDelete: canDelete,
            photoSourceAccounts: appModel.accountsProviders.accounts,
            existingColorIndices: appModel.profiles.profiles.map(\.colorIndex),
            existingEmojiAvatars: appModel.profiles.profiles.compactMap(\.avatarEmoji),
            plexHomeUsersFetcher: { accountID in
                await appModel.plexHomeUsers.plexHomeUsers(forAccountID: accountID)
            },
            onSave: { draft in
                appModel.saveProfile(draft, isKids: createsKidsProfile)
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
