#if canImport(SwiftUI)
import CoreModels
import CoreUI
import FeatureProfiles
import SwiftUI

/// The profile's own name, avatar and colour, as a pushed settings page.
///
/// Exists so a Kids Profile can still change how it looks. Those live on the
/// profile-management page beside the lock, the Kids flag and Delete — so
/// sealing that page behind the Parental PIN took the avatar picker with it, and
/// choosing your own avatar is most of the appeal of having your own profile. It
/// can't escalate anything, so it doesn't belong behind the PIN.
struct ProfileAppearancePage: View {
    let context: SettingsContext
    let profileID: String

    @Environment(\.dismiss) private var dismiss

    private var profile: Profile? {
        context.profiles.first(where: { $0.id == profileID })
    }

    var body: some View {
        if let profile {
            ProfileEditorView(
                editingProfile: profile,
                // Deleting is a parental control; this page is not.
                canDelete: false,
                photoSourceAccounts: context.accounts,
                plexHomeUsersFetcher: context.plexHomeUsersFetcher,
                onSave: { draft in
                    context.onSaveProfile(draft)
                    dismiss()
                },
                onLiveChange: { context.onUpdateProfileCosmetics($0) },
                onCancel: { dismiss() }
            )
        }
        // This page can't delete (it is cosmetics only), but a sync applying a
        // remote deletion while it is open would leave it rendering nothing at
        // all. Same rule as the profile page that pushes here: a page about
        // something that no longer exists should leave, not go blank.
        else {
            Color.clear.onAppear { dismiss() }
        }
    }
}
#endif
