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
        content
            .onChange(of: profile == nil) { _, gone in
                if gone { dismiss() }
            }
    }

    @ViewBuilder
    private var content: some View {
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
                ownsFullScreen: false,
                onCancel: { dismiss() }
            )
            // Identity is the PROFILE, not this view's position in the tree.
            //
            // `context.profiles` is recency-ordered and recomputed, so every
            // live cosmetic edit can hand this page a reordered array. Without a
            // stable id the editor could be treated as a new view, reset its
            // `@State` from the freshly-saved profile, and see that as another
            // edit — which writes again. That loop saturates the main thread and
            // presents as a frozen screen, not a crash.
            .id(profileID)
        }
        // This page can't delete (it is cosmetics only), but a sync applying a
        // remote deletion while it is open would leave it rendering nothing at
        // all — a page about something that no longer exists should leave.
        //
        // On a CHANGE, never on first appearance. `onAppear { dismiss() }` fires
        // during the push itself if the lookup is momentarily empty, and
        // dismissing a screen mid-push wedges the navigation stack.
        else {
            Color.clear
        }
    }
}
#endif
