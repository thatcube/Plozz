#if os(iOS)
import AppRuntime
import CoreModels
import CoreUI
import FeatureSettings
import FeatureSyncSetup
import SwiftUI
import UIKit

struct PlozziOSSettingsView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showingAddServer = false
    /// A server we're signing an ADDITIONAL user into, so the Add Server sheet
    /// opens pre-filled with it instead of at the provider chooser.
    @State private var addUserServer: MediaServer?
    @State private var addServerPresentationColorScheme: ColorScheme = .dark
    let appModel: PlozziOSAppModel
    let onClose: () -> Void
    let systemColorScheme: ColorScheme

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                PlozziOSSettingsSplitView(
                    appModel: appModel,
                    onAddServer: showAddServer,
                    onAddUser: showAddUser(on:),
                    onClose: onClose
                )
            } else {
                NavigationStack {
                    PlozziOSSettingsCompactMenu(
                        appModel: appModel,
                        onAddServer: showAddServer,
                        onAddUser: showAddUser(on:)
                    )
                }
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: onClose)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background { SettingsPageBackground() }
        .environment(\.themePalette, palette)
        .environment(\.colorScheme, palette.isLight ? .light : .dark)
        .tint(palette.primaryText)
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
                .preferredColorScheme(addServerPresentationColorScheme)
                .presentationSizing(.page)
        }
        .sheet(item: plexUserSelectionBinding) { selection in
            PlozziOSPlexUserSelectionView(
                selection: selection,
                onSelect: appModel.selectPlexUserDuringOnboarding
            )
            .preferredColorScheme(addServerPresentationColorScheme)
        }
        .sheet(item: plexPINBinding) { request in
            PlozziOSPlexPINView(
                model: appModel.plexHomeUsers,
                request: request
            )
            .preferredColorScheme(addServerPresentationColorScheme)
        }
        .sheet(item: librarySelectionBinding) { selection in
            PlozziOSLibrarySelectionView(
                accounts: appModel.accountsProviders.resolvedAccounts(
                    withIDs: selection.accountIDs
                ),
                visibility: appModel.settings.homeVisibility,
                onContinue: appModel.completeLibrarySelection
            )
            .preferredColorScheme(addServerPresentationColorScheme)
        }
    }

    /// Signs an additional user in to a server that's already added — the iOS half
    /// of "Watching as ▸ Add Another User". Reuses the Add Server sheet,
    /// pre-filled, so there's one sign-in path rather than two.
    private func showAddUser(on server: MediaServer) {
        addUserServer = server
        showAddServer()
    }

    private func showAddServer() {
        addServerPresentationColorScheme = palette.isLight ? .light : .dark
        appModel.beginManagedServerPresentation()
        showingAddServer = true
    }

    private var plexUserSelectionBinding:
        Binding<PlexHomeUsersModel.PendingPlexUserSelection?>
    {
        Binding(
            get: { appModel.plexHomeUsers.pendingPlexUserSelection },
            set: { selection in
                if selection == nil {
                    appModel.cancelPlexUserSelectionDuringOnboarding()
                }
            }
        )
    }

    private var plexPINBinding:
        Binding<PlexHomeUsersModel.PlexPINRequest?>
    {
        Binding(
            get: { appModel.plexHomeUsers.pendingPlexPINRequest },
            set: { request in
                if request == nil {
                    appModel.plexHomeUsers.dismissPlexPINIfPresented()
                }
            }
        )
    }

    private var librarySelectionBinding:
        Binding<PlozziOSAppModel.PendingLibrarySelection?>
    {
        Binding(
            get: { appModel.pendingLibrarySelection },
            set: { selection in
                if selection == nil {
                    appModel.completeLibrarySelection()
                }
            }
        )
    }

    private var palette: ThemePalette {
        ThemePalette.palette(
            for: appModel.settings.theme.theme,
            systemColorScheme: systemColorScheme
        )
    }
}

private enum PlozziOSSettingsDestination: Hashable {
    case profiles
    case requests
    case servers
    case myLibraries
    /// Parental PIN prompt unsealing a Kids Profile's restricted settings.
    case grownUps
    /// This profile's own management page, reached from Parental Controls.
    case manageProfile
    /// The profile's own name, avatar and colour. Deliberately outside Parental
    /// Controls — it can't escalate anything.
    case profileAppearance
    /// Choosing a different profile. Always available, including from a Kids
    /// Profile — the Parental PIN gate is the protection, not hiding the exit.
    case switchProfile
    /// The household's Parental PIN.
    case parentalPIN
    case trackers
    case appearance
    case home
    case detailPage
    case playback
    case downloads
    case syncSetup
    case metadata
    case subtitles
    case spoilers
    case nightShift
    case diagnostics
    case attributions
    case about
}

var deviceName: String {
    UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
}

/// Heading for the settings every profile shares. Named for the audience rather
/// than the hardware, because most of what's in the group syncs — see
/// `SettingsCopy.everyone`. The reach lives in the section footer instead, so
/// toggling iCloud Sync never appears to move a row into a different scope.
private var deviceSettingsTitle: LocalizedStringResource { SettingsCopy.everyone }

/// Whether this device is currently sharing settings with the user's others.
/// Read at render time so the scope footers track the iCloud Sync row live.
private var settingsScopeSyncEnabled: Bool { SyncSetupFeatureFlag().isEnabled }

/// Reach clause for the shared-settings group.
private var everyoneScopeFooter: LocalizedStringResource {
    SettingsCopy.everyoneScope(syncEnabled: settingsScopeSyncEnabled, deviceName: deviceName)
}

/// Reach clause for the active profile's own settings.
private var profileScopeFooter: LocalizedStringResource {
    SettingsCopy.profileScope(syncEnabled: settingsScopeSyncEnabled, deviceName: deviceName)
}

private struct PlozziOSSettingsSplitView: View {
    @Environment(\.themePalette) private var palette
    let appModel: PlozziOSAppModel
    let onAddServer: () -> Void
    var onAddUser: (MediaServer) -> Void = { _ in }
    let onClose: () -> Void
    @State private var selection: PlozziOSSettingsDestination?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    /// Whether this profile's escalation-capable settings are sealed right now.
    /// Mirrors the tvOS rule exactly, from the same shared policy.
    /// Whether this profile shows a separate parent-controlled group. Only a
    /// Kids Profile does, and only once a Parental PIN exists — without one
    /// there's nothing to control with.
    private var showsParentalControlsSection: Bool {
        appModel.profiles.activeProfile.isKids
            && appModel.profiles.parentalPIN != nil
    }

    private var isParentalSealed: Bool {
        appModel.profiles.activeProfile.isKids
            && appModel.profiles.parentalPIN != nil
            && !isParentalUnlocked
    }
    @State private var confirmSignOutAll = false
    @State private var confirmEraseICloud = false
    /// Whether the Parental PIN has been entered for the Kids Profile currently
    /// open. View state, cleared when the profile changes, so unsealing once
    /// never becomes unsealing for good.
    @State private var isParentalUnlocked = false
    /// Where to go once the Parental PIN is accepted.
    ///
    /// The detail pane is driven by `selection`, not a navigation stack, so the
    /// unlock view's `dismiss()` does nothing here — it stayed on screen and let
    /// you keep typing a PIN that had already worked. Remembering the row that
    /// was tapped lets the unlock carry you INTO it, which is what someone
    /// expects anyway.
    @State private var parentalUnlockTarget: PlozziOSSettingsDestination?
    private var developerMode: DeveloperModeModel { .shared }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ScrollView {
                LazyVStack(spacing: 18) {
                    // Live media-share scan/enrich progress. Renders nothing when
                    // idle, so Settings is unchanged unless a share is working.
                    ShareScanStatusHeader(
                        status: appModel.shareScanStatus,
                        shareIDs: appModel.mediaShareAccountIDs
                    )

                    // The active profile's settings come FIRST: they are what
                    // anyone actually opens Settings to change, where the device
                    // group is setup done once.
                    SettingsSectionGroup(verbatim: appModel.profiles.activeProfile.name) {
                        // Always here, Kids Profile or not. It used to live only
                        // in the household group, which a Kids Profile hides —
                        // leaving that profile with no way out on iOS.
                        if appModel.profiles.profiles.count > 1 {
                            settingsRow(
                                .switchProfile,
                                title: "Switch Profile",
                                systemImage: "arrow.trianglehead.2.clockwise.rotate.90"
                            )
                        }
                        // On a Kids Profile, Libraries moves to its own
                        // parent-controlled group below — it's a parent's
                        // setting, and sitting it among the child's own
                        // preferences made the two look equally theirs.
                        if !showsParentalControlsSection {
                            settingsRow(
                                .myLibraries,
                                title: SettingsCopy.libraries,
                                systemImage: "rectangle.stack"
                            )
                        }
                        // With a PIN, the management page moves into Parental
                        // Controls and only the harmless half stays here. Without
                        // one there's nothing to seal — and iOS has no header
                        // Edit button like tvOS, so leaving it out entirely made
                        // profile management unreachable from a Kids Profile,
                        // including the offer to create the PIN in the first
                        // place.
                        if showsParentalControlsSection {
                            settingsRow(
                                .profileAppearance,
                                title: KidsProfileCopy.nameAndAvatar,
                                systemImage: "person.crop.circle"
                            )
                        } else if appModel.profiles.activeProfile.isKids {
                            settingsRow(
                                .manageProfile,
                                title: KidsProfileCopy.manageProfile,
                                systemImage: "person.crop.circle"
                            )
                        }
                        settingsRow(.trackers, title: "Trackers", systemImage: "link")
                        settingsRow(.appearance, title: "Appearance", systemImage: "paintpalette")
                        settingsRow(.home, title: "Customize Home", systemImage: "house")
                        settingsRow(.detailPage, title: "Detail Page", systemImage: "rectangle.portrait.on.rectangle.portrait")
                        settingsRow(.playback, title: "Playback", systemImage: "play.rectangle")
                        settingsRow(.subtitles, title: "Subtitles", systemImage: "captions.bubble")
                        settingsRow(.spoilers, title: "Spoilers", systemImage: "eye.slash")
                        settingsRow(.nightShift, title: "Circadian Mode", systemImage: "moon.stars.fill")
                    } footer: {
                        Text(profileScopeFooter)
                    }

                    // Real rows with real names; the grouping and the lock carry
                    // the meaning. Mirrors tvOS.
                    if showsParentalControlsSection {
                        SettingsSectionGroup(KidsProfileCopy.parentalControls) {
                            sealableRow(
                                .myLibraries,
                                title: SettingsCopy.libraries,
                                systemImage: "rectangle.stack"
                            )
                            sealableRow(
                                .manageProfile,
                                title: KidsProfileCopy.manageProfile,
                                systemImage: "person.crop.circle"
                            )
                        } footer: {
                            // See the tvOS twin: the lock says "sealed" already.
                            if !isParentalSealed {
                                Text(KidsProfileCopy.parentalControlsOpen)
                            }
                        }
                    }

                    // No household section on a Kids Profile. The card that used
                    // to explain its absence was a second "Kids Profile" heading
                    // that did nothing; once Parental Controls exists, a missing
                    // shared section needs no caption. See the tvOS twin.
                    if !appModel.profiles.activeProfile.isKids {
                        SettingsSectionGroup(deviceSettingsTitle) {
                            Button {
                                selection = .profiles
                            } label: {
                                Label("Profiles", systemImage: "person.2")
                                    .frame(
                                        maxWidth: .infinity,
                                        alignment: .leading
                                    )
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            // Household-level, so it sits here rather than on a
                            // profile — one PIN for everyone, not a property of
                            // any one person. Matches tvOS.
                            settingsRow(
                                .parentalPIN,
                                title: KidsProfileCopy.parentalPIN,
                                systemImage: "figure.and.child.holdinghands"
                            )
                            settingsRow(
                                .requests,
                                verbatimTitle: "Seerr",
                                systemImage: "sparkles.tv"
                            )
                            settingsRow(
                                .servers,
                                title: "Servers",
                                systemImage: "externaldrive.connected.to.line.below"
                            )
                            settingsRow(
                                .downloads,
                                title: "Downloads",
                                systemImage: "arrow.down.circle"
                            )
                            settingsRow(
                                .syncSetup,
                                title: "iCloud Sync",
                                systemImage: "icloud"
                            )
                            settingsRow(
                                .metadata,
                                title: "Metadata",
                                systemImage: "sparkles.rectangle.stack"
                            )
                        } footer: {
                            Text(everyoneScopeFooter)
                        }
                    }

                    SettingsSectionGroup("Support") {
                        settingsRow(.diagnostics, title: "Help & Diagnostics", systemImage: "ladybug")
                        settingsRow(.attributions, title: SettingsCopy.attributions, systemImage: "doc.text.magnifyingglass")
                        settingsRow(.about, title: "About", systemImage: "info.circle")
                    }
                    // Hidden until Developer Mode is unlocked (tap Version seven
                    // times in About). Gating on the runtime flag rather than
                    // `#if DEBUG` hides these in every build — including the
                    // Debug-config branded builds — while keeping them reachable.
                    if developerMode.isEnabled {
                        SettingsSectionGroup("Developer") {
                            Button("Reset to First Run") {
                                appModel.resetToFirstRunForDebugging()
                                onClose()
                            }
                            Button("Turn Off Developer Mode", role: .destructive) {
                                developerMode.disable()
                            }
                        }
                        Button("Erase Everything From iCloud", role: .destructive) {
                            confirmEraseICloud = true
                        }
                        .confirmationDialog(
                            "Erase everything from iCloud?",
                            isPresented: $confirmEraseICloud,
                            titleVisibility: .visible
                        ) {
                            Button("Erase Household From iCloud", role: .destructive) {
                                appModel.eraseEverythingFromICloudForDebugging()
                                onClose()
                            }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("Deletes the whole household — every profile, server, and synced login — from iCloud (all your devices), wipes this device to first-run, and turns iCloud Sync OFF here. Use to test a clean cold start (e.g. set up only on the Apple TV, then fresh-install another device). Re-enable Sync when done.")
                        }
                        PlozziOSDeveloperInfoSection()
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar(removing: .sidebarToggle)
            .settingsPageSurface()
        } detail: {
            NavigationStack {
                ZStack {
                    SettingsPageBackground()
                    Group {
                        settingsDetail
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .id(selection)
            .toolbar(removing: .sidebarToggle)
        }
        .navigationSplitViewStyle(.balanced)
        // Switching profiles re-seals: an unlock proves who is standing there
        // now, not who was standing there for a different profile.
        .onChange(of: appModel.profiles.activeProfileID) { _, _ in
            isParentalUnlocked = false
        }
        .toolbar(removing: .sidebarToggle)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: onClose)
            }
        }
        .alert("Sign out of all accounts?", isPresented: $confirmSignOutAll) {
            Button("Cancel", role: .cancel) {}
            Button("Sign Out", role: .destructive) {
                for account in appModel.accounts {
                    appModel.removeAccount(id: account.id)
                }
            }
        } message: {
            Text("This removes every server and network share from this device.")
        }
        .onChange(of: columnVisibility) { _, visibility in
            if visibility != .all {
                columnVisibility = .all
            }
        }
    }

    /// A Parental Controls row: goes to `destination`, or to the PIN prompt while
    /// sealed — remembering `destination` so the unlock lands there rather than
    /// dumping you back on the list to tap the same row again.
    private func sealableRow(
        _ destination: PlozziOSSettingsDestination,
        title: LocalizedStringResource,
        systemImage: String
    ) -> some View {
        Button {
            if isParentalSealed {
                parentalUnlockTarget = destination
                selection = .grownUps
            } else {
                selection = destination
            }
        } label: {
            Label {
                Text(title)
            } icon: {
                Image(systemName: isParentalSealed ? "lock.fill" : systemImage)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func settingsRow(
        _ destination: PlozziOSSettingsDestination,
        title: LocalizedStringResource,
        systemImage: String
    ) -> some View {
        settingsRow(destination, label: Text(title), systemImage: systemImage)
    }

    /// A row labelled with a BRAND name (e.g. "Seerr"). Brands are never
    /// translated, so this spelling keeps them out of the String Catalog.
    private func settingsRow(
        _ destination: PlozziOSSettingsDestination,
        verbatimTitle: String,
        systemImage: String
    ) -> some View {
        settingsRow(destination, label: Text(verbatim: verbatimTitle), systemImage: systemImage)
    }

    private func settingsRow(
        _ destination: PlozziOSSettingsDestination,
        label title: Text,
        systemImage: String
    ) -> some View {
        Button {
            selection = destination
        } label: {
            Label { title } icon: { Image(systemName: systemImage) }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var settingsDetail: some View {
        switch selection ?? .profiles {
        case .profiles:
            PlozziOSProfilesView(appModel: appModel, onClose: onClose)
        case .requests:
            PlozziOSSeerrSettingsView(appModel: appModel)
        case .servers:
            PlozziOSServersSettingsView(
                appModel: appModel,
                onAddServer: onAddServer
            )
        case .grownUps:
            PlozziOSGrownUpsUnlockView(appModel: appModel) {
                isParentalUnlocked = true
                // Carry on into the row that was tapped. Without this the pane
                // would keep showing the PIN screen it just accepted.
                selection = parentalUnlockTarget ?? .myLibraries
                parentalUnlockTarget = nil
            }
        case .parentalPIN:
            PlozziOSParentalPINSettingsView(appModel: appModel)
        case .switchProfile:
            PlozziOSSwitchProfileView(appModel: appModel, onClose: onClose)
        case .profileAppearance:
            PlozziOSProfileEditorHost(
                appModel: appModel,
                editingProfile: appModel.profiles.activeProfile,
                canDelete: false,
                onFinished: { selection = nil }
            )
        case .manageProfile:
            PlozziOSProfileSettingsView(
                appModel: appModel,
                profileID: appModel.profiles.activeProfileID
            )
        case .myLibraries:
            PlozziOSMyLibrariesSettingsView(
                appModel: appModel,
                onAddServer: onAddServer,
                onAddUser: onAddUser
            )
        case .trackers:
            PlozziOSTrackerSettingsView(appModel: appModel)
        case .appearance:
            PlozziOSAppearanceSettingsView(
                theme: appModel.settings.theme,
                transparency: appModel.settings.transparency,
                cardStyle: appModel.settings.cardStyle,
                density: appModel.settings.density,
                watchIndicator: appModel.settings.watchIndicator
            )
        case .home:
            PlozziOSHomeSettingsView(
                hero: appModel.settings.hero,
                heroBackground: appModel.settings.heroBackground,
                visibility: appModel.settings.homeVisibility,
                accounts: appModel.accountsProviders.resolvedActiveAccounts,
                seerConfigured: appModel.seerService.isConfigured
            )
        case .detailPage:
            PlozziOSDetailPageSettingsView(
                heroBackground: appModel.settings.heroBackground,
                themeMusic: appModel.settings.themeMusic
            )
        case .playback:
            PlozziOSPlaybackSettingsView(
                model: appModel.settings.playback,
                audioPolicy: appModel.settings.audioPolicy
            )
        case .downloads:
            PlozziOSDownloadSettingsView(model: appModel.downloads)
        case .syncSetup:
            PlozziOSSyncSetupSettingsView(appModel: appModel)
        case .metadata:
            PlozziOSMetadataSettingsView(deps: appModel.makeMetadataSettingsDependencies())
        case .subtitles:
            PlozziOSSubtitleSettingsView(
                behavior: appModel.settings.subtitleBehavior,
                policy: appModel.settings.subtitlePolicy,
                style: appModel.settings.subtitleStyle
            )
        case .spoilers:
            PlozziOSSpoilerSettingsView(model: appModel.settings.spoilers)
        case .nightShift:
            PlozziOSNightShiftSettingsView(model: appModel.settings.nightShift)
        case .diagnostics:
            PlozziOSDiagnosticsSettingsView(
                appModel: appModel,
                model: appModel.settings.diagnostics,
                crashReporting: appModel.crashReporting
            )
        case .attributions:
            PlozziOSAttributionsView()
        case .about:
            PlozziOSAboutSettingsView(
                hasAccounts: !appModel.accounts.isEmpty && !appModel.profiles.activeProfile.isKids,
                onSignOutAll: { confirmSignOutAll = true }
            )
        }
    }
}

private struct PlozziOSAboutSettingsView: View {
    let hasAccounts: Bool
    let onSignOutAll: () -> Void

    private var developerMode: DeveloperModeModel { .shared }
    @State private var showDeveloperUnlockedAlert = false

    var body: some View {
        List {
            SettingsSectionGroup(verbatim: "Plozz") {
                LabeledContent("Version") {
                    Text(
                        Bundle.main.infoDictionary?[
                            "CFBundleShortVersionString"
                        ] as? String ?? "—"
                    )
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: handleVersionTap)
                LabeledContent("Build") {
                    Text(
                        Bundle.main.infoDictionary?[
                            "CFBundleVersion"
                        ] as? String ?? "—"
                    )
                }
            }

            if hasAccounts {
                SettingsSectionGroup {
                    Button(
                        "Sign Out of All Accounts",
                        role: .destructive,
                        action: onSignOutAll
                    )
                }
            }
        }
        .settingsPageSurface()
        .navigationTitle("About")
        .alert("Developer Mode Enabled", isPresented: $showDeveloperUnlockedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Diagnostic tools are now shown in Settings under Developer. Turn them off again from that section.")
        }
    }

    private func handleVersionTap() {
        if case .justEnabled = developerMode.registerUnlockActivation() {
            showDeveloperUnlockedAlert = true
        }
    }
}

/// Read-only "Device & Build" facts shown under Developer Mode: which build is
/// installed (canonical vs a `--branded` side-by-side app), release channel, and
/// whether the App Group / crash endpoint are present. A Copy button dumps it all
/// as text for a bug report.
private struct PlozziOSDeveloperInfoSection: View {
    var body: some View {
        SettingsSectionGroup("Device & Build") {
            ForEach(DeveloperInfo.snapshot()) { item in
                LabeledContent(item.label, value: item.value)
            }
            LabeledContent("OS", value: ProcessInfo.processInfo.operatingSystemVersionString)
            Button {
                UIPasteboard.general.string = DeveloperInfo.copyText(
                    DeveloperInfo.snapshot(),
                    extra: [DeveloperInfoItem(
                        id: "os",
                        label: "OS",
                        value: ProcessInfo.processInfo.operatingSystemVersionString
                    )]
                )
            } label: {
                Label("Copy Info", systemImage: "doc.on.doc")
            }
        }
    }
}

private struct PlozziOSSettingsCompactMenu: View {
    let appModel: PlozziOSAppModel
    let onAddServer: () -> Void
    var onAddUser: (MediaServer) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var confirmSignOutAll = false
    @State private var confirmEraseICloud = false
    @State private var showMetadata = false
    private var developerMode: DeveloperModeModel { .shared }
    @State private var showDeveloperUnlockedAlert = false
    /// Whether the Parental PIN has been entered for the Kids Profile currently
    /// open. View state, cleared when the profile changes.
    @State private var isParentalUnlocked = false

    /// Whether this profile shows a separate parent-controlled group. Only a
    /// Kids Profile does, and only once a Parental PIN exists.
    private var showsParentalControlsSection: Bool {
        appModel.profiles.activeProfile.isKids
            && appModel.profiles.parentalPIN != nil
    }

    private var isParentalSealed: Bool {
        showsParentalControlsSection && !isParentalUnlocked
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 18) {
                // Live media-share scan/enrich progress. Renders nothing when idle.
                ShareScanStatusHeader(
                    status: appModel.shareScanStatus,
                    shareIDs: appModel.mediaShareAccountIDs
                )

                // Profile first — see the compact layout above.
                SettingsSectionGroup(verbatim: appModel.profiles.activeProfile.name) {
                // See the split-view twin: always available, so a Kids Profile
                // isn't a dead end.
                if appModel.profiles.profiles.count > 1 {
                    NavigationLink {
                        PlozziOSSwitchProfileView(appModel: appModel) { dismiss() }
                    } label: {
                        Label(
                            "Switch Profile",
                            systemImage: "arrow.trianglehead.2.clockwise.rotate.90"
                        )
                    }
                }
                // On a Kids Profile this moves to the Parental Controls group
                // below — see the split-view twin.
                if !showsParentalControlsSection {
                    NavigationLink {
                        PlozziOSMyLibrariesSettingsView(
                            appModel: appModel,
                            onAddServer: onAddServer,
                            onAddUser: onAddUser
                        )
                    } label: {
                        Label(
                            SettingsCopy.libraries,
                            systemImage: "rectangle.stack"
                        )
                    }
                }
                // See the split-view twin for why the no-PIN case still needs a
                // way in.
                if showsParentalControlsSection {
                    NavigationLink {
                        PlozziOSProfileEditorHost(
                            appModel: appModel,
                            editingProfile: appModel.profiles.activeProfile,
                            canDelete: false,
                            onFinished: {}
                        )
                    } label: {
                        Label(KidsProfileCopy.nameAndAvatar, systemImage: "person.crop.circle")
                    }
                } else if appModel.profiles.activeProfile.isKids {
                    NavigationLink {
                        PlozziOSProfileSettingsView(
                            appModel: appModel,
                            profileID: appModel.profiles.activeProfileID
                        )
                    } label: {
                        Label(KidsProfileCopy.manageProfile, systemImage: "person.crop.circle")
                    }
                }
                NavigationLink {
                    PlozziOSTrackerSettingsView(appModel: appModel)
                } label: {
                    Label("Trackers", systemImage: "link")
                }
                NavigationLink {
                    PlozziOSAppearanceSettingsView(
                        theme: appModel.settings.theme,
                        transparency: appModel.settings.transparency,
                        cardStyle: appModel.settings.cardStyle,
                        density: appModel.settings.density,
                        watchIndicator: appModel.settings.watchIndicator
                    )
                } label: {
                    Label("Appearance", systemImage: "paintpalette")
                }
                NavigationLink {
                    PlozziOSHomeSettingsView(
                        hero: appModel.settings.hero,
                        heroBackground: appModel.settings.heroBackground,
                        visibility: appModel.settings.homeVisibility,
                        accounts: appModel.accountsProviders.resolvedActiveAccounts,
                        seerConfigured: appModel.seerService.isConfigured
                    )
                } label: {
                    Label("Customize Home", systemImage: "house")
                }
                NavigationLink {
                    PlozziOSDetailPageSettingsView(
                        heroBackground: appModel.settings.heroBackground,
                        themeMusic: appModel.settings.themeMusic
                    )
                } label: {
                    Label("Detail Page", systemImage: "rectangle.portrait.on.rectangle.portrait")
                }
                NavigationLink {
                    PlozziOSPlaybackSettingsView(
                        model: appModel.settings.playback,
                        audioPolicy: appModel.settings.audioPolicy
                    )
                } label: {
                    Label("Playback", systemImage: "play.rectangle")
                }
                NavigationLink {
                    PlozziOSSubtitleSettingsView(
                        behavior: appModel.settings.subtitleBehavior,
                        policy: appModel.settings.subtitlePolicy,
                        style: appModel.settings.subtitleStyle
                    )
                } label: {
                    Label("Subtitles", systemImage: "captions.bubble")
                }
                NavigationLink {
                    PlozziOSSpoilerSettingsView(model: appModel.settings.spoilers)
                } label: {
                    Label("Spoilers", systemImage: "eye.slash")
                }
                NavigationLink {
                    PlozziOSNightShiftSettingsView(model: appModel.settings.nightShift)
                } label: {
                    Label("Circadian Mode", systemImage: "moon.stars.fill")
                }
            } footer: {
                Text(profileScopeFooter)
            }

                // Real rows with real names; the grouping and the lock carry the
                // meaning. Mirrors the split view and tvOS.
                if showsParentalControlsSection {
                    SettingsSectionGroup(KidsProfileCopy.parentalControls) {
                        if isParentalSealed {
                            NavigationLink {
                                PlozziOSGrownUpsUnlockView(appModel: appModel) {
                                    isParentalUnlocked = true
                                }
                            } label: {
                                Label(SettingsCopy.libraries, systemImage: "lock.fill")
                            }
                            NavigationLink {
                                PlozziOSGrownUpsUnlockView(appModel: appModel) {
                                    isParentalUnlocked = true
                                }
                            } label: {
                                Label(KidsProfileCopy.manageProfile, systemImage: "lock.fill")
                            }
                        } else {
                            NavigationLink {
                                PlozziOSMyLibrariesSettingsView(
                                    appModel: appModel,
                                    onAddServer: onAddServer,
                                    onAddUser: onAddUser
                                )
                            } label: {
                                Label(SettingsCopy.libraries, systemImage: "rectangle.stack")
                            }
                            NavigationLink {
                                PlozziOSProfileSettingsView(
                                    appModel: appModel,
                                    profileID: appModel.profiles.activeProfileID
                                )
                            } label: {
                                Label(KidsProfileCopy.manageProfile, systemImage: "person.crop.circle")
                            }
                        }
                    } footer: {
                        if !isParentalSealed {
                            Text(KidsProfileCopy.parentalControlsOpen)
                        }
                    }
                }

                // Withheld on a Kids Profile: every destructive control in the app
                // lives in here (remove server, delete profile, sign out of
                // everything).
                if !appModel.profiles.activeProfile.isKids {
                    SettingsSectionGroup(deviceSettingsTitle) {
                    NavigationLink {
                        PlozziOSProfilesView(appModel: appModel, onClose: { dismiss() })
                    } label: {
                        Label("Profiles", systemImage: "person.2")
                    }
                    // Household-level, so it sits here rather than on a profile.
                    NavigationLink {
                        PlozziOSParentalPINSettingsView(appModel: appModel)
                    } label: {
                        Label(
                            KidsProfileCopy.parentalPIN,
                            systemImage: "figure.and.child.holdinghands"
                        )
                    }
    
                    NavigationLink {
                        PlozziOSSeerrSettingsView(appModel: appModel)
                    } label: {
                        Label {
                            Text(verbatim: "Seerr")
                        } icon: {
                            Image(systemName: "sparkles.tv")
                        }
                    }
    
                    NavigationLink {
                        PlozziOSServersSettingsView(
                            appModel: appModel,
                            onAddServer: onAddServer
                        )
                    } label: {
                        Label("Servers", systemImage: "externaldrive.connected.to.line.below")
                    }
                    NavigationLink {
                        PlozziOSDownloadSettingsView(model: appModel.downloads)
                    } label: {
                        Label("Downloads", systemImage: "arrow.down.circle")
                    }
                    NavigationLink {
                        PlozziOSSyncSetupSettingsView(appModel: appModel)
                    } label: {
                        Label("iCloud Sync", systemImage: "icloud")
                    }
                    // Metadata uses the Button + navigationDestination pattern rather than
                    // a NavigationLink: a destination/value NavigationLink nested in a
                    // SettingsSectionGroup eager-pushes/swallows taps on this codebase.
                    Button {
                        showMetadata = true
                    } label: {
                        Label("Metadata", systemImage: "sparkles.rectangle.stack")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } footer: {
                    Text(everyoneScopeFooter)
                }
                }

                SettingsSectionGroup("Support") {
                NavigationLink {
                    PlozziOSDiagnosticsSettingsView(
                        appModel: appModel,
                        model: appModel.settings.diagnostics,
                        crashReporting: appModel.crashReporting
                    )
                } label: {
                    Label("Help & Diagnostics", systemImage: "ladybug")
                }
                NavigationLink {
                    PlozziOSAttributionsView()
                } label: {
                    Label(SettingsCopy.attributions, systemImage: "doc.text.magnifyingglass")
                }
                LabeledContent("Version") {
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if case .justEnabled = developerMode.registerUnlockActivation() {
                        showDeveloperUnlockedAlert = true
                    }
                }
                LabeledContent("Build") {
                    Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—")
                }
                if !appModel.accounts.isEmpty, !appModel.profiles.activeProfile.isKids {
                    Button("Sign Out of All Accounts", role: .destructive) {
                        confirmSignOutAll = true
                    }
                }
            }

                // Hidden until Developer Mode is unlocked (tap Version seven
                // times). Gated on the runtime flag in every build.
                if developerMode.isEnabled {
                    SettingsSectionGroup("Developer") {
                        Button("Reset to First Run") {
                            appModel.resetToFirstRunForDebugging()
                            dismiss()
                        }
                        Button("Turn Off Developer Mode", role: .destructive) {
                            developerMode.disable()
                        }
                    }
                    Button("Erase Everything From iCloud", role: .destructive) {
                        confirmEraseICloud = true
                    }
                    .confirmationDialog(
                        "Erase everything from iCloud?",
                        isPresented: $confirmEraseICloud,
                        titleVisibility: .visible
                    ) {
                        Button("Erase Household From iCloud", role: .destructive) {
                            appModel.eraseEverythingFromICloudForDebugging()
                            dismiss()
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Deletes the whole household — every profile, server, and synced login — from iCloud (all your devices), wipes this device to first-run, and turns iCloud Sync OFF here. Use to test a clean cold start (e.g. set up only on the Apple TV, then fresh-install another device). Re-enable Sync when done.")
                    }
                    PlozziOSDeveloperInfoSection()
                }

                if let accountError = appModel.accountError {
                    SettingsSectionGroup {
                        Label(accountError, systemImage: "exclamationmark.triangle.fill")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .settingsPageSurface()
        .navigationTitle("Settings")
        .navigationDestination(isPresented: $showMetadata) {
            PlozziOSMetadataSettingsView(deps: appModel.makeMetadataSettingsDependencies())
        }
        .alert("Sign out of all accounts?", isPresented: $confirmSignOutAll) {
            Button("Cancel", role: .cancel) {}
            Button("Sign Out", role: .destructive) {
                for account in appModel.accounts {
                    appModel.removeAccount(id: account.id)
                }
            }
        } message: {
            Text("This removes every server and network share from this device.")
        }
        .alert("Developer Mode Enabled", isPresented: $showDeveloperUnlockedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Diagnostic tools are now shown in Settings under Developer. Turn them off again from that section.")
        }
    }
}

private struct PlozziOSProfilesView: View {
    @Environment(\.themePalette) private var palette
    let appModel: PlozziOSAppModel
    @State private var showingAddProfile = false
    @State private var editingProfile: Profile?
    @State private var selectedProfileRoute: PlozziOSProfileSettingsRoute?
    /// Closes Settings, so a switch can raise its gates from the root.
    var onClose: () -> Void = {}

    private var orderedProfiles: [Profile] { appModel.profiles.profilesByRecency }

    var body: some View {
        List {
            SettingsSectionGroup {
                Toggle(
                    "Ask Who’s Watching on Startup",
                    isOn: Binding(
                        get: {
                            appModel.profiles.askProfileOnStartup
                        },
                        set: {
                            appModel.profiles.setAskProfileOnStartup($0)
                        }
                    )
                )
            } footer: {
                Text("Profiles keep Home, settings, and downloads personal. Watch history belongs to the account each profile watches as.")
            }

            SettingsSectionGroup("Who’s watching?") {
                // Tapping a face SWITCHES to it; the trailing button edits.
                //
                // It used to be the other way round — the whole row opened the
                // editor and switching hid in a small picker above — under a
                // "Who's watching?" header, beside a checkmark marking the active
                // profile. Every signal said switcher; the tap said editor.
                ForEach(orderedProfiles) { profile in
                    HStack(spacing: 12) {
                        Button {
                            guard profile.id != appModel.profiles.activeProfileID else { return }
                            // Close Settings first: the Parental PIN and profile
                            // lock gates are presented from the root, and a cover
                            // asked for from under an open sheet is the
                            // arrangement that fails silently.
                            onClose()
                            appModel.selectProfile(profile.id)
                        } label: {
                            HStack {
                                PlozziOSProfileAvatar(
                                    profile: profile,
                                    size: 34
                                )
                                Text(profile.name)
                                Spacer()
                                if profile.id
                                    == appModel.profiles.activeProfileID {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                                // Glance the access state so the list answers
                                // "who's locked?" without opening each one.
                                if profile.isKids {
                                    Image(systemName: "figure.and.child.holdinghands")
                                        .plozzForeground(.secondary)
                                }
                                if profile.isLocked {
                                    Image(systemName: "lock.fill")
                                        .plozzForeground(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        // Its own hit area, so editing never happens by accident
                        // when someone meant to switch.
                        Button {
                            // One optional route owned by this page. A row cannot
                            // activate another row's destination, and there is no
                            // per-row NavigationLink state for SwiftUI's
                            // split-view reconciliation to accidentally stack.
                            selectedProfileRoute = PlozziOSProfileSettingsRoute(
                                profileID: profile.id
                            )
                        } label: {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.tint)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(Text("Edit \(profile.name)"))
                    }
                    .swipeActions {
                        if !appModel.profiles.isDefault(profile) {
                            Button("Delete", role: .destructive) {
                                appModel.removeProfile(profile.id)
                            }
                        }
                    }
                }
                Button("Add Profile", systemImage: "person.badge.plus") {
                    showingAddProfile = true
                }
            }
        }
        .settingsPageSurface()
        .navigationTitle("Profiles")
        // One typed value, one push. Closure-based destinations inside this
        // ForEach were all being activated by the containing split/stack,
        // producing a back-stack containing every profile in list order.
        .navigationDestination(item: $selectedProfileRoute) { route in
            PlozziOSProfileSettingsView(
                appModel: appModel,
                profileID: route.profileID
            )
        }
        .sheet(isPresented: $showingAddProfile) {
            NavigationStack {
                PlozziOSProfileEditorHost(
                    appModel: appModel,
                    onFinished: { showingAddProfile = false }
                )
            }
            .preferredColorScheme(palette.isLight ? .light : .dark)
        }
        .sheet(item: $editingProfile) { profile in
            NavigationStack {
                PlozziOSProfileEditorHost(
                    appModel: appModel,
                    editingProfile: profile,
                    canDelete: !appModel.profiles.isDefault(profile),
                    onFinished: { editingProfile = nil }
                )
            }
            .preferredColorScheme(palette.isLight ? .light : .dark)
        }
        // New-profile setup. A profile is created holding EVERY server, so this
        // runs before its first watchlist import and asks which servers it
        // actually uses and who it watches as on each — otherwise the household's
        // aggregate watchlist lands in a brand new (often child) profile. See
        // `PlozziOSAppModel.ProfileOnboardingStep`.
        //
        // Presented from this page, which is the one that presents Add Profile:
        // a cover asked for from the root would be blocked by the Settings sheet
        // this page lives inside and silently never appear.
        //
        // ONE cover for the whole sequence, switching its content, rather than a
        // cover per step: presenting on `item` would tear the cover down and put
        // a new one up on every step, and SwiftUI drops a presentation requested
        // while another is still dismissing — which is exactly how the theme step
        // went missing before.
        .fullScreenCover(isPresented: Binding(
            get: { appModel.isPresentingProfileOnboarding(from: .settings) },
            set: { if !$0 { appModel.cancelProfileOnboarding() } }
        )) {
            PlozziOSProfileOnboardingCover(appModel: appModel)
        }
    }
}

private struct PlozziOSProfileSettingsRoute: Hashable {
    let profileID: String
}

struct PlozziOSAccountDetailView: View {
    @Environment(\.dismiss) private var dismiss

    let appModel: PlozziOSAppModel
    let account: Account
    @State private var confirmRemoval = false
    @State private var confirmEverywhere = false

    private var offerEverywhere: Bool { appModel.offersRemoveEverywhere }

    var body: some View {
        List {
            SettingsSectionGroup("Account") {
                LabeledContent("Provider", value: account.server.provider.displayName)
                if !account.userName.isEmpty {
                    LabeledContent("User", value: account.userName)
                }
                LabeledContent("Server", value: account.server.name)
                LabeledContent("Address", value: account.server.baseURL.absoluteString)
            }

            if account.server.provider == .plex {
                SettingsSectionGroup("Plex Home") {
                    NavigationLink {
                        PlozziOSPlexHomeUserSettingsView(
                            appModel: appModel,
                            account: account
                        )
                    } label: {
                        Label("Plex User", systemImage: "person.crop.circle")
                    }
                }
            }

            if account.server.provider == .mediaShare {
                PlozziOSShareScanSection(
                    state: appModel.shareScanStatus.state(
                        forShareID: account.id
                    ),
                    onScan: {
                        appModel.rescanShare(accountID: account.id)
                    }
                )
            }

            SettingsSectionGroup {
                Button("Remove Server", role: .destructive) {
                    confirmRemoval = true
                }
            }
        }
        .settingsPageSurface()
        .navigationTitle(account.server.name)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Remove \(account.server.name)?",
            isPresented: $confirmRemoval,
            titleVisibility: .visible
        ) {
            if offerEverywhere {
                Button("Remove Everywhere", role: .destructive) { confirmEverywhere = true }
                Button("Remove from This \(deviceName)", role: .destructive) {
                    appModel.removeAccount(id: account.id)
                    dismiss()
                }
            } else {
                Button("Remove", role: .destructive) {
                    appModel.removeAccount(id: account.id)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(offerEverywhere
                 ? "Remove it from all your devices, or just this \(deviceName)?"
                 : "Signs out and removes this server.")
        }
        .alert("Remove from all devices?", isPresented: $confirmEverywhere) {
            Button("Remove Everywhere", role: .destructive) {
                appModel.removeAccountEverywhere(id: account.id)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("“\(account.server.name)” will also be removed from your other devices signed in to iCloud.")
        }
    }
}

private struct PlozziOSShareScanSection: View {
    let state: ShareScanState?
    let onScan: () -> Void

    var body: some View {
        SettingsSectionGroup("Library") {
            LabeledContent {
                ZStack(alignment: .trailing) {
                    idleValue
                        .opacity(isBusy ? 0 : 1)
                    busyValue
                        .monospacedDigit()
                        .opacity(isBusy ? 1 : 0)
                }
            } label: {
                ZStack(alignment: .leading) {
                    Text("Last scanned")
                        .opacity(isBusy ? 0 : 1)
                    Text(state?.phase ?? LocalizedStringResource("Updating library"))
                        .opacity(isBusy ? 1 : 0)
                }
            }
            ShareScanProgressBar(fraction: state?.fraction)
                .frame(height: isBusy ? 6 : 0)
                .opacity(isBusy ? 1 : 0)
                .clipped()

            Button("Scan Now", systemImage: "arrow.clockwise", action: onScan)
                .disabled(isBusy)
        }
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private var isBusy: Bool {
        state?.isBusy == true
    }

    private var busyValue: Text {
        guard let detail = state?.progressDetail else {
            return Text(verbatim: "")
        }
        return scanProgressDetailText(detail)
    }

    private var idleValue: Text {
        if let date = state?.lastScanAt {
            return Text(date, format: .relative(presentation: .named))
        }
        return Text("Never")
    }
}

struct PlozziOSPlexHomeUserSettingsView: View {
    let appModel: PlozziOSAppModel
    let account: Account
    @State private var users: [PlexHomeUser] = []
    @State private var isLoading = false

    var body: some View {
        List {
            SettingsSectionGroup("Account owner") {
                userButton(
                    name: account.userName.isEmpty ? "Plex Account Owner" : account.userName,
                    avatarURL: nil,
                    requiresPIN: false,
                    user: nil
                )
            }

            SettingsSectionGroup("Home users") {
                if isLoading {
                    HStack {
                        ProgressView()
                        Text("Loading Plex Home…")
                    }
                } else if users.isEmpty {
                    Text("No additional Plex Home users were found.")
                        .plozzForeground(.secondary)
                } else {
                    ForEach(users.filter { !$0.isAdmin }) { user in
                        userButton(
                            name: user.name,
                            avatarURL: user.avatarURL,
                            requiresPIN: user.requiresPIN,
                            user: user
                        )
                    }
                }
            } footer: {
                Text("PIN-protected users must unlock when their Plozz profile becomes active.")
            }
        }
        .settingsPageSurface()
        .navigationTitle("Plex User")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            isLoading = true
            users = await appModel.plexHomeUsers.plexHomeUsers(
                forAccountID: account.id
            )
            isLoading = false
        }
    }

    private func userButton(
        name: String,
        avatarURL: URL?,
        requiresPIN: Bool,
        user: PlexHomeUser?
    ) -> some View {
        Button {
            appModel.plexHomeUsers.setPlexHomeUserForActiveProfile(
                accountID: account.id,
                user: user
            )
        } label: {
            HStack(spacing: 12) {
                AsyncImage(url: avatarURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .plozzForeground(.secondary)
                }
                .frame(width: 40, height: 40)
                .clipShape(Circle())

                Text(name)
                    .foregroundStyle(.primary)
                if requiresPIN {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .plozzForeground(.secondary)
                }
                Spacer()
                if isSelected(user) {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func isSelected(_ user: PlexHomeUser?) -> Bool {
        let binding = appModel.profiles.activeProfile.homeUserBinding(
            forPlexAccount: account.id
        )
        if let user {
            return binding?.homeUserID == user.id
        }
        return binding == nil
    }
}

private struct PlozziOSAppearanceSettingsView: View {
    @Bindable var theme: ThemeSettingsModel
    @Bindable var transparency: TransparencyPreferenceModel
    @Bindable var cardStyle: CardStyleSettingsModel
    @Bindable var density: UIDensitySettingsModel
    @Bindable var watchIndicator: WatchStatusIndicatorSettingsModel
    @Environment(AppLanguageSettingsModel.self) private var appLanguage

    var body: some View {
        @Bindable var appLanguage = appLanguage
        return List {
            SettingsSectionGroup("Language") {
                Picker("Language", selection: $appLanguage.language) {
                    ForEach(AppLanguage.available()) { language in
                        // Endonym verbatim; the "System" row is copy.
                        Group {
                            if let endonym = language.endonym {
                                Text(verbatim: endonym)
                            } else {
                                Text(AppLanguage.systemOptionTitle)
                            }
                        }
                        .tag(language)
                    }
                }
            } footer: {
                Text("Applies to Plozz's own labels. Media titles keep the language your server provides, and system prompts follow the device.")
            }

            SettingsSectionGroup("Theme") {
                Picker("Appearance", selection: $theme.theme) {
                    ForEach(AppTheme.allCases) { theme in
                        Label(theme.displayName, systemImage: theme.symbolName)
                            .tag(theme)
                    }
                }
                Picker(
                    "Liquid Glass",
                    selection: $transparency.preference
                ) {
                    ForEach(TransparencyPreference.allCases) { preference in
                        Text(
                            preference == .system
                                ? "System"
                                : preference.displayName
                        )
                        .tag(preference)
                    }
                }
            }

            SettingsSectionGroup("Library cards") {
                Picker("Card style", selection: $cardStyle.style) {
                    ForEach(CardStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                Picker("Display size", selection: $density.density) {
                    ForEach(UIDensity.allCases) { density in
                        Label(density.displayName, systemImage: density.symbolName)
                            .tag(density)
                    }
                }
                Picker("Watch indicator", selection: $watchIndicator.indicator) {
                    ForEach(WatchStatusIndicator.allCases) { indicator in
                        Text(indicator.displayName).tag(indicator)
                    }
                }
            }
        }
        .settingsPageSurface()
        .navigationTitle("Appearance")
    }
}

private struct PlozziOSHomeSettingsView: View {
    @Bindable var hero: HeroSettingsModel
    @Bindable var heroBackground: HeroBackgroundSettingsModel
    let visibility: HomeLibraryVisibilityModel
    let accounts: [ResolvedAccount]
    let seerConfigured: Bool
    @State private var libraries: [HomeLibraryChoice] = []
    @State private var isLoadingLibraries = false
    @State private var selectedLibraryID: String?

    var body: some View {
        List {
            SettingsSectionGroup("Rows") {
                ForEach(HomeGlobalRow.allCases, id: \.rawValue) { row in
                    Toggle(
                        row.title,
                        isOn: Binding(
                            get: { visibility.isGlobalRowEnabled(row) },
                            set: { visibility.setGlobalRowEnabled($0, for: row) }
                        )
                    )
                }
                Toggle(
                    "Merge libraries",
                    isOn: Binding(
                        get: { visibility.visibility.mergeLibrariesOnHome },
                        set: { merge in
                            visibility.setMergeLibrariesOnHome(merge)
                            if !merge {
                                visibility.seedLibraryRowsIfNeeded(
                                    libraries.flatMap { library in
                                        LibraryHomeRowKind.allCases.map {
                                            (library.key, $0)
                                        }
                                    }
                                )
                            }
                        }
                    )
                )
            }

            SettingsSectionGroup("Libraries") {
                if isLoadingLibraries, libraries.isEmpty {
                    HStack {
                        ProgressView()
                        Text("Loading libraries…")
                    }
                } else if libraries.isEmpty {
                    Text("No video libraries are available.")
                        .plozzForeground(.secondary)
                } else {
                    ForEach(libraries) { library in
                        Button {
                            selectedLibraryID = library.id
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(library.title)
                                    Text(library.serverName)
                                        .font(.caption)
                                        .plozzForeground(.secondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.forward")
                                    .font(.footnote.weight(.semibold))
                                    .plozzForeground(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            } footer: {
                Text("Choose which libraries and library-specific rows appear on Home.")
            }

            SettingsSectionGroup("Hero") {
                Toggle("Show hero", isOn: $hero.settings.isEnabled)
                if hero.settings.isEnabled {
                    Toggle("Hide watched titles", isOn: $hero.settings.hideWatched)
                    Toggle("Auto-advance", isOn: $hero.settings.autoAdvance)
                    Toggle(
                        "Play trailer behind the hero",
                        isOn: $heroBackground.settings.homeTrailerEnabled
                    )
                    if heroBackground.settings.homeTrailerEnabled {
                        Toggle(
                            "Start muted",
                            isOn: $heroBackground.settings.homeTrailerMuted
                        )
                    }
                }
            }

            if hero.settings.isEnabled {
                SettingsSectionGroup("Hero sources") {
                    ForEach(orderedHeroSources, id: \.self) { source in
                        Toggle(
                            source.displayName,
                            isOn: Binding(
                                get: {
                                    source == .featured && !seerConfigured
                                        ? false
                                        : hero.settings.sources.contains(source)
                                },
                                set: { _ in toggleSource(source) }
                            )
                        )
                        .disabled(source == .featured && !seerConfigured)
                    }
                }

                if hero.settings.isEnabled(.randomFromLibrary) {
                    SettingsSectionGroup("Random libraries") {
                        if randomEligibleLibraries.isEmpty {
                            Text("No movie or TV libraries are enabled on Home.")
                                .plozzForeground(.secondary)
                        } else {
                            ForEach(randomEligibleLibraries) { library in
                                Toggle(
                                    library.title,
                                    isOn: Binding(
                                        get: {
                                            isRandomLibraryEnabled(library.key)
                                        },
                                        set: { _ in
                                            toggleRandomLibrary(library.key)
                                        }
                                    )
                                )
                            }
                        }
                    } footer: {
                        Text("Leave every library selected to include all enabled libraries.")
                    }
                }
            }

            if hero.settings.isEnabled {
                SettingsSectionGroup("Rotation") {
                    Stepper(
                        "Items: \(hero.settings.maxItems)",
                        value: $hero.settings.maxItems,
                        in: HeroSettings.maxItemsRange
                    )
                    if hero.settings.autoAdvance {
                        Stepper(
                            "Every \(hero.settings.autoAdvanceSeconds) seconds",
                            value: $hero.settings.autoAdvanceSeconds,
                            in: HeroSettings.autoAdvanceRange
                        )
                    }
                }
            }
        }
        .settingsPageSurface()
        .navigationTitle("Customize Home")
        .navigationDestination(item: $selectedLibraryID) { id in
            if let library = libraries.first(where: { $0.id == id }) {
                PlozziOSLibraryHomeSettingsView(library: library, visibility: visibility)
            }
        }
        .task(id: accounts.map(\.account.id)) {
            await loadLibraries()
        }
    }

    private var orderedHeroSources: [HeroSourceKind] {
        HeroSourceKind.allCases.filter { $0 != .featured } + [.featured]
    }

    private var randomEligibleLibraries: [HomeLibraryChoice] {
        libraries.filter {
            ($0.library.kind == .movie || $0.library.kind == .series)
                && visibility.isVisibleOnHome($0.key)
        }
    }

    private func toggleSource(_ source: HeroSourceKind) {
        guard source != .featured || seerConfigured else { return }
        var enabled = Set(hero.settings.sources)
        if enabled.contains(source) {
            enabled.remove(source)
        } else {
            enabled.insert(source)
        }
        hero.settings.sources = HeroSourceKind.allCases.filter(enabled.contains)
    }

    private func isRandomLibraryEnabled(_ key: String) -> Bool {
        let selected = hero.settings.randomLibraryKeys
        return selected.isEmpty || selected.contains(key)
    }

    private func toggleRandomLibrary(_ key: String) {
        let allKeys = Set(randomEligibleLibraries.map(\.key))
        var selected = hero.settings.randomLibraryKeys.isEmpty
            ? allKeys
            : hero.settings.randomLibraryKeys
        if selected.contains(key) {
            selected.remove(key)
        } else {
            selected.insert(key)
        }
        selected.formIntersection(allKeys)
        hero.settings.randomLibraryKeys = selected == allKeys ? [] : selected
    }

    private func loadLibraries() async {
        isLoadingLibraries = true
        defer { isLoadingLibraries = false }
        var loaded: [HomeLibraryChoice] = []
        for resolved in accounts {
            guard let libraries = try? await resolved.provider.libraries() else {
                continue
            }
            loaded.append(
                contentsOf: libraries
                    .filter { !$0.isMusic }
                    .map {
                        HomeLibraryChoice(
                            accountID: resolved.account.id,
                            serverName: resolved.account.server.name,
                            library: $0
                        )
                    }
            )
        }
        libraries = loaded.sorted {
            if $0.serverName != $1.serverName {
                return $0.serverName.localizedStandardCompare($1.serverName)
                    == .orderedAscending
            }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }
}

private struct HomeLibraryChoice: Identifiable {
    let accountID: String
    let serverName: String
    let library: MediaLibrary

    var id: String { key }
    var key: String { "\(accountID):\(library.id)" }
    var title: String { library.title }   // l10n:content — library name from the server
}

private struct PlozziOSLibraryHomeSettingsView: View {
    let library: HomeLibraryChoice
    let visibility: HomeLibraryVisibilityModel

    var body: some View {
        List {
            SettingsSectionGroup {
                Toggle(
                    "Enabled",
                    isOn: Binding(
                        get: { visibility.isEnabled(library.key) },
                        set: { visibility.setEnabled($0, for: library.key) }
                    )
                )
            } footer: {
                Text("Disabled libraries are hidden from Home and library browsing.")
            }

            if !visibility.mergeLibrariesOnHome {
                SettingsSectionGroup("Home rows") {
                    ForEach(LibraryHomeRowKind.allCases, id: \.rawValue) { kind in
                        Toggle(
                            kind.displayName,
                            isOn: Binding(
                                get: {
                                    visibility.isLibraryRowEnabled(
                                        library.key,
                                        kind: kind
                                    )
                                },
                                set: {
                                    visibility.setLibraryRowEnabled(
                                        $0,
                                        libraryKey: library.key,
                                        kind: kind
                                    )
                                }
                            )
                        )
                        .disabled(!visibility.isEnabled(library.key))
                    }
                }
            }
        }
        .settingsPageSurface()
        .navigationTitle(library.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PlozziOSDetailPageSettingsView: View {
    @Bindable var heroBackground: HeroBackgroundSettingsModel
    @Bindable var themeMusic: ThemeMusicSettingsModel

    var body: some View {
        List {
            SettingsSectionGroup("Behind the hero") {
                Picker(
                    "Background",
                    selection: $heroBackground.settings.detailMode
                ) {
                    ForEach(HeroBackgroundMode.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                if heroBackground.settings.detailMode == .trailer {
                    Toggle(
                        "Start muted",
                        isOn: $heroBackground.settings.detailTrailerMuted
                    )
                }
                if heroBackground.settings.detailMode == .themeMusic {
                    Picker(
                        "Theme music volume",
                        selection: $themeMusic.settings.volume
                    ) {
                        ForEach(ThemeMusicVolume.allCases, id: \.self) {
                            Text($0.displayName).tag($0)
                        }
                    }
                }
            } footer: {
                Text("Choose what plays behind the hero on a movie or show's detail page. Trailer and theme music never play together.")
            }
        }
        .settingsPageSurface()
        .navigationTitle("Detail Page")
    }
}

private struct PlozziOSPlaybackSettingsView: View {
    @Environment(\.locale) private var locale
    @Bindable var model: PlaybackSettingsModel
    @Bindable var audioPolicy: AudioPolicyModel

    private static let policyCategories: [ContentCategory] = [.movie, .tvShow, .anime]
    private static let audioOptions: [AudioLanguagePreference] =
        [.original, .device] + SubtitleLanguageCatalog.languages.map {
            .language($0.code)
        }

    var body: some View {
        List {
            SettingsSectionGroup("Skipping") {
                Picker("Intros and credits", selection: $model.settings.skipIntros) {
                    ForEach(SkipIntrosMode.allCases, id: \.self) {
                        Text($0.title).tag($0)
                    }
                }
                Picker("Skip backward", selection: $model.settings.skipBackwardInterval) {
                    ForEach(SkipInterval.allCases, id: \.self) {
                        Text(verbatim: $0.title(locale: locale)).tag($0)
                    }
                }
                Picker("Skip forward", selection: $model.settings.skipForwardInterval) {
                    ForEach(SkipInterval.allCases, id: \.self) {
                        Text(verbatim: $0.title(locale: locale)).tag($0)
                    }
                }
                Picker("Resume rewind", selection: $model.settings.resumeRewindInterval) {
                    ForEach(ResumeRewindInterval.allCases, id: \.self) {
                        Text(verbatim: $0.title(locale: locale)).tag($0)
                    }
                }
            }

            SettingsSectionGroup("Playback") {
                Toggle("Seek without pausing", isOn: $model.settings.seekWithoutPausing)
                Toggle("Show Up Next card", isOn: $model.settings.showUpNextCard)
                if model.settings.showUpNextCard {
                    Picker("Up Next lead time", selection: $model.settings.upNextLeadSeconds) {
                        ForEach(PlaybackSettings.upNextLeadSecondsOptions, id: \.self) {
                            Text("\($0) sec").tag($0)
                        }
                    }
                }
                Toggle(
                    "Sync watch state across servers",
                    isOn: $model.settings.syncWatchAcrossServers
                )
            }

            SettingsSectionGroup(LocalizedStringResource(
                "settings.section.tracks",
                defaultValue: "Tracks",
                comment: "Settings section for default audio and subtitle track selection. Media streams inside a video file, not music tracks."
            )) {
                Picker("Preferred audio", selection: $model.settings.audioLanguagePreference) {
                    ForEach(Self.audioOptions, id: \.self) { preference in
                        audioName(preference).tag(preference)
                    }
                }
                Toggle("Different default per type", isOn: audioOverridesEnabled)
                if !audioPolicy.overrides.isEmpty {
                    ForEach(Self.policyCategories, id: \.self) { category in
                        Picker(
                            category.displayName,
                            selection: audioBinding(for: category)
                        ) {
                            ForEach(Self.audioOptions, id: \.self) { preference in
                                audioName(preference).tag(preference)
                            }
                        }
                    }
                }
                Toggle(
                    "Remember audio per series",
                    isOn: $model.settings.rememberAudioTrackPerSeries
                )
                Toggle(
                    "Remember subtitles per series",
                    isOn: $model.settings.rememberSubtitleTrackPerSeries
                )
            }
        }
        .settingsPageSurface()
        .navigationTitle("Playback")
    }

    private var audioOverridesEnabled: Binding<Bool> {
        Binding(
            get: { !audioPolicy.overrides.isEmpty },
            set: {
                audioPolicy.overrides = $0
                    ? AudioPolicy.smartDefaultOverrides()
                    : [:]
            }
        )
    }

    private func audioBinding(
        for category: ContentCategory
    ) -> Binding<AudioLanguagePreference> {
        Binding(
            get: {
                audioPolicy.overrides[category]
                    ?? model.settings.audioLanguagePreference
            },
            set: { audioPolicy.overrides[category] = $0 }
        )
    }

    private func audioName(_ preference: AudioLanguagePreference) -> Text {
        switch preference {
        case .original:
            return Text("Original language")
        case .device:
            return Text("Device language")
        case .language(let code):
            return Text(
                verbatim: SubtitleLanguageCatalog.displayName(
                    forCode: code,
                    in: locale
                ) ?? code
            )
        }
    }
}

private struct PlozziOSSubtitleSettingsView: View {
    @Bindable var behavior: SubtitleBehaviorModel
    @Bindable var policy: SubtitlePolicyModel
    @Bindable var style: SubtitleStyleModel

    private static let policyCategories: [SubtitleContentCategory] =
        [.movie, .tvShow, .anime]

    var body: some View {
        List {
            SettingsSectionGroup("Appearance") {
                Toggle("Follow system style", isOn: $style.style.followsSystemStyle)
                Picker("Font", selection: $style.style.fontFamily) {
                    ForEach(SubtitleFontFamily.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                Picker("Weight", selection: $style.style.fontWeight) {
                    ForEach(style.style.fontFamily.availableWeights, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                LabeledContent("Size") {
                    Slider(value: $style.style.fontScale, in: 0.6...2.0)
                        .frame(maxWidth: 360)
                }
                LabeledContent("Opacity") {
                    Slider(value: $style.style.opacity, in: 0.2...1.0)
                        .frame(maxWidth: 360)
                }
                Toggle("Background", isOn: $style.style.background.isEnabled)
            }

            SettingsSectionGroup("Behavior") {
                Picker("Automatic subtitles", selection: $behavior.settings.subtitleMode) {
                    ForEach(SubtitleMode.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                    Toggle("Different default per type", isOn: subtitleOverridesEnabled)
                    if !policy.overrides.isEmpty {
                        ForEach(Self.policyCategories, id: \.self) { category in
                            Picker(category.displayName, selection: modeBinding(for: category)) {
                                ForEach(SubtitleMode.allCases, id: \.self) {
                                    Text($0.displayName).tag($0)
                                }
                            }
                        }
                    }
                }
                Toggle(
                    "Download subtitles automatically",
                    isOn: $behavior.settings.autoDownloadSubtitles
                )
                TextField(
                    "Preferred language code",
                    text: Binding(
                        get: { behavior.settings.preferredSubtitleLanguage ?? "" },
                        set: {
                            behavior.settings.preferredSubtitleLanguage =
                                $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? nil
                                : $0
                        }
                    )
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            }

            SettingsSectionGroup("Subtitle search") {
                Picker(
                    "Hearing impaired",
                    selection: $behavior.settings.hearingImpairedPreference
                ) {
                    ForEach(HearingImpairedPreference.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                Picker(
                    "Forced subtitles",
                    selection: $behavior.settings.forcedSearchPreference
                ) {
                    ForEach(ForcedSubtitlePreference.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
            }
        }
        .settingsPageSurface()
        .navigationTitle("Subtitles")
    }

    private var baseRule: SubtitlePolicy.Rule {
        SubtitlePolicy.inheriting(from: behavior.settings).basePolicy
    }

    private var subtitleOverridesEnabled: Binding<Bool> {
        Binding(
            get: { !policy.overrides.isEmpty },
            set: {
                policy.overrides = $0
                    ? SubtitlePolicy.smartDefaultOverrides(base: baseRule)
                    : [:]
            }
        )
    }

    private func modeBinding(
        for category: SubtitleContentCategory
    ) -> Binding<SubtitleMode> {
        Binding(
            get: { policy.overrides[category]?.mode ?? baseRule.mode },
            set: {
                var rule = policy.overrides[category] ?? baseRule
                rule.mode = $0
                policy.overrides[category] = rule
            }
        )
    }
}

private struct PlozziOSSpoilerSettingsView: View {
    @Bindable var model: SpoilerSettingsModel

    var body: some View {
        List {
            SettingsSectionGroup {
                Toggle("Protect unwatched episodes", isOn: $model.settings.isEnabled)
                Picker("Thumbnail treatment", selection: $model.settings.mode) {
                    ForEach(SpoilerSettings.Mode.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                .disabled(!model.settings.isEnabled)
                Toggle(
                    "Hide ratings until watched",
                    isOn: $model.settings.hideRatingsUntilWatched
                )
            } footer: {
                Text("Episode titles, summaries, and artwork can be hidden until you watch them.")
            }
        }
        .settingsPageSurface()
        .navigationTitle("Spoilers")
    }
}

private struct PlozziOSNightShiftSettingsView: View {
    @Bindable var model: NightShiftSettingsModel
    @Environment(\.locale) private var locale

    var body: some View {
        List {
            SettingsSectionGroup {
                Toggle("Circadian Mode", isOn: $model.settings.isEnabled)
                Picker("Schedule", selection: $model.settings.scheduleMode) {
                    ForEach(NightShiftScheduleMode.allCases) {
                        Text($0.displayName).tag($0)
                    }
                }
                .disabled(!model.settings.isEnabled)

                if model.settings.isEnabled {
                    scheduleDetails
                }
            } footer: {
                Text(model.scheduleSummary(locale: locale))
            }

            if model.settings.isEnabled {
                SettingsSectionGroup("Picture") {
                    Picker("Warmth", selection: $model.settings.warmth) {
                        ForEach(NightShiftWarmth.allCases) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    Picker("Dimness", selection: $model.settings.dimness) {
                        ForEach(NightShiftDimness.allCases) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    if model.settings.scheduleMode != .alwaysOn {
                        Picker("Fade", selection: $model.settings.fadeMinutes) {
                            ForEach(fadeOptions, id: \.self) { minutes in
                                Text(fadeLabel(minutes))
                                    .tag(minutes)
                            }
                        }
                    }
                }

                SettingsSectionGroup("Preview") {
                    Toggle("Preview at Full Strength", isOn: $model.isPreviewing)
                    Button("Preview a Day", systemImage: "sun.and.horizon") {
                        model.runDayNightPreview()
                    }
                    if model.previewProgress != nil {
                        LabeledContent("Simulated time") {
                            Text(model.previewClockText)
                                .monospacedDigit()
                        }
                        ProgressView(value: model.previewProgress ?? 0)
                    }
                }
            }
        }
        .settingsPageSurface()
        .navigationTitle("Circadian Mode")
        .onChange(of: model.settings.isEnabled) { _, enabled in
            if !enabled {
                model.isPreviewing = false
            }
        }
        .onDisappear {
            model.isPreviewing = false
        }
    }

    @ViewBuilder
    private var scheduleDetails: some View {
        switch model.settings.scheduleMode {
        case .solar:
            Picker("Location", selection: $model.settings.regionID) {
                ForEach(NightShiftRegion.sortedCatalog) { region in
                    Text(region.name).tag(region.id)
                }
            }
        case .manual:
            DatePicker(
                "Turns on",
                selection: timeBinding(for: \.manualOnMinutes),
                displayedComponents: .hourAndMinute
            )
            DatePicker(
                "Turns off",
                selection: timeBinding(for: \.manualOffMinutes),
                displayedComponents: .hourAndMinute
            )
        case .alwaysOn:
            EmptyView()
        }
    }

    private func timeBinding(
        for keyPath: WritableKeyPath<NightShiftSettings, Int>
    ) -> Binding<Date> {
        Binding(
            get: {
                let minutes = model.settings[keyPath: keyPath]
                var components = DateComponents()
                components.year = 2001
                components.month = 1
                components.day = 1
                components.hour = minutes / 60
                components.minute = minutes % 60
                return Calendar.current.date(from: components) ?? Date()
            },
            set: { date in
                let components = Calendar.current.dateComponents(
                    [.hour, .minute],
                    from: date
                )
                model.settings[keyPath: keyPath] =
                    (components.hour ?? 0) * 60 + (components.minute ?? 0)
            }
        )
    }

    private var fadeOptions: [Int] {
        Array(
            Set(
                NightShiftSettingsModel.fadeOptions
                    + [model.settings.fadeMinutes]
            )
        )
        .sorted()
    }

    private func fadeLabel(_ minutes: Int) -> String {
        minutes == 0
            ? "Off"
            : NightShiftSettingsModel.fadeLabel(minutes: minutes)
    }
}

private struct PlozziOSAttributionsView: View {
    var body: some View {
        List {
            Text(PlozzAttributions.introduction)
                .font(.footnote)
                .plozzForeground(.secondary)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            ForEach(PlozzAttributions.entries) { entry in
                SettingsSectionGroup(verbatim: entry.title) {
                    Text(verbatim: entry.detail)
                    if !entry.licenses.isEmpty {
                        PlozziOSLicenseBadges(licenses: entry.licenses)
                    }
                }
            }
        }
        .settingsPageSurface()
        .navigationTitle("Attributions")
    }
}

private struct PlozziOSLicenseBadges: View {
    let licenses: [PlozzAttributionLicense]

    var body: some View {
        HStack {
            ForEach(licenses) { license in
                Text(license.label)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.tint.opacity(0.14), in: Capsule())
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(licenses.map(\.label).joined(separator: ", "))
    }
}
#endif
