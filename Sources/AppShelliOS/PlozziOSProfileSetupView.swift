#if os(iOS)
import AppRuntime
import CoreModels
import CoreUI
import FeatureProfiles
import FeatureSettings
import SwiftUI

/// The new-profile setup step on iOS: the REAL Libraries screen, with Done.
///
/// Deliberately not a second implementation, for the same reason the tvOS step
/// reuses its Libraries screen. Setup asks exactly what Settings → Libraries
/// asks — which servers this profile uses, who it watches as on each, and which
/// libraries it shows — so it shows that screen rather than a lookalike that
/// would drift from it.
///
/// It differs from tvOS only in which screen that is: iOS's Libraries page is a
/// `Form`, and the tvOS one is a focus-driven list. The *policy* the two share
/// (the gate, when it lifts, what happens next) lives in the model.
struct PlozziOSProfileSetupView: View {
    let appModel: PlozziOSAppModel
    let onDone: () -> Void

    @State private var showingAddServer = false
    @State private var addUserServer: MediaServer?

    var body: some View {
        NavigationStack {
            PlozziOSMyLibrariesSettingsView(
                appModel: appModel,
                onAddServer: showAddServer,
                onAddUser: showAddUser(on:),
                presentation: .profileSetup
            )
            .navigationTitle("Set Up \(appModel.profiles.activeProfile.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
            .safeAreaInset(edge: .top) {
                Text(
                    "Pick the servers \(appModel.profiles.activeProfile.name) watches with, and who they are on each."
                )
                .font(.subheadline)
                .plozzForeground(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
        }
        // Setup has to finish deliberately: the model releases the watchlist
        // import when it does, so a swipe-away is handled as an explicit cancel
        // rather than being allowed to strand the profile mid-flow.
        .interactiveDismissDisabled()
        .sheet(
            isPresented: $showingAddServer,
            onDismiss: {
                appModel.finishManagedServerPresentation()
                addUserServer = nil
            }
        ) {
            AddServerView(
                appModel: appModel,
                initialProvider: addUserServer?.provider ?? .jellyfin,
                initialAddress: addUserServer?.baseURL.absoluteString ?? ""
            )
            .presentationSizing(.page)
        }
        // These belong to the setup cover, not the app root. Keeping them here
        // prevents Home appearing between account/user selection, Plex PIN and
        // the libraries step.
        .sheet(item: plexUserSelectionBinding) { selection in
            PlozziOSPlexUserSelectionView(
                selection: selection,
                onSelect: appModel.selectPlexUserDuringOnboarding
            )
        }
        .fullScreenCover(item: plexPINBinding) { request in
            PlozziOSPlexPINView(
                model: appModel.plexHomeUsers,
                request: request
            )
        }
        .sheet(item: librarySelectionBinding) { selection in
            PlozziOSLibrarySelectionView(
                accounts: appModel.accountsProviders.resolvedAccounts(
                    withIDs: selection.accountIDs
                ),
                visibility: appModel.settings.homeVisibility,
                onContinue: appModel.completeLibrarySelection
            )
        }
    }

    private func showAddUser(on server: MediaServer) {
        addUserServer = server
        appModel.beginAddingUser(on: server)
        showingAddServer = true
    }

    private func showAddServer() {
        appModel.beginManagedServerPresentation()
        showingAddServer = true
    }

    private var plexUserSelectionBinding:
        Binding<PlexHomeUsersModel.PendingPlexUserSelection?>
    {
        Binding(
            get: { appModel.plexHomeUsers.pendingPlexUserSelection },
            set: { if $0 == nil { appModel.cancelPlexUserSelectionDuringOnboarding() } }
        )
    }

    private var plexPINBinding: Binding<PlexHomeUsersModel.PlexPINRequest?> {
        Binding(
            get: { appModel.plexHomeUsers.pendingPlexPINRequest },
            set: { if $0 == nil { appModel.plexHomeUsers.dismissPlexPINIfPresented() } }
        )
    }

    private var librarySelectionBinding:
        Binding<PlozziOSAppModel.PendingLibrarySelection?>
    {
        Binding(
            get: { appModel.pendingLibrarySelection },
            set: { if $0 == nil { appModel.completeLibrarySelection() } }
        )
    }
}

/// Asks who a profile watches as on a Plex server it just switched on.
///
/// Reuses the Home-user page from Settings, which is already the screen for this
/// question on iOS — the difference is only that here it's asked rather than
/// gone looking for. See `ProfileServerIdentityPrompts` for why enabling a
/// server later has to ask at all.
struct PlozziOSServerIdentityPromptView: View {
    let appModel: PlozziOSAppModel
    let account: Account
    let onFinish: () -> Void

    var body: some View {
        NavigationStack {
            PlozziOSPlexHomeUserSettingsView(appModel: appModel, account: account)
                .navigationTitle("Who are you on \(account.server.name)?")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: onFinish)
                    }
                }
        }
    }
}
/// The whole new-profile setup sequence, in ONE cover.
///
/// One cover switching its content rather than a cover per step: presenting on
/// the step itself would tear the cover down and put a new one up each time, and
/// SwiftUI drops a presentation requested while another is still dismissing —
/// which is exactly how the theme step went missing before.
///
/// A view of its own rather than inline in each presenter: both root and the
/// Profiles settings page present this (see `ProfileOnboardingOrigin`), and the
/// iOS root's body is already at the type-checker's budget.
struct PlozziOSProfileOnboardingCover: View {
    let appModel: PlozziOSAppModel
    @Environment(\.themePalette) private var palette

    var body: some View {
        ZStack {
            // Never expose the profile picker / tab shell between setup pages.
            AppBackground(palette: palette).ignoresSafeArea()
            switch appModel.profileOnboardingStep {
            case .libraries:
                PlozziOSProfileSetupView(
                    appModel: appModel,
                    onDone: { appModel.advanceProfileOnboarding() }
                )
            case .seerr:
                if let profile = appModel.profileBeingOnboarded {
                    ProfileSeerrSetupView(
                        seer: appModel.seerService,
                        profile: profile,
                        onSelect: { user in
                            appModel.setSeerrUser(user, for: profile.id)
                        },
                        onContinue: { appModel.advanceProfileOnboarding() }
                    )
                } else {
                    Color.clear.onAppear {
                        appModel.advanceProfileOnboarding()
                    }
                }
            case .theme:
                NavigationStack {
                    PlozziOSThemeWelcomeView(
                        appModel: appModel,
                        onContinue: { appModel.advanceProfileOnboarding() }
                    )
                }
            case .lockOffer:
                if let profile = appModel.profileBeingOnboarded {
                    ProfileLockOfferView(
                        profile: profile,
                        syncEnabled: SyncSetupFeatureFlag().isEnabled,
                        validatePlexPIN: {
                            await appModel.plexHomeUsers.validatePlexPIN(
                                $0,
                                forProfile: profile.id
                            )
                        },
                        onComplete: { lock in
                            appModel.setLock(lock, forProfile: profile.id)
                            appModel.advanceProfileOnboarding()
                        },
                        onSkip: { appModel.advanceProfileOnboarding() }
                    )
                } else {
                    // The profile was deleted underneath the flow.
                    Color.clear.onAppear {
                        appModel.advanceProfileOnboarding()
                    }
                }
            case nil:
                EmptyView()
            }
        }
        .transaction { $0.animation = nil }
    }
}
#endif
