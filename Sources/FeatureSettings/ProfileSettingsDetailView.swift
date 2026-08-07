#if canImport(SwiftUI)
import CoreModels
import CoreUI
import FeatureProfiles
import SwiftUI

/// Settings → Everyone → Profiles → *one profile*.
///
/// Everything that is true *about* a profile as an entity, for any profile in
/// the household rather than just the active one: how it looks, whether it needs
/// a PIN to open, whether it's restricted, and whether it exists at all.
///
/// Managing every profile's lock from one screen — instead of each person
/// locking their own from inside it — is what Netflix does, and it's the only
/// arrangement that actually works here: a Kids Profile deliberately can't reach
/// this section, so a grown-up has to be able to set the child's restrictions
/// (and their own lock) from a profile the child isn't using.
///
/// Appearance stays behind a sheet in the cosmetic editor, which is deliberately
/// cosmetics-only — "what the profile looks like" separated from "what it can
/// do". A permission has no business in the avatar picker.
struct ProfileSettingsDetailView: View {
    let context: SettingsContext
    let profileID: String
    /// Whether these settings currently reach the user's other devices, so a lock
    /// set here can say when it's device-only.
    let syncEnabled: Bool

    /// The single pushed destination for this page — see `Route`.
    @State private var route: Route?

    @Environment(\.dismiss) private var dismiss

    /// Read live from the context so the page reflects edits made on it (a lock
    /// added, a rename) without needing its own copy to be invalidated.
    private var profile: Profile? {
        context.profiles.first(where: { $0.id == profileID })
    }

    /// The first profile is the household's default and can't be deleted.
    private var canDelete: Bool {
        profileID != context.profiles.first?.id
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if let profile {
                    SettingsPageHeader(
                        verbatim: profile.name,
                        subtitle: "How this profile looks, and who can open it."
                    )
                    actionsPanel(profile)
                }
            }
            .frame(maxWidth: PlozzTheme.Metrics.settingsContentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
            .padding(.vertical, 24)
        }
        .scrollClipDisabled()
        // ONE destination for this level, not three booleans.
        //
        // Pushed rather than presented: modals requested from inside the Settings
        // tab are unreliable — `RootView` stacks several `fullScreenCover`
        // modifiers on one host and a contested slot is silently dropped (the
        // header's Edit button did nothing for exactly this reason). Stacking
        // three `navigationDestination(isPresented:)` on one view reintroduces
        // the same class of bug at the navigation layer: Apple's rule is one
        // destination per level, and with several attached the last one can win
        // and the rest quietly become no-ops.
        .navigationDestination(item: $route) { route in
            destination(for: route)
                .toolbar(.hidden, for: .tabBar)
        }
        // Deleting the profile this page is ABOUT leaves it with nothing to draw:
        // the lookup returns nil, the body renders an empty scroll view, and on
        // tvOS a screen with nothing focusable strands the viewer — it reads as a
        // dead black screen the remote can't leave. Deleting from the profile
        // PICKER never showed this, because that screen deletes from a list it
        // then stays on.
        //
        // Popping is also just the right outcome: a page describing something
        // that no longer exists has nothing to say.
        .onChange(of: profile == nil) { _, profileIsGone in
            if profileIsGone { dismiss() }
        }
    }

    /// What this page can push. One case per destination, so they can't compete.
    enum Route: Hashable, Identifiable {
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
                    syncEnabled: syncEnabled,
                    validatePlexPIN: { await context.validatePlexPIN($0, profileID) },
                    onComplete: { lock in
                        context.onSetProfileLock(profileID, lock)
                        self.route = nil
                    },
                    onCancel: { self.route = nil }
                )
            }
        case .parentalSetup:
            ParentalPINSetupView(
                onComplete: { pin in
                    context.onSetParentalPIN(pin)
                    self.route = nil
                },
                onCancel: { self.route = nil }
            )
        case .appearance:
            if let profile {
                ProfileEditorView(
                    editingProfile: profile,
                    canDelete: false,
                    photoSourceAccounts: context.accounts,
                    plexHomeUsersFetcher: context.plexHomeUsersFetcher,
                    onSave: { draft in
                        context.onSaveProfile(draft)
                        self.route = nil
                    },
                    onLiveChange: { context.onUpdateProfileCosmetics($0) },
                    onCancel: { self.route = nil }
                )
            }
        }
    }

    // MARK: Actions

    /// The same list the picker's Edit sheet shows — one implementation of
    /// "what can I do to this profile", reached from two places.
    ///
    /// Note there's no longer a Profile Lock *page*: selecting the lock row goes
    /// straight to choosing a PIN (or asks change-or-remove when one is already
    /// set). The page it replaced held a status line and a button that opened the
    /// real screen, which was two presses of nothing.
    private func actionsPanel(_ profile: Profile) -> some View {
        SettingsPanel {
            ProfileActionsList(
                profile: profile,
                syncEnabled: syncEnabled,
                offersPlexPINReuse: profile.playsAsPINProtectedPlexUser,
                hasParentalPIN: context.hasParentalPIN,
                // Sealed only when this profile is BOTH a Kids Profile and the
                // one currently open: a grown-up editing a child's profile from
                // their own is exactly who should be able to change it.
                restrictedActionsSealed: profile.isKids
                    && context.activeProfile.id == profileID
                    && context.hasParentalPIN
                    && !context.isParentalUnlocked,
                onEditAppearance: { route = .appearance },
                onEditLock: { route = .lockSetup },
                onCreateParentalPIN: { route = .parentalSetup },
                onSetLock: { context.onSetProfileLock(profileID, $0) },
                onSetKids: { context.onSetKidsProfile(profileID, $0) },
                onSetParentalPIN: context.onSetParentalPIN,
                validatePlexPIN: {
                    await context.validatePlexPIN($0, profileID)
                },
                onDelete: canDelete ? { context.onDeleteProfile(profileID) } : nil,
                isUnlocked: context.isProfileUnlocked(profileID),
                onUnlock: { context.onProfileUnlocked(profileID) }
            )
            .tvOSFocusSection()
        }
    }


}
#endif
